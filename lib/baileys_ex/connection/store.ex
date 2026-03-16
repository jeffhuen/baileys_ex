defmodule BaileysEx.Connection.Store do
  @moduledoc """
  Connection-scoped runtime store with ETS-backed concurrent reads.
  """

  use GenServer

  alias BaileysEx.Auth.State, as: AuthState

  defmodule Ref do
    @moduledoc """
    Read-only reference to a connection store ETS table.
    """

    @enforce_keys [:pid, :table]
    defstruct [:pid, :table]

    @type t :: %__MODULE__{pid: pid(), table: :ets.tid()}
  end

  @type key ::
          :auth_state
          | :blocklist
          | :connection_name
          | :creds
          | :last_prop_hash
          | :last_account_sync_timestamp
          | :privacy_settings
          | :props
          | {:app_state_sync_key, String.t()}
          | {:app_state_sync_version, atom()}
          | atom()

  @doc """
  Returns a `Ref` struct allowing safe, concurrent reads from the ETS table
  owned by the `Store` server.
  """
  @spec wrap(GenServer.server()) :: Ref.t()
  def wrap(server) do
    pid = GenServer.whereis(server)

    if is_pid(pid) do
      %Ref{pid: pid, table: GenServer.call(server, :table)}
    else
      raise ArgumentError, "store #{inspect(server)} is not running"
    end
  end

  @doc """
  Reads a value from the connection store via an ETS ref immediately.
  Returns `default` if the key is not found or the ETS query fails.
  """
  @spec get(Ref.t(), key(), term()) :: term()
  def get(%Ref{} = ref, key, default \\ nil) do
    case :ets.lookup(ref.table, key) do
      [{^key, value}] -> value
      [] -> default
    end
  rescue
    ArgumentError -> default
  end

  @doc """
  Synchronously puts a key-value pair into the connection store.
  """
  @spec put(GenServer.server() | Ref.t(), key(), term()) :: :ok
  def put(%Ref{pid: pid}, key, value), do: put(pid, key, value)
  def put(server, key, value), do: GenServer.call(server, {:put, key, value})

  @doc """
  Merges map updates into the connection's `:auth_state`, automatically computing 
  and saving the `:creds` view projection simultaneously.
  """
  @spec merge_creds(GenServer.server() | Ref.t(), map()) :: :ok
  def merge_creds(%Ref{pid: pid}, updates), do: merge_creds(pid, updates)

  def merge_creds(server, updates) when is_map(updates),
    do: GenServer.call(server, {:merge_creds, updates})

  @doc """
  Retrieves a deep map snapshot of the entire ETS connection store contents.
  """
  @spec snapshot(GenServer.server() | Ref.t()) :: map()
  def snapshot(%Ref{pid: pid}), do: snapshot(pid)
  def snapshot(server), do: GenServer.call(server, :snapshot)

  # ============================================================================
  # App State Sync helpers — Syncd key and version storage
  # ============================================================================

  @doc """
  Fetch an app state sync key by its base64-encoded key ID.

  Returns `{:ok, %{key_data: binary()}}` or `{:error, {:key_not_found, key_id}}`.
  Keys are stored under `{:app_state_sync_key, key_id}` in the ETS table.
  """
  @spec get_app_state_sync_key(Ref.t() | GenServer.server(), String.t()) ::
          {:ok, %{key_data: binary()}} | {:error, term()}
  def get_app_state_sync_key(%Ref{} = ref, key_id) do
    case get(ref, {:app_state_sync_key, key_id}) do
      nil -> {:error, {:key_not_found, key_id}}
      value -> {:ok, value}
    end
  end

  def get_app_state_sync_key(server, key_id) do
    get_app_state_sync_key(wrap(server), key_id)
  end

  @doc """
  Store an app state sync key by its base64-encoded key ID.
  """
  @spec put_app_state_sync_key(GenServer.server() | Ref.t(), String.t(), map()) :: :ok
  def put_app_state_sync_key(server_or_ref, key_id, key_data) do
    put(server_or_ref, {:app_state_sync_key, key_id}, key_data)
  end

  @doc """
  Fetch the LTHash sync version state for a collection.

  Returns `nil` if the collection has not been synced yet.
  """
  @spec get_app_state_sync_version(Ref.t() | GenServer.server(), atom()) :: map() | nil
  def get_app_state_sync_version(%Ref{} = ref, collection_name) do
    get(ref, {:app_state_sync_version, collection_name})
  end

  def get_app_state_sync_version(server, collection_name) do
    get_app_state_sync_version(wrap(server), collection_name)
  end

  @doc """
  Persist the LTHash sync version state for a collection.
  """
  @spec put_app_state_sync_version(GenServer.server() | Ref.t(), atom(), map() | nil) :: :ok
  def put_app_state_sync_version(server_or_ref, collection_name, state) do
    put(server_or_ref, {:app_state_sync_version, collection_name}, state)
  end

  @doc """
  Starts the GenServer that owns the connection ETS table.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    genserver_opts =
      case Keyword.fetch(opts, :name) do
        {:ok, name} -> [name: name]
        :error -> []
      end

    GenServer.start_link(__MODULE__, opts, genserver_opts)
  end

  @impl true
  def init(opts) do
    table = :ets.new(__MODULE__, [:set, :protected, read_concurrency: true])
    auth_state = Keyword.get(opts, :auth_state, %{})

    persist_entries(table, %{
      auth_state: auth_state,
      creds: AuthState.creds_view(auth_state),
      connection_name: Keyword.get(opts, :connection_name)
    })

    {:ok, %{table: table}}
  end

  @impl true
  def handle_call(:table, _from, state), do: {:reply, state.table, state}

  def handle_call({:put, key, value}, _from, state) do
    persist_entries(state.table, %{key => value})
    {:reply, :ok, state}
  end

  def handle_call({:merge_creds, updates}, _from, state) do
    current_auth_state = lookup(state.table, :auth_state, %{})
    merged_auth_state = AuthState.merge_updates(current_auth_state, updates)
    merged_creds = AuthState.creds_view(merged_auth_state)

    persist_entries(state.table, %{auth_state: merged_auth_state, creds: merged_creds})

    {:reply, :ok, state}
  end

  def handle_call(:snapshot, _from, state) do
    snapshot =
      state.table
      |> :ets.tab2list()
      |> Map.new()

    {:reply, snapshot, state}
  end

  defp lookup(table, key, default) do
    case :ets.lookup(table, key) do
      [{^key, value}] -> value
      [] -> default
    end
  end

  defp persist_entries(table, entries) do
    entries
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.each(fn {key, value} -> true = :ets.insert(table, {key, value}) end)

    :ok
  end
end
