defmodule BaileysEx.Message.HistorySyncTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Message.Builder
  alias BaileysEx.Protocol.Proto.Message
  alias BaileysEx.Protocol.Proto.MessageKey
  alias BaileysEx.Protocol.Proto.WebMessageInfo
  alias BaileysEx.Protocol.Proto.Wire

  test "process_notification/3 decodes inline bootstrap payloads and extracts explicit and fallback PN-LID mappings" do
    payload =
      encode_history_sync(
        sync_type: :INITIAL_BOOTSTRAP,
        progress: 77,
        phone_number_to_lid_mappings: [
          %{pn_jid: "15550000000@s.whatsapp.net", lid_jid: "50000@lid"}
        ],
        conversations: [
          %{
            id: "12345@lid",
            display_name: "Fallback Chat",
            messages: [
              %{
                key: %{remote_jid: "12345@lid", id: "hist-msg-1", from_me: true},
                message: Builder.build(%{text: "hello history"}),
                message_timestamp: 1_710_000_700,
                user_receipt: [%{user_jid: "15551234567@s.whatsapp.net"}]
              }
            ]
          },
          %{
            id: "15557654321@s.whatsapp.net",
            pn_jid: "15557654321@s.whatsapp.net",
            lid_jid: "76543@lid",
            display_name: "Explicit Chat",
            messages: [
              %{
                key: %{remote_jid: "15557654321@s.whatsapp.net", id: "hist-msg-2", from_me: false},
                message: Builder.build(%{text: "world history"}),
                message_timestamp: 1_710_000_701
              }
            ]
          }
        ]
      )

    notification =
      %Message.HistorySyncNotification{
        sync_type: :INITIAL_BOOTSTRAP,
        progress: 77,
        peer_data_request_session_id: "pdo-hist-1"
      }
      |> Map.put(:initial_hist_bootstrap_inline_payload, payload)

    assert {:ok, data} =
             apply(BaileysEx.Message.HistorySync, :process_notification, [
               notification,
               %{key: %{id: "history-msg"}},
               %{inflate_fun: fn bytes -> {:ok, bytes} end}
             ])

    assert data.sync_type == :INITIAL_BOOTSTRAP
    assert data.progress == 77
    assert data.peer_data_request_session_id == "pdo-hist-1"
    assert [%{id: "12345@lid"}, %{id: "15557654321@s.whatsapp.net"}] = data.chats
    assert Enum.any?(data.contacts, &(&1.id == "12345@lid" and &1.name == "Fallback Chat"))

    assert Enum.any?(
             data.contacts,
             &(&1.id == "15557654321@s.whatsapp.net" and &1.lid == "76543@lid")
           )

    assert Enum.map(data.messages, & &1.key.id) == ["hist-msg-1", "hist-msg-2"]

    assert Enum.member?(data.lid_pn_mappings, %{
             lid: "50000@lid",
             pn: "15550000000@s.whatsapp.net"
           })

    assert Enum.member?(data.lid_pn_mappings, %{
             lid: "12345@lid",
             pn: "15551234567@s.whatsapp.net"
           })

    assert Enum.member?(data.lid_pn_mappings, %{
             lid: "76543@lid",
             pn: "15557654321@s.whatsapp.net"
           })
  end

  test "process_notification/3 downloads payloads when inline data is absent" do
    payload =
      encode_history_sync(
        sync_type: :PUSH_NAME,
        progress: 12,
        pushnames: [
          %{id: "15551234567@s.whatsapp.net", pushname: "Updated Name"}
        ]
      )

    notification =
      %Message.HistorySyncNotification{sync_type: :PUSH_NAME, progress: 12}
      |> Map.put(:direct_path, "/history-sync/1")

    assert {:ok, data} =
             apply(BaileysEx.Message.HistorySync, :process_notification, [
               notification,
               %{key: %{id: "history-msg-2"}},
               %{
                 history_sync_download_fun: fn received_notification, _context ->
                   assert received_notification.direct_path == "/history-sync/1"
                   {:ok, payload}
                 end,
                 inflate_fun: fn bytes -> {:ok, bytes} end
               }
             ])

    assert data.sync_type == :PUSH_NAME
    assert data.progress == 12
    assert data.chats == []
    assert data.messages == []
    assert data.lid_pn_mappings == []
    assert data.contacts == [%{id: "15551234567@s.whatsapp.net", notify: "Updated Name"}]
  end

  defp encode_history_sync(opts) do
    sync_type =
      opts[:sync_type]
      |> sync_type_value()
      |> then(&Wire.encode_uint(1, &1))

    conversations =
      opts
      |> Keyword.get(:conversations, [])
      |> Enum.map(&Wire.encode_bytes(2, encode_conversation(&1)))

    progress = Wire.encode_uint(6, opts[:progress] || 0)

    pushnames =
      opts
      |> Keyword.get(:pushnames, [])
      |> Enum.map(&Wire.encode_bytes(7, encode_pushname(&1)))

    mappings =
      opts
      |> Keyword.get(:phone_number_to_lid_mappings, [])
      |> Enum.map(&Wire.encode_bytes(15, encode_phone_number_to_lid_mapping(&1)))

    IO.iodata_to_binary([sync_type, conversations, progress, pushnames, mappings])
  end

  defp encode_conversation(conversation) do
    [
      Wire.encode_bytes(1, conversation.id),
      Enum.map(
        conversation.messages || [],
        &Wire.encode_bytes(2, encode_history_sync_message(&1))
      ),
      Wire.encode_bytes(38, conversation[:display_name]),
      Wire.encode_bytes(39, conversation[:pn_jid]),
      Wire.encode_bytes(42, conversation[:lid_jid])
    ]
    |> IO.iodata_to_binary()
  end

  defp encode_history_sync_message(message) do
    Wire.encode_bytes(1, encode_web_message_info(message))
  end

  defp encode_web_message_info(message) do
    base =
      %WebMessageInfo{
        key: struct(MessageKey, message.key),
        message: message.message,
        message_timestamp: message.message_timestamp
      }
      |> WebMessageInfo.encode()

    user_receipts =
      message
      |> Map.get(:user_receipt, [])
      |> Enum.map(&Wire.encode_bytes(40, encode_user_receipt(&1)))

    IO.iodata_to_binary([base, user_receipts])
  end

  defp encode_user_receipt(receipt) do
    [
      Wire.encode_bytes(1, receipt.user_jid),
      Wire.encode_uint(2, receipt[:receipt_timestamp]),
      Wire.encode_uint(3, receipt[:read_timestamp]),
      Wire.encode_uint(4, receipt[:played_timestamp])
    ]
    |> IO.iodata_to_binary()
  end

  defp encode_pushname(pushname) do
    Wire.encode_bytes(1, pushname.id) <> Wire.encode_bytes(2, pushname.pushname)
  end

  defp encode_phone_number_to_lid_mapping(mapping) do
    Wire.encode_bytes(1, mapping.pn_jid) <> Wire.encode_bytes(2, mapping.lid_jid)
  end

  defp sync_type_value(:INITIAL_BOOTSTRAP), do: 0
  defp sync_type_value(:FULL), do: 2
  defp sync_type_value(:RECENT), do: 3
  defp sync_type_value(:PUSH_NAME), do: 4
  defp sync_type_value(:ON_DEMAND), do: 6
end
