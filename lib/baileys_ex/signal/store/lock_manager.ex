defmodule BaileysEx.Signal.Store.LockManager do
  @moduledoc false

  @type state :: %{required(:locks) => map(), required(:monitor_keys) => map()}

  @spec acquire(state(), term(), GenServer.from(), pid()) :: {:acquired | :queued, state()}
  def acquire(state, key, from, owner) do
    case Map.get(state.locks, key) do
      nil ->
        {updated_state, _lock} = put_lock(state, key, owner)
        {:acquired, updated_state}

      _lock ->
        {:queued, enqueue_waiter(state, key, from, owner)}
    end
  end

  @spec release(state(), term(), pid(), reference() | nil) :: state()
  def release(state, key, owner, monitor_ref \\ nil) do
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

  @spec handle_owner_down(state(), reference(), pid()) :: state()
  def handle_owner_down(state, monitor_ref, owner) do
    case Map.pop(state.monitor_keys, monitor_ref) do
      {nil, _monitor_keys} ->
        state

      {key, monitor_keys} ->
        updated_state = %{state | monitor_keys: monitor_keys}
        release(updated_state, key, owner, monitor_ref)
    end
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

  defp promote_next_waiter(state, key, queue) do
    case :queue.out(queue) do
      {{:value, {from, owner}}, remaining} ->
        {updated_state, lock} = put_lock(state, key, owner)
        GenServer.reply(from, :ok)
        put_in(updated_state, [:locks, key], %{lock | queue: remaining})

      {:empty, _queue} ->
        %{state | locks: Map.delete(state.locks, key)}
    end
  end
end
