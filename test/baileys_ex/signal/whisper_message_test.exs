defmodule BaileysEx.Signal.WhisperMessageTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Signal.WhisperMessage

  @ratchet_key :binary.copy(<<0xAA>>, 32)
  @ciphertext :binary.copy(<<0xBB>>, 48)
  @mac_key :binary.copy(<<0xCC>>, 32)
  @sender_identity <<5>> <> :binary.copy(<<0x01>>, 32)
  @receiver_identity <<5>> <> :binary.copy(<<0x02>>, 32)

  test "roundtrip encode/decode preserves all fields" do
    {:ok, msg} =
      WhisperMessage.new(
        @ratchet_key,
        42,
        10,
        @ciphertext,
        @mac_key,
        @sender_identity,
        @receiver_identity
      )

    assert msg.ratchet_key == @ratchet_key
    assert msg.counter == 42
    assert msg.previous_counter == 10
    assert msg.ciphertext == @ciphertext

    {:ok, decoded} = WhisperMessage.decode(msg.serialized)

    assert decoded.ratchet_key == @ratchet_key
    assert decoded.counter == 42
    assert decoded.previous_counter == 10
    assert decoded.ciphertext == @ciphertext
  end

  test "serialized format starts with version byte 0x33" do
    {:ok, msg} =
      WhisperMessage.new(
        @ratchet_key,
        0,
        0,
        @ciphertext,
        @mac_key,
        @sender_identity,
        @receiver_identity
      )

    assert <<0x33, _rest::binary>> = WhisperMessage.serialize(msg)
  end

  test "serialized format ends with 8-byte MAC" do
    {:ok, msg} =
      WhisperMessage.new(
        @ratchet_key,
        0,
        0,
        @ciphertext,
        @mac_key,
        @sender_identity,
        @receiver_identity
      )

    serialized = WhisperMessage.serialize(msg)
    assert byte_size(serialized) > 8

    # Last 8 bytes should be MAC
    mac_start = byte_size(serialized) - 8
    <<_message::binary-size(mac_start), mac::binary-8>> = serialized
    assert byte_size(mac) == 8
  end

  test "decode rejects too-short binary" do
    assert {:error, :invalid_whisper_message} = WhisperMessage.decode(<<1, 2, 3>>)
  end

  test "decode rejects wrong version byte" do
    # Build a binary with wrong version byte but correct length
    fake = <<0x22>> <> :binary.copy(<<0>>, 20) <> :binary.copy(<<0>>, 8)
    assert {:error, :invalid_whisper_message} = WhisperMessage.decode(fake)
  end

  test "counter=0 and previous_counter=0 roundtrip" do
    {:ok, msg} =
      WhisperMessage.new(
        @ratchet_key,
        0,
        0,
        @ciphertext,
        @mac_key,
        @sender_identity,
        @receiver_identity
      )

    {:ok, decoded} = WhisperMessage.decode(msg.serialized)
    assert decoded.counter == 0
    assert decoded.previous_counter == 0
  end

  test "large counter values roundtrip" do
    {:ok, msg} =
      WhisperMessage.new(
        @ratchet_key,
        65_535,
        32_767,
        @ciphertext,
        @mac_key,
        @sender_identity,
        @receiver_identity
      )

    {:ok, decoded} = WhisperMessage.decode(msg.serialized)
    assert decoded.counter == 65_535
    assert decoded.previous_counter == 32_767
  end

  test "version_byte returns 0x33" do
    assert WhisperMessage.version_byte() == 0x33
  end

  test "mac_length returns 8" do
    assert WhisperMessage.mac_length() == 8
  end

  test "verify_mac validates the serialized message with the provided MAC key" do
    {:ok, msg} =
      WhisperMessage.new(
        @ratchet_key,
        7,
        3,
        @ciphertext,
        @mac_key,
        @sender_identity,
        @receiver_identity
      )

    assert WhisperMessage.verify_mac(msg, @mac_key, @sender_identity, @receiver_identity)

    refute WhisperMessage.verify_mac(
             msg,
             :binary.copy(<<0xDD>>, 32),
             @sender_identity,
             @receiver_identity
           )
  end
end
