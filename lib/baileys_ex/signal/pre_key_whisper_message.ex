defmodule BaileysEx.Signal.PreKeyWhisperMessage do
  @moduledoc false

  import Bitwise

  alias BaileysEx.Protocol.Proto.Wire

  @current_version 3
  @version_byte @current_version <<< 4 ||| @current_version

  @type t :: %__MODULE__{
          registration_id: non_neg_integer(),
          pre_key_id: non_neg_integer() | nil,
          signed_pre_key_id: non_neg_integer(),
          base_key: binary(),
          identity_key: binary(),
          message: binary(),
          serialized: binary()
        }

  @enforce_keys [
    :registration_id,
    :signed_pre_key_id,
    :base_key,
    :identity_key,
    :message,
    :serialized
  ]
  defstruct [
    :registration_id,
    :pre_key_id,
    :signed_pre_key_id,
    :base_key,
    :identity_key,
    :message,
    :serialized
  ]

  @spec new(keyword()) :: {:ok, t()}
  def new(opts) do
    registration_id = Keyword.fetch!(opts, :registration_id)
    pre_key_id = Keyword.get(opts, :pre_key_id)
    signed_pre_key_id = Keyword.fetch!(opts, :signed_pre_key_id)
    base_key = Keyword.fetch!(opts, :base_key)
    identity_key = Keyword.fetch!(opts, :identity_key)
    message = Keyword.fetch!(opts, :message)

    payload =
      encode_optional_uint(1, pre_key_id) <>
        Wire.encode_bytes(2, base_key) <>
        Wire.encode_bytes(3, identity_key) <>
        Wire.encode_bytes(4, message) <>
        Wire.encode_uint(5, registration_id) <>
        Wire.encode_uint(6, signed_pre_key_id)

    serialized = <<@version_byte>> <> payload

    {:ok,
     %__MODULE__{
       registration_id: registration_id,
       pre_key_id: pre_key_id,
       signed_pre_key_id: signed_pre_key_id,
       base_key: base_key,
       identity_key: identity_key,
       message: message,
       serialized: serialized
     }}
  end

  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(<<@version_byte, payload::binary>>) do
    with {:ok, decoded} <-
           decode_fields(payload, %{
             registration_id: 0,
             pre_key_id: nil,
             signed_pre_key_id: 0,
             base_key: <<>>,
             identity_key: <<>>,
             message: <<>>
           }) do
      {:ok,
       %__MODULE__{
         registration_id: decoded.registration_id,
         pre_key_id: decoded.pre_key_id,
         signed_pre_key_id: decoded.signed_pre_key_id,
         base_key: decoded.base_key,
         identity_key: decoded.identity_key,
         message: decoded.message,
         serialized: <<@version_byte>> <> payload
       }}
    end
  end

  def decode(_binary), do: {:error, :invalid_pre_key_whisper_message}

  @spec serialize(t()) :: binary()
  def serialize(%__MODULE__{serialized: serialized}), do: serialized

  @spec version_byte() :: byte()
  def version_byte, do: @version_byte

  defp encode_optional_uint(_field_number, nil), do: <<>>
  defp encode_optional_uint(field_number, value), do: Wire.encode_uint(field_number, value)

  defp decode_fields(<<>>, state), do: {:ok, state}

  defp decode_fields(binary, state) do
    case Wire.decode_key(binary) do
      {:ok, field, wire_type, rest} -> decode_field(field, wire_type, rest, state)
      {:error, _} = error -> error
    end
  end

  # preKeyId (field 1)
  defp decode_field(1, 0, rest, state),
    do: Wire.continue_varint(rest, state, &Map.put(&1, :pre_key_id, &2), &decode_fields/2)

  # baseKey (field 2)
  defp decode_field(2, 2, rest, state),
    do: Wire.continue_bytes(rest, state, &Map.put(&1, :base_key, &2), &decode_fields/2)

  # identityKey (field 3)
  defp decode_field(3, 2, rest, state),
    do: Wire.continue_bytes(rest, state, &Map.put(&1, :identity_key, &2), &decode_fields/2)

  # message (field 4) — embedded WhisperMessage bytes
  defp decode_field(4, 2, rest, state),
    do: Wire.continue_bytes(rest, state, &Map.put(&1, :message, &2), &decode_fields/2)

  # registrationId (field 5)
  defp decode_field(5, 0, rest, state),
    do: Wire.continue_varint(rest, state, &Map.put(&1, :registration_id, &2), &decode_fields/2)

  # signedPreKeyId (field 6)
  defp decode_field(6, 0, rest, state),
    do: Wire.continue_varint(rest, state, &Map.put(&1, :signed_pre_key_id, &2), &decode_fields/2)

  defp decode_field(_field, wire_type, rest, state),
    do: Wire.skip_and_continue(wire_type, rest, state, &decode_fields/2)
end
