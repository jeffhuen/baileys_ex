defmodule BaileysEx.Auth.FilePersistence do
  @moduledoc """
  Default multi-file auth persistence mirroring Baileys `useMultiFileAuthState`.
  """

  @behaviour BaileysEx.Auth.Persistence

  alias BaileysEx.Auth.KeyStore
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

  # Persistence decoding is intentionally bounded to explicit atoms/modules instead of
  # relying on generic atom reconstruction from disk. This keeps auth loading
  # deterministic across fresh and warm VMs and avoids reopening unbounded atom
  # creation from persisted files.
  #
  # Top-level struct fields are derived from the owning structs so they track schema
  # changes automatically. Nested map atoms still need explicit maintenance because
  # they are persisted as atom keys without dedicated structs. When adding persisted
  # nested fields, update the relevant decode context below and extend the fresh-VM
  # regressions in `test/baileys_ex/auth/file_persistence_test.exs`.
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
        :default_disappearing_mode
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
    with :ok <- ensure_directory(path) do
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
         :ok <- ensure_directory(path) do
      write_data(path, "creds.json", state)
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
    with :ok <- ensure_directory(path) do
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
    with :ok <- ensure_directory(path) do
      write_data(path, data_file_name(type, id), data)
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
    with :ok <- ensure_directory(path) do
      remove_data(path, data_file_name(type, id))
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
          {:ok, contents |> JSON.decode!() |> decoder_fun.()}

        {:error, :enoent} ->
          {:ok, nil}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  rescue
    error in [ArgumentError] -> {:error, error}
  end

  defp write_data(path, file_name, data) do
    file_path = Path.join(path, sanitize_file_name(file_name))

    with_file_lock(file_path, fn ->
      temp_path = temporary_path(file_path)
      encoded = data |> encode_term() |> JSON.encode!()

      with :ok <- File.write(temp_path, encoded),
           :ok <- File.rename(temp_path, file_path) do
        :ok
      else
        {:error, _reason} = error ->
          _ = File.rm(temp_path)
          error
      end
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

  defp temporary_path(file_path) do
    suffix = System.unique_integer([:positive, :monotonic])
    "#{file_path}.tmp-#{suffix}"
  end

  defp with_file_lock(file_path, fun) do
    :global.trans({__MODULE__, file_path}, fun)
  end

  defp encode_term(%_{} = struct) do
    %{
      "__type__" => "struct",
      "module" => Atom.to_string(struct.__struct__),
      "value" => encode_term(Map.from_struct(struct))
    }
  end

  defp encode_term(nil), do: nil
  defp encode_term(boolean) when is_boolean(boolean), do: boolean

  defp encode_term(map) when is_map(map) do
    case encode_json_object(map) do
      {:ok, json_object} ->
        json_object

      :error ->
        %{
          "__type__" => "map",
          "entries" =>
            Enum.map(map, fn {key, value} ->
              [encode_term(key), encode_term(value)]
            end)
        }
    end
  end

  defp encode_term(list) when is_list(list), do: Enum.map(list, &encode_term/1)

  defp encode_term(tuple) when is_tuple(tuple) do
    %{
      "__type__" => "tuple",
      "items" => tuple |> Tuple.to_list() |> Enum.map(&encode_term/1)
    }
  end

  defp encode_term(atom) when is_atom(atom) do
    %{
      "__type__" => "atom",
      "value" => Atom.to_string(atom)
    }
  end

  defp encode_term(binary) when is_binary(binary) do
    if String.valid?(binary) and String.printable?(binary) do
      binary
    else
      %{"type" => @buffer_tag, "data" => :binary.bin_to_list(binary)}
    end
  end

  defp encode_term(other), do: other

  defp decode_credentials(value) do
    case decode_term(value, @credential_decode_context) do
      %State{} = state -> state
      %{} = fields -> struct(State, fields)
      other -> other
    end
  end

  defp decode_key_data(:session, value), do: decode_term(value, @session_decode_context)
  defp decode_key_data(:"pre-key", value), do: decode_term(value, @pre_key_decode_context)
  defp decode_key_data(:"sender-key", value), do: decode_term(value, @sender_key_decode_context)
  defp decode_key_data(:"sender-key-memory", value), do: decode_term(value, @empty_decode_context)

  defp decode_key_data(:"app-state-sync-key", value),
    do: decode_term(value, @app_state_sync_key_decode_context)

  defp decode_key_data(:"app-state-sync-version", value),
    do: decode_term(value, @app_state_sync_version_decode_context)

  defp decode_key_data(:"lid-mapping", value), do: decode_term(value, @empty_decode_context)
  defp decode_key_data(:"device-list", value), do: decode_term(value, @empty_decode_context)
  defp decode_key_data(:tctoken, value), do: decode_term(value, @tc_token_decode_context)
  defp decode_key_data(:"identity-key", value), do: decode_term(value, @empty_decode_context)
  defp decode_key_data(_type, value), do: decode_term(value)

  defp decode_term(value), do: decode_term(value, @empty_decode_context)

  defp decode_term(
         %{"__type__" => "struct", "module" => module_name, "value" => value},
         decode_context
       ) do
    module = decode_module(module_name, decode_context)
    fields = decode_term(value, decode_context)
    struct(module, fields)
  end

  defp decode_term(%{"__type__" => "map", "entries" => entries}, decode_context) do
    entries
    |> Enum.map(fn [key, value] ->
      {decode_term(key, decode_context), decode_term(value, decode_context)}
    end)
    |> Map.new()
  end

  defp decode_term(%{"__type__" => "tuple", "items" => items}, decode_context) do
    items
    |> Enum.map(&decode_term(&1, decode_context))
    |> List.to_tuple()
  end

  defp decode_term(%{"__type__" => "atom", "value" => value}, decode_context)
       when is_binary(value) do
    decode_atom(value, decode_context)
  end

  defp decode_term(%{"type" => @buffer_tag, "data" => data}, _decode_context) when is_list(data),
    do: :erlang.list_to_binary(data)

  defp decode_term(%{} = map, decode_context) do
    atom_keys = Map.get(map, "__atom_keys__", [])

    map
    |> Map.delete("__atom_keys__")
    |> Enum.map(fn {key, value} ->
      decoded_key =
        if key in atom_keys do
          decode_atom(key, decode_context)
        else
          key
        end

      {decoded_key, decode_term(value, decode_context)}
    end)
    |> Map.new()
  end

  defp decode_term(list, decode_context) when is_list(list),
    do: Enum.map(list, &decode_term(&1, decode_context))

  defp decode_term(other, _decode_context), do: other

  defp decode_atom(value, %{atoms: atoms}) do
    case Map.fetch(atoms, value) do
      {:ok, atom} ->
        atom

      :error ->
        raise ArgumentError,
              "unknown persisted atom #{inspect(value)}; " <>
                "add it to the relevant decode context in #{inspect(__MODULE__)}"
    end
  end

  defp decode_module(module_name, %{modules: modules}) do
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

  defp encode_json_object(map) do
    map
    |> Enum.reduce_while({:ok, %{}, []}, &reduce_json_object_entry/2)
    |> case do
      {:ok, %{"__collision__" => true}, _atom_keys} ->
        :error

      {:ok, json_object, []} ->
        {:ok, json_object}

      {:ok, json_object, atom_keys} ->
        {:ok, Map.put(json_object, "__atom_keys__", Enum.reverse(atom_keys))}

      :error ->
        :error
    end
  end

  defp reduce_json_object_entry({key, value}, {:ok, acc, atom_keys}) do
    case json_object_key(key) do
      {:ok, json_key, atom_key?} ->
        {:cont,
         {:ok, put_json_object_value(acc, json_key, encode_term(value)),
          maybe_track_atom_key(atom_keys, atom_key?, json_key)}}

      :error ->
        {:halt, :error}
    end
  end

  defp put_json_object_value(acc, json_key, encoded_value) do
    if Map.has_key?(acc, json_key) do
      Map.put(acc, "__collision__", true)
    else
      Map.put(acc, json_key, encoded_value)
    end
  end

  defp maybe_track_atom_key(atom_keys, true, json_key), do: [json_key | atom_keys]
  defp maybe_track_atom_key(atom_keys, false, _json_key), do: atom_keys

  defp json_object_key(key) when is_atom(key), do: {:ok, Atom.to_string(key), true}

  defp json_object_key(key) when is_binary(key) do
    if String.valid?(key) do
      {:ok, key, false}
    else
      :error
    end
  end

  defp json_object_key(_key), do: :error
end
