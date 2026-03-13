defmodule BaileysEx.Message.WireTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Message.Wire
  alias BaileysEx.Protocol.Proto.Message

  test "generate_message_id/1 falls back gracefully for oversized user ids" do
    oversized_user =
      String.duplicate("1234567890", 3) <> "@s.whatsapp.net"

    message_id = Wire.generate_message_id(oversized_user)

    assert message_id =~ ~r/^3EB0[0-9A-F]{18}$/
  end

  test "encode/1 and decode/1 roundtrip with random padding" do
    message = %Message{extended_text_message: %Message.ExtendedTextMessage{text: "wire"}}

    assert {:ok, %Message{extended_text_message: %Message.ExtendedTextMessage{text: "wire"}}} =
             message
             |> Wire.encode()
             |> Wire.decode()
  end
end
