defmodule BaileysEx.Signal.WhisperMessage do
  @moduledoc false

  import Bitwise

  alias BaileysEx.Crypto
  alias BaileysEx.Protocol.Proto.Wire

  @current_version 3
  @version_byte @current_version <<< 4 ||| @current_version
  @mac_length 8

  @type t :: %__MODULE__{
          ratchet_key: binary(),
          counter: non_neg_integer(),
          previous_counter: non_neg_integer(),
          ciphertext: binary(),
          serialized: binary()
        }

  @enforce_keys [:ratchet_key, :counter, :previous_counter, :ciphertext, :serialized]
  defstruct [:ratchet_key, :counter, :previous_counter, :ciphertext, :serialized]

  @spec new(binary(), non_neg_integer(), non_neg_integer(), binary(), binary(), binary()) ::
          {:ok, t()}
  def new(ratchet_key, counter, previous_counter, ciphertext, sender_identity, receiver_identity) do
    payload =
      Wire.encode_bytes(1, ratchet_key) <>
        Wire.encode_uint(2, counter) <>
        Wire.encode_uint(3, previous_counter) <>
        Wire.encode_bytes(4, ciphertext)

    message = <<@version_byte>> <> payload
    mac = compute_mac(sender_identity, receiver_identity, message)

    {:ok,
     %__MODULE__{
       ratchet_key: ratchet_key,
       counter: counter,
       previous_counter: previous_counter,
       ciphertext: ciphertext,
       serialized: message <> mac
     }}
  end

  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(binary) when byte_size(binary) > @mac_length do
    message_size = byte_size(binary) - @mac_length
    <<message::binary-size(message_size), _mac::binary-size(@mac_length)>> = binary

    case message do
      <<@version_byte, payload::binary>> ->
        with {:ok, decoded} <-
               decode_fields(payload, %{
                 ratchet_key: <<>>,
                 counter: 0,
                 previous_counter: 0,
                 ciphertext: <<>>
               }) do
          {:ok,
           %__MODULE__{
             ratchet_key: decoded.ratchet_key,
             counter: decoded.counter,
             previous_counter: decoded.previous_counter,
             ciphertext: decoded.ciphertext,
             serialized: binary
           }}
        end

      _ ->
        {:error, :invalid_whisper_message}
    end
  end

  def decode(_binary), do: {:error, :invalid_whisper_message}

  @spec verify_mac(t(), binary(), binary(), binary()) :: boolean()
  def verify_mac(%__MODULE__{serialized: serialized}, mac_key, sender_identity, receiver_identity) do
    message_size = byte_size(serialized) - @mac_length
    <<message::binary-size(message_size), mac::binary-size(@mac_length)>> = serialized
    expected_mac = compute_mac(mac_key, sender_identity, receiver_identity, message)
    mac == expected_mac
  end

  @spec verify_mac_with_key(t(), binary(), binary(), binary()) :: boolean()
  def verify_mac_with_key(
        %__MODULE__{serialized: serialized},
        mac_key,
        sender_identity,
        receiver_identity
      ) do
    message_size = byte_size(serialized) - @mac_length
    <<message::binary-size(message_size), mac::binary-size(@mac_length)>> = serialized
    expected_mac = compute_mac(mac_key, sender_identity, receiver_identity, message)
    mac == expected_mac
  end

  @spec serialize(t()) :: binary()
  def serialize(%__MODULE__{serialized: serialized}), do: serialized

  @spec version_byte() :: byte()
  def version_byte, do: @version_byte

  @spec mac_length() :: non_neg_integer()
  def mac_length, do: @mac_length

  defp compute_mac(sender_identity, receiver_identity, message) do
    compute_mac(nil, sender_identity, receiver_identity, message)
  end

  defp compute_mac(mac_key, sender_identity, receiver_identity, message) do
    # MAC input: sender_identity(33) || receiver_identity(33) || version_byte+protobuf
    # MAC key is derived from message keys; for initial creation we use HMAC of the
    # identity keys concatenation as per Signal spec
    key = mac_key || Crypto.hmac_sha256(sender_identity, receiver_identity)

    full_mac = Crypto.hmac_sha256(key, sender_identity <> receiver_identity <> message)
    binary_part(full_mac, 0, @mac_length)
  end

  defp decode_fields(<<>>, state), do: {:ok, state}

  defp decode_fields(binary, state) do
    case Wire.decode_key(binary) do
      {:ok, field, wire_type, rest} -> decode_field(field, wire_type, rest, state)
      {:error, _} = error -> error
    end
  end

  defp decode_field(1, 2, rest, state),
    do: Wire.continue_bytes(rest, state, &Map.put(&1, :ratchet_key, &2), &decode_fields/2)

  defp decode_field(2, 0, rest, state),
    do: Wire.continue_varint(rest, state, &Map.put(&1, :counter, &2), &decode_fields/2)

  defp decode_field(3, 0, rest, state),
    do: Wire.continue_varint(rest, state, &Map.put(&1, :previous_counter, &2), &decode_fields/2)

  defp decode_field(4, 2, rest, state),
    do: Wire.continue_bytes(rest, state, &Map.put(&1, :ciphertext, &2), &decode_fields/2)

  defp decode_field(_field, wire_type, rest, state),
    do: Wire.skip_and_continue(wire_type, rest, state, &decode_fields/2)
end
