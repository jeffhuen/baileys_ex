defmodule BaileysEx.Signal.Store.Memory do
  @moduledoc """
  In-memory runtime implementation of `BaileysEx.Signal.Store`.

  Reads go through ETS. Writes and transaction locks are coordinated by the
  owner process. Transaction-local cache and mutation state live on an explicit
  transaction handle instead of hidden caller-local process state.
  """

  use GenServer

  @behaviour BaileysEx.Signal.Store

  alias BaileysEx.Signal.Store.LockManager
  alias BaileysEx.Signal.Store.TransactionBuffer

  defmodule Ref do
    @moduledoc false

    @enforce_keys [:pid, :table]
    defstruct [:pid, :table]
  end

  defmodule TxRef do
    @moduledoc false

    @enforce_keys [:pid, :table, :tx_table]
    defstruct [:pid, :table, :tx_table]
  end

  @impl true
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  @impl true
  def wrap(pid) when is_pid(pid) do
    %Ref{pid: pid, table: GenServer.call(pid, :table)}
  end

  @impl true
  def get(%Ref{} = ref, type, ids) when is_list(ids) do
    read_entries(ref.table, type, ids)
  end

  def get(%TxRef{} = ref, type, ids) when is_list(ids) do
    read_entries_in_transaction(ref, type, ids)
  end

  @impl true
  def set(%Ref{} = ref, data) when is_map(data) do
    GenServer.call(ref.pid, {:set, data}, :infinity)
  end

  def set(%TxRef{} = ref, data) when is_map(data) do
    :ok = TransactionBuffer.put_entries(ref.tx_table, data)
    :ok
  end

  @impl true
  def clear(%Ref{} = ref) do
    GenServer.call(ref.pid, :clear, :infinity)
  end

  def clear(%TxRef{} = ref) do
    :ok = TransactionBuffer.clear(ref.tx_table)
    :ok
  end

  @impl true
  def transaction(%Ref{} = ref, key, fun) when is_binary(key) and is_function(fun, 1) do
    :ok = GenServer.call(ref.pid, {:lock, key, self()}, :infinity)
    tx_table = TransactionBuffer.new()
    tx_ref = %TxRef{pid: ref.pid, table: ref.table, tx_table: tx_table}

    try do
      result = fun.(tx_ref)
      :ok = commit(tx_ref)
      result
    after
      TransactionBuffer.delete(tx_table)
      :ok = GenServer.call(ref.pid, {:unlock, key, self()}, :infinity)
    end
  end

  @impl true
  def transaction(%TxRef{} = ref, _key, fun) when is_function(fun, 1), do: fun.(ref)

  @impl true
  def in_transaction?(%Ref{}), do: false
  def in_transaction?(%TxRef{}), do: true

  @impl true
  def init(_opts) do
    table = :ets.new(__MODULE__, [:set, :protected, read_concurrency: true])
    {:ok, %{table: table, locks: %{}, monitor_keys: %{}}}
  end

  @impl true
  def handle_call(:table, _from, state), do: {:reply, state.table, state}

  def handle_call({:set, data}, _from, state) do
    :ok = persist_entries(state.table, data)
    {:reply, :ok, state}
  end

  def handle_call({:commit_tx, clear?, data}, _from, state) do
    if clear? do
      true = :ets.delete_all_objects(state.table)
    end

    :ok = persist_entries(state.table, data)
    {:reply, :ok, state}
  end

  def handle_call(:clear, _from, state) do
    true = :ets.delete_all_objects(state.table)
    {:reply, :ok, state}
  end

  def handle_call({:lock, key, owner}, from, state) do
    case LockManager.acquire(state, key, from, owner) do
      {:acquired, updated_state} ->
        {:reply, :ok, updated_state}

      {:queued, updated_state} ->
        {:noreply, updated_state}
    end
  end

  def handle_call({:unlock, key, owner}, _from, state) do
    {:reply, :ok, LockManager.release(state, key, owner)}
  end

  @impl true
  def handle_info({:DOWN, monitor_ref, :process, owner, _reason}, state) do
    {:noreply, LockManager.handle_owner_down(state, monitor_ref, owner)}
  end

  defp read_entries_in_transaction(%TxRef{} = ref, type, ids) do
    {_entries, missing_ids} = TransactionBuffer.cached_entries(ref.tx_table, type, ids)

    if missing_ids != [] do
      fetched =
        if TransactionBuffer.cleared?(ref.tx_table) do
          %{}
        else
          read_entries(ref.table, type, missing_ids)
        end

      :ok = TransactionBuffer.cache_fetched(ref.tx_table, type, missing_ids, fetched)
    end

    ref.tx_table
    |> TransactionBuffer.cached_entries(type, ids)
    |> elem(0)
  end

  defp read_entries(_table, _type, []), do: %{}

  defp read_entries(table, type, ids) do
    Enum.reduce(ids, %{}, fn id, acc ->
      case :ets.lookup(table, {type, id}) do
        [{{^type, ^id}, value}] -> Map.put(acc, id, value)
        [] -> acc
      end
    end)
  end

  defp commit(%TxRef{pid: pid, tx_table: tx_table}) do
    clear? = TransactionBuffer.cleared?(tx_table)
    mutations = TransactionBuffer.mutation_data(tx_table)

    if not clear? and map_size(mutations) == 0 do
      :ok
    else
      GenServer.call(pid, {:commit_tx, clear?, mutations}, :infinity)
    end
  end

  defp persist_entries(table, data) do
    Enum.each(data, fn {type, entries} ->
      Enum.each(entries, fn
        {id, nil} -> :ets.delete(table, {type, id})
        {id, value} -> true = :ets.insert(table, {{type, id}, value})
      end)
    end)

    :ok
  end
end
