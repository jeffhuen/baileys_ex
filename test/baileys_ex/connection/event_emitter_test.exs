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
end
