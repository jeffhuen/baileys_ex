defmodule BaileysEx.Connection.EventEmitter.Server do
  @moduledoc false

  use GenServer

  @bufferable_events Map.new(
                       [
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
                       ],
                       &{&1, true}
                     )

  defmodule State do
    @moduledoc false

    defstruct subscribers: %{},
              taps: %{},
              tap_order: [],
              handler_table: nil,
              task_supervisor: nil,
              dispatch_queue: :queue.new(),
              dispatch_task: nil,
              dispatch_entry: nil,
              task_owners: %{},
              dispatch_retry_timer: nil,
              max_dispatch_queue: 1_024,
              ref_fun: nil,
              buffer_timeout_ms: 30_000,
              buffer_timer: nil,
              flush_pending_timer: nil,
              buffering?: false,
              buffer_count: 0,
              seed: %{},
              buffered_events: %{}
  end

  defmodule Subscriber do
    @moduledoc false

    defstruct subscribed?: true,
              reserved: 0,
              queue: :queue.new(),
              task: nil,
              entry: nil
  end

  defmodule Tap do
    @moduledoc false

    defstruct subscribed?: true, pending: 0
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
          | :message_capping_update
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
  @spec emit(GenServer.server(), event(), term()) ::
          :ok | {:error, :dispatch_queue_full}
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
  @spec flush(GenServer.server()) :: boolean() | {:error, :dispatch_queue_full}
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
    state = %State{
      handler_table: :ets.new(__MODULE__, [:set, :protected, read_concurrency: true]),
      buffer_timeout_ms: Keyword.get(opts, :buffer_timeout_ms, 30_000),
      task_supervisor: Keyword.get(opts, :task_supervisor),
      max_dispatch_queue: normalize_max_dispatch_queue(Keyword.get(opts, :max_dispatch_queue)),
      ref_fun: Keyword.get(opts, :ref_fun, &make_ref/0)
    }

    {:ok, register_initial_subscribers(state, Keyword.get(opts, :initial_subscribers, []))}
  end

  @impl true
  def handle_call({:process, handler}, _from, %State{} = state) do
    ref = state.ref_fun.()
    true = :ets.insert(state.handler_table, {{:subscriber, ref}, handler})

    {:reply, ref, %{state | subscribers: Map.put(state.subscribers, ref, %Subscriber{})}}
  end

  def handle_call({:tap, handler}, _from, %State{} = state) do
    ref = state.ref_fun.()
    true = :ets.insert(state.handler_table, {{:tap, ref}, handler})

    {:reply, ref,
     %{
       state
       | taps: Map.put(state.taps, ref, %Tap{}),
         tap_order: state.tap_order ++ [ref]
     }}
  end

  def handle_call({:emit, event, data}, _from, %State{} = state) do
    {updated_state, deliveries} = emit_event(state, event, data)

    case enqueue_dispatch(updated_state, [%{event => data}], deliveries) do
      {:ok, updated_state} -> {:reply, :ok, updated_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
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
    {flushed_state, deliveries} = flush_buffer(state, :stop)

    case enqueue_dispatch(flushed_state, [], deliveries) do
      {:ok, state} -> {:reply, true, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:buffering?, _from, %State{} = state) do
    {:reply, state.buffering?, state}
  end

  def handle_call({:seed, values}, _from, %State{} = state) do
    {:reply, :ok, %{state | seed: Map.merge(state.seed, values)}}
  end

  @impl true
  def handle_cast({:unsubscribe, ref}, %State{} = state) do
    {:noreply, unsubscribe_subscriber(state, ref)}
  end

  def handle_cast({:unsubscribe_tap, ref}, %State{} = state) do
    {:noreply, unsubscribe_tap(state, ref)}
  end

  @impl true
  def handle_info(:buffer_timeout, %State{buffering?: false} = state) do
    {:noreply, %{state | buffer_timer: nil}}
  end

  def handle_info(:buffer_timeout, %State{} = state) do
    {:noreply, flush_when_dispatch_available(state)}
  end

  def handle_info(:flush_pending, %State{buffering?: true, buffer_count: 0} = state) do
    {:noreply, flush_when_dispatch_available(state)}
  end

  def handle_info(:flush_pending, %State{} = state) do
    {:noreply, %{state | flush_pending_timer: nil}}
  end

  def handle_info({task_ref, :ok}, %State{} = state) when is_reference(task_ref) do
    {:noreply, complete_task(state, task_ref)}
  end

  # A dispatch task can disappear with its Task.Supervisor. Retain the active
  # entry and retry it once the supervisor is available again.
  def handle_info({:DOWN, task_ref, :process, _pid, _reason}, %State{} = state) do
    {:noreply, fail_task(state, task_ref)}
  end

  def handle_info(:dispatch_retry, %State{} = state) do
    {:noreply, state |> Map.put(:dispatch_retry_timer, nil) |> maybe_start_dispatches()}
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
    if Map.has_key?(@bufferable_events, event) do
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
    tap_refs = active_tap_refs(state)
    tap_work? = tap_deliveries != [] and tap_refs != []
    subscriber_work? = deliveries != [] and active_subscribers?(state)

    do_enqueue_dispatch(
      state,
      tap_refs,
      tap_deliveries,
      deliveries,
      tap_work?,
      subscriber_work?
    )
  end

  defp do_enqueue_dispatch(state, _tap_refs, _tap_deliveries, _deliveries, false, false),
    do: {:ok, state}

  defp do_enqueue_dispatch(
         %State{} = state,
         tap_refs,
         tap_deliveries,
         deliveries,
         tap_work?,
         subscriber_work?
       ) do
    gate_subscribers? = tap_work? or (subscriber_work? and dispatch_queue_size(state) > 0)

    if gate_subscribers? and dispatch_queue_size(state) >= state.max_dispatch_queue do
      {:error, :dispatch_queue_full}
    else
      queue_dispatch(state, tap_refs, tap_deliveries, deliveries, gate_subscribers?)
    end
  end

  defp queue_dispatch(state, tap_refs, tap_deliveries, deliveries, gate_subscribers?) do
    {state, subscriber_refs} =
      prepare_subscribers(state, deliveries, gate_subscribers?)

    state =
      maybe_enqueue_gated_dispatch(
        state,
        tap_refs,
        tap_deliveries,
        subscriber_refs,
        deliveries,
        gate_subscribers?
      )

    {:ok, maybe_start_dispatches(state)}
  end

  defp maybe_enqueue_gated_dispatch(state, _tap_refs, _tap_deliveries, _refs, _deliveries, false),
    do: state

  defp maybe_enqueue_gated_dispatch(
         state,
         tap_refs,
         tap_deliveries,
         subscriber_refs,
         deliveries,
         true
       ) do
    entry = {
      state.ref_fun.(),
      tap_refs,
      tap_deliveries,
      subscriber_refs,
      deliveries
    }

    state
    |> retain_taps(tap_refs)
    |> Map.update!(:dispatch_queue, &:queue.in(entry, &1))
  end

  defp dispatch_queue_size(%State{} = state) do
    :queue.len(state.dispatch_queue) + if(state.dispatch_task, do: 1, else: 0)
  end

  defp active_tap_refs(%State{} = state) do
    Enum.filter(state.tap_order, fn ref ->
      match?(%Tap{subscribed?: true}, Map.get(state.taps, ref))
    end)
  end

  defp active_subscribers?(%State{} = state) do
    Enum.any?(state.subscribers, fn {_ref, subscriber} -> subscriber.subscribed? end)
  end

  defp prepare_subscribers(%State{} = state, [], _gated?), do: {state, []}

  defp prepare_subscribers(%State{} = state, deliveries, gated?) do
    delivery_count = length(deliveries)

    state.subscribers
    |> Map.keys()
    |> Enum.reduce({state, []}, fn ref, {acc, refs} ->
      case prepare_subscriber(acc, ref, deliveries, delivery_count, gated?) do
        {:include, updated_state} -> {updated_state, [ref | refs]}
        {:skip, updated_state} -> {updated_state, refs}
      end
    end)
    |> then(fn {updated_state, refs} -> {updated_state, Enum.reverse(refs)} end)
  end

  defp prepare_subscriber(state, ref, deliveries, delivery_count, gated?) do
    case Map.get(state.subscribers, ref) do
      %Subscriber{subscribed?: true} = subscriber ->
        prepare_active_subscriber(state, ref, subscriber, deliveries, delivery_count, gated?)

      _ ->
        {:skip, state}
    end
  end

  defp prepare_active_subscriber(state, ref, subscriber, deliveries, delivery_count, gated?) do
    if subscriber_queue_size(subscriber) + delivery_count > state.max_dispatch_queue do
      {:skip, drop_subscriber(state, ref, :dispatch_queue_full)}
    else
      subscriber = reserve_or_enqueue(subscriber, deliveries, delivery_count, gated?)
      subscribers = Map.put(state.subscribers, ref, subscriber)
      {:include, %{state | subscribers: subscribers}}
    end
  end

  defp reserve_or_enqueue(subscriber, _deliveries, delivery_count, true),
    do: %{subscriber | reserved: subscriber.reserved + delivery_count}

  defp reserve_or_enqueue(subscriber, deliveries, _delivery_count, false),
    do: enqueue_subscriber_deliveries(subscriber, deliveries)

  defp enqueue_subscriber_deliveries(%Subscriber{} = subscriber, deliveries) do
    queue = Enum.reduce(deliveries, subscriber.queue, &:queue.in/2)
    %{subscriber | queue: queue}
  end

  defp subscriber_queue_size(%Subscriber{} = subscriber) do
    :queue.len(subscriber.queue) + subscriber.reserved + if(subscriber.task, do: 1, else: 0)
  end

  defp retain_taps(%State{} = state, refs) do
    taps =
      Enum.reduce(refs, state.taps, fn ref, taps ->
        Map.update!(taps, ref, &%{&1 | pending: &1.pending + 1})
      end)

    %{state | taps: taps}
  end

  defp maybe_start_dispatches(%State{} = state) do
    state
    |> maybe_dispatch_next()
    |> maybe_start_subscribers()
  end

  defp maybe_dispatch_next(%State{dispatch_task: %Task{}} = state), do: state

  defp maybe_dispatch_next(%State{} = state) do
    case :queue.out(state.dispatch_queue) do
      {{:value, entry}, remaining} ->
        dispatch_entry(state, entry, remaining)

      {:empty, _queue} ->
        state
    end
  end

  defp dispatch_entry(
         state,
         {_dispatch_id, [], _tap_deliveries, subscriber_refs, deliveries},
         remaining
       ) do
    state
    |> Map.put(:dispatch_queue, remaining)
    |> release_subscriber_deliveries(subscriber_refs, deliveries)
    |> maybe_dispatch_next()
  end

  defp dispatch_entry(
         state,
         {_dispatch_id, tap_refs, tap_deliveries, _subscriber_refs, _deliveries} = entry,
         remaining
       ) do
    table = state.handler_table

    case start_dispatch_task(state, fn ->
           dispatch_handlers(table, :tap, tap_refs, tap_deliveries)
         end) do
      {:ok, task} ->
        %{
          state
          | dispatch_queue: remaining,
            dispatch_task: task,
            dispatch_entry: entry,
            task_owners: Map.put(state.task_owners, task.ref, :tap)
        }

      :unavailable ->
        schedule_dispatch_retry(state)
    end
  end

  defp maybe_start_subscribers(%State{} = state) do
    Enum.reduce(Map.keys(state.subscribers), state, &maybe_start_subscriber(&2, &1))
  end

  defp maybe_start_subscriber(%State{} = state, ref) do
    case Map.get(state.subscribers, ref) do
      %Subscriber{task: nil} = subscriber ->
        start_next_subscriber_delivery(state, ref, subscriber)

      _ ->
        state
    end
  end

  defp start_next_subscriber_delivery(state, ref, subscriber) do
    case :queue.out(subscriber.queue) do
      {{:value, delivery}, remaining} ->
        start_subscriber_delivery(state, ref, subscriber, delivery, remaining)

      {:empty, _queue} ->
        maybe_remove_subscriber(state, ref)
    end
  end

  defp start_subscriber_delivery(state, ref, subscriber, delivery, remaining) do
    table = state.handler_table

    case start_dispatch_task(state, fn ->
           dispatch_handlers(table, :subscriber, [ref], [delivery])
         end) do
      {:ok, task} ->
        subscriber = %{subscriber | queue: remaining, task: task, entry: delivery}

        %{
          state
          | subscribers: Map.put(state.subscribers, ref, subscriber),
            task_owners: Map.put(state.task_owners, task.ref, {:subscriber, ref})
        }

      :unavailable ->
        schedule_dispatch_retry(state)
    end
  end

  defp start_dispatch_task(%State{} = state, fun) do
    case resolve_runtime_ref(state.task_supervisor) do
      nil ->
        :unavailable

      task_supervisor ->
        try do
          {:ok, Task.Supervisor.async_nolink(task_supervisor, fun)}
        catch
          :exit, _reason -> :unavailable
        end
    end
  end

  defp complete_task(%State{} = state, task_ref) do
    case Map.pop(state.task_owners, task_ref) do
      {:tap, task_owners} ->
        Process.demonitor(task_ref, [:flush])

        state
        |> Map.put(:task_owners, task_owners)
        |> complete_tap_dispatch()
        |> maybe_start_dispatches()

      {{:subscriber, ref}, task_owners} ->
        Process.demonitor(task_ref, [:flush])

        state
        |> Map.put(:task_owners, task_owners)
        |> complete_subscriber_dispatch(ref)
        |> maybe_start_dispatches()

      {nil, _task_owners} ->
        state
    end
  end

  defp complete_tap_dispatch(%State{dispatch_entry: entry} = state) do
    {_dispatch_id, tap_refs, _tap_deliveries, subscriber_refs, deliveries} = entry

    state
    |> Map.put(:dispatch_task, nil)
    |> Map.put(:dispatch_entry, nil)
    |> release_taps(tap_refs)
    |> release_subscriber_deliveries(subscriber_refs, deliveries)
  end

  defp complete_subscriber_dispatch(%State{} = state, ref) do
    case Map.get(state.subscribers, ref) do
      %Subscriber{} = subscriber ->
        subscriber = %{subscriber | task: nil, entry: nil}

        state
        |> Map.put(:subscribers, Map.put(state.subscribers, ref, subscriber))
        |> maybe_remove_subscriber(ref)

      nil ->
        state
    end
  end

  defp fail_task(%State{} = state, task_ref) do
    case Map.pop(state.task_owners, task_ref) do
      {:tap, task_owners} ->
        state
        |> Map.put(:task_owners, task_owners)
        |> Map.update!(:dispatch_queue, &:queue.in_r(state.dispatch_entry, &1))
        |> Map.put(:dispatch_task, nil)
        |> Map.put(:dispatch_entry, nil)
        |> maybe_start_dispatches()

      {{:subscriber, ref}, task_owners} ->
        state = %{state | task_owners: task_owners}

        case Map.get(state.subscribers, ref) do
          %Subscriber{entry: entry} = subscriber ->
            subscriber = %{
              subscriber
              | queue: :queue.in_r(entry, subscriber.queue),
                task: nil,
                entry: nil
            }

            state
            |> Map.put(:subscribers, Map.put(state.subscribers, ref, subscriber))
            |> maybe_start_dispatches()

          nil ->
            state
        end

      {nil, _task_owners} ->
        state
    end
  end

  defp release_taps(%State{} = state, refs) do
    Enum.reduce(refs, state, fn ref, acc ->
      case Map.get(acc.taps, ref) do
        %Tap{} = tap ->
          tap = %{tap | pending: max(tap.pending - 1, 0)}
          acc = %{acc | taps: Map.put(acc.taps, ref, tap)}
          maybe_remove_tap(acc, ref)

        nil ->
          acc
      end
    end)
  end

  defp release_subscriber_deliveries(%State{} = state, refs, deliveries) do
    delivery_count = length(deliveries)

    Enum.reduce(refs, state, fn ref, acc ->
      case Map.get(acc.subscribers, ref) do
        %Subscriber{} = subscriber ->
          subscriber =
            subscriber
            |> Map.update!(:reserved, &max(&1 - delivery_count, 0))
            |> enqueue_subscriber_deliveries(deliveries)

          %{acc | subscribers: Map.put(acc.subscribers, ref, subscriber)}

        nil ->
          acc
      end
    end)
  end

  defp unsubscribe_subscriber(%State{} = state, ref) do
    case Map.get(state.subscribers, ref) do
      %Subscriber{} = subscriber ->
        state
        |> Map.put(
          :subscribers,
          Map.put(state.subscribers, ref, %{subscriber | subscribed?: false})
        )
        |> maybe_remove_subscriber(ref)

      nil ->
        state
    end
  end

  defp maybe_remove_subscriber(%State{} = state, ref) do
    case Map.get(state.subscribers, ref) do
      %Subscriber{subscribed?: false} = subscriber ->
        if subscriber_queue_size(subscriber) == 0 do
          true = :ets.delete(state.handler_table, {:subscriber, ref})
          %{state | subscribers: Map.delete(state.subscribers, ref)}
        else
          state
        end

      _ ->
        state
    end
  end

  defp drop_subscriber(%State{} = state, ref, reason) do
    require Logger

    Logger.warning(
      "[EventEmitter] removing overloaded subscriber #{inspect(ref)}: #{inspect(reason)}"
    )

    state = stop_subscriber_task(state, ref)
    true = :ets.delete(state.handler_table, {:subscriber, ref})
    %{state | subscribers: Map.delete(state.subscribers, ref)}
  end

  defp stop_subscriber_task(%State{} = state, ref) do
    case Map.get(state.subscribers, ref) do
      %Subscriber{task: %Task{} = task} ->
        _ = Task.shutdown(task, :brutal_kill)
        %{state | task_owners: Map.delete(state.task_owners, task.ref)}

      _ ->
        state
    end
  end

  defp unsubscribe_tap(%State{} = state, ref) do
    case Map.get(state.taps, ref) do
      %Tap{} = tap ->
        state
        |> Map.put(:taps, Map.put(state.taps, ref, %{tap | subscribed?: false}))
        |> maybe_remove_tap(ref)

      nil ->
        state
    end
  end

  defp maybe_remove_tap(%State{} = state, ref) do
    case Map.get(state.taps, ref) do
      %Tap{subscribed?: false, pending: 0} ->
        true = :ets.delete(state.handler_table, {:tap, ref})

        %{
          state
          | taps: Map.delete(state.taps, ref),
            tap_order: List.delete(state.tap_order, ref)
        }

      _ ->
        state
    end
  end

  defp schedule_dispatch_retry(%State{dispatch_retry_timer: nil} = state) do
    %{state | dispatch_retry_timer: Process.send_after(self(), :dispatch_retry, 10)}
  end

  defp schedule_dispatch_retry(%State{} = state), do: state

  defp flush_when_dispatch_available(%State{} = state) do
    {flushed_state, deliveries} = flush_buffer(state, :stop)

    case enqueue_dispatch(flushed_state, [], deliveries) do
      {:ok, state} ->
        state

      {:error, _reason} ->
        %{state | flush_pending_timer: Process.send_after(self(), :flush_pending, 10)}
    end
  end

  defp resolve_runtime_ref(resolver) when is_function(resolver, 0), do: resolver.()
  defp resolve_runtime_ref(ref), do: ref

  defp dispatch_handlers(_table, _kind, _refs, []), do: :ok

  defp dispatch_handlers(table, kind, refs, deliveries) do
    Enum.each(deliveries, &dispatch_delivery(table, kind, refs, &1))

    :ok
  rescue
    ArgumentError -> :ok
  end

  defp dispatch_delivery(table, kind, refs, delivery) do
    Enum.each(refs, &dispatch_handler(table, kind, &1, delivery))
  end

  defp dispatch_handler(table, kind, ref, delivery) do
    case :ets.lookup(table, {kind, ref}) do
      [{{^kind, ^ref}, handler}] -> invoke_handler(handler, kind, ref, delivery)
      [] -> :ok
    end
  end

  defp invoke_handler(handler, kind, ref, delivery) do
    require Logger

    try do
      handler.(delivery)
    rescue
      error ->
        Logger.error(
          "[EventEmitter] #{kind} #{inspect(ref)} crashed: #{Exception.message(error)}"
        )
    catch
      caught_kind, reason ->
        Logger.error(
          "[EventEmitter] #{kind} #{inspect(ref)} crashed: " <>
            Exception.format_banner(caught_kind, reason)
        )
    end
  end

  defp register_initial_subscribers(%State{} = state, subscribers) when is_list(subscribers) do
    Enum.reduce(subscribers, state, fn
      handler, %State{} = acc when is_function(handler, 1) ->
        ref = acc.ref_fun.()
        true = :ets.insert(acc.handler_table, {{:subscriber, ref}, handler})
        %{acc | subscribers: Map.put(acc.subscribers, ref, %Subscriber{})}

      _handler, %State{} = acc ->
        acc
    end)
  end

  defp register_initial_subscribers(%State{} = state, _subscribers), do: state

  defp normalize_max_dispatch_queue(value) when is_integer(value) and value > 0, do: value
  defp normalize_max_dispatch_queue(_value), do: 1_024

  defp maybe_put(map, _key, _value, false), do: map
  defp maybe_put(map, key, value, true), do: Map.put(map, key, value)
end
