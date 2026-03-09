defmodule BaileysEx.Connection.FrameTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Connection.Frame

  test "encode/1 prefixes a payload with its 3-byte big-endian length" do
    assert {:ok, <<0, 0, 5, "hello">>} = Frame.encode("hello")
  end

  test "encode/1 rejects payloads larger than the 24-bit frame limit" do
    oversized_payload = :binary.copy(<<0>>, 16_777_216)

    assert {:error, :frame_too_large} = Frame.encode(oversized_payload)
  end

  test "decode_stream/1 extracts complete frames and preserves an incomplete tail" do
    assert {:ok, encoded_one} = Frame.encode("one")
    assert {:ok, encoded_two} = Frame.encode("two")
    assert {:ok, encoded_three} = Frame.encode("three")

    partial_three = binary_part(encoded_three, 0, byte_size(encoded_three) - 2)

    assert {["one", "two"], ^partial_three} =
             Frame.decode_stream(encoded_one <> encoded_two <> partial_three)
  end

  test "decode_stream/1 returns all complete payloads when the buffer is exact" do
    assert {:ok, encoded_one} = Frame.encode("alpha")
    assert {:ok, encoded_two} = Frame.encode("beta")

    assert {["alpha", "beta"], <<>>} = Frame.decode_stream(encoded_one <> encoded_two)
  end
end
