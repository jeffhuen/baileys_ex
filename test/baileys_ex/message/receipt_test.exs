defmodule BaileysEx.Message.ReceiptTest do
  use ExUnit.Case, async: true

  alias BaileysEx.BinaryNode
  alias BaileysEx.Connection.EventEmitter
  alias BaileysEx.Message.Receipt

  test "read_messages/3 chooses read-self when privacy disables read receipts and aggregates ids" do
    parent = self()

    keys = [
      %{remote_jid: "15551234567@s.whatsapp.net", id: "a", from_me: false},
      %{remote_jid: "15551234567@s.whatsapp.net", id: "b", from_me: false}
    ]

    assert :ok =
             Receipt.read_messages(
               fn node ->
                 send(parent, {:receipt, node})
                 :ok
               end,
               keys,
               %{readreceipts: "none"}
             )

    assert_receive {:receipt,
                    %BinaryNode{
                      tag: "receipt",
                      attrs: %{
                        "id" => "a",
                        "to" => "15551234567@s.whatsapp.net",
                        "type" => "read-self",
                        "t" => _
                      },
                      content: [
                        %BinaryNode{
                          tag: "list",
                          content: [%BinaryNode{tag: "item", attrs: %{"id" => "b"}}]
                        }
                      ]
                    }}
  end

  test "process_receipt/2 emits messages_update for direct receipts and message_receipt_update for group receipts" do
    {:ok, emitter} = EventEmitter.start_link()
    parent = self()
    unsubscribe = EventEmitter.process(emitter, &send(parent, {:events, &1}))

    direct = %BinaryNode{
      tag: "receipt",
      attrs: %{
        "id" => "direct-1",
        "from" => "15551234567@s.whatsapp.net",
        "t" => "1710000300"
      },
      content: nil
    }

    assert :ok = Receipt.process_receipt(direct, emitter)

    assert_receive {:events,
                    %{
                      messages_update: [
                        %{
                          key: %{
                            remote_jid: "15551234567@s.whatsapp.net",
                            id: "direct-1",
                            from_me: true
                          },
                          update: %{status: :delivery_ack, message_timestamp: 1_710_000_300}
                        }
                      ]
                    }}

    group = %BinaryNode{
      tag: "receipt",
      attrs: %{
        "id" => "group-1",
        "from" => "120363001234567890@g.us",
        "participant" => "15551234567@s.whatsapp.net",
        "type" => "read",
        "t" => "1710000400"
      },
      content: [
        %BinaryNode{
          tag: "list",
          attrs: %{},
          content: [%BinaryNode{tag: "item", attrs: %{"id" => "group-2"}, content: nil}]
        }
      ]
    }

    assert :ok = Receipt.process_receipt(group, emitter)

    assert_receive {:events,
                    %{
                      message_receipt_update: [
                        %{
                          key: %{remote_jid: "120363001234567890@g.us", id: "group-1"},
                          receipt: %{
                            user_jid: "15551234567@s.whatsapp.net",
                            read_timestamp: 1_710_000_400
                          }
                        },
                        %{
                          key: %{remote_jid: "120363001234567890@g.us", id: "group-2"},
                          receipt: %{
                            user_jid: "15551234567@s.whatsapp.net",
                            read_timestamp: 1_710_000_400
                          }
                        }
                      ]
                    }}

    unsubscribe.()
  end
end
