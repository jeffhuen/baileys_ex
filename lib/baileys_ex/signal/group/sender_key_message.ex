defmodule BaileysEx.Signal.Group.SenderKeyMessage do
  @moduledoc false

  import Bitwise

  alias BaileysEx.Protocol.Proto.Wire
  alias BaileysEx.Signal.Curve

  @current_version 3
  @version_byte @current_version <<< 4 ||| @current_version
  @signature_length 64

  @type t :: %__MODULE__{
          id: non_neg_integer(),
          iteration: non_neg_integer(),
          ciphertext: binary(),
          signature: binary(),
          serialized: binary()
        }

  @enforce_keys [:id, :iteration, :ciphertext, :signature, :serialized]
  defstruct [:id, :iteration, :ciphertext, :signature, :serialized]

  @spec new(non_neg_integer(), non_neg_integer(), binary(), binary()) ::
          {:ok, t()} | {:error, term()}
  def new(id, iteration, ciphertext, signature_key) do
    payload =
      Wire.encode_uint(1, id) <>
        Wire.encode_uint(2, iteration) <>
        Wire.encode_bytes(3, ciphertext)

    message = <<@version_byte>> <> payload

    with {:ok, signature} <- Curve.sign(signature_key, message) do
      {:ok,
       %__MODULE__{
         id: id,
         iteration: iteration,
         ciphertext: ciphertext,
         signature: signature,
         serialized: message <> signature
       }}
    end
  end

  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(binary) when byte_size(binary) > @signature_length do
    message_size = byte_size(binary) - @signature_length
    <<message::binary-size(message_size), signature::binary-size(@signature_length)>> = binary

    case message do
      <<@version_byte, payload::binary>> ->
        with {:ok, decoded} <- decode_fields(payload, %{id: 0, iteration: 0, ciphertext: <<>>}) do
          {:ok,
           %__MODULE__{
             id: decoded.id,
             iteration: decoded.iteration,
             ciphertext: decoded.ciphertext,
             signature: signature,
             serialized: binary
           }}
        end

      _ ->
        {:error, :invalid_sender_key_message}
    end
  end

  def decode(_binary), do: {:error, :invalid_sender_key_message}

  @spec verify_signature(t(), binary()) :: boolean()
  def verify_signature(%__MODULE__{serialized: serialized, signature: signature}, public_key) do
    message_size = byte_size(serialized) - byte_size(signature)
    <<message::binary-size(message_size), _::binary>> = serialized
    Curve.verify(public_key, message, signature)
  end

  @spec serialize(t()) :: binary()
  def serialize(%__MODULE__{serialized: serialized}), do: serialized

  defp decode_fields(<<>>, state), do: {:ok, state}

  defp decode_fields(binary, state) do
    case Wire.decode_key(binary) do
      {:ok, field, wire_type, rest} -> decode_field(field, wire_type, rest, state)
      {:error, _} = error -> error
    end
  end

  defp decode_field(1, 0, rest, state),
    do: Wire.continue_varint(rest, state, &Map.put(&1, :id, &2), &decode_fields/2)

  defp decode_field(2, 0, rest, state),
    do: Wire.continue_varint(rest, state, &Map.put(&1, :iteration, &2), &decode_fields/2)

  defp decode_field(3, 2, rest, state),
    do: Wire.continue_bytes(rest, state, &Map.put(&1, :ciphertext, &2), &decode_fields/2)

  defp decode_field(_field, wire_type, rest, state),
    do: Wire.skip_and_continue(wire_type, rest, state, &decode_fields/2)
end
