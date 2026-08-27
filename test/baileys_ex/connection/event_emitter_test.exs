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
    test_pid = self()
    {:ok, ref_store} = Agent.start_link(fn -> 0 end)

    ref_fun = fn ->
      Agent.get_and_update(ref_store, fn current -> {{:ref, current}, current + 1} end)
    end

    {:ok, emitter} = EventEmitter.start_link(buffer_timeout_ms: 50, ref_fun: ref_fun)
    unsubscribe = EventEmitter.process(emitter, &send(test_pid, {:processed, &1}))
    untap = EventEmitter.tap(emitter, &send(test_pid, {:tapped, &1}))

    assert :ok = EventEmitter.emit(emitter, :connection_update, %{connection: :open})
    assert_receive {:tapped, %{connection_update: %{connection: :open}}}
    assert_receive {:processed, %{connection_update: %{connection: :open}}}

    unsubscribe.()
    untap.()

    assert :ok = EventEmitter.emit(emitter, :connection_update, %{connection: :close})
    refute_receive {:tapped, _events}, 50
    refute_receive {:processed, _events}, 50
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

    _bad_unsubscribe =
      EventEmitter.process(emitter, fn _events ->
        exit(:boom)
      end)

    assert :ok = EventEmitter.emit(emitter, :connection_update, %{connection: :connecting})
    Process.sleep(50)

    _good_unsubscribe =
      EventEmitter.process(emitter, &send(test_pid, {:processed_events, &1}))

    assert :ok = EventEmitter.emit(emitter, :connection_update, %{connection: :open})
    assert_receive {:processed_events, %{connection_update: %{connection: :open}}}
  end

  test "subscriber throws do not kill the emitter" do
    test_pid = self()
    {:ok, emitter} = EventEmitter.start_link(buffer_timeout_ms: 50)

    _bad_unsubscribe =
      EventEmitter.process(emitter, fn _events ->
        throw(:boom)
      end)

    assert :ok = EventEmitter.emit(emitter, :connection_update, %{connection: :connecting})
    Process.sleep(50)

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

  test "a stuck public subscriber does not stall internal taps or other subscribers" do
    test_pid = self()
    gate = make_ref()
    {:ok, emitter} = EventEmitter.start_link()

    _untap =
      EventEmitter.tap(emitter, fn events ->
        send(test_pid, {:tapped, events})
      end)

    _slow_unsubscribe =
      EventEmitter.process(emitter, fn events ->
        send(test_pid, {:slow_started, self(), events})

        case events do
          %{connection_update: %{n: 1}} ->
            receive do
              {:continue, ^gate} -> :ok
            end

          _events ->
            :ok
        end

        send(test_pid, {:slow_finished, events})
      end)

    _fast_unsubscribe =
      EventEmitter.process(emitter, fn events ->
        send(test_pid, {:fast_finished, events})
      end)

    assert :ok = EventEmitter.emit(emitter, :connection_update, %{n: 1})
    assert_receive {:tapped, %{connection_update: %{n: 1}}}
    assert_receive {:slow_started, slow_task, %{connection_update: %{n: 1}}}
    assert_receive {:fast_finished, %{connection_update: %{n: 1}}}

    assert :ok = EventEmitter.emit(emitter, :connection_update, %{n: 2})
    assert_receive {:tapped, %{connection_update: %{n: 2}}}
    assert_receive {:fast_finished, %{connection_update: %{n: 2}}}
    refute_received {:slow_finished, %{connection_update: %{n: 1}}}

    send(slow_task, {:continue, gate})
    assert_receive {:slow_finished, %{connection_update: %{n: 1}}}
    assert_receive {:slow_started, _next_task, %{connection_update: %{n: 2}}}
    assert_receive {:slow_finished, %{connection_update: %{n: 2}}}
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

  test "dispatch capacity is bounded and recovers after queued work completes" do
    test_pid = self()
    gate = make_ref()
    {:ok, emitter} = EventEmitter.start_link(max_dispatch_queue: 2)

    _untap =
      EventEmitter.tap(emitter, fn events ->
        send(test_pid, {:dispatch_started, self(), events})

        receive do
          {:continue, ^gate} -> :ok
        end

        send(test_pid, {:processed_events, events})
      end)

    assert :ok = EventEmitter.emit(emitter, :connection_update, %{n: 1})
    assert_receive {:dispatch_started, first_task, %{connection_update: %{n: 1}}}

    assert :ok = EventEmitter.emit(emitter, :connection_update, %{n: 2})

    assert {:error, :dispatch_queue_full} =
             EventEmitter.emit(emitter, :connection_update, %{n: 3})

    send(first_task, {:continue, gate})
    assert_receive {:processed_events, %{connection_update: %{n: 1}}}
    assert_receive {:dispatch_started, second_task, %{connection_update: %{n: 2}}}
    send(second_task, {:continue, gate})
    assert_receive {:processed_events, %{connection_update: %{n: 2}}}

    assert :ok = EventEmitter.emit(emitter, :connection_update, %{n: 4})
    assert_receive {:dispatch_started, fourth_task, %{connection_update: %{n: 4}}}
    send(fourth_task, {:continue, gate})
    assert_receive {:processed_events, %{connection_update: %{n: 4}}}
    refute_received {:processed_events, %{connection_update: %{n: 3}}}
  end

  test "queued events retain their emission-time subscriber membership" do
    test_pid = self()
    gate = make_ref()
    {:ok, emitter} = EventEmitter.start_link()

    unsubscribe =
      EventEmitter.process(emitter, fn events ->
        send(test_pid, {:old_subscriber_started, self(), events})

        case events do
          %{connection_update: %{n: 1}} ->
            receive do
              {:continue, ^gate} -> :ok
            end

          _events ->
            :ok
        end

        send(test_pid, {:old_subscriber_finished, events})
      end)

    assert :ok = EventEmitter.emit(emitter, :connection_update, %{n: 1})
    assert_receive {:old_subscriber_started, first_task, %{connection_update: %{n: 1}}}
    assert :ok = EventEmitter.emit(emitter, :connection_update, %{n: 2})

    unsubscribe.()

    _new_unsubscribe =
      EventEmitter.process(emitter, fn events ->
        send(test_pid, {:new_subscriber, events})
      end)

    send(first_task, {:continue, gate})
    assert_receive {:old_subscriber_finished, %{connection_update: %{n: 1}}}
    assert_receive {:old_subscriber_started, _second_task, %{connection_update: %{n: 2}}}
    assert_receive {:old_subscriber_finished, %{connection_update: %{n: 2}}}
    refute_received {:new_subscriber, %{connection_update: %{n: 2}}}

    assert :ok = EventEmitter.emit(emitter, :connection_update, %{n: 3})
    assert_receive {:new_subscriber, %{connection_update: %{n: 3}}}
    refute_received {:old_subscriber_started, _task, %{connection_update: %{n: 3}}}
  end

  test "subscribers may emit reentrant events without deadlocking delivery" do
    test_pid = self()
    {:ok, emitter} = EventEmitter.start_link()

    _unsubscribe =
      EventEmitter.process(emitter, fn
        %{connection_update: %{n: 1}} = events ->
          send(test_pid, {:processed_events, events})

          send(
            test_pid,
            {:nested_emit_result, EventEmitter.emit(emitter, :connection_update, %{n: 2})}
          )

        events ->
          send(test_pid, {:processed_events, events})
      end)

    assert :ok = EventEmitter.emit(emitter, :connection_update, %{n: 1})
    assert_receive {:processed_events, %{connection_update: %{n: 1}}}
    assert_receive {:nested_emit_result, :ok}
    assert_receive {:processed_events, %{connection_update: %{n: 2}}}
  end

  test "dispatch work restarts after unexpected task death" do
    test_pid = self()
    {:ok, emitter} = EventEmitter.start_link(buffer_timeout_ms: 50)
    gate = make_ref()

    _unsubscribe =
      EventEmitter.process(emitter, fn events ->
        send(test_pid, {:dispatch_started, self(), events})

        receive do
          {:continue, ^gate} -> send(test_pid, {:processed_events, events})
        end
      end)

    assert :ok = EventEmitter.emit(emitter, :connection_update, %{connection: :open})
    assert_receive {:dispatch_started, first_task, %{connection_update: %{connection: :open}}}

    task_ref = Process.monitor(first_task)
    Process.exit(first_task, :kill)
    assert_receive {:DOWN, ^task_ref, :process, ^first_task, :killed}

    assert_receive {:dispatch_started, retry_task, %{connection_update: %{connection: :open}}}
    refute retry_task == first_task
    send(retry_task, {:continue, gate})
    assert_receive {:processed_events, %{connection_update: %{connection: :open}}}, 300
  end

  test "dispatch work survives callback TaskSupervisor restart" do
    test_pid = self()
    gate = make_ref()
    {:ok, emitter} = EventEmitter.start_link()

    _unsubscribe =
      EventEmitter.process(emitter, fn events ->
        send(test_pid, {:dispatch_started, self(), events})

        receive do
          {:continue, ^gate} -> send(test_pid, {:processed_events, events})
        end
      end)

    assert :ok = EventEmitter.emit(emitter, :connection_update, %{n: 1})
    assert_receive {:dispatch_started, first_task, %{connection_update: %{n: 1}}}
    assert :ok = EventEmitter.emit(emitter, :connection_update, %{n: 2})

    task_supervisor = child_pid!(emitter, Task.Supervisor)
    task_supervisor_ref = Process.monitor(task_supervisor)
    Process.exit(task_supervisor, :kill)
    assert_receive {:DOWN, ^task_supervisor_ref, :process, ^task_supervisor, :killed}

    assert_receive {:dispatch_started, retry_task, %{connection_update: %{n: 1}}}, 500
    refute retry_task == first_task
    send(retry_task, {:continue, gate})
    assert_receive {:processed_events, %{connection_update: %{n: 1}}}

    assert_receive {:dispatch_started, second_task, %{connection_update: %{n: 2}}}
    send(second_task, {:continue, gate})
    assert_receive {:processed_events, %{connection_update: %{n: 2}}}
  end

  test "active dispatch task exits when the emitter stops" do
    test_pid = self()
    {:ok, emitter} = EventEmitter.start_link(buffer_timeout_ms: 50)

    _unsubscribe =
      EventEmitter.process(emitter, fn events ->
        send(test_pid, {:dispatch_started, self(), events})
        Process.sleep(:infinity)
      end)

    assert :ok = EventEmitter.emit(emitter, :connection_update, %{connection: :open})
    assert_receive {:dispatch_started, task, %{connection_update: %{connection: :open}}}
    task_ref = Process.monitor(task)

    Supervisor.stop(emitter)

    assert_receive {:DOWN, ^task_ref, :process, ^task, _reason}, 300
  end

  defp child_pid!(supervisor, child_id) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {^child_id, pid, _type, _modules} when is_pid(pid) -> pid
      _child -> nil
    end)
    |> case do
      pid when is_pid(pid) -> pid
      nil -> flunk("missing child #{inspect(child_id)}")
    end
  end
end
