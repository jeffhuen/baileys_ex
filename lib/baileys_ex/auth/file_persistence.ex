defmodule BaileysEx.Auth.FilePersistence do
  @moduledoc """
  Default multi-file auth persistence mirroring Baileys `useMultiFileAuthState`.
  """

  @behaviour BaileysEx.Auth.Persistence

  alias BaileysEx.Auth.KeyStore
  alias BaileysEx.Auth.State

  @buffer_tag "Buffer"
  @default_dir "baileys_auth_info"

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
      case read_data(path, "creds.json") do
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
    with :ok <- ensure_directory(path) do
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

      case read_data(path, file_name) do
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

  defp read_data(path, file_name) do
    file_path = Path.join(path, sanitize_file_name(file_name))

    with_file_lock(file_path, fn ->
      case File.read(file_path) do
        {:ok, contents} ->
          {:ok, JSON.decode!(contents) |> decode_term()}

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

  defp decode_term(%{"__type__" => "struct", "module" => module_name, "value" => value}) do
    module = String.to_existing_atom(module_name)
    fields = decode_term(value)
    struct(module, fields)
  end

  defp decode_term(%{"__type__" => "map", "entries" => entries}) do
    entries
    |> Enum.map(fn [key, value] -> {decode_term(key), decode_term(value)} end)
    |> Map.new()
  end

  defp decode_term(%{"__type__" => "tuple", "items" => items}) do
    items
    |> Enum.map(&decode_term/1)
    |> List.to_tuple()
  end

  defp decode_term(%{"__type__" => "atom", "value" => value}) when is_binary(value) do
    String.to_atom(value)
  end

  defp decode_term(%{"type" => @buffer_tag, "data" => data}) when is_list(data) do
    :erlang.list_to_binary(data)
  end

  defp decode_term(%{} = map) do
    atom_keys = Map.get(map, "__atom_keys__", [])

    map
    |> Map.delete("__atom_keys__")
    |> Enum.map(fn {key, value} ->
      decoded_key =
        if key in atom_keys do
          String.to_atom(key)
        else
          key
        end

      {decoded_key, decode_term(value)}
    end)
    |> Map.new()
  end

  defp decode_term(list) when is_list(list), do: Enum.map(list, &decode_term/1)
  defp decode_term(other), do: other

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
  defp json_object_key(key) when is_binary(key), do: {:ok, key, false}
  defp json_object_key(_key), do: :error
end
