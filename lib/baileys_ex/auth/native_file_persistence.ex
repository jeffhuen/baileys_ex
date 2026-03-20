defmodule BaileysEx.Auth.NativeFilePersistence do
  @moduledoc """
  Recommended durable auth persistence for Elixir-first deployments.

  This backend stores credentials and Signal keys as ETF on disk with crash-safe
  writes. Use `BaileysEx.Auth.FilePersistence` when you need the
  Baileys-compatible JSON multi-file helper instead.

  Switching an existing linked device from the compatibility JSON backend to
  this backend is explicit. Use `BaileysEx.Auth.PersistenceMigration` to
  preserve the current session, or re-pair on a fresh native directory.

  The built-in file lock here is `:global.trans`, which coordinates file access
  inside one BEAM cluster. Treat one auth directory as owned by one runtime at a
  time; this module is not a distributed storage protocol.
  """

  @behaviour BaileysEx.Auth.Persistence

  alias BaileysEx.Auth.KeyStore
  alias BaileysEx.Auth.Persistence
  alias BaileysEx.Auth.PersistenceHelpers
  alias BaileysEx.Auth.PersistenceIO
  alias BaileysEx.Auth.State

  @default_dir "baileys_native_auth_info"
  @manifest_file ".baileys_ex_native_file_persistence.etf"
  @backend_id "native_file_persistence"
  @format_version 1
  @persisted_key_types [
    :session,
    :"pre-key",
    :"sender-key",
    :"sender-key-memory",
    :"app-state-sync-key",
    :"app-state-sync-version",
    :"lid-mapping",
    :"device-list",
    :tctoken,
    :"identity-key"
  ]
  @key_type_prefixes @persisted_key_types
                     |> Enum.map(fn type -> {type, "#{Atom.to_string(type)}-"} end)
                     |> Enum.sort_by(fn {_type, prefix} -> -byte_size(prefix) end)

  @doc """
  Loads the auth state and returns the runtime options for the built-in
  file-backed Signal store using the durable native backend.
  """
  @spec use_native_file_auth_state(Path.t()) ::
          {:ok, Persistence.auth_state_helper()} | {:error, term()}
  def use_native_file_auth_state(path \\ default_path()) when is_binary(path) do
    with {:ok, %State{} = state} <- load_credentials(path) do
      {:ok,
       %{
         state: state,
         connect_opts: [
           signal_store_module: KeyStore,
           signal_store_opts: [persistence_module: __MODULE__, persistence_context: path]
         ],
         save_creds: &save_credentials(path, normalize_credentials_state(&1))
       }}
    end
  end

  @doc """
  Loads the core credentials state from the default configured directory.
  """
  @spec load_credentials() :: {:ok, State.t()} | {:error, term()}
  def load_credentials, do: load_credentials(default_path())

  @doc """
  Loads the core credentials state from the given path.
  """
  @spec load_credentials(Path.t()) :: {:ok, State.t()} | {:error, term()}
  def load_credentials(path) when is_binary(path) do
    with :ok <- ensure_directory(path),
         :ok <- validate_manifest(path) do
      case read_term(path, "creds.etf") do
        {:ok, nil} ->
          {:ok, State.new()}

        {:ok, %State{} = state} ->
          {:ok, state}

        {:ok, %{} = fields} ->
          {:ok, struct(State, fields)}

        {:ok, other} ->
          {:error, {:invalid_credentials_data, other}}

        {:error, _reason} = error ->
          error
      end
    end
  end

  @doc """
  Saves the core credentials state into the default directory.
  """
  @spec save_credentials(State.t()) :: :ok | {:error, term()}
  def save_credentials(%State{} = state), do: save_credentials(default_path(), state)

  @doc """
  Saves the core credentials state into the given directory path.
  """
  @spec save_credentials(Path.t(), State.t()) :: :ok | {:error, term()}
  def save_credentials(path, %State{} = state) when is_binary(path) do
    with :ok <- ensure_directory(path),
         :ok <- validate_manifest(path),
         :ok <- write_term(path, "creds.etf", state) do
      ensure_manifest(path)
    end
  end

  @doc """
  Loads a Signal key record by type and ID from the default directory.
  """
  @spec load_keys(atom(), term()) :: {:ok, term()} | {:error, term()}
  def load_keys(type, id), do: load_keys(default_path(), type, id)

  @doc """
  Loads a Signal key record by type and ID from the given directory.
  """
  @spec load_keys(Path.t(), atom(), term()) :: {:ok, term()} | {:error, term()}
  def load_keys(path, type, id) when is_binary(path) and is_atom(type) do
    with :ok <- ensure_directory(path),
         :ok <- validate_manifest(path) do
      case read_term(path, data_file_name(type, id)) do
        {:ok, nil} -> {:error, :not_found}
        {:ok, value} -> {:ok, value}
        {:error, _reason} = error -> error
      end
    end
  end

  @doc """
  Saves a Signal key record by type and ID into the default directory.
  """
  @spec save_keys(atom(), term(), term()) :: :ok | {:error, term()}
  def save_keys(type, id, data), do: save_keys(default_path(), type, id, data)

  @doc """
  Saves a Signal key record by type and ID into the specified directory.
  """
  @spec save_keys(Path.t(), atom(), term(), term()) :: :ok | {:error, term()}
  def save_keys(path, type, id, data) when is_binary(path) and is_atom(type) do
    with :ok <- ensure_directory(path),
         :ok <- validate_manifest(path),
         :ok <- write_term(path, data_file_name(type, id), data) do
      upsert_manifest_key(path, type, id)
    end
  end

  @doc """
  Deletes a Signal key record by type and ID from the default directory.
  """
  @spec delete_keys(atom(), term()) :: :ok | {:error, term()}
  def delete_keys(type, id), do: delete_keys(default_path(), type, id)

  @doc """
  Deletes a Signal key record by type and ID from the specified directory.
  """
  @spec delete_keys(Path.t(), atom(), term()) :: :ok | {:error, term()}
  def delete_keys(path, type, id) when is_binary(path) and is_atom(type) do
    with :ok <- ensure_directory(path),
         :ok <- validate_manifest(path),
         :ok <- remove_term(path, data_file_name(type, id)) do
      remove_manifest_key(path, type, id)
    end
  end

  @doc false
  @spec list_persisted_keys(Path.t()) ::
          {:ok, %{optional(atom()) => [String.t()]}} | {:error, term()}
  def list_persisted_keys(path) when is_binary(path) do
    with :ok <- ensure_directory(path),
         {:ok, manifest} <- read_manifest(path),
         {:ok, scanned} <- scan_persisted_keys(path) do
      {:ok, PersistenceHelpers.merge_key_indexes(manifest_key_index(manifest), scanned)}
    end
  end

  defp default_path do
    Application.get_env(:baileys_ex, __MODULE__, [])
    |> Keyword.get(:path, Path.join(File.cwd!(), @default_dir))
  end

  defp ensure_directory(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp data_file_name(type, id) do
    "#{Atom.to_string(type)}-#{id}.etf"
    |> sanitize_file_name()
  end

  defp manifest_path(path), do: Path.join(path, @manifest_file)

  defp ensure_manifest(path) do
    update_manifest(path, & &1)
  end

  defp upsert_manifest_key(path, type, id) do
    id = persisted_id(id)

    update_manifest(path, fn manifest ->
      update_in(manifest, ["key_index", Atom.to_string(type)], fn
        nil -> [id]
        ids -> [id | ids] |> Enum.uniq() |> Enum.sort()
      end)
    end)
  end

  defp remove_manifest_key(path, type, id) do
    case read_manifest(path) do
      {:ok, nil} ->
        :ok

      {:ok, _manifest} ->
        update_manifest(path, &drop_manifest_key(&1, type, persisted_id(id)))

      {:error, _reason} = error ->
        error
    end
  end

  defp validate_manifest(path) do
    case read_manifest(path) do
      {:ok, _manifest} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp read_manifest(path) do
    manifest_path = manifest_path(path)

    case File.read(manifest_path) do
      {:ok, contents} ->
        decode_manifest(contents)

      {:error, :enoent} ->
        {:ok, nil}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error in [ArgumentError] -> {:error, {:invalid_persistence_metadata, __MODULE__, error}}
  end

  defp update_manifest(path, updater_fun) when is_function(updater_fun, 1) do
    manifest_path = manifest_path(path)

    with_file_lock(manifest_path, fn ->
      case read_manifest(path) do
        {:ok, manifest} ->
          updated_manifest =
            manifest
            |> manifest_or_default()
            |> updater_fun.()
            |> normalize_manifest_shape()

          write_manifest(manifest_path, updated_manifest)

        {:error, _reason} = error ->
          error
      end
    end)
  end

  defp decode_manifest(contents) do
    contents
    |> :erlang.binary_to_term([:safe])
    |> normalize_manifest()
  end

  defp write_manifest(manifest_path, manifest) do
    encoded = :erlang.term_to_binary(manifest)
    PersistenceIO.atomic_write(manifest_path, encoded)
  end

  defp normalize_manifest(nil), do: {:ok, nil}

  defp normalize_manifest(%{"backend" => @backend_id, "version" => @format_version} = manifest) do
    {:ok, normalize_manifest_shape(manifest)}
  end

  defp normalize_manifest(%{"backend" => @backend_id, "version" => version})
       when is_integer(version) do
    {:error, {:unsupported_persistence_version, __MODULE__, version}}
  end

  defp normalize_manifest(%{"backend" => backend}) when is_binary(backend) do
    {:error, {:unexpected_persistence_backend, __MODULE__, backend}}
  end

  defp normalize_manifest(other), do: {:error, {:invalid_persistence_metadata, __MODULE__, other}}

  defp normalize_manifest_shape(manifest) do
    %{
      "backend" => @backend_id,
      "version" => @format_version,
      "key_index" => normalize_manifest_key_index(Map.get(manifest, "key_index", %{}))
    }
  end

  defp normalize_manifest_key_index(index) when is_map(index) do
    Enum.reduce(index, %{}, fn {type, ids}, acc ->
      case key_type_from_string(type) do
        {:ok, _known_type} ->
          normalized_ids =
            ids
            |> List.wrap()
            |> Enum.filter(&is_binary/1)
            |> Enum.uniq()
            |> Enum.sort()

          Map.put(acc, type, normalized_ids)

        :error ->
          acc
      end
    end)
  end

  defp normalize_manifest_key_index(_other), do: %{}

  defp manifest_or_default(nil), do: normalize_manifest_shape(%{})
  defp manifest_or_default(manifest), do: manifest

  defp drop_manifest_key(manifest, type, id) do
    update_in(manifest, ["key_index", Atom.to_string(type)], fn
      nil -> nil
      ids -> ids |> Enum.reject(&(&1 == id)) |> Enum.sort()
    end)
  end

  defp manifest_key_index(nil), do: %{}

  defp manifest_key_index(%{"key_index" => index}) do
    Enum.reduce(index, %{}, fn {type, ids}, acc ->
      case key_type_from_string(type) do
        {:ok, known_type} -> Map.put(acc, known_type, ids)
        :error -> acc
      end
    end)
  end

  defp scan_persisted_keys(path) do
    case File.ls(path) do
      {:ok, entries} ->
        {:ok, Enum.reduce(entries, %{}, &accumulate_persisted_entry/2)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_persisted_entry("creds.etf"), do: :ignore
  defp decode_persisted_entry(@manifest_file), do: :ignore
  defp decode_persisted_entry(entry) when not is_binary(entry), do: :ignore

  defp decode_persisted_entry(entry) do
    if String.ends_with?(entry, ".etf") and not String.contains?(entry, ".tmp-") do
      entry
      |> String.trim_trailing(".etf")
      |> decode_persisted_name()
    else
      :ignore
    end
  end

  defp decode_persisted_name(persisted_name) do
    case Enum.find(@key_type_prefixes, fn {_type, prefix} ->
           String.starts_with?(persisted_name, prefix)
         end) do
      nil ->
        :ignore

      {type, prefix} ->
        id = persisted_name |> String.replace_prefix(prefix, "") |> restore_legacy_id(type)
        {:ok, type, id}
    end
  end

  defp accumulate_persisted_entry(entry, acc) do
    case decode_persisted_entry(entry) do
      {:ok, type, id} ->
        Map.update(acc, type, [id], fn ids -> Enum.sort(Enum.uniq([id | ids])) end)

      :ignore ->
        acc
    end
  end

  defp restore_legacy_id(encoded_id, :"sender-key") do
    restored = String.replace(encoded_id, "__", "/")

    case Regex.run(~r/^(.*)--([^-]+)--(\d+)$/, restored, capture: :all_but_first) do
      [group_id, sender, device_id] -> "#{group_id}::#{sender}::#{device_id}"
      _ -> restored
    end
  end

  defp restore_legacy_id(encoded_id, _type), do: String.replace(encoded_id, "__", "/")

  defp key_type_from_string(type) when is_binary(type) do
    case Enum.find(@persisted_key_types, &(Atom.to_string(&1) == type)) do
      nil -> :error
      key_type -> {:ok, key_type}
    end
  end

  defp persisted_id(id), do: to_string(id)

  defp sanitize_file_name(file_name) do
    file_name
    |> String.replace("/", "__")
    |> String.replace(":", "-")
  end

  defp read_term(path, file_name) do
    file_path = Path.join(path, sanitize_file_name(file_name))

    with_file_lock(file_path, fn ->
      case File.read(file_path) do
        {:ok, contents} ->
          {:ok, :erlang.binary_to_term(contents, [:safe])}

        {:error, :enoent} ->
          {:ok, nil}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  rescue
    error in [ArgumentError] -> {:error, error}
  end

  defp write_term(path, file_name, data) do
    file_path = Path.join(path, sanitize_file_name(file_name))

    with_file_lock(file_path, fn ->
      encoded = :erlang.term_to_binary(data)
      PersistenceIO.atomic_write(file_path, encoded)
    end)
  end

  defp remove_term(path, file_name) do
    file_path = Path.join(path, sanitize_file_name(file_name))

    with_file_lock(file_path, fn ->
      case File.rm(file_path) do
        :ok ->
          PersistenceIO.sync_parent_directory(file_path)

        {:error, :enoent} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  defp with_file_lock(file_path, fun) do
    :global.trans({__MODULE__, file_path}, fun)
  end

  defp normalize_credentials_state(%State{} = state), do: state

  defp normalize_credentials_state(%{} = state) do
    state
    |> State.creds_view()
    |> then(&struct(State, &1))
  end

  defp normalize_credentials_state(_state), do: State.new()
end
