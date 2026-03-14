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

  test "generate_message_id/2 accepts deterministic timestamp and random bytes" do
    assert "3EB06AF2C68842CBB3F8CA" ==
             Wire.generate_message_id(
               "15551234567@s.whatsapp.net",
               timestamp: 1_710_000_000,
               random_bytes: <<0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15>>
             )
  end

  test "write_random_pad_max16/2 accepts a deterministic random byte" do
    assert "wire" <> :binary.copy(<<12>>, 12) ==
             Wire.write_random_pad_max16("wire", random_byte: 0xAB)
  end

  test "encode/1 and decode/1 roundtrip with random padding" do
    message = %Message{extended_text_message: %Message.ExtendedTextMessage{text: "wire"}}

    assert {:ok, %Message{extended_text_message: %Message.ExtendedTextMessage{text: "wire"}}} =
             message
             |> Wire.encode()
             |> Wire.decode()
  end
end
