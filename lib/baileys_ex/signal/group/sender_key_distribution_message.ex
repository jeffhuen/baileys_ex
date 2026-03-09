defmodule BaileysEx.Signal.Group.SenderKeyDistributionMessage do
  @moduledoc false

  import Bitwise

  alias BaileysEx.Protocol.Proto.Wire

  @current_version 3
  @version_byte @current_version <<< 4 ||| @current_version

  @type t :: %__MODULE__{
          id: non_neg_integer(),
          iteration: non_neg_integer(),
          chain_key: binary(),
          signing_key: binary()
        }

  @enforce_keys [:id, :iteration, :chain_key, :signing_key]
  defstruct [:id, :iteration, :chain_key, :signing_key]

  @spec new(non_neg_integer(), non_neg_integer(), binary(), binary()) :: t()
  def new(id, iteration, chain_key, signing_key) do
    %__MODULE__{id: id, iteration: iteration, chain_key: chain_key, signing_key: signing_key}
  end

  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = message) do
    payload =
      Wire.encode_uint(1, message.id) <>
        Wire.encode_uint(2, message.iteration) <>
        Wire.encode_bytes(3, message.chain_key) <>
        Wire.encode_bytes(4, message.signing_key)

    <<@version_byte>> <> payload
  end

  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(<<version, payload::binary>>) when version == @version_byte do
    decode_fields(payload, %__MODULE__{id: 0, iteration: 0, chain_key: <<>>, signing_key: <<>>})
  end

  def decode(_binary), do: {:error, :invalid_sender_key_distribution_message}

  defp decode_fields(<<>>, %__MODULE__{} = message), do: {:ok, message}

  defp decode_fields(binary, %__MODULE__{} = message) do
    case Wire.decode_key(binary) do
      {:ok, field, wire_type, rest} -> decode_field(field, wire_type, rest, message)
      {:error, _} = error -> error
    end
  end

  defp decode_field(1, 0, rest, message),
    do: Wire.continue_varint(rest, message, &Map.put(&1, :id, &2), &decode_fields/2)

  defp decode_field(2, 0, rest, message),
    do: Wire.continue_varint(rest, message, &Map.put(&1, :iteration, &2), &decode_fields/2)

  defp decode_field(3, 2, rest, message),
    do: Wire.continue_bytes(rest, message, &Map.put(&1, :chain_key, &2), &decode_fields/2)

  defp decode_field(4, 2, rest, message),
    do: Wire.continue_bytes(rest, message, &Map.put(&1, :signing_key, &2), &decode_fields/2)

  defp decode_field(_field, wire_type, rest, message),
    do: Wire.skip_and_continue(wire_type, rest, message, &decode_fields/2)
end
