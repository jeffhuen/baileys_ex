defmodule BaileysEx.Connection.EventEmitterTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Connection.EventEmitter

  test "process/2 receives emitted event maps" do
    test_pid = self()
    {:ok, emitter} = EventEmitter.start_link(buffer_timeout_ms: 50)
    unsubscribe = EventEmitter.process(emitter, &send(test_pid, {:processed_events, &1}))

    assert :ok = EventEmitter.emit(emitter, :connection_update, %{connection: :connecting})

    assert_receive {:processed_events, %{connection_update: %{connection: :connecting}}}

    unsubscribe.()
  end

  test "process/2 and tap/2 accept injected refs for deterministic subscriptions" do
    {:ok, ref_store} = Agent.start_link(fn -> [:process_ref, :tap_ref] end)

    ref_fun = fn ->
      Agent.get_and_update(ref_store, fn [next | rest] -> {next, rest} end)
    end

    {:ok, emitter} = EventEmitter.start_link(buffer_timeout_ms: 50, ref_fun: ref_fun)
    unsubscribe = EventEmitter.process(emitter, fn _events -> :ok end)
    untap = EventEmitter.tap(emitter, fn _events -> :ok end)

    state = :sys.get_state(emitter)
    assert Map.has_key?(state.subscribers, :process_ref)
    assert Map.has_key?(state.taps, :tap_ref)

    unsubscribe.()
    untap.()
  end

  test "buffer/flush buffers bufferable events and flushes them as a batch" do
    test_pid = self()
    {:ok, emitter} = EventEmitter.start_link(buffer_timeout_ms: 50)
    _unsubscribe = EventEmitter.process(emitter, &send(test_pid, {:processed_events, &1}))

    assert :ok = EventEmitter.buffer(emitter)
    assert true == EventEmitter.buffering?(emitter)

    assert :ok =
             EventEmitter.emit(emitter, :messages_upsert, %{
               messages: [%{id: "m-1"}],
               type: :append
             })

    refute_received {:processed_events, _events}

    assert true == EventEmitter.flush(emitter)

    assert_receive {:processed_events,
                    %{messages_upsert: %{messages: [%{id: "m-1"}], type: :append}}}

    assert false == EventEmitter.buffering?(emitter)
  end

  test "buffer auto-flushes after the configured timeout" do
    test_pid = self()
    {:ok, emitter} = EventEmitter.start_link(buffer_timeout_ms: 20)
    _unsubscribe = EventEmitter.process(emitter, &send(test_pid, {:processed_events, &1}))

    assert :ok = EventEmitter.buffer(emitter)

    assert :ok =
             EventEmitter.emit(emitter, :messages_upsert, %{
               messages: [%{id: "m-1"}],
               type: :append
             })

    assert_receive {:processed_events,
                    %{messages_upsert: %{messages: [%{id: "m-1"}], type: :append}}},
                   200
  end

  test "non-bufferable events pass through while buffering is active" do
    test_pid = self()
    {:ok, emitter} = EventEmitter.start_link(buffer_timeout_ms: 50)
    _unsubscribe = EventEmitter.process(emitter, &send(test_pid, {:processed_events, &1}))

    assert :ok = EventEmitter.buffer(emitter)
    assert :ok = EventEmitter.emit(emitter, :presence_update, %{id: "chat-1", presences: %{}})

    assert_receive {:processed_events, %{presence_update: %{id: "chat-1", presences: %{}}}}
  end

  test "tap/2 observes bufferable events immediately while process subscribers stay buffered" do
    test_pid = self()
    {:ok, emitter} = EventEmitter.start_link(buffer_timeout_ms: 50)
    _unsubscribe = EventEmitter.process(emitter, &send(test_pid, {:processed_events, &1}))
    _untap = EventEmitter.tap(emitter, &send(test_pid, {:tapped_events, &1}))

    assert :ok = EventEmitter.buffer(emitter)

    assert :ok =
             EventEmitter.emit(emitter, :messaging_history_set, %{
               chats: [],
               contacts: [],
               messages: [],
               sync_type: :recent
             })

    assert_receive {:tapped_events,
                    %{
                      messaging_history_set: %{
                        chats: [],
                        contacts: [],
                        messages: [],
                        sync_type: :recent
                      }
                    }}

    refute_received {:processed_events, %{messaging_history_set: _history}}
  end

  test "groups_update is treated as a bufferable event" do
    test_pid = self()
    {:ok, emitter} = EventEmitter.start_link(buffer_timeout_ms: 50)
    _unsubscribe = EventEmitter.process(emitter, &send(test_pid, {:processed_events, &1}))

    assert :ok = EventEmitter.buffer(emitter)

    assert :ok =
             EventEmitter.emit(emitter, :groups_update, [%{id: "group-1", subject: "Phase 6"}])

    refute_received {:processed_events, _events}

    assert true == EventEmitter.flush(emitter)
    assert_receive {:processed_events, %{groups_update: [%{id: "group-1", subject: "Phase 6"}]}}
  end

  test "mixed messages_upsert types create a flush boundary" do
    test_pid = self()
    {:ok, emitter} = EventEmitter.start_link(buffer_timeout_ms: 50)
    _unsubscribe = EventEmitter.process(emitter, &send(test_pid, {:processed_events, &1}))

    assert :ok = EventEmitter.buffer(emitter)

    assert :ok =
             EventEmitter.emit(emitter, :messages_upsert, %{
               messages: [%{id: "append-1"}],
               type: :append
             })

    assert :ok =
             EventEmitter.emit(emitter, :messages_upsert, %{
               messages: [%{id: "notify-1"}],
               type: :notify
             })

    assert_receive {:processed_events,
                    %{messages_upsert: %{messages: [%{id: "append-1"}], type: :append}}}

    assert true == EventEmitter.flush(emitter)

    assert_receive {:processed_events,
                    %{messages_upsert: %{messages: [%{id: "notify-1"}], type: :notify}}}
  end

  test "conditional chat updates survive a flush until the condition resolves" do
    test_pid = self()
    gate = :erlang.make_ref()

    {:ok, emitter} = EventEmitter.start_link(buffer_timeout_ms: 50)
    _unsubscribe = EventEmitter.process(emitter, &send(test_pid, {:processed_events, &1}))

    condition = fn data ->
      if Map.get(data, gate) do
        true
      else
        nil
      end
    end

    assert :ok = EventEmitter.buffer(emitter)

    assert :ok =
             EventEmitter.emit(emitter, :chats_update, [
               %{id: "chat-1", muted: true, conditional: condition}
             ])

    assert true == EventEmitter.flush(emitter)
    refute_received {:processed_events, %{chats_update: _updates}}

    assert :ok = EventEmitter.seed(emitter, %{gate => true})
    assert :ok = EventEmitter.buffer(emitter)
    assert true == EventEmitter.flush(emitter)

    assert_receive {:processed_events, %{chats_update: [%{id: "chat-1", muted: true}]}}
  end

  test "create_buffered_function buffers nested work and flushes when it completes" do
    test_pid = self()
    {:ok, emitter} = EventEmitter.start_link(buffer_timeout_ms: 50)
    _unsubscribe = EventEmitter.process(emitter, &send(test_pid, {:processed_events, &1}))

    buffered_fun =
      EventEmitter.create_buffered_function(emitter, fn ->
        assert :ok =
                 EventEmitter.emit(emitter, :groups_update, [%{id: "group-1", subject: "Phase 6"}])

        :done
      end)

    assert :done == buffered_fun.()

    assert_receive {:processed_events, %{groups_update: [%{id: "group-1", subject: "Phase 6"}]}},
                   200
  end

  test "utils-driven connection events dispatch through process subscribers" do
    test_pid = self()
    {:ok, emitter} = EventEmitter.start_link(buffer_timeout_ms: 50)
    _unsubscribe = EventEmitter.process(emitter, &send(test_pid, {:processed_events, &1}))

    events = [
      {:messaging_history_set, %{chats: [], contacts: [], messages: [], sync_type: :recent}},
      {:messages_reaction, [%{key: %{id: "message-1"}, reaction: %{text: "👍"}}]},
      {:group_participants_update, %{id: "group-1", participants: ["1@s.whatsapp.net"]}},
      {:group_join_request, %{id: "group-1", participants: ["2@s.whatsapp.net"]}},
      {:group_member_tag_update, %{id: "group-1", member_tag: %{label: "vip"}}},
      {:lid_mapping_update, %{lid: "123@lid", pn: "15551234567@s.whatsapp.net"}},
      {:settings_update, %{privacy: %{"last" => "contacts"}}},
      {:chats_lock, %{id: "chat-1", locked: true}}
    ]

    Enum.each(events, fn {event, payload} ->
      assert :ok = EventEmitter.emit(emitter, event, payload)
      assert_receive {:processed_events, %{^event => ^payload}}
    end)
  end

  test "emit/3 returns before slow subscribers finish processing" do
    test_pid = self()
    {:ok, emitter} = EventEmitter.start_link(buffer_timeout_ms: 50)

    _unsubscribe =
      EventEmitter.process(emitter, fn events ->
        send(test_pid, {:subscriber_started, events})
        Process.sleep(150)
        send(test_pid, {:processed_events, events})
      end)

    start = System.monotonic_time(:millisecond)
    assert :ok = EventEmitter.emit(emitter, :connection_update, %{connection: :connecting})
    elapsed = System.monotonic_time(:millisecond) - start

    assert elapsed < 100
    assert_receive {:subscriber_started, %{connection_update: %{connection: :connecting}}}
    assert_receive {:processed_events, %{connection_update: %{connection: :connecting}}}, 300
  end

  test "subscriber exits do not crash the emitter" do
    test_pid = self()
    {:ok, emitter} = EventEmitter.start_link(buffer_timeout_ms: 50)
    initial_dispatcher = :sys.get_state(emitter).dispatcher_pid

    _bad_unsubscribe =
      EventEmitter.process(emitter, fn _events ->
        exit(:boom)
      end)

    assert :ok = EventEmitter.emit(emitter, :connection_update, %{connection: :connecting})
    Process.sleep(50)

    assert Process.alive?(emitter)
    assert Process.alive?(initial_dispatcher)
    assert :sys.get_state(emitter).dispatcher_pid == initial_dispatcher

    _good_unsubscribe =
      EventEmitter.process(emitter, &send(test_pid, {:processed_events, &1}))

    assert :ok = EventEmitter.emit(emitter, :connection_update, %{connection: :open})
    assert_receive {:processed_events, %{connection_update: %{connection: :open}}}
  end

  test "subscriber throws do not kill the dispatcher" do
    test_pid = self()
    {:ok, emitter} = EventEmitter.start_link(buffer_timeout_ms: 50)
    initial_dispatcher = :sys.get_state(emitter).dispatcher_pid

    _bad_unsubscribe =
      EventEmitter.process(emitter, fn _events ->
        throw(:boom)
      end)

    assert :ok = EventEmitter.emit(emitter, :connection_update, %{connection: :connecting})
    Process.sleep(50)

    assert Process.alive?(initial_dispatcher)
    assert :sys.get_state(emitter).dispatcher_pid == initial_dispatcher

    _good_unsubscribe =
      EventEmitter.process(emitter, &send(test_pid, {:processed_events, &1}))

    assert :ok = EventEmitter.emit(emitter, :connection_update, %{connection: :open})
    assert_receive {:processed_events, %{connection_update: %{connection: :open}}}
  end

  test "in-flight subscribers do not block later emits" do
    test_pid = self()
    {:ok, emitter} = EventEmitter.start_link(buffer_timeout_ms: 50)

    _unsubscribe =
      EventEmitter.process(emitter, fn events ->
        send(test_pid, {:subscriber_started, events})
        Process.sleep(200)
        send(test_pid, {:processed_events, events})
      end)

    assert :ok = EventEmitter.emit(emitter, :connection_update, %{n: 1})
    assert_receive {:subscriber_started, %{connection_update: %{n: 1}}}

    start = System.monotonic_time(:millisecond)
    assert :ok = EventEmitter.emit(emitter, :connection_update, %{n: 2})
    elapsed = System.monotonic_time(:millisecond) - start

    assert elapsed < 100
    assert_receive {:subscriber_started, %{connection_update: %{n: 2}}}, 300
  end

  test "later emits preserve subscriber delivery order" do
    test_pid = self()
    gate = make_ref()
    {:ok, emitter} = EventEmitter.start_link(buffer_timeout_ms: 50)

    _unsubscribe =
      EventEmitter.process(emitter, fn events ->
        send(test_pid, {:subscriber_started, self(), events})

        case events do
          %{connection_update: %{n: 1}} ->
            receive do
              {:continue, ^gate} -> :ok
            after
              500 -> exit(:timed_out_waiting_for_continue)
            end

          _ ->
            :ok
        end

        send(test_pid, {:processed_events, events})
      end)

    assert :ok = EventEmitter.emit(emitter, :connection_update, %{n: 1})
    assert_receive {:subscriber_started, first_handler, %{connection_update: %{n: 1}}}

    assert :ok = EventEmitter.emit(emitter, :connection_update, %{n: 2})
    refute_receive {:subscriber_started, _second_handler, %{connection_update: %{n: 2}}}, 50

    send(first_handler, {:continue, gate})

    assert_receive {:processed_events, %{connection_update: %{n: 1}}}, 300
    assert_receive {:subscriber_started, _second_handler, %{connection_update: %{n: 2}}}, 300
    assert_receive {:processed_events, %{connection_update: %{n: 2}}}, 300
  end

  test "dispatcher restarts after unexpected death and continues delivering events" do
    test_pid = self()
    {:ok, emitter} = EventEmitter.start_link(buffer_timeout_ms: 50)
    _unsubscribe = EventEmitter.process(emitter, &send(test_pid, {:processed_events, &1}))

    dispatcher = :sys.get_state(emitter).dispatcher_pid
    ref = Process.monitor(dispatcher)
    Process.exit(dispatcher, :kill)
    assert_receive {:DOWN, ^ref, :process, ^dispatcher, :killed}

    assert :ok = EventEmitter.emit(emitter, :connection_update, %{connection: :open})
    assert_receive {:processed_events, %{connection_update: %{connection: :open}}}, 300
  end

  test "dispatcher exits when the emitter stops" do
    {:ok, emitter} = EventEmitter.start_link(buffer_timeout_ms: 50)
    dispatcher = :sys.get_state(emitter).dispatcher_pid
    dispatcher_ref = Process.monitor(dispatcher)

    GenServer.stop(emitter)

    assert_receive {:DOWN, ^dispatcher_ref, :process, ^dispatcher, _reason}, 300
  end
end
