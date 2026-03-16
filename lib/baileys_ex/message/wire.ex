defmodule BaileysEx.Message.Wire do
  @moduledoc """
  Wire helpers for padded WAProto message payloads and Baileys-style message IDs.
  """

  alias BaileysEx.Protocol.JID, as: JIDUtil
  alias BaileysEx.Protocol.Proto.Message

  @type proto_message :: struct()

  @doc """
  Serializes and adds random WhatsApp XMPP padding to a WAProto message.
  """
  @spec encode(proto_message(), keyword()) :: binary()
  def encode(%Message{} = message, opts \\ []) do
    message
    |> Message.encode()
    |> write_random_pad_max16(opts)
  end

  @doc """
  Unpads and deserializes a WAProto message from binary.
  """
  @spec decode(binary()) :: {:ok, proto_message()} | {:error, term()}
  def decode(binary) when is_binary(binary) do
    case unpad_random_max16(binary) do
      {:ok, unpadded} ->
        case Message.decode(unpadded) do
          {:ok, %Message{} = message} -> {:ok, message}
          {:error, _reason} -> Message.decode(binary)
        end

      {:error, :invalid_padding} ->
        Message.decode(binary)
    end
  end

  @doc """
  Generates a 3EB0... random message ID that WhatsApp Web typically uses.
  """
  @spec generate_message_id(String.t() | nil, keyword()) :: String.t()
  def generate_message_id(user_id \\ nil, opts \\ []) do
    buffer = :binary.copy(<<0>>, 44)
    timestamp = Keyword.get_lazy(opts, :timestamp, fn -> System.system_time(:second) end)
    buffer = <<timestamp::unsigned-big-64, binary_part(buffer, 8, 36)::binary>>

    buffer = maybe_seed_user_id(buffer, user_id)

    random = Keyword.get_lazy(opts, :random_bytes, fn -> :crypto.strong_rand_bytes(16) end)
    buffer = binary_part(buffer, 0, 28) <> random

    hash =
      :sha256
      |> :crypto.hash(buffer)
      |> Base.encode16(case: :upper)

    "3EB0" <> binary_part(hash, 0, 18)
  end

  defp maybe_seed_user_id(buffer, user_id) do
    case JIDUtil.parse(user_id) do
      %BaileysEx.JID{user: user} when is_binary(user) ->
        id = user <> "@c.us"

        if byte_size(id) <= 20 do
          prefix = binary_part(buffer, 0, 8)
          suffix = binary_part(buffer, 8 + byte_size(id), 36 - byte_size(id))
          <<prefix::binary, id::binary, suffix::binary>>
        else
          buffer
        end

      _ ->
        buffer
    end
  end

  @doc """
  Produces the device participant hash indicating which E2E key copies were distributed.
  """
  @spec generate_participant_hash([String.t()]) :: String.t()
  def generate_participant_hash(participants) when is_list(participants) do
    hash =
      participants
      |> Enum.sort()
      |> Enum.join("")
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode64(padding: false)

    "2:" <> binary_part(hash, 0, 6)
  end

  @doc """
  Pads a binary buffer dynamically using deterministic/cryptographic randomness.
  """
  @spec write_random_pad_max16(binary(), keyword()) :: binary()
  def write_random_pad_max16(binary, opts \\ []) when is_binary(binary) do
    random =
      case Keyword.get(opts, :random_byte) do
        nil ->
          <<random>> = :crypto.strong_rand_bytes(1)
          random

        value when is_integer(value) and value >= 0 and value <= 255 ->
          value

        <<value>> ->
          value
      end

    pad_length = Bitwise.band(random, 0x0F) + 1
    binary <> :binary.copy(<<pad_length>>, pad_length)
  end

  @doc """
  Strips WAProto padding block, returning only the underlying protobuf.
  """
  @spec unpad_random_max16(binary()) :: {:ok, binary()} | {:error, term()}
  def unpad_random_max16(<<>>), do: {:error, :invalid_padding}

  def unpad_random_max16(binary) when is_binary(binary) do
    pad_length = :binary.last(binary)
    size = byte_size(binary)

    if pad_length == 0 or pad_length > size do
      {:error, :invalid_padding}
    else
      {:ok, binary_part(binary, 0, size - pad_length)}
    end
  end
end
