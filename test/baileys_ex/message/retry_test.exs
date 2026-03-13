defmodule BaileysEx.Message.RetryTest do
  use ExUnit.Case, async: true

  alias BaileysEx.BinaryNode
  alias BaileysEx.Connection.Store
  alias BaileysEx.Message.Retry
  alias BaileysEx.Protocol.Proto.Message

  test "should_recreate_session/5 recreates immediately for missing sessions and MAC errors with cooldown" do
    {:ok, store} = Store.start_link()
    ref = Store.wrap(store)

    assert %{recreate: true} =
             Retry.should_recreate_session(ref, "15551234567@s.whatsapp.net", false)

    assert %{recreate: true} =
             Retry.should_recreate_session(
               ref,
               "15551234567@s.whatsapp.net",
               true,
               :SIGNAL_ERROR_BAD_MAC
             )

    assert %{recreate: false} =
             Retry.should_recreate_session(ref, "15551234567@s.whatsapp.net", true)
  end

  test "recent-message cache stores, looks up, and prunes to the configured size" do
    {:ok, store} = Store.start_link()
    ref = Store.wrap(store)

    assert :ok =
             Retry.add_recent_message(ref, "15551234567@s.whatsapp.net", "a", %Message{},
               max_size: 2
             )

    assert :ok =
             Retry.add_recent_message(ref, "15551234567@s.whatsapp.net", "b", %Message{},
               max_size: 2
             )

    assert :ok =
             Retry.add_recent_message(ref, "15551234567@s.whatsapp.net", "c", %Message{},
               max_size: 2
             )

    assert %{message: %Message{}} =
             Retry.get_recent_message(ref, "15551234567@s.whatsapp.net", "b")

    assert %{message: %Message{}} =
             Retry.get_recent_message(ref, "15551234567@s.whatsapp.net", "c")

    assert Retry.get_recent_message(ref, "15551234567@s.whatsapp.net", "a") == nil
  end

  test "schedule_phone_request/5 debounces prior timers and cancel_phone_request/2 prevents callback delivery" do
    {:ok, store} = Store.start_link()
    ref = Store.wrap(store)
    parent = self()

    assert :ok =
             Retry.schedule_phone_request(ref, "msg-1", fn -> send(parent, :first) end,
               delay_ms: 5
             )

    assert :ok =
             Retry.schedule_phone_request(ref, "msg-1", fn -> send(parent, :second) end,
               delay_ms: 5
             )

    refute_receive :first, 20
    assert_receive :second, 50

    assert :ok =
             Retry.schedule_phone_request(ref, "msg-2", fn -> send(parent, :cancelled) end,
               delay_ms: 5
             )

    assert :ok = Retry.cancel_phone_request(ref, "msg-2")
    refute_receive :cancelled, 20
  end

  test "request_placeholder_resend/4 deduplicates, resolves early, and delegates to PDO transport" do
    {:ok, store} = Store.start_link()
    ref = Store.wrap(store)
    parent = self()

    key = %{remote_jid: "15551234567@s.whatsapp.net", from_me: false, id: "placeholder-1"}

    assert {:ok, "pdo-1"} =
             Retry.request_placeholder_resend(ref, key, %{message_timestamp: 123},
               delay_ms: 0,
               timeout_ms: 20,
               send_request_fun: fn pdo_message ->
                 send(parent, {:pdo, pdo_message})
                 {:ok, "pdo-1"}
               end
             )

    assert_receive {:pdo,
                    %Message.PeerDataOperationRequestMessage{
                      peer_data_operation_request_type: :PLACEHOLDER_MESSAGE_RESEND,
                      placeholder_message_resend_request: [
                        %Message.PeerDataOperationRequestMessage.PlaceholderMessageResendRequest{
                          message_key: %{id: "placeholder-1"}
                        }
                      ]
                    }}

    assert {:ok, nil} =
             Retry.request_placeholder_resend(ref, key, nil,
               delay_ms: 0,
               send_request_fun: fn _ -> flunk("should not send duplicate PDO request") end
             )

    resolved_key = %{
      remote_jid: "15551234567@s.whatsapp.net",
      from_me: false,
      id: "placeholder-2"
    }

    task =
      Task.async(fn ->
        Retry.request_placeholder_resend(ref, resolved_key, %{message_timestamp: 124},
          delay_ms: 10,
          timeout_ms: 20,
          send_request_fun: fn _ -> flunk("resolved resend should not reach PDO transport") end
        )
      end)

    Process.sleep(2)
    assert :ok = Retry.resolve_placeholder_resend(ref, "placeholder-2")
    assert {:ok, "RESOLVED"} = Task.await(task, 100)
  end

  test "handle_retry_receipt/3 resends cached messages and enforces the max retry count" do
    {:ok, store} = Store.start_link()
    ref = Store.wrap(store)
    parent = self()

    assert :ok =
             Retry.add_recent_message(ref, "15551234567@s.whatsapp.net", "retry-1", %Message{})

    node = %BinaryNode{
      tag: "receipt",
      attrs: %{
        "id" => "retry-1",
        "from" => "15551234567@s.whatsapp.net",
        "type" => "retry"
      },
      content: [
        %BinaryNode{
          tag: "retry",
          attrs: %{"count" => "1"},
          content: nil
        }
      ]
    }

    assert {:ok, [%Message{}]} =
             Retry.handle_retry_receipt(ref, node,
               resend_fun: fn message, meta ->
                 send(parent, {:resent, message, meta})
                 :ok
               end
             )

    assert_receive {:resent, %Message{},
                    %{remote_jid: "15551234567@s.whatsapp.net", ids: ["retry-1"]}}

    too_many =
      put_in(node.content, [
        %BinaryNode{
          tag: "retry",
          attrs: %{"count" => "5"},
          content: nil
        }
      ])

    assert {:error, :max_retries_exceeded} =
             Retry.handle_retry_receipt(ref, too_many, resend_fun: fn _, _ -> :ok end)
  end

  test "send_retry_request/3 emits a retry receipt, increments counters, and schedules placeholder resend" do
    {:ok, store} = Store.start_link()
    ref = Store.wrap(store)
    parent = self()

    node = %BinaryNode{
      tag: "message",
      attrs: %{
        "id" => "retry-out-1",
        "from" => "15551234567@s.whatsapp.net",
        "participant" => "15551234567:1@s.whatsapp.net",
        "t" => "1710000700"
      },
      content: []
    }

    assert {:ok,
            %BinaryNode{
              tag: "receipt",
              attrs: %{
                "id" => "retry-out-1",
                "type" => "retry",
                "to" => "15551234567@s.whatsapp.net",
                "participant" => "15551234567:1@s.whatsapp.net"
              },
              content: [%BinaryNode{tag: "retry", attrs: %{"count" => "1", "error" => "0"}}]
            }} =
             Retry.send_retry_request(ref, node,
               send_node_fun: fn receipt ->
                 send(parent, {:receipt, receipt})
                 :ok
               end,
               request_placeholder_resend_fun: fn message_key, msg_data ->
                 send(parent, {:placeholder_resend, message_key, msg_data})
                 :ok
               end,
               phone_request_delay_ms: 5
             )

    assert Retry.get_retry_count(ref, "retry-out-1") == 1
    assert_receive {:receipt, %BinaryNode{tag: "receipt", attrs: %{"id" => "retry-out-1"}}}

    assert_receive {:placeholder_resend,
                    %{id: "retry-out-1", remote_jid: "15551234567@s.whatsapp.net"},
                    %{key: %{id: "retry-out-1"}}}
  end
end
