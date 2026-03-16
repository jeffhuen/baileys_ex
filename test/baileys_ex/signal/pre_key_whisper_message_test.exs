defmodule BaileysEx.Signal.PreKeyWhisperMessageTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Signal.PreKeyWhisperMessage

  @base_key <<5>> <> :binary.copy(<<0xAA>>, 32)
  @identity_key <<5>> <> :binary.copy(<<0xBB>>, 32)
  @inner_message :binary.copy(<<0xCC>>, 64)

  test "roundtrip encode/decode preserves all fields" do
    {:ok, msg} =
      PreKeyWhisperMessage.new(
        registration_id: 12_345,
        pre_key_id: 42,
        signed_pre_key_id: 7,
        base_key: @base_key,
        identity_key: @identity_key,
        message: @inner_message
      )

    assert msg.registration_id == 12_345
    assert msg.pre_key_id == 42
    assert msg.signed_pre_key_id == 7
    assert msg.base_key == @base_key
    assert msg.identity_key == @identity_key
    assert msg.message == @inner_message

    {:ok, decoded} = PreKeyWhisperMessage.decode(msg.serialized)

    assert decoded.registration_id == 12_345
    assert decoded.pre_key_id == 42
    assert decoded.signed_pre_key_id == 7
    assert decoded.base_key == @base_key
    assert decoded.identity_key == @identity_key
    assert decoded.message == @inner_message
  end

  test "serialized format starts with version byte 0x33" do
    {:ok, msg} =
      PreKeyWhisperMessage.new(
        registration_id: 1,
        pre_key_id: 0,
        signed_pre_key_id: 0,
        base_key: @base_key,
        identity_key: @identity_key,
        message: @inner_message
      )

    assert <<0x33, _rest::binary>> = PreKeyWhisperMessage.serialize(msg)
  end

  test "roundtrip without pre_key_id (nil)" do
    {:ok, msg} =
      PreKeyWhisperMessage.new(
        registration_id: 99,
        signed_pre_key_id: 3,
        base_key: @base_key,
        identity_key: @identity_key,
        message: @inner_message
      )

    assert msg.pre_key_id == nil

    {:ok, decoded} = PreKeyWhisperMessage.decode(msg.serialized)

    assert decoded.registration_id == 99
    assert decoded.pre_key_id == nil
    assert decoded.signed_pre_key_id == 3
    assert decoded.base_key == @base_key
    assert decoded.identity_key == @identity_key
    assert decoded.message == @inner_message
  end

  test "decode rejects wrong version byte" do
    assert {:error, :invalid_pre_key_whisper_message} =
             PreKeyWhisperMessage.decode(<<0x22, 0, 0, 0>>)
  end

  test "decode rejects empty binary" do
    assert {:error, :invalid_pre_key_whisper_message} = PreKeyWhisperMessage.decode(<<>>)
  end

  test "large registration_id and key_id values roundtrip" do
    {:ok, msg} =
      PreKeyWhisperMessage.new(
        registration_id: 2_147_483_647,
        pre_key_id: 65_535,
        signed_pre_key_id: 65_535,
        base_key: @base_key,
        identity_key: @identity_key,
        message: @inner_message
      )

    {:ok, decoded} = PreKeyWhisperMessage.decode(msg.serialized)
    assert decoded.registration_id == 2_147_483_647
    assert decoded.pre_key_id == 65_535
    assert decoded.signed_pre_key_id == 65_535
  end

  test "version_byte returns 0x33" do
    assert PreKeyWhisperMessage.version_byte() == 0x33
  end
end
