defmodule BaileysEx.Parity.MessageTest do
  use BaileysEx.Parity.Case, async: true

  alias BaileysEx.Message.Builder
  alias BaileysEx.Protocol.Proto.Message

  @message_secret :binary.copy(<<0x33>>, 32)

  test "Baileys generateWAMessageContent matches Elixir for plain text content" do
    content = %{"text" => "parity hello"}

    expected_hex =
      run_baileys_reference!("message.generate_content", %{
        "content" => content,
        "message_secret_base64" => Base.encode64(@message_secret)
      })["message_hex"]

    actual_hex =
      %{text: "parity hello"}
      |> Builder.build(message_secret: @message_secret)
      |> Message.encode()
      |> Base.encode16(case: :lower)

    assert actual_hex == expected_hex
  end

  test "Baileys generateWAMessageContent matches Elixir for reaction content" do
    sender_timestamp_ms = 1_710_000_123_456

    content = %{
      "react" => %{
        "key" => %{"id" => "msg-1", "remoteJid" => "15551234567@s.whatsapp.net"},
        "text" => "🔥",
        "senderTimestampMs" => sender_timestamp_ms
      }
    }

    expected_hex =
      run_baileys_reference!("message.generate_content", %{
        "content" => content
      })["message_hex"]

    actual_hex =
      %{
        react: %{
          key: %{id: "msg-1", remote_jid: "15551234567@s.whatsapp.net"},
          text: "🔥",
          sender_timestamp_ms: sender_timestamp_ms
        }
      }
      |> Builder.build()
      |> Message.encode()
      |> Base.encode16(case: :lower)

    assert actual_hex == expected_hex
  end

  test "Baileys generateWAMessageContent matches Elixir for limit_sharing content" do
    now_ms = 1_710_000_000_000

    expected_hex =
      run_baileys_reference!("message.generate_content", %{
        "content" => %{"limitSharing" => true},
        "now_ms" => now_ms,
        "message_secret_base64" => Base.encode64(@message_secret)
      })["message_hex"]

    actual_hex =
      %{limit_sharing: true}
      |> Builder.build(now_ms: fn -> now_ms end, message_secret: @message_secret)
      |> Message.encode()
      |> Base.encode16(case: :lower)

    assert actual_hex == expected_hex
  end
end
