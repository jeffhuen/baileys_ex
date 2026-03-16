defmodule BaileysEx.Protocol.Noise do
  @moduledoc """
  WhatsApp Noise handshake and transport state aligned with the Baileys reference.

  This module mirrors `dev/reference/Baileys-master/src/Utils/noise-handler.ts`:
  the WhatsApp-specific protobuf handshake, certificate validation, handshake hash
  mixing, and transport frame counters live in Elixir, while the expensive crypto
  primitives stay native via `:crypto` and narrow NIF helpers.
  """

  import Bitwise

  alias BaileysEx.Crypto
  alias BaileysEx.Signal.Curve
  alias BaileysEx.Protocol.Proto.CertChain
  alias BaileysEx.Protocol.Proto.CertChain.NoiseCertificate
  alias BaileysEx.Protocol.Proto.CertChain.NoiseCertificate.Details
  alias BaileysEx.Protocol.Proto.HandshakeMessage
  alias BaileysEx.Protocol.Proto.HandshakeMessage.ClientFinish
  alias BaileysEx.Protocol.Proto.HandshakeMessage.ClientHello
  alias BaileysEx.Protocol.Proto.HandshakeMessage.ServerHello
  alias BaileysEx.Telemetry

  @noise_mode "Noise_XX_25519_AESGCM_SHA256\0\0\0\0"
  @noise_wa_header <<87, 65, 6, 3>>
  @empty <<>>
  @default_trusted_cert %{
    serial: 0,
    public_key:
      Base.decode16!(
        "142375574d0a587166aae71ebe516437c4a28b73e3695c6ce1f7f9545da8ee6b",
        case: :lower
      )
  }

  defmodule TransportState do
    @moduledoc """
    Derived transport keys and frame counters for the established Noise session.
    """

    @enforce_keys [:enc_key, :dec_key]
    defstruct [:enc_key, :dec_key, read_counter: 0, write_counter: 0]

    @type t :: %__MODULE__{
            enc_key: <<_::256>>,
            dec_key: <<_::256>>,
            read_counter: non_neg_integer(),
            write_counter: non_neg_integer()
          }
  end

  @type key_pair :: Crypto.key_pair()
  @type cert_details :: %{serial: non_neg_integer(), public_key: binary()}

  @type t :: %__MODULE__{
          ephemeral_key_pair: key_pair(),
          hash: binary(),
          salt: binary(),
          enc_key: binary(),
          dec_key: binary(),
          counter: non_neg_integer(),
          intro_header: binary(),
          sent_intro?: boolean(),
          pending_static: binary() | nil,
          in_bytes: binary(),
          trusted_cert: cert_details(),
          transport: TransportState.t() | nil
        }

  @enforce_keys [
    :ephemeral_key_pair,
    :hash,
    :salt,
    :enc_key,
    :dec_key,
    :intro_header,
    :trusted_cert
  ]
  defstruct [
    :ephemeral_key_pair,
    :hash,
    :salt,
    :enc_key,
    :dec_key,
    :intro_header,
    :trusted_cert,
    counter: 0,
    sent_intro?: false,
    pending_static: nil,
    in_bytes: <<>>,
    transport: nil
  ]

  @doc """
  Create a new initiator-side WhatsApp Noise state.

  Options:
  - `:ephemeral_key_pair` - injected X25519 key pair for deterministic tests
  - `:routing_info` - optional WhatsApp routing info for the intro header
  - `:header` - custom Noise header, defaults to WhatsApp's `<<87, 65, 6, 3>>`
  - `:trusted_cert` - trusted certificate authority details for validation
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts \\ []) do
    header = Keyword.get(opts, :header, @noise_wa_header)
    routing_info = Keyword.get(opts, :routing_info)
    trusted_cert = Keyword.get(opts, :trusted_cert, @default_trusted_cert)

    ephemeral_key_pair =
      Keyword.get_lazy(opts, :ephemeral_key_pair, fn -> Crypto.generate_key_pair(:x25519) end)

    hash = initial_hash()

    state =
      %__MODULE__{
        ephemeral_key_pair: ephemeral_key_pair,
        hash: hash,
        salt: hash,
        enc_key: hash,
        dec_key: hash,
        intro_header: build_intro_header(header, routing_info),
        trusted_cert: trusted_cert
      }
      |> authenticate(header)
      |> authenticate(ephemeral_key_pair.public)

    {:ok, state}
  rescue
    error -> {:error, normalize_error(error)}
  end

  @doc "Return WhatsApp's Noise header."
  @spec noise_header() :: binary()
  def noise_header, do: @noise_wa_header

  @doc "Return the trusted WhatsApp Noise certificate anchor used by default."
  @spec default_trusted_cert() :: cert_details()
  def default_trusted_cert, do: @default_trusted_cert

  @doc "True once the handshake has transitioned into transport mode."
  @spec transport_ready?(t()) :: boolean()
  def transport_ready?(%__MODULE__{transport: transport}), do: not is_nil(transport)

  @doc """
  Encode the client hello `HandshakeMessage`.
  """
  @spec client_hello(t()) :: {:ok, {t(), binary()}} | {:error, term()}
  def client_hello(%__MODULE__{} = state) do
    message =
      HandshakeMessage.encode(%HandshakeMessage{
        client_hello: %ClientHello{ephemeral: state.ephemeral_key_pair.public}
      })

    {:ok, {state, message}}
  rescue
    error -> {:error, normalize_error(error)}
  end

  @doc """
  Process a server hello `HandshakeMessage` and validate its certificate chain.

  The `noise_key_pair` is the client's long-term static Noise key pair that will
  be sent in the subsequent client finish message.
  """
  @spec process_server_hello(t(), binary(), key_pair()) :: {:ok, t()} | {:error, term()}
  def process_server_hello(%__MODULE__{} = state, server_hello_binary, noise_key_pair) do
    with {:ok, %HandshakeMessage{server_hello: %ServerHello{} = server_hello}} <-
           HandshakeMessage.decode(server_hello_binary),
         {:ok, state} <- do_process_server_hello(state, server_hello, noise_key_pair) do
      {:ok, state}
    else
      {:ok, %HandshakeMessage{}} -> {:error, :invalid_server_hello}
      {:error, _} = error -> error
    end
  rescue
    error -> {:error, normalize_error(error)}
  end

  @doc """
  Build the client finish `HandshakeMessage`.

  Transport mode does not begin until `finish_init/1` is called after the framed
  handshake message has been sent on the wire.
  """
  @spec client_finish(t(), binary()) :: {:ok, {t(), binary()}} | {:error, term()}
  def client_finish(%__MODULE__{pending_static: nil}, _client_payload) do
    {:error, :handshake_not_ready}
  end

  def client_finish(%__MODULE__{transport: %TransportState{}} = _state, _client_payload) do
    {:error, :already_in_transport}
  end

  def client_finish(%__MODULE__{} = state, client_payload) do
    with {:ok, state, payload} <- encrypt_handshake(state, client_payload) do
      message =
        HandshakeMessage.encode(%HandshakeMessage{
          client_finish: %ClientFinish{
            static: state.pending_static,
            payload: payload
          }
        })

      {:ok, {%{state | pending_static: nil}, message}}
    end
  rescue
    error -> {:error, normalize_error(error)}
  end

  @doc """
  Transition the Noise state into transport mode after the framed handshake has
  been sent.
  """
  @spec finish_init(t()) :: {:ok, t()} | {:error, term()}
  def finish_init(%__MODULE__{transport: %TransportState{}} = state), do: {:ok, state}

  def finish_init(%__MODULE__{} = state) do
    finish_transport(state)
  rescue
    error -> {:error, normalize_error(error)}
  end

  @doc """
  Encode an outbound length-prefixed frame.

  On the first transport frame, this prepends WhatsApp's intro header exactly as
  Baileys does. Payload encryption only happens after the handshake is complete.
  """
  @spec encode_frame(t(), binary()) :: {:ok, {t(), binary()}} | {:error, term()}
  def encode_frame(%__MODULE__{} = state, data) when is_binary(data) do
    with {:ok, state, payload} <- maybe_encrypt_transport(state, data) do
      size = byte_size(payload)

      frame =
        if state.sent_intro? do
          IO.iodata_to_binary([<<size::24-big>>, payload])
        else
          IO.iodata_to_binary([state.intro_header, <<size::24-big>>, payload])
        end

      {:ok, {%{state | sent_intro?: true}, frame}}
    end
  rescue
    error -> {:error, normalize_error(error)}
  end

  @doc """
  Decode one or more inbound length-prefixed frames from a buffer chunk.

  Returns all complete frame payloads in order and keeps any partial trailing
  bytes buffered in the returned state.
  """
  @spec decode_frames(t(), binary()) :: {:ok, {t(), [binary()]}} | {:error, term()}
  def decode_frames(%__MODULE__{} = state, new_data) when is_binary(new_data) do
    buffer =
      if state.in_bytes == @empty do
        new_data
      else
        <<state.in_bytes::binary, new_data::binary>>
      end

    with {:ok, state, frames, rest} <- do_decode_frames(%{state | in_bytes: @empty}, buffer, []) do
      {:ok, {%{state | in_bytes: rest}, frames}}
    end
  rescue
    error -> {:error, normalize_error(error)}
  end

  defp do_process_server_hello(state, %ServerHello{} = server_hello, noise_key_pair) do
    with true <- is_binary(server_hello.ephemeral) and server_hello.ephemeral != nil,
         true <- is_binary(server_hello.static) and server_hello.static != nil,
         true <- is_binary(server_hello.payload) and server_hello.payload != nil,
         {:ok, state} <- server_hello_ephemeral(state, server_hello.ephemeral),
         {:ok, state, server_static} <- decrypt_handshake(state, server_hello.static),
         {:ok, shared_static} <-
           Crypto.shared_secret(state.ephemeral_key_pair.private, server_static),
         {:ok, state} <- mix_into_key(state, shared_static),
         {:ok, state, cert_payload} <- decrypt_handshake(state, server_hello.payload),
         :ok <- validate_cert_chain(cert_payload, state.trusted_cert),
         {:ok, state, pending_static} <- encrypt_handshake(state, noise_key_pair.public),
         {:ok, shared_noise} <-
           Crypto.shared_secret(noise_key_pair.private, server_hello.ephemeral),
         {:ok, state} <- mix_into_key(state, shared_noise) do
      {:ok, %{state | pending_static: pending_static}}
    else
      false -> {:error, :invalid_server_hello}
      {:error, _} = error -> error
    end
  end

  defp server_hello_ephemeral(state, server_ephemeral) do
    state = authenticate(state, server_ephemeral)

    with {:ok, shared_secret} <-
           Crypto.shared_secret(state.ephemeral_key_pair.private, server_ephemeral) do
      mix_into_key(state, shared_secret)
    end
  end

  defp validate_cert_chain(payload, trusted_cert) do
    with {:ok,
          %CertChain{
            leaf: %NoiseCertificate{} = leaf,
            intermediate: %NoiseCertificate{} = intermediate
          }} <-
           CertChain.decode(payload),
         true <- is_binary(leaf.details) and is_binary(leaf.signature),
         true <- is_binary(intermediate.details) and is_binary(intermediate.signature),
         {:ok, %Details{key: intermediate_key, issuer_serial: issuer_serial}} <-
           Details.decode(intermediate.details),
         true <- is_binary(intermediate_key),
         true <- Curve.verify(intermediate_key, leaf.details, leaf.signature),
         true <-
           Curve.verify(trusted_cert.public_key, intermediate.details, intermediate.signature),
         true <- issuer_serial == trusted_cert.serial do
      :ok
    else
      false -> {:error, :invalid_certificate}
      {:error, _} -> {:error, :invalid_certificate}
      _ -> {:error, :invalid_certificate}
    end
  end

  defp maybe_encrypt_transport(%__MODULE__{transport: nil} = state, data), do: {:ok, state, data}

  defp maybe_encrypt_transport(%__MODULE__{transport: transport} = state, data) do
    with {:ok, transport, ciphertext} <- transport_encrypt(transport, data) do
      Telemetry.execute(
        [:nif, :noise, :encrypt],
        %{bytes: byte_size(data)},
        %{phase: :transport}
      )

      {:ok, %{state | transport: transport}, ciphertext}
    end
  end

  defp do_decode_frames(state, <<length::24-big, rest::binary>>, acc)
       when byte_size(rest) >= length do
    <<frame::binary-size(length), tail::binary>> = rest

    with {:ok, state, decoded_frame} <- maybe_decrypt_transport(state, frame) do
      do_decode_frames(state, tail, [decoded_frame | acc])
    end
  end

  defp do_decode_frames(state, buffer, acc), do: {:ok, state, Enum.reverse(acc), buffer}

  defp maybe_decrypt_transport(%__MODULE__{transport: nil} = state, data), do: {:ok, state, data}

  defp maybe_decrypt_transport(%__MODULE__{transport: transport} = state, data) do
    with {:ok, transport, plaintext} <- transport_decrypt(transport, data) do
      Telemetry.execute(
        [:nif, :noise, :decrypt],
        %{bytes: byte_size(plaintext)},
        %{phase: :transport}
      )

      {:ok, %{state | transport: transport}, plaintext}
    end
  end

  defp finish_transport(%__MODULE__{transport: %TransportState{}} = state), do: {:ok, state}

  defp finish_transport(%__MODULE__{} = state) do
    with {:ok, write_key, read_key} <- local_hkdf(state.salt, @empty) do
      transport = %TransportState{enc_key: write_key, dec_key: read_key}
      {:ok, %{state | transport: transport}}
    end
  end

  defp transport_encrypt(%TransportState{} = transport, plaintext) do
    iv = generate_iv(transport.write_counter)

    with {:ok, ciphertext} <- Crypto.aes_gcm_encrypt(transport.enc_key, iv, plaintext, @empty) do
      {:ok, %{transport | write_counter: transport.write_counter + 1}, ciphertext}
    end
  end

  defp transport_decrypt(%TransportState{} = transport, ciphertext) do
    iv = generate_iv(transport.read_counter)

    with {:ok, plaintext} <- Crypto.aes_gcm_decrypt(transport.dec_key, iv, ciphertext, @empty) do
      {:ok, %{transport | read_counter: transport.read_counter + 1}, plaintext}
    end
  end

  defp encrypt_handshake(%__MODULE__{} = state, plaintext) do
    iv = generate_iv(state.counter)

    with {:ok, ciphertext} <- Crypto.aes_gcm_encrypt(state.enc_key, iv, plaintext, state.hash) do
      state =
        state
        |> Map.update!(:counter, &(&1 + 1))
        |> authenticate(ciphertext)

      {:ok, state, ciphertext}
    end
  end

  defp decrypt_handshake(%__MODULE__{} = state, ciphertext) do
    iv = generate_iv(state.counter)

    with {:ok, plaintext} <- Crypto.aes_gcm_decrypt(state.dec_key, iv, ciphertext, state.hash) do
      state =
        state
        |> Map.update!(:counter, &(&1 + 1))
        |> authenticate(ciphertext)

      {:ok, state, plaintext}
    end
  end

  defp mix_into_key(%__MODULE__{} = state, data) do
    with {:ok, write_key, read_key} <- local_hkdf(state.salt, data) do
      {:ok, %{state | salt: write_key, enc_key: read_key, dec_key: read_key, counter: 0}}
    end
  end

  defp local_hkdf(salt, data) do
    with {:ok, key_material} <- Crypto.hkdf(data, @empty, 64, salt) do
      <<write_key::binary-size(32), read_key::binary-size(32)>> = key_material
      {:ok, write_key, read_key}
    end
  end

  defp authenticate(%__MODULE__{transport: nil} = state, data) do
    %{state | hash: Crypto.sha256([state.hash, data])}
  end

  defp authenticate(%__MODULE__{} = state, _data), do: state

  defp build_intro_header(header, nil), do: header

  defp build_intro_header(header, routing_info) when is_binary(routing_info) do
    routing_length = byte_size(routing_info)

    IO.iodata_to_binary([
      "ED",
      <<0, 1, routing_length >>> 16, routing_length &&& 0xFFFF::16-big>>,
      routing_info,
      header
    ])
  end

  defp initial_hash do
    if byte_size(@noise_mode) == 32 do
      @noise_mode
    else
      Crypto.sha256(@noise_mode)
    end
  end

  defp generate_iv(counter), do: <<0::64, counter::32-big>>

  defp normalize_error(error) do
    case Exception.message(error) do
      message when is_binary(message) and message != "" -> message
      _ -> inspect(error)
    end
  end
end
