defmodule BaileysEx.Protocol.Proto.ADVEncryptionType do
  @moduledoc false

  @e2ee 0
  @hosted 1

  @spec e2ee() :: 0
  def e2ee, do: @e2ee

  @spec hosted() :: 1
  def hosted, do: @hosted
end

defmodule BaileysEx.Protocol.Proto.ADVDeviceIdentity do
  @moduledoc false

  alias BaileysEx.Protocol.Proto.Wire

  defstruct raw_id: nil,
            timestamp: nil,
            key_index: nil,
            account_type: nil,
            device_type: nil

  @type t :: %__MODULE__{
          raw_id: non_neg_integer() | nil,
          timestamp: non_neg_integer() | nil,
          key_index: non_neg_integer() | nil,
          account_type: non_neg_integer() | nil,
          device_type: non_neg_integer() | nil
        }

  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = identity) do
    Wire.encode_uint(1, identity.raw_id) <>
      Wire.encode_uint(2, identity.timestamp) <>
      Wire.encode_uint(3, identity.key_index) <>
      Wire.encode_uint(4, identity.account_type) <>
      Wire.encode_uint(5, identity.device_type)
  end

  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(binary), do: decode_fields(binary, %__MODULE__{})

  defp decode_fields(<<>>, identity), do: {:ok, identity}

  defp decode_fields(binary, identity) do
    case Wire.decode_key(binary) do
      {:ok, field, wire_type, rest} -> decode_field(field, wire_type, rest, identity)
      {:error, _} = error -> error
    end
  end

  defp decode_field(1, 0, rest, identity),
    do: Wire.continue_varint(rest, identity, &Map.put(&1, :raw_id, &2), &decode_fields/2)

  defp decode_field(2, 0, rest, identity),
    do: Wire.continue_varint(rest, identity, &Map.put(&1, :timestamp, &2), &decode_fields/2)

  defp decode_field(3, 0, rest, identity),
    do: Wire.continue_varint(rest, identity, &Map.put(&1, :key_index, &2), &decode_fields/2)

  defp decode_field(4, 0, rest, identity),
    do: Wire.continue_varint(rest, identity, &Map.put(&1, :account_type, &2), &decode_fields/2)

  defp decode_field(5, 0, rest, identity),
    do: Wire.continue_varint(rest, identity, &Map.put(&1, :device_type, &2), &decode_fields/2)

  defp decode_field(_field, wire_type, rest, identity),
    do: Wire.skip_and_continue(wire_type, rest, identity, &decode_fields/2)
end

defmodule BaileysEx.Protocol.Proto.ADVSignedDeviceIdentity do
  @moduledoc false

  alias BaileysEx.Protocol.Proto.Wire

  defstruct details: nil,
            account_signature_key: nil,
            account_signature: nil,
            device_signature: nil

  @type t :: %__MODULE__{
          details: binary() | nil,
          account_signature_key: binary() | nil,
          account_signature: binary() | nil,
          device_signature: binary() | nil
        }

  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = identity) do
    Wire.encode_bytes(1, identity.details) <>
      Wire.encode_bytes(2, identity.account_signature_key) <>
      Wire.encode_bytes(3, identity.account_signature) <>
      Wire.encode_bytes(4, identity.device_signature)
  end

  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(binary), do: decode_fields(binary, %__MODULE__{})

  defp decode_fields(<<>>, identity), do: {:ok, identity}

  defp decode_fields(binary, identity) do
    case Wire.decode_key(binary) do
      {:ok, field, wire_type, rest} -> decode_field(field, wire_type, rest, identity)
      {:error, _} = error -> error
    end
  end

  defp decode_field(1, 2, rest, identity),
    do: Wire.continue_bytes(rest, identity, &Map.put(&1, :details, &2), &decode_fields/2)

  defp decode_field(2, 2, rest, identity),
    do:
      Wire.continue_bytes(
        rest,
        identity,
        &Map.put(&1, :account_signature_key, &2),
        &decode_fields/2
      )

  defp decode_field(3, 2, rest, identity),
    do:
      Wire.continue_bytes(rest, identity, &Map.put(&1, :account_signature, &2), &decode_fields/2)

  defp decode_field(4, 2, rest, identity),
    do: Wire.continue_bytes(rest, identity, &Map.put(&1, :device_signature, &2), &decode_fields/2)

  defp decode_field(_field, wire_type, rest, identity),
    do: Wire.skip_and_continue(wire_type, rest, identity, &decode_fields/2)
end

defmodule BaileysEx.Protocol.Proto.ADVSignedDeviceIdentityHMAC do
  @moduledoc false

  alias BaileysEx.Protocol.Proto.Wire

  defstruct details: nil, hmac: nil, account_type: nil

  @type t :: %__MODULE__{
          details: binary() | nil,
          hmac: binary() | nil,
          account_type: non_neg_integer() | nil
        }

  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = identity) do
    Wire.encode_bytes(1, identity.details) <>
      Wire.encode_bytes(2, identity.hmac) <>
      Wire.encode_uint(3, identity.account_type)
  end

  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(binary), do: decode_fields(binary, %__MODULE__{})

  defp decode_fields(<<>>, identity), do: {:ok, identity}

  defp decode_fields(binary, identity) do
    case Wire.decode_key(binary) do
      {:ok, field, wire_type, rest} -> decode_field(field, wire_type, rest, identity)
      {:error, _} = error -> error
    end
  end

  defp decode_field(1, 2, rest, identity),
    do: Wire.continue_bytes(rest, identity, &Map.put(&1, :details, &2), &decode_fields/2)

  defp decode_field(2, 2, rest, identity),
    do: Wire.continue_bytes(rest, identity, &Map.put(&1, :hmac, &2), &decode_fields/2)

  defp decode_field(3, 0, rest, identity),
    do: Wire.continue_varint(rest, identity, &Map.put(&1, :account_type, &2), &decode_fields/2)

  defp decode_field(_field, wire_type, rest, identity),
    do: Wire.skip_and_continue(wire_type, rest, identity, &decode_fields/2)
end
