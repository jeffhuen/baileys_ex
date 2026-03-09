defmodule BaileysEx.Signal.Store.Memory do
  @moduledoc """
  In-memory runtime implementation of `BaileysEx.Signal.Store`.

  Reads go through ETS. Writes and transaction locks are coordinated by the
  owner process so concurrent callers can share a single mutable store without
  manually threading state through repository calls.
  """

  use GenServer

  @behaviour BaileysEx.Signal.Store

  defmodule Ref do
    @moduledoc false

    @enforce_keys [:pid, :table]
    defstruct [:pid, :table]
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
    case current_tx(ref) do
      nil -> read_entries(ref.table, type, ids)
      context -> read_entries_in_transaction(ref, context, type, ids)
    end
  end

  @impl true
  def set(%Ref{} = ref, data) when is_map(data) do
    case current_tx(ref) do
      nil ->
        GenServer.call(ref.pid, {:set, data}, :infinity)

      context ->
        update_tx(ref, merge_data(context, data))
        :ok
    end
  end

  @impl true
  def clear(%Ref{} = ref) do
    GenServer.call(ref.pid, :clear, :infinity)
  end

  @impl true
  def transaction(%Ref{} = ref, key, fun) when is_binary(key) and is_function(fun, 0) do
    case current_tx(ref) do
      nil ->
        :ok = GenServer.call(ref.pid, {:lock, key, self()}, :infinity)
        update_tx(ref, %{cache: %{}, mutations: %{}})

        try do
          result = fun.()
          context = current_tx(ref)
          :ok = commit(ref, context.mutations)
          result
        after
          clear_tx(ref)
          :ok = GenServer.call(ref.pid, {:unlock, key, self()}, :infinity)
        end

      _existing ->
        fun.()
    end
  end

  @impl true
  def in_transaction?(%Ref{} = ref), do: not is_nil(current_tx(ref))

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

  def handle_call(:clear, _from, state) do
    true = :ets.delete_all_objects(state.table)
    {:reply, :ok, state}
  end

  def handle_call({:lock, key, owner}, from, state) do
    case Map.get(state.locks, key) do
      nil ->
        {updated_state, _lock} = put_lock(state, key, owner)
        {:reply, :ok, updated_state}

      _lock ->
        {:noreply, enqueue_waiter(state, key, from, owner)}
    end
  end

  def handle_call({:unlock, key, owner}, _from, state) do
    {:reply, :ok, release_lock(state, key, owner)}
  end

  @impl true
  def handle_info({:DOWN, monitor_ref, :process, owner, _reason}, state) do
    case Map.pop(state.monitor_keys, monitor_ref) do
      {nil, _monitor_keys} ->
        {:noreply, state}

      {key, monitor_keys} ->
        updated_state = %{state | monitor_keys: monitor_keys}
        {:noreply, release_lock(updated_state, key, owner, monitor_ref)}
    end
  end

  defp current_tx(%Ref{pid: pid}), do: Process.get({__MODULE__, pid})
  defp update_tx(%Ref{pid: pid}, context), do: Process.put({__MODULE__, pid}, context)
  defp clear_tx(%Ref{pid: pid}), do: Process.delete({__MODULE__, pid})

  defp read_entries_in_transaction(ref, context, type, ids) do
    type_cache = Map.get(context.cache, type, %{})
    missing_ids = Enum.reject(ids, &Map.has_key?(type_cache, &1))
    fetched = read_entries(ref.table, type, missing_ids)
    updated_context = cache_fetched(context, type, missing_ids, fetched)

    ref
    |> update_tx(updated_context)

    ids
    |> Enum.reduce(%{}, fn id, acc ->
      case Map.fetch(updated_context.cache[type] || %{}, id) do
        {:ok, nil} -> acc
        {:ok, value} -> Map.put(acc, id, value)
        :error -> acc
      end
    end)
  end

  defp cache_fetched(context, type, missing_ids, fetched) do
    type_cache =
      Enum.reduce(missing_ids, Map.get(context.cache, type, %{}), fn id, acc ->
        Map.put(acc, id, Map.get(fetched, id))
      end)

    put_in(context, [:cache, type], type_cache)
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

  defp merge_data(context, data) do
    Enum.reduce(data, context, fn {type, entries}, acc ->
      acc
      |> update_in([:cache, type], &Map.merge(&1 || %{}, entries))
      |> update_in([:mutations, type], &Map.merge(&1 || %{}, entries))
    end)
  end

  defp commit(_ref, mutations) when map_size(mutations) == 0, do: :ok
  defp commit(%Ref{pid: pid}, mutations), do: GenServer.call(pid, {:set, mutations}, :infinity)

  defp persist_entries(table, data) do
    Enum.each(data, fn {type, entries} ->
      Enum.each(entries, fn
        {id, nil} -> :ets.delete(table, {type, id})
        {id, value} -> true = :ets.insert(table, {{type, id}, value})
      end)
    end)

    :ok
  end

  defp put_lock(state, key, owner) do
    monitor_ref = Process.monitor(owner)
    lock = %{owner: owner, monitor_ref: monitor_ref, queue: :queue.new()}

    updated_state = %{
      state
      | locks: Map.put(state.locks, key, lock),
        monitor_keys: Map.put(state.monitor_keys, monitor_ref, key)
    }

    {updated_state, lock}
  end

  defp enqueue_waiter(state, key, from, owner) do
    update_in(state, [:locks, key, :queue], fn queue ->
      :queue.in({from, owner}, queue || :queue.new())
    end)
  end

  defp release_lock(state, key, owner, monitor_ref \\ nil) do
    case Map.get(state.locks, key) do
      %{owner: ^owner, monitor_ref: lock_monitor_ref, queue: queue} ->
        demonitor_ref = monitor_ref || lock_monitor_ref
        Process.demonitor(demonitor_ref, [:flush])

        state
        |> update_in([:monitor_keys], &Map.delete(&1, demonitor_ref))
        |> promote_next_waiter(key, queue)

      _other ->
        state
    end
  end

  defp promote_next_waiter(state, key, queue) do
    case :queue.out(queue) do
      {{:value, {from, owner}}, remaining} ->
        {updated_state, lock} = put_lock(state, key, owner)
        next_state = put_in(updated_state, [:locks, key, :queue], remaining)
        GenServer.reply(from, :ok)
        put_in(next_state, [:locks, key], %{lock | queue: remaining})

      {:empty, _queue} ->
        %{state | locks: Map.delete(state.locks, key)}
    end
  end
end
