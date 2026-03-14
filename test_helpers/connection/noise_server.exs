defmodule BaileysEx.TestSupport.Connection.NoiseServer do
  @moduledoc false

  alias BaileysEx.Crypto
  alias BaileysEx.Native.XEdDSA
  alias BaileysEx.Protocol.Proto.CertChain
  alias BaileysEx.Protocol.Proto.CertChain.NoiseCertificate
  alias BaileysEx.Protocol.Proto.CertChain.NoiseCertificate.Details
  alias BaileysEx.Protocol.Proto.HandshakeMessage
  alias BaileysEx.Protocol.Proto.HandshakeMessage.ClientFinish
  alias BaileysEx.Protocol.Proto.HandshakeMessage.ClientHello
  alias BaileysEx.Protocol.Proto.HandshakeMessage.ServerHello

  @noise_mode "Noise_XX_25519_AESGCM_SHA256\0\0\0\0"
  @noise_header <<87, 65, 6, 3>>
  @empty <<>>

  @spec build_server_hello(binary(), keyword()) :: {:ok, binary(), map()}
  def build_server_hello(client_hello_binary, opts) do
    root_key_pair = Keyword.fetch!(opts, :root_key_pair)
    intermediate_key_pair = Keyword.fetch!(opts, :intermediate_key_pair)
    server_static_key_pair = Keyword.fetch!(opts, :server_static_key_pair)
    issuer_serial = Keyword.fetch!(opts, :issuer_serial)

    server_ephemeral_key_pair =
      Keyword.get_lazy(opts, :server_ephemeral_key_pair, fn ->
        Crypto.generate_key_pair(:x25519, private_key: <<91::256>>)
      end)

    {:ok, %HandshakeMessage{client_hello: %ClientHello{ephemeral: client_ephemeral}}} =
      HandshakeMessage.decode(client_hello_binary)

    state =
      init_handshake_state()
      |> authenticate(@noise_header)
      |> authenticate(client_ephemeral)
      |> authenticate(server_ephemeral_key_pair.public)

    {:ok, shared_ephemeral} =
      Crypto.shared_secret(server_ephemeral_key_pair.private, client_ephemeral)

    {:ok, state} = mix_into_key(state, shared_ephemeral)
    {:ok, state, static_ciphertext} = encrypt_handshake(state, server_static_key_pair.public)

    {:ok, shared_static} = Crypto.shared_secret(server_static_key_pair.private, client_ephemeral)
    {:ok, state} = mix_into_key(state, shared_static)

    cert_chain =
      build_cert_chain(
        root_key_pair,
        intermediate_key_pair,
        server_static_key_pair.public,
        issuer_serial
      )

    {:ok, state, payload_ciphertext} = encrypt_handshake(state, cert_chain)

    server_hello =
      HandshakeMessage.encode(%HandshakeMessage{
        server_hello: %ServerHello{
          ephemeral: server_ephemeral_key_pair.public,
          static: static_ciphertext,
          payload: payload_ciphertext
        }
      })

    {:ok, server_hello, Map.put(state, :ephemeral_key_pair, server_ephemeral_key_pair)}
  end

  @spec process_client_finish(map(), binary()) ::
          {:ok, %{transport: map(), client_static: binary(), client_payload: binary()}}
  def process_client_finish(server_state, client_finish_binary) do
    {:ok,
     %HandshakeMessage{
       client_finish: %ClientFinish{static: static_ciphertext, payload: payload_ciphertext}
     }} = HandshakeMessage.decode(client_finish_binary)

    {:ok, server_state, client_static} = decrypt_handshake(server_state, static_ciphertext)

    {:ok, shared_noise} =
      Crypto.shared_secret(server_state.ephemeral_key_pair.private, client_static)

    {:ok, server_state} = mix_into_key(server_state, shared_noise)
    {:ok, server_state, client_payload} = decrypt_handshake(server_state, payload_ciphertext)
    {:ok, transport} = finish_transport(server_state, :server)

    {:ok,
     %{
       transport: transport,
       client_static: client_static,
       client_payload: client_payload
     }}
  end

  defp build_cert_chain(root_key_pair, intermediate_key_pair, server_static_public, issuer_serial) do
    intermediate_details =
      Details.encode(%Details{
        serial: 1,
        issuer_serial: issuer_serial,
        key: intermediate_key_pair.public,
        not_before: 1,
        not_after: 4_102_444_800
      })

    {:ok, intermediate_signature} = XEdDSA.sign(root_key_pair.private, intermediate_details)

    leaf_details =
      Details.encode(%Details{
        serial: 2,
        issuer_serial: 1,
        key: server_static_public,
        not_before: 1,
        not_after: 4_102_444_800
      })

    {:ok, leaf_signature} = XEdDSA.sign(intermediate_key_pair.private, leaf_details)

    CertChain.encode(%CertChain{
      leaf: %NoiseCertificate{details: leaf_details, signature: leaf_signature},
      intermediate: %NoiseCertificate{
        details: intermediate_details,
        signature: intermediate_signature
      }
    })
  end

  defp init_handshake_state do
    hash = initial_hash()
    %{hash: hash, salt: hash, enc_key: hash, dec_key: hash, counter: 0}
  end

  defp finish_transport(state, role) do
    {:ok, key_material} = Crypto.hkdf(@empty, @empty, 64, state.salt)
    <<write_key::binary-size(32), read_key::binary-size(32)>> = key_material

    transport =
      case role do
        :client -> %{enc_key: write_key, dec_key: read_key, read_counter: 0, write_counter: 0}
        :server -> %{enc_key: read_key, dec_key: write_key, read_counter: 0, write_counter: 0}
      end

    {:ok, transport}
  end

  defp encrypt_handshake(state, plaintext) do
    iv = generate_iv(state.counter)
    {:ok, ciphertext} = Crypto.aes_gcm_encrypt(state.enc_key, iv, plaintext, state.hash)
    state = state |> Map.update!(:counter, &(&1 + 1)) |> authenticate(ciphertext)
    {:ok, state, ciphertext}
  end

  defp decrypt_handshake(state, ciphertext) do
    iv = generate_iv(state.counter)
    {:ok, plaintext} = Crypto.aes_gcm_decrypt(state.dec_key, iv, ciphertext, state.hash)
    state = state |> Map.update!(:counter, &(&1 + 1)) |> authenticate(ciphertext)
    {:ok, state, plaintext}
  end

  defp mix_into_key(state, data) do
    {:ok, key_material} = Crypto.hkdf(data, @empty, 64, state.salt)
    <<write_key::binary-size(32), read_key::binary-size(32)>> = key_material
    {:ok, %{state | salt: write_key, enc_key: read_key, dec_key: read_key, counter: 0}}
  end

  defp authenticate(state, data), do: %{state | hash: Crypto.sha256([state.hash, data])}

  defp initial_hash do
    if byte_size(@noise_mode) == 32 do
      @noise_mode
    else
      Crypto.sha256(@noise_mode)
    end
  end

  defp generate_iv(counter), do: <<0::64, counter::32-big>>
end
