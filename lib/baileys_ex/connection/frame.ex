defmodule BaileysEx.Connection.Frame do
  @moduledoc """
  Pure helpers for WhatsApp's 3-byte length-prefixed transport frames.
  """

  @max_payload_size 16_777_215

  @type encode_error :: :frame_too_large

  @spec encode(binary()) :: {:ok, binary()} | {:error, encode_error()}
  def encode(payload) when is_binary(payload) do
    payload_size = byte_size(payload)

    if payload_size <= @max_payload_size do
      {:ok, <<payload_size::unsigned-big-integer-size(24), payload::binary>>}
    else
      {:error, :frame_too_large}
    end
  end

  @spec decode_stream(binary()) :: {[binary()], binary()}
  def decode_stream(buffer) when is_binary(buffer), do: decode_stream(buffer, [])

  defp decode_stream(<<payload_size::unsigned-big-integer-size(24), rest::binary>>, frames)
       when byte_size(rest) >= payload_size do
    <<payload::binary-size(payload_size), tail::binary>> = rest
    decode_stream(tail, [payload | frames])
  end

  defp decode_stream(buffer, frames), do: {Enum.reverse(frames), buffer}
end
