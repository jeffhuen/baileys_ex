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

  test "buffered contacts_upsert batches accumulate by contact id instead of overwriting" do
    test_pid = self()
    {:ok, emitter} = EventEmitter.start_link(buffer_timeout_ms: 5_000)
    _unsubscribe = EventEmitter.process(emitter, &send(test_pid, {:processed_events, &1}))

    EventEmitter.create_buffered_function(emitter, fn ->
      :ok = EventEmitter.emit(emitter, :contacts_upsert, [%{id: "a@s.whatsapp.net", name: "A"}])

      :ok =
        EventEmitter.emit(emitter, :lid_mapping_update, %{lid: "1@lid", pn: "a@s.whatsapp.net"})

      :ok = EventEmitter.emit(emitter, :contacts_upsert, [%{id: "b@s.whatsapp.net", name: "B"}])

      :ok =
        EventEmitter.emit(emitter, :contacts_upsert, [
          %{id: "a@s.whatsapp.net", name: nil, notify: "Ann"}
        ])
    end).()

    assert_receive {:processed_events, %{contacts_upsert: contacts}}, 1_000

    assert contacts == [
             %{id: "a@s.whatsapp.net", name: "A", notify: "Ann"},
             %{id: "b@s.whatsapp.net", name: "B"}
           ]
  end

  test "buffered history chunks and list events merge instead of keeping only the last one" do
    test_pid = self()
    {:ok, emitter} = EventEmitter.start_link(buffer_timeout_ms: 5_000)
    _unsubscribe = EventEmitter.process(emitter, &send(test_pid, {:processed_events, &1}))
    key = fn id -> %{remote_jid: "a@s.whatsapp.net", id: id, from_me: false} end

    :ok = EventEmitter.buffer(emitter)

    :ok =
      EventEmitter.emit(emitter, :messaging_history_set, %{
        chats: [%{id: "a@s.whatsapp.net"}],
        contacts: [%{id: "a@s.whatsapp.net", name: "A"}],
        messages: [%{key: key.("m1")}, %{key: key.("m2")}],
        lid_pn_mappings: [%{lid: "1@lid", pn: "a@s.whatsapp.net"}],
        sync_type: :INITIAL_BOOTSTRAP,
        progress: 50,
        is_latest: true
      })

    :ok =
      EventEmitter.emit(emitter, :messaging_history_set, %{
        chats: [%{id: "b@s.whatsapp.net"}],
        contacts: [%{id: "a@s.whatsapp.net", name: nil, notify: "Ann"}],
        messages: [%{key: key.("m2")}, %{key: key.("m3")}],
        lid_pn_mappings: [%{lid: "2@lid", pn: "b@s.whatsapp.net"}],
        sync_type: :PUSH_NAME,
        progress: 100,
        is_latest: false
      })

    :ok = EventEmitter.emit(emitter, :chats_upsert, [%{id: "c1"}])
    :ok = EventEmitter.emit(emitter, :chats_upsert, [%{id: "c2"}])
    :ok = EventEmitter.emit(emitter, :chats_delete, ["d1"])
    :ok = EventEmitter.emit(emitter, :chats_delete, ["d2", "d1"])
    :ok = EventEmitter.emit(emitter, :messages_update, [%{key: key.("m1"), update: %{status: 2}}])

    :ok =
      EventEmitter.emit(emitter, :messages_update, [
        %{key: key.("m1"), update: %{starred: true}},
        %{key: key.("m4"), update: %{status: 3}},
        %{key: key.("m4"), update: %{starred: true}}
      ])

    :ok = EventEmitter.emit(emitter, :messages_delete, %{keys: [key.("m5")]})
    :ok = EventEmitter.emit(emitter, :messages_delete, %{keys: [key.("m6")]})

    :ok =
      EventEmitter.emit(emitter, :messages_reaction, [%{key: key.("m1"), reaction: %{text: "a"}}])

    :ok =
      EventEmitter.emit(emitter, :messages_reaction, [%{key: key.("m2"), reaction: %{text: "b"}}])

    :ok =
      EventEmitter.emit(emitter, :message_receipt_update, [
        %{key: key.("m1"), receipt: %{type: :read}}
      ])

    :ok =
      EventEmitter.emit(emitter, :message_receipt_update, [
        %{key: key.("m2"), receipt: %{type: :delivery}}
      ])

    # Non-keys messages_delete emits immediately without waiting for flush
    :ok = EventEmitter.emit(emitter, :messages_delete, %{jid: "a@s.whatsapp.net", all: true})

    assert_receive {:processed_events, %{messages_delete: %{jid: "a@s.whatsapp.net", all: true}}},
                   1_000

    assert EventEmitter.flush(emitter)

    assert_receive {:processed_events, events}, 1_000

    history = events.messaging_history_set
    assert Enum.map(history.chats, & &1.id) == ["a@s.whatsapp.net", "b@s.whatsapp.net"]
    assert history.contacts == [%{id: "a@s.whatsapp.net", name: "A", notify: "Ann"}]

    assert history.messages == [
             %{key: key.("m1"), status: 2, starred: true},
             %{key: key.("m2")},
             %{key: key.("m3")}
           ]

    assert %{sync_type: :PUSH_NAME, progress: 100, is_latest: true} = history

    assert history.lid_pn_mappings == [
             %{lid: "1@lid", pn: "a@s.whatsapp.net"},
             %{lid: "2@lid", pn: "b@s.whatsapp.net"}
           ]

    assert events.chats_upsert == [%{id: "c1"}, %{id: "c2"}]
    assert events.chats_delete == ["d1", "d2"]

    assert events.messages_update == [
             %{key: key.("m4"), update: %{status: 3, starred: true}}
           ]

    assert events.messages_delete == %{keys: [key.("m5"), key.("m6")]}

    assert events.messages_reaction == [
             %{key: key.("m1"), reaction: %{text: "a"}},
             %{key: key.("m2"), reaction: %{text: "b"}}
           ]

    assert events.message_receipt_update == [
             %{key: key.("m1"), receipt: %{type: :read}},
             %{key: key.("m2"), receipt: %{type: :delivery}}
           ]
  end

  test "buffered cross-event consolidation folds deletes, updates, upserts, and past_participants" do
    test_pid = self()
    {:ok, emitter} = EventEmitter.start_link(buffer_timeout_ms: 5_000)
    _unsubscribe = EventEmitter.process(emitter, &send(test_pid, {:processed_events, &1}))
    key = fn id -> %{remote_jid: "chat-1@s.whatsapp.net", id: id, from_me: false} end

    :ok = EventEmitter.buffer(emitter)

    :ok =
      EventEmitter.emit(emitter, :messaging_history_set, %{
        chats: [%{id: "chat-1@s.whatsapp.net", unread_count: 2}, %{id: "deleted-chat"}],
        contacts: [%{id: "c-hist@s.whatsapp.net", name: "Hist"}],
        messages: [],
        past_participants: [
          %{
            group_jid: "g1@g.us",
            past_participants: [
              %{user_jid: "u1@s.whatsapp.net", leave_ts: 1, leave_reason: :LEFT}
            ]
          }
        ]
      })

    :ok =
      EventEmitter.emit(emitter, :messaging_history_set, %{
        chats: [],
        contacts: [],
        messages: [],
        past_participants: [
          %{
            group_jid: "g1@g.us",
            past_participants: [
              %{user_jid: "u1@s.whatsapp.net", leave_ts: 1, leave_reason: :LEFT},
              %{user_jid: "u2@s.whatsapp.net", leave_ts: 2, leave_reason: :REMOVED}
            ]
          }
        ]
      })

    # Chat update folds into history chat with summed unread_count; standalone updates merge by id
    :ok =
      EventEmitter.emit(emitter, :chats_update, [
        %{id: "chat-1@s.whatsapp.net", unread_count: 3, archived: true},
        %{id: "chat-standalone", unread_count: 1},
        %{id: "chat-standalone", unread_count: 4, muted: true},
        %{id: "chat-neutralize", unread_count: -1},
        %{id: "chat-neutralize", unread_count: nil, archived: false}
      ])

    # Chat delete purges history chat and any pending upsert/update
    :ok = EventEmitter.emit(emitter, :chats_upsert, [%{id: "deleted-upsert"}])
    :ok = EventEmitter.emit(emitter, :chats_delete, ["deleted-chat", "deleted-upsert"])

    # Contact update before upsert gets absorbed into upsert; update on history contact folds in
    :ok =
      EventEmitter.emit(emitter, :contacts_update, [
        %{id: "c-hist@s.whatsapp.net", notify: "HistNotify"},
        %{id: "c-new@s.whatsapp.net", notify: "BeforeUpsert"}
      ])

    :ok =
      EventEmitter.emit(emitter, :contacts_upsert, [
        %{id: "c-new@s.whatsapp.net", name: "FullName"}
      ])

    # Message update before upsert is absorbed; message delete purges pending upsert and update
    :ok =
      EventEmitter.emit(emitter, :messages_update, [
        %{key: key.("m-upsert"), update: %{status: 4}},
        %{key: key.("m-del-upd"), update: %{status: 2}}
      ])

    :ok =
      EventEmitter.emit(emitter, :messages_upsert, %{
        type: :notify,
        messages: [%{key: key.("m-upsert")}, %{key: key.("m-del-ups")}]
      })

    :ok =
      EventEmitter.emit(emitter, :messages_delete, %{keys: [key.("m-del-ups"), key.("m-del-upd")]})

    assert EventEmitter.flush(emitter)
    assert_receive {:processed_events, events}, 1_000

    history = events.messaging_history_set
    assert history.chats == [%{id: "chat-1@s.whatsapp.net", unread_count: 5, archived: true}]

    assert history.contacts == [
             %{id: "c-hist@s.whatsapp.net", name: "Hist", notify: "HistNotify"}
           ]

    assert history.past_participants == [
             %{
               group_jid: "g1@g.us",
               past_participants: [
                 %{user_jid: "u1@s.whatsapp.net", leave_ts: 1, leave_reason: :LEFT},
                 %{user_jid: "u2@s.whatsapp.net", leave_ts: 2, leave_reason: :REMOVED}
               ]
             }
           ]

    assert events.chats_update == [
             %{id: "chat-standalone", unread_count: 5, muted: true},
             %{id: "chat-neutralize", archived: false}
           ]

    refute Map.has_key?(events, :chats_upsert)
    assert events.chats_delete == ["deleted-chat", "deleted-upsert"]

    assert events.contacts_upsert == [
             %{id: "c-new@s.whatsapp.net", notify: "BeforeUpsert", name: "FullName"}
           ]

    refute Map.has_key?(events, :contacts_update)

    assert events.messages_upsert == %{
             type: :notify,
             messages: [%{key: key.("m-upsert"), status: 4}]
           }

    refute Map.has_key?(events, :messages_update)
    assert events.messages_delete == %{keys: [key.("m-del-ups"), key.("m-del-upd")]}
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

  test "buffered chat updates preserve explicit nil clears for pin and mute_end_time while keeping absent keys" do
    test_pid = self()
    {:ok, emitter} = EventEmitter.start_link(buffer_timeout_ms: 5_000)
    _unsubscribe = EventEmitter.process(emitter, &send(test_pid, {:processed_events, &1}))

    :ok = EventEmitter.buffer(emitter)

    :ok =
      EventEmitter.emit(emitter, :chats_upsert, [
        %{
          id: "chat-pin@s.whatsapp.net",
          pin: 1_710_000_001,
          mute_end_time: 1_710_009_999,
          name: "Keep"
        }
      ])

    :ok =
      EventEmitter.emit(emitter, :chats_update, [
        %{id: "chat-pin@s.whatsapp.net", pin: nil},
        %{id: "chat-pin@s.whatsapp.net", mute_end_time: nil},
        %{id: "chat-standalone@s.whatsapp.net", pin: 100, archived: true},
        %{id: "chat-standalone@s.whatsapp.net", pin: nil},
        %{id: "chat-mute@s.whatsapp.net", mute_end_time: 500},
        %{id: "chat-mute@s.whatsapp.net", mute_end_time: nil}
      ])

    assert EventEmitter.flush(emitter)
    assert_receive {:processed_events, events}, 1_000

    assert events.chats_upsert == [
             %{
               id: "chat-pin@s.whatsapp.net",
               pin: nil,
               mute_end_time: nil,
               name: "Keep"
             }
           ]

    assert events.chats_update == [
             %{id: "chat-standalone@s.whatsapp.net", pin: nil, archived: true},
             %{id: "chat-mute@s.whatsapp.net", mute_end_time: nil}
           ]
  end

  test "messages_upsert type change drains only message upserts, keeps other buffered events, and preserves watchdog timer" do
    test_pid = self()
    {:ok, emitter} = EventEmitter.start_link(buffer_timeout_ms: 80)
    _unsubscribe = EventEmitter.process(emitter, &send(test_pid, {:processed_events, &1}))

    :ok = EventEmitter.buffer(emitter)

    :ok =
      EventEmitter.emit(emitter, :messaging_history_set, %{
        chats: [%{id: "hist@s.whatsapp.net"}],
        contacts: [],
        messages: [],
        sync_type: :INITIAL_BOOTSTRAP
      })

    :ok = EventEmitter.emit(emitter, :chats_update, [%{id: "u@s.whatsapp.net", archived: true}])

    :ok =
      EventEmitter.emit(emitter, :messages_upsert, %{
        type: :append,
        messages: [%{key: %{remote_jid: "a@s.whatsapp.net", id: "append-1", from_me: false}}]
      })

    :ok =
      EventEmitter.emit(emitter, :messages_upsert, %{
        type: :notify,
        messages: [%{key: %{remote_jid: "a@s.whatsapp.net", id: "notify-1", from_me: false}}]
      })

    # Immediate drain emits ONLY the previous :append upsert — NOT history or chat updates
    assert_receive {:processed_events, first_batch}, 500

    assert first_batch == %{
             messages_upsert: %{
               type: :append,
               messages: [
                 %{key: %{remote_jid: "a@s.whatsapp.net", id: "append-1", from_me: false}}
               ]
             }
           }

    assert EventEmitter.buffering?(emitter)

    # Watchdog timer remains intact and auto-flushes the :notify upsert alongside pending history + chat updates
    assert_receive {:processed_events, second_batch}, 500

    assert %{
             messaging_history_set: %{chats: [%{id: "hist@s.whatsapp.net"}]},
             chats_update: [%{id: "u@s.whatsapp.net", archived: true}],
             messages_upsert: %{
               type: :notify,
               messages: [
                 %{key: %{remote_jid: "a@s.whatsapp.net", id: "notify-1", from_me: false}}
               ]
             }
           } = second_batch

    refute EventEmitter.buffering?(emitter)
  end

  test "buffered messages_upsert preserves request_id and does not coalesce across different request_ids" do
    test_pid = self()
    {:ok, emitter} = EventEmitter.start_link(buffer_timeout_ms: 5_000)
    _unsubscribe = EventEmitter.process(emitter, &send(test_pid, {:processed_events, &1}))

    :ok = EventEmitter.buffer(emitter)

    :ok =
      EventEmitter.emit(emitter, :messages_upsert, %{
        type: :notify,
        request_id: "pdo-req-1",
        messages: [%{key: %{remote_jid: "a@s.whatsapp.net", id: "restored-1", from_me: false}}]
      })

    :ok =
      EventEmitter.emit(emitter, :messages_upsert, %{
        type: :notify,
        request_id: "pdo-req-1",
        messages: [%{key: %{remote_jid: "a@s.whatsapp.net", id: "restored-2", from_me: false}}]
      })

    # Different request_id drains the first group cleanly without losing request_id
    :ok =
      EventEmitter.emit(emitter, :messages_upsert, %{
        type: :notify,
        request_id: "pdo-req-2",
        messages: [%{key: %{remote_jid: "a@s.whatsapp.net", id: "restored-3", from_me: false}}]
      })

    assert_receive {:processed_events,
                    %{
                      messages_upsert: %{
                        type: :notify,
                        request_id: "pdo-req-1",
                        messages: [
                          %{key: %{id: "restored-1"}},
                          %{key: %{id: "restored-2"}}
                        ]
                      }
                    }},
                   500

    assert EventEmitter.flush(emitter)

    assert_receive {:processed_events,
                    %{
                      messages_upsert: %{
                        type: :notify,
                        request_id: "pdo-req-2",
                        messages: [%{key: %{id: "restored-3"}}]
                      }
                    }},
                   500
  end

  test "buffered reactions and receipts fold into matching upserts and consolidate standalone entries per author/user" do
    test_pid = self()
    {:ok, emitter} = EventEmitter.start_link(buffer_timeout_ms: 5_000)
    _unsubscribe = EventEmitter.process(emitter, &send(test_pid, {:processed_events, &1}))

    group_key = fn id -> %{remote_jid: "g1@g.us", id: id, from_me: true} end

    :ok = EventEmitter.buffer(emitter)

    # Upsert message that will absorb both reaction and receipts
    :ok =
      EventEmitter.emit(emitter, :messages_upsert, %{
        type: :notify,
        messages: [%{key: group_key.("m-in-buf"), message: %{conversation: "hi"}}]
      })

    # Reactions on buffered upsert: same author replaces first reaction; other author kept
    :ok =
      EventEmitter.emit(emitter, :messages_reaction, [
        %{
          key: group_key.("m-in-buf"),
          reaction: %{
            key: %{
              remote_jid: "g1@g.us",
              participant: "u1@s.whatsapp.net",
              from_me: false,
              id: "r1"
            },
            text: "👍"
          }
        },
        %{
          key: group_key.("m-in-buf"),
          reaction: %{
            key: %{
              remote_jid: "g1@g.us",
              participant: "u1@s.whatsapp.net",
              from_me: false,
              id: "r2"
            },
            text: "❤️"
          }
        },
        %{
          key: group_key.("m-in-buf"),
          reaction: %{
            key: %{
              remote_jid: "g1@g.us",
              participant: "u2@s.whatsapp.net",
              from_me: false,
              id: "r3"
            },
            text: "🔥"
          }
        }
      ])

    # Receipts on buffered upsert: delivery + read for u1 merge together
    :ok =
      EventEmitter.emit(emitter, :message_receipt_update, [
        %{
          key: Map.put(group_key.("m-in-buf"), :participant, "u1@s.whatsapp.net"),
          receipt: %{user_jid: "u1@s.whatsapp.net", receipt_timestamp: 100}
        },
        %{
          key: Map.put(group_key.("m-in-buf"), :participant, "u1@s.whatsapp.net"),
          receipt: %{user_jid: "u1@s.whatsapp.net", read_timestamp: 200}
        }
      ])

    # Standalone reactions + receipts (message not in buffer) also consolidate per author/user
    :ok =
      EventEmitter.emit(emitter, :messages_reaction, [
        %{
          key: group_key.("m-standalone"),
          reaction: %{
            key: %{
              remote_jid: "g1@g.us",
              participant: "u1@s.whatsapp.net",
              from_me: false,
              id: "r4"
            },
            text: "😀"
          }
        },
        %{
          key: group_key.("m-standalone"),
          reaction: %{
            key: %{
              remote_jid: "g1@g.us",
              participant: "u1@s.whatsapp.net",
              from_me: false,
              id: "r5"
            },
            text: "🎉"
          }
        }
      ])

    :ok =
      EventEmitter.emit(emitter, :message_receipt_update, [
        %{
          key: Map.put(group_key.("m-standalone"), :participant, "u1@s.whatsapp.net"),
          receipt: %{user_jid: "u1@s.whatsapp.net", receipt_timestamp: 300}
        },
        %{
          key: Map.put(group_key.("m-standalone"), :participant, "u1@s.whatsapp.net"),
          receipt: %{user_jid: "u1@s.whatsapp.net", read_timestamp: 400}
        },
        %{
          key: Map.put(group_key.("m-standalone"), :participant, "u2@s.whatsapp.net"),
          receipt: %{user_jid: "u2@s.whatsapp.net", receipt_timestamp: 350}
        }
      ])

    assert EventEmitter.flush(emitter)
    assert_receive {:processed_events, events}, 1_000

    assert %{
             messages_upsert: %{
               type: :notify,
               messages: [
                 %{
                   key: %{id: "m-in-buf"},
                   reactions: [
                     %{key: %{id: "r2", participant: "u1@s.whatsapp.net"}, text: "❤️"},
                     %{key: %{id: "r3", participant: "u2@s.whatsapp.net"}, text: "🔥"}
                   ],
                   user_receipt: [
                     %{user_jid: "u1@s.whatsapp.net", receipt_timestamp: 100, read_timestamp: 200}
                   ]
                 }
               ]
             },
             messages_reaction: [
               %{
                 key: %{id: "m-standalone"},
                 reaction: %{key: %{id: "r5", participant: "u1@s.whatsapp.net"}, text: "🎉"}
               }
             ],
             message_receipt_update: [
               %{
                 key: %{id: "m-standalone"},
                 receipt: %{
                   user_jid: "u1@s.whatsapp.net",
                   receipt_timestamp: 300,
                   read_timestamp: 400
                 }
               },
               %{
                 key: %{id: "m-standalone"},
                 receipt: %{user_jid: "u2@s.whatsapp.net", receipt_timestamp: 350}
               }
             ]
           } = events
  end

  test "history deduplication persists across flushes, permits later named contacts, and resets above max cache size" do
    test_pid = self()
    {:ok, emitter} = EventEmitter.start_link(buffer_timeout_ms: 5_000, max_history_cache_size: 4)
    _unsubscribe = EventEmitter.process(emitter, &send(test_pid, {:processed_events, &1}))
    msg_key = fn id -> %{remote_jid: "c1@s.whatsapp.net", id: id, from_me: false} end

    # First flush populates the cross-flush history cache (3 entries: chat c1, contact c1, msg m1)
    :ok = EventEmitter.buffer(emitter)

    :ok =
      EventEmitter.emit(emitter, :messaging_history_set, %{
        chats: [%{id: "c1@s.whatsapp.net"}],
        contacts: [%{id: "c1@s.whatsapp.net"}],
        messages: [%{key: msg_key.("m1")}],
        sync_type: :INITIAL_BOOTSTRAP
      })

    assert EventEmitter.flush(emitter)
    assert_receive {:processed_events, %{messaging_history_set: first}}, 500
    assert Enum.map(first.chats, & &1.id) == ["c1@s.whatsapp.net"]
    assert first.contacts == [%{id: "c1@s.whatsapp.net"}]
    assert Enum.map(first.messages, & &1.key.id) == ["m1"]

    # Second flush overlaps c1 and m1, adds a nameless duplicate c1 (skipped) and a named c1 (permitted!), plus m2
    :ok = EventEmitter.buffer(emitter)

    :ok =
      EventEmitter.emit(emitter, :messaging_history_set, %{
        chats: [%{id: "c1@s.whatsapp.net"}, %{id: "c2@s.whatsapp.net"}],
        contacts: [%{id: "c1@s.whatsapp.net"}],
        messages: [%{key: msg_key.("m1")}, %{key: msg_key.("m2")}],
        sync_type: :RECENT
      })

    assert EventEmitter.flush(emitter)
    assert_receive {:processed_events, %{messaging_history_set: second}}, 500
    assert Enum.map(second.chats, & &1.id) == ["c2@s.whatsapp.net"]
    assert second.contacts == []
    assert Enum.map(second.messages, & &1.key.id) == ["m2"]

    # Cache size is now 5 (> max_history_cache_size 4), so flush cleared it; also verify named contact always passes
    :ok = EventEmitter.buffer(emitter)

    :ok =
      EventEmitter.emit(emitter, :messaging_history_set, %{
        chats: [%{id: "c1@s.whatsapp.net"}],
        contacts: [%{id: "c1@s.whatsapp.net", name: "Alice"}],
        messages: [%{key: msg_key.("m1")}],
        sync_type: :FULL
      })

    assert EventEmitter.flush(emitter)
    assert_receive {:processed_events, %{messaging_history_set: third}}, 500
    assert Enum.map(third.chats, & &1.id) == ["c1@s.whatsapp.net"]
    assert third.contacts == [%{id: "c1@s.whatsapp.net", name: "Alice"}]
    assert Enum.map(third.messages, & &1.key.id) == ["m1"]

    # Immediately following flush (cache size 3 <= 4): nameless contact skipped, named contact still emitted
    :ok = EventEmitter.buffer(emitter)

    :ok =
      EventEmitter.emit(emitter, :messaging_history_set, %{
        chats: [],
        contacts: [%{id: "c1@s.whatsapp.net", notify: "Alice Push"}],
        messages: [],
        sync_type: :PUSH_NAME
      })

    assert EventEmitter.flush(emitter)
    assert_receive {:processed_events, %{messaging_history_set: fourth}}, 500
    assert fourth.contacts == [%{id: "c1@s.whatsapp.net", notify: "Alice Push"}]
  end

  test "buffered PDO upsert stays canonical across history overlap, revoke/edit, boundary flush, and reverse order" do
    test_pid = self()
    {:ok, emitter} = EventEmitter.start_link(buffer_timeout_ms: 5_000)
    _unsubscribe = EventEmitter.process(emitter, &send(test_pid, {:processed_events, &1}))
    pdo_key = %{remote_jid: "c1@s.whatsapp.net", id: "pdo-m1", from_me: false}
    other_hist_key = %{remote_jid: "c1@s.whatsapp.net", id: "hist-m2", from_me: false}

    # 1. History -> PDO restore -> revoke before flush: single canonical copy in messages_upsert gets the revoke
    :ok = EventEmitter.buffer(emitter)

    :ok =
      EventEmitter.emit(emitter, :messaging_history_set, %{
        chats: [%{id: "c1@s.whatsapp.net"}],
        contacts: [],
        messages: [
          %{key: pdo_key, message_timestamp: 1_710_000_100},
          %{key: other_hist_key, message_timestamp: 1_710_000_101}
        ],
        sync_type: :RECENT
      })

    :ok =
      EventEmitter.emit(emitter, :messages_upsert, %{
        type: :notify,
        request_id: "pdo-req-42",
        messages: [%{key: pdo_key, message: %{conversation: "restored from phone"}}]
      })

    :ok =
      EventEmitter.emit(emitter, :messages_update, [
        %{key: pdo_key, update: %{message: nil, message_stub_type: :REVOKE}}
      ])

    assert EventEmitter.flush(emitter)
    assert_receive {:processed_events, events}, 1_000

    assert %{
             messaging_history_set: %{messages: [%{key: ^other_hist_key}]},
             messages_upsert: %{
               type: :notify,
               request_id: "pdo-req-42",
               messages: [
                 %{
                   key: ^pdo_key,
                   message: nil,
                   message_stub_type: :REVOKE,
                   message_timestamp: 1_710_000_100
                 }
               ]
             }
           } = events

    refute Map.has_key?(events, :messages_update)

    # 2. History -> PDO restore -> boundary flush (new upsert with nil request_id) -> revoke emits standalone update
    pdo_key_2 = %{remote_jid: "c1@s.whatsapp.net", id: "pdo-m2", from_me: false}
    other_key_3 = %{remote_jid: "c1@s.whatsapp.net", id: "live-m3", from_me: false}

    :ok = EventEmitter.buffer(emitter)

    :ok =
      EventEmitter.emit(emitter, :messaging_history_set, %{
        chats: [%{id: "c1@s.whatsapp.net"}],
        contacts: [],
        messages: [%{key: pdo_key_2, message_timestamp: 1_710_000_200}],
        sync_type: :RECENT
      })

    :ok =
      EventEmitter.emit(emitter, :messages_upsert, %{
        type: :notify,
        request_id: "pdo-req-99",
        messages: [%{key: pdo_key_2, message: %{conversation: "restored before boundary"}}]
      })

    :ok =
      EventEmitter.emit(emitter, :messages_upsert, %{
        type: :notify,
        messages: [%{key: other_key_3, message: %{conversation: "live"}}]
      })

    assert_receive {:processed_events,
                    %{
                      messages_upsert: %{
                        type: :notify,
                        request_id: "pdo-req-99",
                        messages: [
                          %{
                            key: ^pdo_key_2,
                            message: %{conversation: "restored before boundary"},
                            message_timestamp: 1_710_000_200
                          }
                        ]
                      }
                    }},
                   1_000

    :ok =
      EventEmitter.emit(emitter, :messages_update, [
        %{key: pdo_key_2, update: %{message: nil, message_stub_type: :REVOKE}}
      ])

    assert EventEmitter.flush(emitter)
    assert_receive {:processed_events, boundary_events}, 1_000

    assert %{
             messaging_history_set: %{messages: []},
             messages_upsert: %{type: :notify, messages: [%{key: ^other_key_3}]},
             messages_update: [
               %{key: ^pdo_key_2, update: %{message: nil, message_stub_type: :REVOKE}}
             ]
           } = boundary_events

    # 3. Reverse order: PDO restore -> History -> edit folds edit into tagged upsert with no duplicate in history
    pdo_key_3 = %{remote_jid: "c1@s.whatsapp.net", id: "pdo-m3", from_me: false}

    :ok = EventEmitter.buffer(emitter)

    :ok =
      EventEmitter.emit(emitter, :messages_upsert, %{
        type: :notify,
        request_id: "pdo-req-77",
        messages: [%{key: pdo_key_3, message: %{conversation: "restored first"}}]
      })

    :ok =
      EventEmitter.emit(emitter, :messaging_history_set, %{
        chats: [%{id: "c1@s.whatsapp.net"}],
        contacts: [],
        messages: [%{key: pdo_key_3, message_timestamp: 1_710_000_300}],
        sync_type: :RECENT
      })

    :ok =
      EventEmitter.emit(emitter, :messages_update, [
        %{key: pdo_key_3, update: %{message: %{conversation: "edited"}}}
      ])

    assert EventEmitter.flush(emitter)
    assert_receive {:processed_events, reverse_events}, 1_000

    assert %{
             messaging_history_set: %{messages: []},
             messages_upsert: %{
               type: :notify,
               request_id: "pdo-req-77",
               messages: [
                 %{
                   key: ^pdo_key_3,
                   message: %{conversation: "edited"},
                   message_timestamp: 1_710_000_300
                 }
               ]
             }
           } = reverse_events

    refute Map.has_key?(reverse_events, :messages_update)
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
