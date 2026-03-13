defmodule BaileysEx.Message.OfflineQueueTest do
  use ExUnit.Case, async: true

  alias BaileysEx.BinaryNode
  alias BaileysEx.Connection.EventEmitter
  alias BaileysEx.Message.OfflineQueue

  test "drain/3 preserves FIFO order, yields after 10 nodes, and flushes buffered events when empty" do
    {:ok, emitter} = EventEmitter.start_link()
    parent = self()
    unsubscribe = EventEmitter.process(emitter, &send(parent, {:events, &1}))

    state =
      1..12
      |> Enum.reduce(OfflineQueue.new(), fn index, acc ->
        OfflineQueue.enqueue(acc, :message, %BinaryNode{
          tag: "message",
          attrs: %{"id" => "offline-#{index}"},
          content: nil
        })
      end)

    drain_fun = fn :message, %BinaryNode{attrs: %{"id" => id}} ->
      send(parent, {:processed, id})

      EventEmitter.emit(emitter, :messages_upsert, %{
        type: :append,
        messages: [%{key: %{id: id}}]
      })
    end

    assert {:ok, state, %{processed_count: 10, continue?: true}} =
             OfflineQueue.drain(state, %{event_emitter: emitter}, drain_fun)

    for index <- 1..10 do
      id = "offline-#{index}"
      assert_receive {:processed, ^id}
    end

    refute_received {:processed, "offline-11"}
    refute_received {:events, _events}
    assert EventEmitter.buffering?(emitter)

    assert {:ok, _state, %{processed_count: 2, continue?: false}} =
             OfflineQueue.drain(state, %{event_emitter: emitter}, drain_fun)

    assert_receive {:processed, "offline-11"}
    assert_receive {:processed, "offline-12"}

    assert_receive {:events,
                    %{
                      messages_upsert: %{
                        type: :append,
                        messages: messages
                      }
                    }}

    assert Enum.map(messages, & &1.key.id) == Enum.map(1..12, &"offline-#{&1}")
    refute EventEmitter.buffering?(emitter)

    unsubscribe.()
  end
end
