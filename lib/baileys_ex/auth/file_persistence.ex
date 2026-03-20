defmodule BaileysEx.Auth.FilePersistence do
  @moduledoc """
  Baileys-compatible multi-file auth persistence mirroring `useMultiFileAuthState`.

  Use `BaileysEx.Auth.NativeFilePersistence` for the recommended durable file
  backend in Elixir-first applications. Use this module when you need the
  Baileys-shaped JSON file layout and helper semantics.

  Treat this backend as a compatibility bridge for migrating existing
  Baileys JS sidecar deployments onto BaileysEx. It is intentionally kept
  separate from the native durable backend so the Elixir-first path can remain
  idiomatic, and it can be retired in a future major release once users no
  longer depend on the Baileys JSON helper contract.

  This module does not migrate existing auth directories automatically. If you
  switch an existing linked device from this backend to the native backend,
  migrate once with `BaileysEx.Auth.PersistenceMigration` or re-pair on the new
  backend.

  The built-in file lock here is `:global.trans`, which coordinates file access
  inside one BEAM cluster. Treat one auth directory as owned by one runtime at a
  time; this module is not a distributed storage protocol.
  """

  @behaviour BaileysEx.Auth.Persistence

  alias BaileysEx.Auth.KeyStore
  alias BaileysEx.Auth.PersistenceHelpers
  alias BaileysEx.Auth.PersistenceIO
  alias BaileysEx.Auth.State
  alias BaileysEx.Protocol.Proto.ADVSignedDeviceIdentity
  alias BaileysEx.Protocol.Proto.MessageKey
  alias BaileysEx.Signal.Group.SenderChainKey
  alias BaileysEx.Signal.Group.SenderKeyRecord
  alias BaileysEx.Signal.Group.SenderKeyState
  alias BaileysEx.Signal.Group.SenderMessageKey
  alias BaileysEx.Signal.SessionRecord

  @buffer_tag "Buffer"
  @default_dir "baileys_auth_info"
  @manifest_file ".baileys_ex_file_persistence.json"
  @backend_id "file_persistence"
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

  # ## Why explicit compatibility codecs exist
  #
  # This backend mirrors Baileys' JSON multi-file auth helper, so the on-disk format
  # must stay JSON and keep BufferJSON-style binary tagging. The runtime state on the
  # Elixir side still uses atoms, structs, and binary map keys, but those are BEAM
  # implementation details, not compatibility promises.
  #
  # The write path therefore uses explicit family-specific JSON codecs instead of a
  # generic Elixir term serializer. That keeps the compatibility files predictable:
  # string keys on disk, BufferJSON base64 for binary fields, and explicit string
  # enums for values like `"pn"` / `"lid"` and `"sending"` / `"receiving"`.
  #
  # The legacy tagged-term decoder remains only as a read fallback for already-shipped
  # auth directories until the phase's migration tooling fully replaces it.
  #
  # ## What still needs manual updates
  #
  # New persisted atom-backed fields or enums still need codec updates here, because
  # JSON itself has no atom type and we intentionally do not roundtrip arbitrary
  # Elixir terms through the compatibility helper.
  #
  # ## IMPORTANT: when you hit a compatibility persistence regression
  #
  # If code elsewhere starts persisting a new auth/session field or enum, you MUST:
  #
  # 1. Add it to the relevant explicit encoder/decoder below
  # 2. Extend the compatibility/fresh-VM regressions in the file persistence tests
  #
  # The tests prove both the on-disk JSON shape and the fresh-VM runtime decode path.
  @empty_decode_context %{atoms: %{}, modules: %{}}

  @credential_decode_context %{
    atoms:
      State.__struct__()
      |> Map.keys()
      |> Enum.reject(&(&1 == :__struct__))
      |> Kernel.++(
        ADVSignedDeviceIdentity.__struct__()
        |> Map.keys()
        |> Enum.reject(&(&1 == :__struct__))
      )
      |> Kernel.++(
        MessageKey.__struct__()
        |> Map.keys()
        |> Enum.reject(&(&1 == :__struct__))
      )
      |> Kernel.++([
        :public,
        :private,
        :key_pair,
        :key_id,
        :signature,
        :identifier,
        :identifier_key,
        :name,
        :device_id,
        :lid,
        :key,
        :message_timestamp,
        :unarchive_chats,
        :default_disappearing_mode,
        # processed_history_messages message key atoms
        :id,
        :remote_jid,
        :remote_jid_alt,
        :participant,
        :participant_alt,
        :from_me,
        :addressing_mode,
        :server_id,
        # addressing_mode atom values
        :pn,
        :lid
      ])
      |> Enum.uniq()
      |> Map.new(&{Atom.to_string(&1), &1}),
    modules:
      [State, ADVSignedDeviceIdentity, MessageKey]
      |> Map.new(&{Atom.to_string(&1), &1})
  }

  @session_decode_context %{
    atoms:
      SessionRecord.__struct__()
      |> Map.keys()
      |> Enum.reject(&(&1 == :__struct__))
      |> Kernel.++([
        :current_ratchet,
        :root_key,
        :ephemeral_key_pair,
        :public,
        :private,
        :last_remote_ephemeral,
        :previous_counter,
        :index_info,
        :remote_identity_key,
        :local_identity_key,
        :base_key,
        :base_key_type,
        :closed,
        :chains,
        :pending_pre_key,
        :registration_id,
        :chain_key,
        :counter,
        :key,
        :chain_type,
        :message_keys,
        :pre_key_id,
        :signed_pre_key_id,
        :sending,
        :receiving
      ])
      |> Enum.uniq()
      |> Map.new(&{Atom.to_string(&1), &1}),
    modules:
      [SessionRecord]
      |> Map.new(&{Atom.to_string(&1), &1})
  }

  @sender_key_decode_context %{
    atoms:
      SenderKeyRecord.__struct__()
      |> Map.keys()
      |> Enum.reject(&(&1 == :__struct__))
      |> Kernel.++(
        SenderKeyState.__struct__()
        |> Map.keys()
        |> Enum.reject(&(&1 == :__struct__))
      )
      |> Kernel.++(
        SenderChainKey.__struct__()
        |> Map.keys()
        |> Enum.reject(&(&1 == :__struct__))
      )
      |> Kernel.++(
        SenderMessageKey.__struct__()
        |> Map.keys()
        |> Enum.reject(&(&1 == :__struct__))
      )
      |> Kernel.++([:public, :private])
      |> Enum.uniq()
      |> Map.new(&{Atom.to_string(&1), &1}),
    modules:
      [SenderKeyRecord, SenderKeyState, SenderChainKey, SenderMessageKey]
      |> Map.new(&{Atom.to_string(&1), &1})
  }

  @pre_key_decode_context %{
    atoms: %{Atom.to_string(:public) => :public, Atom.to_string(:private) => :private},
    modules: %{}
  }

  @app_state_sync_key_decode_context %{
    atoms: %{Atom.to_string(:key_data) => :key_data},
    modules: %{}
  }

  @app_state_sync_version_decode_context %{
    atoms:
      [:version, :hash, :index_value_map, :value_mac]
      |> Map.new(&{Atom.to_string(&1), &1}),
    modules: %{}
  }

  @tc_token_decode_context %{
    atoms:
      [:token, :timestamp]
      |> Map.new(&{Atom.to_string(&1), &1}),
    modules: %{}
  }

  @typedoc """
  Helper map returned by `use_multi_file_auth_state/1`.

  `connect_opts` is ready to merge into `BaileysEx.connect/2`, and `save_creds`
  persists the latest auth-state snapshot back into the Baileys-compatible JSON
  directory.
  """
  @type multi_file_auth_state :: %{
          required(:state) => State.t(),
          required(:connect_opts) => keyword(),
          required(:save_creds) => (State.t() | map() -> :ok | {:error, term()})
        }

  @doc """
  Loads the auth state and returns the runtime options needed to mirror
  Baileys' multi-file auth helper with the built-in file-backed Signal store.
  """
  @spec use_multi_file_auth_state(Path.t()) ::
          {:ok, multi_file_auth_state()} | {:error, term()}
  def use_multi_file_auth_state(path \\ default_path()) when is_binary(path) do
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
      case read_data(path, "creds.json", &decode_credentials/1) do
        {:ok, nil} ->
          {:ok, State.new()}

        {:ok, %State{} = state} ->
          {:ok, state}

        {:ok, decoded} when is_map(decoded) ->
          {:ok, struct(State, decoded)}

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
    with :ok <- validate_additional_data(state.additional_data),
         :ok <- ensure_directory(path),
         :ok <- validate_manifest(path),
         :ok <- write_data(path, "creds.json", state, &encode_credentials/1) do
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
      file_name = data_file_name(type, id)

      case read_data(path, file_name, &decode_key_data(type, &1)) do
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
         :ok <- write_data(path, data_file_name(type, id), data, &encode_key_data(type, &1)) do
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
         :ok <- remove_data(path, data_file_name(type, id)) do
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

  defp validate_additional_data(nil), do: :ok
  defp validate_additional_data(data), do: validate_json_safe(data, [:additional_data])

  defp validate_json_safe(nil, _path), do: :ok
  defp validate_json_safe(value, _path) when is_binary(value), do: :ok
  defp validate_json_safe(value, _path) when is_number(value), do: :ok
  defp validate_json_safe(value, _path) when is_boolean(value), do: :ok

  defp validate_json_safe(list, path) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {item, i}, :ok ->
      case validate_json_safe(item, [i | path]) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_json_safe(map, path) when is_map(map) do
    Enum.reduce_while(map, :ok, fn {key, value}, :ok ->
      with :ok <- validate_json_safe_key(key, path),
           :ok <- validate_json_safe(value, [key | path]) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp validate_json_safe(value, path) do
    {:error,
     {:invalid_additional_data,
      "additional_data contains a #{type_name(value)} at path #{inspect(Enum.reverse(path))}; " <>
        "only strings, numbers, booleans, lists, and string-keyed maps are supported"}}
  end

  defp validate_json_safe_key(key, _path) when is_binary(key), do: :ok

  defp validate_json_safe_key(key, path) do
    {:error,
     {:invalid_additional_data,
      "additional_data contains a #{type_name(key)} map key at path #{inspect(Enum.reverse(path))}; " <>
        "only string keys are supported"}}
  end

  defp type_name(value) when is_atom(value), do: "atom (#{inspect(value)})"
  defp type_name(value) when is_tuple(value), do: "tuple"
  defp type_name(value) when is_pid(value), do: "pid"
  defp type_name(value) when is_reference(value), do: "reference"
  defp type_name(value) when is_function(value), do: "function"
  defp type_name(_value), do: "unsupported term"

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
    "#{Atom.to_string(type)}-#{id}.json"
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
        decode_manifest_json(contents)

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

  defp write_manifest(manifest_path, manifest) do
    PersistenceIO.atomic_write(manifest_path, JSON.encode!(manifest))
  rescue
    error in [ArgumentError] -> {:error, {:invalid_persistence_metadata, __MODULE__, error}}
  end

  defp decode_manifest_json(contents) do
    case JSON.decode(contents) do
      {:ok, decoded} ->
        normalize_manifest(decoded)

      {:error, error} ->
        {:error, {:invalid_persistence_metadata, __MODULE__, error}}
    end
  rescue
    error in [ArgumentError] -> {:error, {:invalid_persistence_metadata, __MODULE__, error}}
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

  defp decode_persisted_entry("creds.json"), do: :ignore
  defp decode_persisted_entry(@manifest_file), do: :ignore
  defp decode_persisted_entry(entry) when not is_binary(entry), do: :ignore

  defp decode_persisted_entry(entry) do
    if String.ends_with?(entry, ".json") and not String.contains?(entry, ".tmp-") do
      entry
      |> String.trim_trailing(".json")
      |> decode_persisted_name()
    else
      :ignore
    end
  end

  defp decode_persisted_name(persisted_name) do
    case Enum.find(@key_type_prefixes, fn {_type, prefix} ->
           String.starts_with?(persisted_name, prefix)
         end) do
      {type, prefix} ->
        id = persisted_name |> String.replace_prefix(prefix, "") |> restore_legacy_id(type)
        {:ok, type, id}

      nil ->
        :ignore
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

  defp read_data(path, file_name, decoder_fun) do
    file_path = Path.join(path, sanitize_file_name(file_name))

    with_file_lock(file_path, fn ->
      case File.read(file_path) do
        {:ok, contents} ->
          case JSON.decode(contents) do
            {:ok, decoded} -> {:ok, decoder_fun.(decoded)}
            {:error, error} -> {:error, error}
          end

        {:error, :enoent} ->
          {:ok, nil}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  rescue
    error in [ArgumentError] -> {:error, error}
  end

  defp write_data(path, file_name, data, encoder_fun) do
    file_path = Path.join(path, sanitize_file_name(file_name))

    with_file_lock(file_path, fn ->
      encoded = data |> encoder_fun.() |> JSON.encode!()
      PersistenceIO.atomic_write(file_path, encoded, fsync?: false, sync_parent?: false)
    end)
  rescue
    error in [ArgumentError] -> {:error, error}
  end

  defp remove_data(path, file_name) do
    file_path = Path.join(path, sanitize_file_name(file_name))

    with_file_lock(file_path, fn ->
      case File.rm(file_path) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp with_file_lock(file_path, fun) do
    :global.trans({__MODULE__, file_path}, fun)
  end

  defp encode_credentials(%State{} = state) do
    %{
      "account" => encode_optional(state.account, &encode_account/1),
      "account_settings" => encode_account_settings(state.account_settings),
      "account_sync_counter" => state.account_sync_counter,
      "additional_data" => encode_optional(state.additional_data, &encode_json_safe/1),
      "adv_secret_key" => state.adv_secret_key,
      "first_unuploaded_pre_key_id" => state.first_unuploaded_pre_key_id,
      "last_account_sync_timestamp" => state.last_account_sync_timestamp,
      "last_prop_hash" => encode_optional(state.last_prop_hash, &encode_json_safe/1),
      "me" => encode_optional(state.me, &encode_json_safe/1),
      "my_app_state_key_id" => state.my_app_state_key_id,
      "next_pre_key_id" => state.next_pre_key_id,
      "noise_key" => encode_key_pair(state.noise_key),
      "pairing_code" => state.pairing_code,
      "pairing_ephemeral_key" => encode_optional(state.pairing_ephemeral_key, &encode_key_pair/1),
      "platform" => state.platform,
      "processed_history_messages" =>
        Enum.map(state.processed_history_messages || [], &encode_processed_history_message/1),
      "registered" => state.registered,
      "registration_id" => state.registration_id,
      "routing_info" => encode_optional(state.routing_info, &encode_buffer/1),
      "signal_identities" => Enum.map(state.signal_identities || [], &encode_signal_identity/1),
      "signed_identity_key" => encode_key_pair(state.signed_identity_key),
      "signed_pre_key" => encode_signed_key_pair(state.signed_pre_key)
    }
  end

  defp encode_key_data(:session, %SessionRecord{} = record), do: encode_session_record(record)
  defp encode_key_data(:"pre-key", value), do: encode_key_pair(value)

  defp encode_key_data(:"sender-key", %SenderKeyRecord{} = record),
    do: encode_sender_key_record(record)

  defp encode_key_data(:"sender-key-memory", value), do: encode_json_safe(value)
  defp encode_key_data(:"app-state-sync-key", value), do: encode_app_state_sync_key(value)
  defp encode_key_data(:"app-state-sync-version", value), do: encode_app_state_sync_version(value)
  defp encode_key_data(:"lid-mapping", value), do: encode_json_safe(value)
  defp encode_key_data(:"device-list", value), do: encode_json_safe(value)
  defp encode_key_data(:tctoken, value), do: encode_tctoken(value)
  defp encode_key_data(:"identity-key", value) when is_binary(value), do: encode_buffer(value)
  defp encode_key_data(:"identity-key", value), do: encode_binary_values(value)
  defp encode_key_data(_type, value), do: encode_json_safe(value)

  defp decode_credentials(value) do
    if legacy_encoded?(value) do
      decode_legacy_credentials(value)
    else
      decode_explicit_credentials(value)
    end
  end

  defp decode_key_data(type, value) do
    if legacy_encoded?(value) do
      decode_legacy_key_data(type, value)
    else
      decode_explicit_key_data(type, value)
    end
  end

  defp decode_explicit_credentials(%{} = value) do
    struct(State, %{
      account: decode_optional(Map.get(value, "account"), &decode_account/1),
      account_settings: decode_account_settings(Map.get(value, "account_settings")),
      account_sync_counter: Map.get(value, "account_sync_counter", 0),
      additional_data: decode_optional(Map.get(value, "additional_data"), &decode_json_safe/1),
      adv_secret_key: Map.get(value, "adv_secret_key"),
      first_unuploaded_pre_key_id: Map.get(value, "first_unuploaded_pre_key_id", 1),
      last_account_sync_timestamp: Map.get(value, "last_account_sync_timestamp"),
      last_prop_hash: decode_optional(Map.get(value, "last_prop_hash"), &decode_json_safe/1),
      me: decode_optional(Map.get(value, "me"), &decode_me/1),
      my_app_state_key_id: Map.get(value, "my_app_state_key_id"),
      next_pre_key_id: Map.get(value, "next_pre_key_id", 1),
      noise_key: decode_key_pair(Map.get(value, "noise_key")),
      pairing_code: Map.get(value, "pairing_code"),
      pairing_ephemeral_key:
        decode_optional(Map.get(value, "pairing_ephemeral_key"), &decode_key_pair/1),
      platform: Map.get(value, "platform"),
      processed_history_messages:
        value
        |> Map.get("processed_history_messages", [])
        |> Enum.map(&decode_processed_history_message/1),
      registered: Map.get(value, "registered", false),
      registration_id: Map.get(value, "registration_id", 0),
      routing_info: decode_optional(Map.get(value, "routing_info"), &decode_buffer/1),
      signal_identities:
        value
        |> Map.get("signal_identities", [])
        |> Enum.map(&decode_signal_identity/1),
      signed_identity_key: decode_key_pair(Map.get(value, "signed_identity_key")),
      signed_pre_key: decode_signed_key_pair(Map.get(value, "signed_pre_key"))
    })
  end

  defp decode_explicit_credentials(other), do: other

  defp decode_explicit_key_data(:session, value), do: decode_session_record(value)
  defp decode_explicit_key_data(:"pre-key", value), do: decode_key_pair(value)
  defp decode_explicit_key_data(:"sender-key", value), do: decode_sender_key_record(value)
  defp decode_explicit_key_data(:"sender-key-memory", value), do: decode_json_safe(value)

  defp decode_explicit_key_data(:"app-state-sync-key", value),
    do: decode_app_state_sync_key(value)

  defp decode_explicit_key_data(:"app-state-sync-version", value),
    do: decode_app_state_sync_version(value)

  defp decode_explicit_key_data(:"lid-mapping", value), do: decode_json_safe(value)
  defp decode_explicit_key_data(:"device-list", value), do: decode_json_safe(value)
  defp decode_explicit_key_data(:tctoken, value), do: decode_tctoken(value)

  defp decode_explicit_key_data(:"identity-key", %{"type" => @buffer_tag} = value),
    do: decode_buffer(value)

  defp decode_explicit_key_data(:"identity-key", value), do: decode_binary_values(value)
  defp decode_explicit_key_data(_type, value), do: decode_json_safe(value)

  defp encode_account(%ADVSignedDeviceIdentity{} = account) do
    %{
      "account_signature" => encode_buffer(account.account_signature),
      "account_signature_key" => encode_buffer(account.account_signature_key),
      "details" => encode_buffer(account.details),
      "device_signature" => encode_buffer(account.device_signature)
    }
  end

  defp encode_account(%{} = account), do: encode_json_safe(account)

  defp decode_account(%{} = account) do
    if Map.has_key?(account, "details") and Map.has_key?(account, "account_signature") do
      %ADVSignedDeviceIdentity{
        account_signature: decode_buffer(account["account_signature"]),
        account_signature_key: decode_buffer(account["account_signature_key"]),
        details: decode_buffer(account["details"]),
        device_signature: decode_buffer(account["device_signature"])
      }
    else
      decode_json_safe(account)
    end
  end

  defp decode_account(other), do: other

  defp encode_account_settings(settings) when is_map(settings) do
    %{
      "default_disappearing_mode" =>
        encode_optional(
          fetch_map_value(settings, :default_disappearing_mode),
          &encode_json_safe/1
        ),
      "unarchive_chats" => !!fetch_map_value(settings, :unarchive_chats, false)
    }
  end

  defp encode_account_settings(_settings) do
    %{"default_disappearing_mode" => nil, "unarchive_chats" => false}
  end

  defp decode_account_settings(nil),
    do: %{unarchive_chats: false, default_disappearing_mode: nil}

  defp decode_account_settings(%{} = settings) do
    %{
      unarchive_chats: !!Map.get(settings, "unarchive_chats", false),
      default_disappearing_mode:
        decode_optional(Map.get(settings, "default_disappearing_mode"), &decode_json_safe/1)
    }
  end

  defp decode_me(%{} = me) do
    Map.new(me, fn {key, value} ->
      {decode_known_key(key, [:id, :name, :lid, :device_id]), decode_json_safe(value)}
    end)
  end

  defp encode_signal_identity(identity) when is_map(identity) do
    identifier = fetch_map_value(identity, :identifier, %{})

    %{
      "identifier" => %{
        "device_id" => fetch_map_value(identifier, :device_id),
        "name" => fetch_map_value(identifier, :name)
      },
      "identifier_key" => encode_buffer(fetch_map_value(identity, :identifier_key))
    }
  end

  defp decode_signal_identity(%{"identifier" => identifier, "identifier_key" => identifier_key}) do
    %{
      identifier: %{
        device_id: Map.get(identifier, "device_id"),
        name: Map.get(identifier, "name")
      },
      identifier_key: decode_buffer(identifier_key)
    }
  end

  defp decode_signal_identity(%{} = identity) do
    identifier = required_json_map_field!(identity, "identifier", "signal_identity")

    %{
      identifier: %{
        device_id: Map.get(identifier, "device_id"),
        name: Map.get(identifier, "name")
      },
      identifier_key:
        identity
        |> required_json_field!("identifier_key", "signal_identity")
        |> decode_buffer()
    }
  end

  defp decode_signal_identity(other), do: invalid_explicit_json!("signal_identity", other)

  defp encode_processed_history_message(entry) when is_map(entry) do
    %{
      "key" => encode_message_key(fetch_map_value(entry, :key, %{})),
      "message_timestamp" => fetch_map_value(entry, :message_timestamp)
    }
  end

  defp decode_processed_history_message(%{"key" => key} = entry) do
    %{
      key: decode_message_key(key),
      message_timestamp: Map.get(entry, "message_timestamp")
    }
  end

  defp decode_processed_history_message(%{} = entry) do
    %{
      key:
        entry
        |> required_json_map_field!("key", "processed_history_messages[]")
        |> decode_message_key(),
      message_timestamp: Map.get(entry, "message_timestamp")
    }
  end

  defp decode_processed_history_message(other),
    do: invalid_explicit_json!("processed_history_messages[]", other)

  defp encode_message_key(%MessageKey{} = key), do: encode_message_key(Map.from_struct(key))

  defp encode_message_key(key) when is_map(key) do
    %{
      "addressing_mode" =>
        encode_optional(fetch_map_value(key, :addressing_mode), &encode_addressing_mode/1),
      "from_me" => fetch_map_value(key, :from_me, false),
      "id" => fetch_map_value(key, :id),
      "participant" => fetch_map_value(key, :participant),
      "participant_alt" => fetch_map_value(key, :participant_alt),
      "remote_jid" => fetch_map_value(key, :remote_jid),
      "remote_jid_alt" => fetch_map_value(key, :remote_jid_alt),
      "server_id" => fetch_map_value(key, :server_id)
    }
  end

  defp decode_message_key(%{} = key) do
    %{
      id: Map.get(key, "id"),
      participant: Map.get(key, "participant"),
      participant_alt: Map.get(key, "participant_alt"),
      remote_jid: Map.get(key, "remote_jid"),
      remote_jid_alt: Map.get(key, "remote_jid_alt"),
      from_me: Map.get(key, "from_me", false),
      addressing_mode:
        decode_optional(Map.get(key, "addressing_mode"), &decode_addressing_mode/1),
      server_id: Map.get(key, "server_id")
    }
  end

  defp encode_session_record(%SessionRecord{} = record) do
    %{"sessions" => encode_binary_keyed_map(record.sessions, &encode_session/1)}
  end

  defp decode_session_record(%{"sessions" => sessions}) when is_map(sessions) do
    %SessionRecord{sessions: decode_binary_keyed_map(sessions, &decode_session/1)}
  end

  defp decode_session_record(%{} = record) do
    sessions = required_json_map_field!(record, "sessions", "session")
    %SessionRecord{sessions: decode_binary_keyed_map(sessions, &decode_session/1)}
  end

  defp decode_session_record(other), do: invalid_explicit_json!("session", other)

  defp encode_session(session) when is_map(session) do
    %{
      "chains" =>
        session |> fetch_map_value(:chains, %{}) |> encode_binary_keyed_map(&encode_chain/1),
      "current_ratchet" =>
        encode_current_ratchet(fetch_map_value(session, :current_ratchet, %{})),
      "index_info" => encode_index_info(fetch_map_value(session, :index_info, %{})),
      "pending_pre_key" =>
        encode_optional(fetch_map_value(session, :pending_pre_key), &encode_pending_pre_key/1),
      "registration_id" => fetch_map_value(session, :registration_id)
    }
  end

  defp decode_session(%{} = session) do
    %{
      chains:
        session
        |> Map.get("chains", %{})
        |> decode_binary_keyed_map(&decode_chain/1),
      current_ratchet: decode_current_ratchet(Map.get(session, "current_ratchet", %{})),
      index_info: decode_index_info(Map.get(session, "index_info", %{})),
      pending_pre_key:
        decode_optional(Map.get(session, "pending_pre_key"), &decode_pending_pre_key/1),
      registration_id: Map.get(session, "registration_id")
    }
  end

  defp encode_current_ratchet(ratchet) when is_map(ratchet) do
    %{
      "ephemeral_key_pair" =>
        encode_optional(fetch_map_value(ratchet, :ephemeral_key_pair), &encode_key_pair/1),
      "last_remote_ephemeral" =>
        encode_optional(fetch_map_value(ratchet, :last_remote_ephemeral), &encode_buffer/1),
      "previous_counter" => fetch_map_value(ratchet, :previous_counter),
      "root_key" => encode_optional(fetch_map_value(ratchet, :root_key), &encode_buffer/1)
    }
  end

  defp decode_current_ratchet(%{} = ratchet) do
    %{
      ephemeral_key_pair:
        decode_optional(Map.get(ratchet, "ephemeral_key_pair"), &decode_key_pair/1),
      last_remote_ephemeral:
        decode_optional(Map.get(ratchet, "last_remote_ephemeral"), &decode_buffer/1),
      previous_counter: Map.get(ratchet, "previous_counter"),
      root_key: decode_optional(Map.get(ratchet, "root_key"), &decode_buffer/1)
    }
  end

  defp encode_index_info(index_info) when is_map(index_info) do
    %{
      "base_key" => encode_optional(fetch_map_value(index_info, :base_key), &encode_buffer/1),
      "base_key_type" =>
        encode_optional(fetch_map_value(index_info, :base_key_type), &encode_direction/1),
      "closed" => fetch_map_value(index_info, :closed),
      "local_identity_key" =>
        encode_optional(fetch_map_value(index_info, :local_identity_key), &encode_buffer/1),
      "remote_identity_key" =>
        encode_optional(fetch_map_value(index_info, :remote_identity_key), &encode_buffer/1)
    }
  end

  defp decode_index_info(%{} = index_info) do
    %{
      base_key: decode_optional(Map.get(index_info, "base_key"), &decode_buffer/1),
      base_key_type: decode_optional(Map.get(index_info, "base_key_type"), &decode_direction/1),
      closed: Map.get(index_info, "closed"),
      local_identity_key:
        decode_optional(Map.get(index_info, "local_identity_key"), &decode_buffer/1),
      remote_identity_key:
        decode_optional(Map.get(index_info, "remote_identity_key"), &decode_buffer/1)
    }
  end

  defp encode_pending_pre_key(pending_pre_key) when is_map(pending_pre_key) do
    %{
      "base_key" =>
        encode_optional(fetch_map_value(pending_pre_key, :base_key), &encode_buffer/1),
      "pre_key_id" => fetch_map_value(pending_pre_key, :pre_key_id),
      "signed_pre_key_id" => fetch_map_value(pending_pre_key, :signed_pre_key_id)
    }
  end

  defp decode_pending_pre_key(%{} = pending_pre_key) do
    %{
      base_key: decode_optional(Map.get(pending_pre_key, "base_key"), &decode_buffer/1),
      pre_key_id: Map.get(pending_pre_key, "pre_key_id"),
      signed_pre_key_id: Map.get(pending_pre_key, "signed_pre_key_id")
    }
  end

  defp encode_chain(chain) when is_map(chain) do
    %{
      "chain_key" => encode_chain_key(fetch_map_value(chain, :chain_key, %{})),
      "chain_type" => encode_optional(fetch_map_value(chain, :chain_type), &encode_direction/1),
      "message_keys" =>
        chain
        |> fetch_map_value(:message_keys, %{})
        |> encode_integer_keyed_map(&encode_buffer/1)
    }
  end

  defp decode_chain(%{} = chain) do
    %{
      chain_key: decode_chain_key(Map.get(chain, "chain_key", %{})),
      chain_type: decode_optional(Map.get(chain, "chain_type"), &decode_direction/1),
      message_keys:
        chain
        |> Map.get("message_keys", %{})
        |> decode_integer_keyed_map(&decode_buffer/1)
    }
  end

  defp encode_chain_key(chain_key) when is_map(chain_key) do
    %{
      "counter" => fetch_map_value(chain_key, :counter),
      "key" => encode_optional(fetch_map_value(chain_key, :key), &encode_buffer/1)
    }
  end

  defp decode_chain_key(%{} = chain_key) do
    %{
      counter: Map.get(chain_key, "counter"),
      key: decode_optional(Map.get(chain_key, "key"), &decode_buffer/1)
    }
  end

  defp encode_sender_key_record(%SenderKeyRecord{} = record) do
    %{
      "sender_key_states" => Enum.map(record.sender_key_states, &encode_sender_key_state/1)
    }
  end

  defp decode_sender_key_record(%{"sender_key_states" => states}) when is_list(states) do
    %SenderKeyRecord{
      sender_key_states: Enum.map(states, &decode_sender_key_state/1)
    }
  end

  defp decode_sender_key_record(%{} = record) do
    states = required_json_list_field!(record, "sender_key_states", "sender_key_record")
    %SenderKeyRecord{sender_key_states: Enum.map(states, &decode_sender_key_state/1)}
  end

  defp decode_sender_key_record(other), do: invalid_explicit_json!("sender_key_record", other)

  defp encode_sender_key_state(%SenderKeyState{} = state) do
    structure = SenderKeyState.to_structure(state)

    %{
      "sender_chain_key" => %{
        "iteration" => structure.sender_chain_key.iteration,
        "seed" => encode_buffer(structure.sender_chain_key.seed)
      },
      "sender_key_id" => structure.sender_key_id,
      "sender_message_keys" =>
        Enum.map(structure.sender_message_keys, fn key ->
          %{"iteration" => key.iteration, "seed" => encode_buffer(key.seed)}
        end),
      "sender_signing_key" => encode_key_pair(structure.sender_signing_key)
    }
  end

  defp decode_sender_key_state(%{} = state) do
    SenderKeyState.from_structure(%{
      sender_chain_key: %{
        iteration: get_in(state, ["sender_chain_key", "iteration"]),
        seed: state |> get_in(["sender_chain_key", "seed"]) |> decode_buffer()
      },
      sender_key_id: Map.get(state, "sender_key_id"),
      sender_message_keys:
        Enum.map(Map.get(state, "sender_message_keys", []), fn key ->
          %{iteration: Map.get(key, "iteration"), seed: key |> Map.get("seed") |> decode_buffer()}
        end),
      sender_signing_key: decode_key_pair(Map.get(state, "sender_signing_key"))
    })
  end

  defp encode_app_state_sync_key(value) when is_binary(value), do: encode_buffer(value)

  defp encode_app_state_sync_key(value) when is_map(value) do
    %{"key_data" => value |> fetch_map_value(:key_data) |> encode_buffer()}
  end

  defp decode_app_state_sync_key(%{"type" => @buffer_tag} = value), do: decode_buffer(value)

  defp decode_app_state_sync_key(%{} = value) do
    %{
      key_data:
        value
        |> required_json_field!("key_data", "app_state_sync_key")
        |> decode_buffer()
    }
  end

  defp decode_app_state_sync_key(other), do: invalid_explicit_json!("app_state_sync_key", other)

  defp encode_app_state_sync_version(value) when is_map(value) do
    %{
      "hash" => value |> fetch_map_value(:hash) |> encode_buffer(),
      "index_value_map" =>
        value
        |> fetch_map_value(:index_value_map, %{})
        |> Map.new(fn {key, nested} ->
          {json_key(key),
           %{"value_mac" => nested |> fetch_map_value(:value_mac) |> encode_buffer()}}
        end),
      "version" => fetch_map_value(value, :version)
    }
  end

  defp decode_app_state_sync_version(%{} = value) do
    %{
      hash:
        value
        |> required_json_field!("hash", "app_state_sync_version")
        |> decode_buffer(),
      index_value_map:
        value
        |> Map.get("index_value_map", %{})
        |> Map.new(fn {key, nested} -> {key, decode_index_value_map_entry(nested)} end),
      version: Map.get(value, "version")
    }
  end

  defp decode_app_state_sync_version(other),
    do: invalid_explicit_json!("app_state_sync_version", other)

  defp encode_tctoken(value) when is_map(value) do
    %{
      "timestamp" => value |> fetch_map_value(:timestamp) |> encode_json_safe(),
      "token" => value |> fetch_map_value(:token) |> encode_json_safe()
    }
  end

  defp decode_tctoken(value) when is_map(value) do
    %{
      timestamp: value |> Map.get("timestamp") |> decode_json_safe(),
      token: value |> Map.get("token") |> decode_json_safe()
    }
  end

  defp encode_binary_values(value) when is_map(value) do
    Map.new(value, fn {key, binary} -> {json_key(key), encode_buffer(binary)} end)
  end

  defp decode_binary_values(value) when is_map(value) do
    Map.new(value, fn {key, binary} -> {key, decode_buffer(binary)} end)
  end

  defp encode_key_pair(value) when is_map(value) do
    %{
      "private" => encode_optional(fetch_map_value(value, :private), &encode_buffer/1),
      "public" => encode_optional(fetch_map_value(value, :public), &encode_buffer/1)
    }
  end

  defp decode_key_pair(%{} = value) do
    %{
      private: decode_optional(Map.get(value, "private"), &decode_buffer/1),
      public: decode_optional(Map.get(value, "public"), &decode_buffer/1)
    }
  end

  defp decode_key_pair(other), do: invalid_explicit_json!("key_pair", other)

  defp encode_signed_key_pair(value) when is_map(value) do
    %{
      "key_id" => fetch_map_value(value, :key_id),
      "key_pair" => encode_key_pair(fetch_map_value(value, :key_pair, %{})),
      "signature" => encode_optional(fetch_map_value(value, :signature), &encode_buffer/1)
    }
  end

  defp decode_signed_key_pair(%{} = value) do
    %{
      key_id: Map.get(value, "key_id"),
      key_pair:
        value
        |> required_json_map_field!("key_pair", "signed_pre_key")
        |> decode_key_pair(),
      signature: decode_optional(Map.get(value, "signature"), &decode_buffer/1)
    }
  end

  defp decode_signed_key_pair(other), do: invalid_explicit_json!("signed_pre_key", other)

  defp decode_index_value_map_entry(%{} = nested) do
    %{
      value_mac:
        nested
        |> required_json_field!("value_mac", "app_state_sync_version.index_value_map[]")
        |> decode_buffer()
    }
  end

  defp decode_index_value_map_entry(other),
    do: invalid_explicit_json!("app_state_sync_version.index_value_map[]", other)

  defp encode_binary_keyed_map(map, value_encoder) when is_map(map) do
    Map.new(map, fn {key, value} -> {Base.encode64(key), value_encoder.(value)} end)
  end

  defp encode_binary_keyed_map(nil, _value_encoder), do: %{}

  defp decode_binary_keyed_map(map, value_decoder) when is_map(map) do
    Map.new(map, fn {key, value} -> {Base.decode64!(key), value_decoder.(value)} end)
  end

  defp encode_integer_keyed_map(map, value_encoder) when is_map(map) do
    Map.new(map, fn {key, value} -> {Integer.to_string(key), value_encoder.(value)} end)
  end

  defp decode_integer_keyed_map(map, value_decoder) when is_map(map) do
    Map.new(map, fn {key, value} -> {String.to_integer(key), value_decoder.(value)} end)
  end

  defp encode_json_safe(nil), do: nil
  defp encode_json_safe(value) when is_boolean(value), do: value
  defp encode_json_safe(value) when is_number(value), do: value

  defp encode_json_safe(value) when is_binary(value) do
    if String.valid?(value) and String.printable?(value) do
      value
    else
      encode_buffer(value)
    end
  end

  defp encode_json_safe(list) when is_list(list), do: Enum.map(list, &encode_json_safe/1)

  defp encode_json_safe(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {key, value} -> {json_key(key), encode_json_safe(value)} end)
  end

  defp encode_json_safe(%_{} = value) do
    raise ArgumentError,
          "unsupported struct in compatibility JSON persistence: #{inspect(value.__struct__)}"
  end

  defp encode_json_safe(value) when is_atom(value) do
    raise ArgumentError, "unsupported atom in compatibility JSON persistence: #{inspect(value)}"
  end

  defp encode_json_safe(value) do
    raise ArgumentError, "unsupported term in compatibility JSON persistence: #{inspect(value)}"
  end

  defp decode_json_safe(nil), do: nil
  defp decode_json_safe(value) when is_boolean(value), do: value
  defp decode_json_safe(value) when is_number(value), do: value
  defp decode_json_safe(value) when is_binary(value), do: value
  defp decode_json_safe(%{"type" => @buffer_tag} = value), do: decode_buffer(value)

  defp decode_json_safe(%{} = value) do
    if numeric_byte_map?(value) do
      decode_numeric_byte_map(value)
    else
      Map.new(value, fn {key, nested} -> {key, decode_json_safe(nested)} end)
    end
  end

  defp decode_json_safe(list) when is_list(list), do: Enum.map(list, &decode_json_safe/1)
  defp decode_json_safe(value), do: value

  defp encode_buffer(value) when is_binary(value),
    do: %{"type" => @buffer_tag, "data" => Base.encode64(value)}

  defp decode_buffer(%{"type" => @buffer_tag, "data" => data}) when is_binary(data),
    do: Base.decode64!(data)

  defp decode_buffer(%{"type" => @buffer_tag, "data" => data}) when is_list(data),
    do: :erlang.list_to_binary(data)

  defp decode_buffer(other) do
    raise ArgumentError, "invalid buffer encoding in compatibility JSON: #{inspect(other)}"
  end

  defp numeric_byte_map?(value) when map_size(value) == 0, do: false

  defp numeric_byte_map?(value) do
    Enum.all?(value, fn {key, nested} ->
      case Integer.parse(key) do
        {_, ""} -> is_integer(nested)
        _ -> false
      end
    end)
  end

  defp decode_numeric_byte_map(value) do
    value
    |> Enum.sort_by(fn {key, _nested} -> String.to_integer(key) end)
    |> Enum.map(fn {_key, nested} -> nested end)
    |> :erlang.list_to_binary()
  end

  defp encode_optional(nil, _fun), do: nil
  defp encode_optional(value, fun), do: fun.(value)

  defp decode_optional(nil, _fun), do: nil
  defp decode_optional(value, fun), do: fun.(value)

  defp required_json_field!(map, key, context) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} when not is_nil(value) -> value
      _ -> invalid_explicit_json!("#{context}.#{key}", map)
    end
  end

  defp required_json_map_field!(map, key, context) when is_map(map) and is_binary(key) do
    case required_json_field!(map, key, context) do
      %{} = value -> value
      other -> invalid_explicit_json!("#{context}.#{key}", other)
    end
  end

  defp required_json_list_field!(map, key, context) when is_map(map) and is_binary(key) do
    case required_json_field!(map, key, context) do
      value when is_list(value) -> value
      other -> invalid_explicit_json!("#{context}.#{key}", other)
    end
  end

  defp invalid_explicit_json!(context, value) do
    raise ArgumentError, "invalid #{context} in compatibility JSON: #{inspect(value)}"
  end

  defp encode_addressing_mode(:pn), do: "pn"
  defp encode_addressing_mode(:lid), do: "lid"

  defp encode_addressing_mode(mode),
    do: raise(ArgumentError, "unsupported addressing mode: #{inspect(mode)}")

  defp decode_addressing_mode("pn"), do: :pn
  defp decode_addressing_mode("lid"), do: :lid

  defp decode_addressing_mode(mode) do
    raise ArgumentError, "unsupported addressing mode in compatibility JSON: #{inspect(mode)}"
  end

  defp encode_direction(:sending), do: "sending"
  defp encode_direction(:receiving), do: "receiving"

  defp encode_direction(direction),
    do: raise(ArgumentError, "unsupported direction enum: #{inspect(direction)}")

  defp decode_direction("sending"), do: :sending
  defp decode_direction("receiving"), do: :receiving

  defp decode_direction(direction) do
    raise ArgumentError, "unsupported direction enum in compatibility JSON: #{inspect(direction)}"
  end

  defp fetch_map_value(map, key, default \\ nil) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key), default)
    end
  end

  defp decode_known_key(key, known_atoms) when is_binary(key) do
    case Enum.find(known_atoms, &(Atom.to_string(&1) == key)) do
      nil -> key
      atom -> atom
    end
  end

  defp decode_known_key(key, _known_atoms), do: key

  defp json_key(key) when is_atom(key), do: Atom.to_string(key)

  defp json_key(key) when is_binary(key) do
    if String.valid?(key) do
      key
    else
      raise ArgumentError, "unsupported JSON key in compatibility persistence: #{inspect(key)}"
    end
  end

  defp json_key(key) do
    raise ArgumentError, "unsupported JSON key in compatibility persistence: #{inspect(key)}"
  end

  defp legacy_encoded?(%{"__type__" => _}), do: true
  defp legacy_encoded?(%{"__atom_keys__" => _}), do: true
  defp legacy_encoded?(%{"type" => @buffer_tag, "data" => data}) when is_list(data), do: true
  defp legacy_encoded?(_value), do: false

  defp decode_legacy_credentials(value) do
    case decode_legacy_term(value, @credential_decode_context) do
      %State{} = state -> state
      %{} = fields -> struct(State, fields)
      other -> other
    end
  end

  defp decode_legacy_key_data(:session, value),
    do: decode_legacy_term(value, @session_decode_context)

  defp decode_legacy_key_data(:"pre-key", value),
    do: decode_legacy_term(value, @pre_key_decode_context)

  defp decode_legacy_key_data(:"sender-key", value),
    do: decode_legacy_term(value, @sender_key_decode_context)

  defp decode_legacy_key_data(:"sender-key-memory", value),
    do: decode_legacy_term(value, @empty_decode_context)

  defp decode_legacy_key_data(:"app-state-sync-key", value),
    do: decode_legacy_term(value, @app_state_sync_key_decode_context)

  defp decode_legacy_key_data(:"app-state-sync-version", value),
    do: decode_legacy_term(value, @app_state_sync_version_decode_context)

  defp decode_legacy_key_data(:"lid-mapping", value),
    do: decode_legacy_term(value, @empty_decode_context)

  defp decode_legacy_key_data(:"device-list", value),
    do: decode_legacy_term(value, @empty_decode_context)

  defp decode_legacy_key_data(:tctoken, value),
    do: decode_legacy_term(value, @tc_token_decode_context)

  defp decode_legacy_key_data(:"identity-key", value),
    do: decode_legacy_term(value, @empty_decode_context)

  defp decode_legacy_key_data(_type, value), do: decode_legacy_term(value)

  defp decode_legacy_term(value), do: decode_legacy_term(value, @empty_decode_context)

  defp decode_legacy_term(
         %{"__type__" => "struct", "module" => module_name, "value" => value},
         decode_context
       ) do
    module = decode_legacy_module(module_name, decode_context)
    fields = decode_legacy_term(value, decode_context)
    struct(module, fields)
  end

  defp decode_legacy_term(%{"__type__" => "map", "entries" => entries}, decode_context) do
    entries
    |> Enum.map(fn [key, value] ->
      {decode_legacy_term(key, decode_context), decode_legacy_term(value, decode_context)}
    end)
    |> Map.new()
  end

  defp decode_legacy_term(%{"__type__" => "tuple", "items" => items}, decode_context) do
    items
    |> Enum.map(&decode_legacy_term(&1, decode_context))
    |> List.to_tuple()
  end

  defp decode_legacy_term(%{"__type__" => "atom", "value" => value}, decode_context)
       when is_binary(value) do
    decode_legacy_atom(value, decode_context)
  end

  defp decode_legacy_term(%{"type" => @buffer_tag, "data" => data}, _decode_context)
       when is_list(data),
       do: :erlang.list_to_binary(data)

  defp decode_legacy_term(%{} = map, decode_context) do
    atom_keys = Map.get(map, "__atom_keys__", [])

    map
    |> Map.delete("__atom_keys__")
    |> Enum.map(fn {key, value} ->
      decoded_key =
        if key in atom_keys do
          decode_legacy_atom(key, decode_context)
        else
          key
        end

      {decoded_key, decode_legacy_term(value, decode_context)}
    end)
    |> Map.new()
  end

  defp decode_legacy_term(list, decode_context) when is_list(list),
    do: Enum.map(list, &decode_legacy_term(&1, decode_context))

  defp decode_legacy_term(other, _decode_context), do: other

  defp decode_legacy_atom(value, %{atoms: atoms}) do
    case Map.fetch(atoms, value) do
      {:ok, atom} ->
        atom

      :error ->
        raise ArgumentError,
              "unknown persisted atom #{inspect(value)}; " <>
                "add it to the relevant decode context in #{inspect(__MODULE__)}"
    end
  end

  defp decode_legacy_module(module_name, %{modules: modules}) do
    case Map.fetch(modules, module_name) do
      {:ok, module} ->
        module

      :error ->
        raise ArgumentError,
              "unknown persisted module #{inspect(module_name)}; " <>
                "add it to the relevant decode context in #{inspect(__MODULE__)}"
    end
  end

  defp normalize_credentials_state(%State{} = state), do: state

  defp normalize_credentials_state(%{} = state) do
    state
    |> State.creds_view()
    |> then(&struct(State, &1))
  end

  defp normalize_credentials_state(_state), do: State.new()
end
