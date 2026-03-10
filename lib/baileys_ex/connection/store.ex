defmodule BaileysEx.Connection.Store do
  @moduledoc """
  Connection-scoped runtime store with ETS-backed concurrent reads.
  """

  use GenServer

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
          | atom()

  @spec wrap(GenServer.server()) :: Ref.t()
  def wrap(server) do
    pid = GenServer.whereis(server)

    if is_pid(pid) do
      %Ref{pid: pid, table: GenServer.call(server, :table)}
    else
      raise ArgumentError, "store #{inspect(server)} is not running"
    end
  end

  @spec get(Ref.t(), key(), term()) :: term()
  def get(%Ref{} = ref, key, default \\ nil) do
    case :ets.lookup(ref.table, key) do
      [{^key, value}] -> value
      [] -> default
    end
  rescue
    ArgumentError -> default
  end

  @spec put(GenServer.server() | Ref.t(), key(), term()) :: :ok
  def put(%Ref{pid: pid}, key, value), do: put(pid, key, value)
  def put(server, key, value), do: GenServer.call(server, {:put, key, value})

  @spec merge_creds(GenServer.server() | Ref.t(), map()) :: :ok
  def merge_creds(%Ref{pid: pid}, updates), do: merge_creds(pid, updates)

  def merge_creds(server, updates) when is_map(updates),
    do: GenServer.call(server, {:merge_creds, updates})

  @spec snapshot(GenServer.server() | Ref.t()) :: map()
  def snapshot(%Ref{pid: pid}), do: snapshot(pid)
  def snapshot(server), do: GenServer.call(server, :snapshot)

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
      creds: get_in(auth_state, [:creds]) || %{},
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
    current_creds = lookup(state.table, :creds, %{})
    merged_creds = merge_maps(current_creds, updates)
    merged_auth_state = merge_maps(current_auth_state, %{creds: merged_creds})

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

  defp merge_maps(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      if is_map(left_value) and is_map(right_value) do
        merge_maps(left_value, right_value)
      else
        right_value
      end
    end)
  end
end
