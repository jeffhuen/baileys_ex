defmodule BaileysEx.Protocol.Proto.Wire do
  @moduledoc false

  import Bitwise

  @wire_varint 0
  @wire_64bit 1
  @wire_bytes 2
  @wire_32bit 5

  def encode_varint(int) when is_integer(int) and int >= 0 do
    do_encode_varint(int, <<>>)
  end

  defp do_encode_varint(int, acc) when int < 0x80, do: acc <> <<int>>

  defp do_encode_varint(int, acc),
    do: do_encode_varint(int >>> 7, acc <> <<(int &&& 0x7F) ||| 0x80>>)

  def decode_varint(binary), do: do_decode_varint(binary, 0, 0)

  defp do_decode_varint(<<>>, _shift, _acc), do: {:error, :unexpected_eof}

  defp do_decode_varint(<<byte, rest::binary>>, shift, acc) do
    value = acc ||| (byte &&& 0x7F) <<< shift

    if (byte &&& 0x80) == 0 do
      {:ok, value, rest}
    else
      do_decode_varint(rest, shift + 7, value)
    end
  end

  def encode_key(field_number, wire_type), do: encode_varint(field_number <<< 3 ||| wire_type)

  def encode_bytes(_field_number, nil), do: <<>>

  def encode_bytes(field_number, value) when is_binary(value) do
    encode_key(field_number, @wire_bytes) <> encode_varint(byte_size(value)) <> value
  end

  def encode_bool(_field_number, nil), do: <<>>

  def encode_bool(field_number, value) when is_boolean(value),
    do:
      encode_varint(field_number <<< 3 ||| @wire_varint) <>
        encode_varint(if(value, do: 1, else: 0))

  def encode_uint(_field_number, nil), do: <<>>

  def encode_uint(field_number, value) when is_integer(value) and value >= 0,
    do: encode_varint(field_number <<< 3 ||| @wire_varint) <> encode_varint(value)

  def encode_fixed32(_field_number, nil), do: <<>>

  def encode_fixed32(field_number, value) when is_integer(value) and value >= 0,
    do: encode_key(field_number, @wire_32bit) <> <<value::unsigned-little-32>>

  def encode_float(_field_number, nil), do: <<>>

  def encode_float(field_number, value) when is_number(value),
    do: encode_key(field_number, @wire_32bit) <> <<value::float-little-32>>

  def encode_double(_field_number, nil), do: <<>>

  def encode_double(field_number, value) when is_number(value),
    do: encode_key(field_number, @wire_64bit) <> <<value::float-little-64>>

  def decode_key(binary) do
    with {:ok, key, rest} <- decode_varint(binary) do
      {:ok, key >>> 3, key &&& 0x07, rest}
    end
  end

  def decode_bytes(binary) do
    with {:ok, length, rest} <- decode_varint(binary),
         true <- byte_size(rest) >= length do
      <<value::binary-size(length), tail::binary>> = rest
      {:ok, value, tail}
    else
      false -> {:error, :unexpected_eof}
      {:error, _} = error -> error
    end
  end

  def decode_fixed32(<<value::unsigned-little-32, rest::binary>>), do: {:ok, value, rest}
  def decode_fixed32(_binary), do: {:error, :unexpected_eof}

  def decode_float(<<value::float-little-32, rest::binary>>), do: {:ok, value, rest}
  def decode_float(_binary), do: {:error, :unexpected_eof}

  def decode_double(<<value::float-little-64, rest::binary>>), do: {:ok, value, rest}
  def decode_double(_binary), do: {:error, :unexpected_eof}

  def skip_field(@wire_varint, binary) do
    with {:ok, _value, rest} <- decode_varint(binary), do: {:ok, rest}
  end

  def skip_field(@wire_bytes, binary) do
    with {:ok, _value, rest} <- decode_bytes(binary), do: {:ok, rest}
  end

  def skip_field(@wire_64bit, <<_value::binary-size(8), rest::binary>>), do: {:ok, rest}
  def skip_field(@wire_64bit, _binary), do: {:error, :unexpected_eof}

  def skip_field(@wire_32bit, <<_value::binary-size(4), rest::binary>>), do: {:ok, rest}
  def skip_field(@wire_32bit, _binary), do: {:error, :unexpected_eof}

  def skip_field(_, _binary), do: {:error, :unsupported_wire_type}

  def continue_varint(binary, state, updater, cont) do
    with {:ok, value, rest} <- decode_varint(binary) do
      cont.(rest, updater.(state, value))
    end
  end

  def continue_bytes(binary, state, updater, cont) do
    with {:ok, value, rest} <- decode_bytes(binary) do
      cont.(rest, updater.(state, value))
    end
  end

  def continue_fixed32(binary, state, updater, cont) do
    with {:ok, value, rest} <- decode_fixed32(binary) do
      cont.(rest, updater.(state, value))
    end
  end

  def continue_float(binary, state, updater, cont) do
    with {:ok, value, rest} <- decode_float(binary) do
      cont.(rest, updater.(state, value))
    end
  end

  def continue_double(binary, state, updater, cont) do
    with {:ok, value, rest} <- decode_double(binary) do
      cont.(rest, updater.(state, value))
    end
  end

  def continue_nested_bytes(binary, state, decoder, updater, cont) do
    with {:ok, value, rest} <- decode_bytes(binary),
         {:ok, decoded} <- decoder.(value) do
      cont.(rest, updater.(state, decoded))
    end
  end

  def skip_and_continue(wire_type, binary, state, cont) do
    with {:ok, rest} <- skip_field(wire_type, binary) do
      cont.(rest, state)
    end
  end
end

defmodule BaileysEx.Protocol.Proto.CertChain.NoiseCertificate.Details do
  @moduledoc false

  alias BaileysEx.Protocol.Proto.Wire

  defstruct serial: nil, issuer_serial: nil, key: nil, not_before: nil, not_after: nil

  @type t :: %__MODULE__{
          serial: non_neg_integer() | nil,
          issuer_serial: non_neg_integer() | nil,
          key: binary() | nil,
          not_before: non_neg_integer() | nil,
          not_after: non_neg_integer() | nil
        }

  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = details) do
    Wire.encode_uint(1, details.serial) <>
      Wire.encode_uint(2, details.issuer_serial) <>
      Wire.encode_bytes(3, details.key) <>
      Wire.encode_uint(4, details.not_before) <>
      Wire.encode_uint(5, details.not_after)
  end

  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(binary), do: decode_fields(binary, %__MODULE__{})

  defp decode_fields(<<>>, details), do: {:ok, details}

  defp decode_fields(binary, details) do
    case Wire.decode_key(binary) do
      {:ok, field, wire_type, rest} -> decode_field(field, wire_type, rest, details)
      {:error, _} = error -> error
    end
  end

  defp decode_field(1, 0, rest, details),
    do: Wire.continue_varint(rest, details, &Map.put(&1, :serial, &2), &decode_fields/2)

  defp decode_field(2, 0, rest, details),
    do: Wire.continue_varint(rest, details, &Map.put(&1, :issuer_serial, &2), &decode_fields/2)

  defp decode_field(3, 2, rest, details),
    do: Wire.continue_bytes(rest, details, &Map.put(&1, :key, &2), &decode_fields/2)

  defp decode_field(4, 0, rest, details),
    do: Wire.continue_varint(rest, details, &Map.put(&1, :not_before, &2), &decode_fields/2)

  defp decode_field(5, 0, rest, details),
    do: Wire.continue_varint(rest, details, &Map.put(&1, :not_after, &2), &decode_fields/2)

  defp decode_field(_field, wire_type, rest, details),
    do: Wire.skip_and_continue(wire_type, rest, details, &decode_fields/2)
end

defmodule BaileysEx.Protocol.Proto.CertChain.NoiseCertificate do
  @moduledoc false

  alias BaileysEx.Protocol.Proto.Wire

  defstruct details: nil, signature: nil

  @type t :: %__MODULE__{details: binary() | nil, signature: binary() | nil}

  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = cert) do
    Wire.encode_bytes(1, cert.details) <> Wire.encode_bytes(2, cert.signature)
  end

  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(binary), do: decode_fields(binary, %__MODULE__{})

  defp decode_fields(<<>>, cert), do: {:ok, cert}

  defp decode_fields(binary, cert) do
    case Wire.decode_key(binary) do
      {:ok, field, wire_type, rest} -> decode_field(field, wire_type, rest, cert)
      {:error, _} = error -> error
    end
  end

  defp decode_field(1, 2, rest, cert),
    do: Wire.continue_bytes(rest, cert, &Map.put(&1, :details, &2), &decode_fields/2)

  defp decode_field(2, 2, rest, cert),
    do: Wire.continue_bytes(rest, cert, &Map.put(&1, :signature, &2), &decode_fields/2)

  defp decode_field(_field, wire_type, rest, cert),
    do: Wire.skip_and_continue(wire_type, rest, cert, &decode_fields/2)
end

defmodule BaileysEx.Protocol.Proto.CertChain do
  @moduledoc false

  alias BaileysEx.Protocol.Proto.CertChain.NoiseCertificate
  alias BaileysEx.Protocol.Proto.Wire

  defstruct leaf: nil, intermediate: nil

  @type t :: %__MODULE__{
          leaf: NoiseCertificate.t() | nil,
          intermediate: NoiseCertificate.t() | nil
        }

  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = chain) do
    leaf = if chain.leaf, do: NoiseCertificate.encode(chain.leaf)
    intermediate = if chain.intermediate, do: NoiseCertificate.encode(chain.intermediate)

    Wire.encode_bytes(1, leaf) <> Wire.encode_bytes(2, intermediate)
  end

  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(binary), do: decode_fields(binary, %__MODULE__{})

  defp decode_fields(<<>>, chain), do: {:ok, chain}

  defp decode_fields(binary, chain) do
    case Wire.decode_key(binary) do
      {:ok, field, wire_type, rest} -> decode_field(field, wire_type, rest, chain)
      {:error, _} = error -> error
    end
  end

  defp decode_field(1, 2, rest, chain) do
    Wire.continue_nested_bytes(
      rest,
      chain,
      &NoiseCertificate.decode/1,
      &Map.put(&1, :leaf, &2),
      &decode_fields/2
    )
  end

  defp decode_field(2, 2, rest, chain) do
    Wire.continue_nested_bytes(
      rest,
      chain,
      &NoiseCertificate.decode/1,
      &Map.put(&1, :intermediate, &2),
      &decode_fields/2
    )
  end

  defp decode_field(_field, wire_type, rest, chain),
    do: Wire.skip_and_continue(wire_type, rest, chain, &decode_fields/2)
end

defmodule BaileysEx.Protocol.Proto.HandshakeMessage.ClientHello do
  @moduledoc false

  alias BaileysEx.Protocol.Proto.Wire

  defstruct ephemeral: nil, static: nil, payload: nil, use_extended: nil, extended_ciphertext: nil

  @type t :: %__MODULE__{
          ephemeral: binary() | nil,
          static: binary() | nil,
          payload: binary() | nil,
          use_extended: boolean() | nil,
          extended_ciphertext: binary() | nil
        }

  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = hello) do
    Wire.encode_bytes(1, hello.ephemeral) <>
      Wire.encode_bytes(2, hello.static) <>
      Wire.encode_bytes(3, hello.payload) <>
      Wire.encode_bool(4, hello.use_extended) <>
      Wire.encode_bytes(5, hello.extended_ciphertext)
  end

  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(binary), do: decode_fields(binary, %__MODULE__{})

  defp decode_fields(<<>>, hello), do: {:ok, hello}

  defp decode_fields(binary, hello) do
    case Wire.decode_key(binary) do
      {:ok, field, wire_type, rest} -> decode_field(field, wire_type, rest, hello)
      {:error, _} = error -> error
    end
  end

  defp decode_field(1, 2, rest, hello),
    do: Wire.continue_bytes(rest, hello, &Map.put(&1, :ephemeral, &2), &decode_fields/2)

  defp decode_field(2, 2, rest, hello),
    do: Wire.continue_bytes(rest, hello, &Map.put(&1, :static, &2), &decode_fields/2)

  defp decode_field(3, 2, rest, hello),
    do: Wire.continue_bytes(rest, hello, &Map.put(&1, :payload, &2), &decode_fields/2)

  defp decode_field(4, 0, rest, hello),
    do: Wire.continue_varint(rest, hello, &Map.put(&1, :use_extended, &2 != 0), &decode_fields/2)

  defp decode_field(5, 2, rest, hello),
    do: Wire.continue_bytes(rest, hello, &Map.put(&1, :extended_ciphertext, &2), &decode_fields/2)

  defp decode_field(_field, wire_type, rest, hello),
    do: Wire.skip_and_continue(wire_type, rest, hello, &decode_fields/2)
end

defmodule BaileysEx.Protocol.Proto.HandshakeMessage.ServerHello do
  @moduledoc false

  alias BaileysEx.Protocol.Proto.Wire

  defstruct ephemeral: nil, static: nil, payload: nil, extended_static: nil

  @type t :: %__MODULE__{
          ephemeral: binary() | nil,
          static: binary() | nil,
          payload: binary() | nil,
          extended_static: binary() | nil
        }

  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = hello) do
    Wire.encode_bytes(1, hello.ephemeral) <>
      Wire.encode_bytes(2, hello.static) <>
      Wire.encode_bytes(3, hello.payload) <>
      Wire.encode_bytes(4, hello.extended_static)
  end

  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(binary), do: decode_fields(binary, %__MODULE__{})

  defp decode_fields(<<>>, hello), do: {:ok, hello}

  defp decode_fields(binary, hello) do
    case Wire.decode_key(binary) do
      {:ok, field, wire_type, rest} -> decode_field(field, wire_type, rest, hello)
      {:error, _} = error -> error
    end
  end

  defp decode_field(1, 2, rest, hello),
    do: Wire.continue_bytes(rest, hello, &Map.put(&1, :ephemeral, &2), &decode_fields/2)

  defp decode_field(2, 2, rest, hello),
    do: Wire.continue_bytes(rest, hello, &Map.put(&1, :static, &2), &decode_fields/2)

  defp decode_field(3, 2, rest, hello),
    do: Wire.continue_bytes(rest, hello, &Map.put(&1, :payload, &2), &decode_fields/2)

  defp decode_field(4, 2, rest, hello),
    do: Wire.continue_bytes(rest, hello, &Map.put(&1, :extended_static, &2), &decode_fields/2)

  defp decode_field(_field, wire_type, rest, hello),
    do: Wire.skip_and_continue(wire_type, rest, hello, &decode_fields/2)
end

defmodule BaileysEx.Protocol.Proto.HandshakeMessage.ClientFinish do
  @moduledoc false

  alias BaileysEx.Protocol.Proto.Wire

  defstruct static: nil, payload: nil, extended_ciphertext: nil

  @type t :: %__MODULE__{
          static: binary() | nil,
          payload: binary() | nil,
          extended_ciphertext: binary() | nil
        }

  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = finish) do
    Wire.encode_bytes(1, finish.static) <>
      Wire.encode_bytes(2, finish.payload) <>
      Wire.encode_bytes(3, finish.extended_ciphertext)
  end

  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(binary), do: decode_fields(binary, %__MODULE__{})

  defp decode_fields(<<>>, finish), do: {:ok, finish}

  defp decode_fields(binary, finish) do
    case Wire.decode_key(binary) do
      {:ok, field, wire_type, rest} -> decode_field(field, wire_type, rest, finish)
      {:error, _} = error -> error
    end
  end

  defp decode_field(1, 2, rest, finish),
    do: Wire.continue_bytes(rest, finish, &Map.put(&1, :static, &2), &decode_fields/2)

  defp decode_field(2, 2, rest, finish),
    do: Wire.continue_bytes(rest, finish, &Map.put(&1, :payload, &2), &decode_fields/2)

  defp decode_field(3, 2, rest, finish),
    do:
      Wire.continue_bytes(rest, finish, &Map.put(&1, :extended_ciphertext, &2), &decode_fields/2)

  defp decode_field(_field, wire_type, rest, finish),
    do: Wire.skip_and_continue(wire_type, rest, finish, &decode_fields/2)
end

defmodule BaileysEx.Protocol.Proto.HandshakeMessage do
  @moduledoc false

  alias BaileysEx.Protocol.Proto.HandshakeMessage.ClientFinish
  alias BaileysEx.Protocol.Proto.HandshakeMessage.ClientHello
  alias BaileysEx.Protocol.Proto.HandshakeMessage.ServerHello
  alias BaileysEx.Protocol.Proto.Wire

  defstruct client_hello: nil, server_hello: nil, client_finish: nil

  @type t :: %__MODULE__{
          client_hello: ClientHello.t() | nil,
          server_hello: ServerHello.t() | nil,
          client_finish: ClientFinish.t() | nil
        }

  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = handshake) do
    client_hello = if handshake.client_hello, do: ClientHello.encode(handshake.client_hello)
    server_hello = if handshake.server_hello, do: ServerHello.encode(handshake.server_hello)
    client_finish = if handshake.client_finish, do: ClientFinish.encode(handshake.client_finish)

    Wire.encode_bytes(2, client_hello) <>
      Wire.encode_bytes(3, server_hello) <>
      Wire.encode_bytes(4, client_finish)
  end

  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(binary), do: decode_fields(binary, %__MODULE__{})

  defp decode_fields(<<>>, handshake), do: {:ok, handshake}

  defp decode_fields(binary, handshake) do
    case Wire.decode_key(binary) do
      {:ok, field, wire_type, rest} -> decode_field(field, wire_type, rest, handshake)
      {:error, _} = error -> error
    end
  end

  defp decode_field(2, 2, rest, handshake) do
    Wire.continue_nested_bytes(
      rest,
      handshake,
      &ClientHello.decode/1,
      &Map.put(&1, :client_hello, &2),
      &decode_fields/2
    )
  end

  defp decode_field(3, 2, rest, handshake) do
    Wire.continue_nested_bytes(
      rest,
      handshake,
      &ServerHello.decode/1,
      &Map.put(&1, :server_hello, &2),
      &decode_fields/2
    )
  end

  defp decode_field(4, 2, rest, handshake) do
    Wire.continue_nested_bytes(
      rest,
      handshake,
      &ClientFinish.decode/1,
      &Map.put(&1, :client_finish, &2),
      &decode_fields/2
    )
  end

  defp decode_field(_field, wire_type, rest, handshake),
    do: Wire.skip_and_continue(wire_type, rest, handshake, &decode_fields/2)
end
