defmodule BaileysEx.Connection.EventEmitter do
  @moduledoc """
  Buffered connection event emitter modeled after Baileys' `makeEventBuffer`.
  """

  use GenServer

  @bufferable_events MapSet.new([
                       :messaging_history_set,
                       :chats_upsert,
                       :chats_update,
                       :chats_delete,
                       :contacts_upsert,
                       :contacts_update,
                       :messages_upsert,
                       :messages_update,
                       :messages_delete,
                       :messages_reaction,
                       :message_receipt_update,
                       :groups_update
                     ])

  defmodule State do
    @moduledoc false

    defstruct subscribers: %{},
              taps: %{},
              dispatcher_pid: nil,
              dispatcher_ref: nil,
              dispatch_queue: :queue.new(),
              dispatching?: false,
              ref_fun: nil,
              buffer_timeout_ms: 30_000,
              buffer_timer: nil,
              flush_pending_timer: nil,
              buffering?: false,
              buffer_count: 0,
              seed: %{},
              buffered_events: %{}
  end

  @type event ::
          :blocklist_set
          | :blocklist_update
          | :call
          | :chats_delete
          | :chats_lock
          | :chats_update
          | :chats_upsert
          | :connection_update
          | :contacts_update
          | :contacts_upsert
          | :creds_update
          | :dirty_update
          | :group_join_request
          | :group_member_tag_update
          | :group_participants_update
          | :groups_update
          | :groups_upsert
          | :labels_association
          | :labels_edit
          | :lid_mapping_update
          | :message_receipt_update
          | :messages_delete
          | :messages_media_update
          | :messages_reaction
          | :messages_update
          | :messages_upsert
          | :messaging_history_set
          | :newsletter_participants_update
          | :newsletter_reaction
          | :newsletter_settings_update
          | :newsletter_view
          | :presence_update
          | :socket_node
          | :settings_update

  @doc """
  Starts the EventEmitter.
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

  @doc """
  Registers a process handler function for events.
  Returns an unsubscription function.
  """
  @spec process(GenServer.server(), (map() -> term())) :: (-> :ok)
  def process(server, handler) when is_function(handler, 1) do
    ref = GenServer.call(server, {:process, handler})
    fn -> GenServer.cast(server, {:unsubscribe, ref}) end
  end

  @doc """
  Registers a tap handler function that processes events before the main dispatch.
  Returns an unsubscription function.
  """
  @spec tap(GenServer.server(), (map() -> term())) :: (-> :ok)
  def tap(server, handler) when is_function(handler, 1) do
    ref = GenServer.call(server, {:tap, handler})
    fn -> GenServer.cast(server, {:unsubscribe_tap, ref}) end
  end

  @doc """
  Emit a specific event. Will buffer the event if buffering is currently active.
  """
  @spec emit(GenServer.server(), event(), term()) :: :ok
  def emit(server, event, data), do: GenServer.call(server, {:emit, event, data})

  @doc """
  Signals the emitter to enter buffering mode.
  """
  @spec buffer(GenServer.server()) :: :ok
  def buffer(server), do: GenServer.call(server, :buffer)

  @doc """
  Wraps a function execution in an active event buffer context.
  """
  @spec create_buffered_function(GenServer.server(), (-> term())) :: (-> term())
  def create_buffered_function(server, work) when is_function(work, 0) do
    fn ->
      :ok = buffer(server)

      try do
        work.()
      after
        :ok = GenServer.call(server, :buffer_complete)
      end
    end
  end

  @doc """
  Manually flushes the buffer if active. Returns true if a flush occurred.
  """
  @spec flush(GenServer.server()) :: boolean()
  def flush(server), do: GenServer.call(server, :flush)

  @doc """
  Returns whether the event emitter is currently in buffering mode.
  """
  @spec buffering?(GenServer.server()) :: boolean()
  def buffering?(server), do: GenServer.call(server, :buffering?)

  @doc """
  Provides seed values used during conditional event flush evaluation.
  """
  @spec seed(GenServer.server(), map()) :: :ok
  def seed(server, values) when is_map(values), do: GenServer.call(server, {:seed, values})

  @impl true
  def init(opts) do
    {dispatcher_pid, dispatcher_ref} = start_dispatcher(self())

    state = %State{
      buffer_timeout_ms: Keyword.get(opts, :buffer_timeout_ms, 30_000),
      dispatcher_pid: dispatcher_pid,
      dispatcher_ref: dispatcher_ref,
      ref_fun: Keyword.get(opts, :ref_fun, &make_ref/0)
    }

    {:ok, register_initial_subscribers(state, Keyword.get(opts, :initial_subscribers, []))}
  end

  @impl true
  def handle_call({:process, handler}, _from, %State{} = state) do
    ref = state.ref_fun.()
    {:reply, ref, %{state | subscribers: Map.put(state.subscribers, ref, handler)}}
  end

  def handle_call({:tap, handler}, _from, %State{} = state) do
    ref = state.ref_fun.()
    {:reply, ref, %{state | taps: Map.put(state.taps, ref, handler)}}
  end

  def handle_call({:emit, event, data}, _from, %State{} = state) do
    {state, deliveries} = emit_event(state, event, data)
    {:reply, :ok, enqueue_dispatch(state, [%{event => data}], deliveries)}
  end

  def handle_call(:buffer, _from, %State{} = state) do
    state =
      state
      |> ensure_buffering()
      |> Map.update!(:buffer_count, &(&1 + 1))

    {:reply, :ok, state}
  end

  def handle_call(:buffer_complete, _from, %State{} = state) do
    state =
      state
      |> Map.update!(:buffer_count, &max(&1 - 1, 0))
      |> schedule_pending_flush()

    {:reply, :ok, state}
  end

  def handle_call(:flush, _from, %State{buffering?: false} = state) do
    {:reply, false, state}
  end

  def handle_call(:flush, _from, %State{} = state) do
    {state, deliveries} = flush_buffer(state, :stop)
    {:reply, true, enqueue_dispatch(state, [], deliveries)}
  end

  def handle_call(:buffering?, _from, %State{} = state) do
    {:reply, state.buffering?, state}
  end

  def handle_call({:seed, values}, _from, %State{} = state) do
    {:reply, :ok, %{state | seed: Map.merge(state.seed, values)}}
  end

  @impl true
  def handle_cast({:unsubscribe, ref}, %State{} = state) do
    {:noreply, %{state | subscribers: Map.delete(state.subscribers, ref)}}
  end

  def handle_cast({:unsubscribe_tap, ref}, %State{} = state) do
    {:noreply, %{state | taps: Map.delete(state.taps, ref)}}
  end

  @impl true
  def handle_info(:buffer_timeout, %State{buffering?: false} = state) do
    {:noreply, %{state | buffer_timer: nil}}
  end

  def handle_info(:buffer_timeout, %State{} = state) do
    {state, deliveries} = flush_buffer(state, :stop)
    {:noreply, enqueue_dispatch(state, [], deliveries)}
  end

  def handle_info(:flush_pending, %State{buffering?: true, buffer_count: 0} = state) do
    {state, deliveries} = flush_buffer(state, :stop)
    {:noreply, enqueue_dispatch(state, [], deliveries)}
  end

  def handle_info(:flush_pending, %State{} = state) do
    {:noreply, %{state | flush_pending_timer: nil}}
  end

  def handle_info(
        {:dispatch_complete, dispatcher_pid, dispatch_id},
        %State{dispatcher_pid: dispatcher_pid, dispatching?: true} = state
      ) do
    case :queue.out(state.dispatch_queue) do
      {{:value, {^dispatch_id, _taps, _tap_deliveries, _subscribers, _deliveries}}, remaining} ->
        state =
          state
          |> Map.put(:dispatch_queue, remaining)
          |> Map.put(:dispatching?, false)
          |> maybe_dispatch_next()

        {:noreply, state}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info(
        {:DOWN, dispatcher_ref, :process, dispatcher_pid, _reason},
        %State{dispatcher_ref: dispatcher_ref, dispatcher_pid: dispatcher_pid} = state
      ) do
    {new_dispatcher_pid, new_dispatcher_ref} = start_dispatcher(self())

    state =
      state
      |> Map.put(:dispatcher_pid, new_dispatcher_pid)
      |> Map.put(:dispatcher_ref, new_dispatcher_ref)
      |> Map.put(:dispatching?, false)
      |> maybe_dispatch_next()

    {:noreply, state}
  end

  def handle_info(_message, %State{} = state), do: {:noreply, state}

  defp emit_event(%State{buffering?: true} = state, :messages_upsert, %{type: type} = data) do
    {state, deliveries} =
      case get_in(state.buffered_events, [:messages_upsert, :type]) do
        nil ->
          {state, []}

        ^type ->
          {state, []}

        _buffered_type ->
          flush_buffer(state, :keep)
      end

    state =
      update_in(state.buffered_events, fn buffered_events ->
        Map.update(buffered_events, :messages_upsert, data, fn existing ->
          %{existing | messages: existing.messages ++ data.messages}
        end)
      end)

    {state, deliveries}
  end

  defp emit_event(%State{buffering?: true} = state, :chats_update, updates)
       when is_list(updates) do
    state =
      update_in(state.buffered_events, fn buffered_events ->
        Map.update(buffered_events, :chats_update, updates, &(&1 ++ updates))
      end)

    {state, []}
  end

  defp emit_event(%State{buffering?: true} = state, event, data) do
    if MapSet.member?(@bufferable_events, event) do
      state =
        update_in(state.buffered_events, fn buffered_events ->
          Map.put(buffered_events, event, data)
        end)

      {state, []}
    else
      {state, [%{event => data}]}
    end
  end

  defp emit_event(%State{} = state, event, data), do: {state, [%{event => data}]}

  defp flush_buffer(%State{} = state, mode) do
    {events_to_emit, buffered_events} = build_flush_payload(state.buffered_events, state.seed)

    state =
      state
      |> maybe_cancel_buffer_timer()
      |> maybe_cancel_pending_flush()
      |> Map.put(:buffered_events, buffered_events)
      |> Map.put(:buffer_timer, nil)
      |> Map.put(:flush_pending_timer, nil)
      |> Map.put(:buffering?, mode == :keep)
      |> Map.put(:buffer_count, 0)

    deliveries =
      if map_size(events_to_emit) == 0 do
        []
      else
        [events_to_emit]
      end

    state =
      if mode == :keep do
        ensure_buffering(%{state | buffer_timer: nil})
      else
        state
      end

    {state, deliveries}
  end

  defp build_flush_payload(buffered_events, seed) do
    generic_events =
      buffered_events
      |> Map.drop([:chats_update])
      |> Enum.reject(fn {_event, data} -> is_nil(data) end)
      |> Map.new()

    {chat_updates, unresolved_chat_updates} =
      buffered_events
      |> Map.get(:chats_update, [])
      |> Enum.reduce({[], []}, fn update, {ready, pending} ->
        case evaluate_chat_update(update, seed) do
          {:emit, emitted_update} -> {[emitted_update | ready], pending}
          {:pending, pending_update} -> {ready, [pending_update | pending]}
          :drop -> {ready, pending}
        end
      end)

    events_to_emit =
      generic_events
      |> maybe_put(:chats_update, Enum.reverse(chat_updates), chat_updates != [])

    buffered_events =
      %{}
      |> maybe_put(
        :chats_update,
        Enum.reverse(unresolved_chat_updates),
        unresolved_chat_updates != []
      )

    {events_to_emit, buffered_events}
  end

  defp evaluate_chat_update(%{conditional: condition} = update, seed)
       when is_function(condition, 1) do
    case condition.(seed) do
      true -> {:emit, Map.delete(update, :conditional)}
      nil -> {:pending, update}
      _ -> :drop
    end
  end

  defp evaluate_chat_update(update, _seed), do: {:emit, update}

  defp ensure_buffering(%State{buffering?: true} = state), do: state

  defp ensure_buffering(%State{} = state) do
    state
    |> maybe_cancel_buffer_timer()
    |> Map.put(:buffering?, true)
    |> Map.put(
      :buffer_timer,
      Process.send_after(self(), :buffer_timeout, state.buffer_timeout_ms)
    )
  end

  defp schedule_pending_flush(%State{buffer_count: count} = state) when count > 0, do: state
  defp schedule_pending_flush(%State{buffering?: false} = state), do: state

  defp schedule_pending_flush(%State{flush_pending_timer: timer} = state) when not is_nil(timer),
    do: state

  defp schedule_pending_flush(%State{} = state) do
    %{
      state
      | flush_pending_timer: Process.send_after(self(), :flush_pending, 100)
    }
  end

  defp maybe_cancel_buffer_timer(%State{buffer_timer: nil} = state), do: state

  defp maybe_cancel_buffer_timer(%State{buffer_timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | buffer_timer: nil}
  end

  defp maybe_cancel_pending_flush(%State{flush_pending_timer: nil} = state), do: state

  defp maybe_cancel_pending_flush(%State{flush_pending_timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | flush_pending_timer: nil}
  end

  defp enqueue_dispatch(%State{} = state, tap_deliveries, deliveries) do
    if tap_deliveries == [] and deliveries == [] do
      state
    else
      dispatch_entry = {
        state.ref_fun.(),
        state.taps,
        tap_deliveries,
        state.subscribers,
        deliveries
      }

      state
      |> Map.update!(:dispatch_queue, &:queue.in(dispatch_entry, &1))
      |> maybe_dispatch_next()
    end
  end

  defp start_dispatcher(owner_pid) when is_pid(owner_pid) do
    spawn_monitor(fn ->
      Process.flag(:trap_exit, true)
      owner_ref = Process.monitor(owner_pid)
      dispatch_loop(owner_pid, owner_ref)
    end)
  end

  defp maybe_dispatch_next(%State{dispatching?: true} = state), do: state

  defp maybe_dispatch_next(%State{} = state) do
    case :queue.out(state.dispatch_queue) do
      {{:value, {dispatch_id, taps, tap_deliveries, subscribers, deliveries}}, _remaining} ->
        send(
          state.dispatcher_pid,
          {:dispatch, self(), dispatch_id, taps, tap_deliveries, subscribers, deliveries}
        )

        %{state | dispatching?: true}

      {:empty, _queue} ->
        state
    end
  end

  defp dispatch_loop(owner_pid, owner_ref) do
    receive do
      {:dispatch, ^owner_pid, dispatch_id, taps, tap_deliveries, subscribers, deliveries} ->
        dispatch(taps, tap_deliveries)
        dispatch(subscribers, deliveries)
        send(owner_pid, {:dispatch_complete, self(), dispatch_id})
        dispatch_loop(owner_pid, owner_ref)

      {:DOWN, ^owner_ref, :process, ^owner_pid, _reason} ->
        :ok

      {:EXIT, _pid, _reason} ->
        dispatch_loop(owner_pid, owner_ref)

      _other ->
        dispatch_loop(owner_pid, owner_ref)
    end
  end

  defp dispatch(_subscribers, []), do: :ok

  defp dispatch(subscribers, deliveries) do
    require Logger

    Enum.each(deliveries, fn delivery ->
      Enum.each(subscribers, fn {ref, handler} ->
        try do
          handler.(delivery)
        rescue
          error ->
            Logger.error(
              "[EventEmitter] subscriber #{inspect(ref)} crashed: #{Exception.message(error)}"
            )
        catch
          kind, reason ->
            Logger.error(
              "[EventEmitter] subscriber #{inspect(ref)} crashed: " <>
                Exception.format_banner(kind, reason)
            )
        end
      end)
    end)
  end

  defp register_initial_subscribers(%State{} = state, subscribers) when is_list(subscribers) do
    Enum.reduce(subscribers, state, fn
      handler, %State{} = acc when is_function(handler, 1) ->
        ref = acc.ref_fun.()
        %{acc | subscribers: Map.put(acc.subscribers, ref, handler)}

      _handler, %State{} = acc ->
        acc
    end)
  end

  defp register_initial_subscribers(%State{} = state, _subscribers), do: state

  defp maybe_put(map, _key, _value, false), do: map
  defp maybe_put(map, key, value, true), do: Map.put(map, key, value)
end
