defmodule BaileysEx.Protocol.NoiseTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Crypto
  alias BaileysEx.Native.XEdDSA
  alias BaileysEx.Protocol.Noise
  alias BaileysEx.Protocol.Proto.CertChain
  alias BaileysEx.Protocol.Proto.CertChain.NoiseCertificate
  alias BaileysEx.Protocol.Proto.CertChain.NoiseCertificate.Details
  alias BaileysEx.Protocol.Proto.HandshakeMessage
  alias BaileysEx.Protocol.Proto.HandshakeMessage.ClientFinish
  alias BaileysEx.Protocol.Proto.HandshakeMessage.ClientHello
  alias BaileysEx.Protocol.Proto.HandshakeMessage.ServerHello

  @noise_mode "Noise_XX_25519_AESGCM_SHA256\0\0\0\0"
  @noise_header Noise.noise_header()
  @empty <<>>

  test "client_hello encodes the initiator ephemeral key" do
    ephemeral_key_pair = x25519_key_pair(1)
    ephemeral_public = ephemeral_key_pair.public

    assert {:ok, noise} = Noise.new(ephemeral_key_pair: ephemeral_key_pair)
    assert {:ok, {noise, client_hello}} = Noise.client_hello(noise)

    assert {:ok,
            %HandshakeMessage{
              client_hello: %ClientHello{ephemeral: ^ephemeral_public}
            }} = HandshakeMessage.decode(client_hello)

    refute Noise.transport_ready?(noise)
  end

  test "full client handshake and transport flow matches the Baileys algorithm" do
    client_ephemeral_key_pair = x25519_key_pair(2)
    client_noise_key_pair = x25519_key_pair(3)
    client_noise_public = client_noise_key_pair.public
    root_key_pair = x25519_key_pair(4)
    intermediate_key_pair = x25519_key_pair(5)
    server_static_key_pair = x25519_key_pair(6)

    trusted_cert = %{serial: 0, public_key: root_key_pair.public}

    assert {:ok, noise} =
             Noise.new(
               ephemeral_key_pair: client_ephemeral_key_pair,
               trusted_cert: trusted_cert
             )

    assert {:ok, {noise, client_hello}} = Noise.client_hello(noise)

    assert {:ok, server_hello, server_state} =
             build_server_hello(client_hello,
               root_key_pair: root_key_pair,
               intermediate_key_pair: intermediate_key_pair,
               server_static_key_pair: server_static_key_pair,
               issuer_serial: trusted_cert.serial
             )

    assert {:ok, noise} = Noise.process_server_hello(noise, server_hello, client_noise_key_pair)
    refute Noise.transport_ready?(noise)

    client_payload = "client finish payload"

    assert {:ok, {noise, client_finish}} = Noise.client_finish(noise, client_payload)
    assert Noise.transport_ready?(noise)

    assert {:ok,
            %{
              transport: server_transport,
              client_payload: ^client_payload,
              client_static: ^client_noise_public
            }} = process_client_finish(server_state, client_finish)

    assert {:ok, {noise, client_frame}} = Noise.encode_frame(noise, "client ping")

    header_size = byte_size(@noise_header)
    <<intro_header::binary-size(header_size), rest::binary>> = client_frame
    assert intro_header == @noise_header

    assert {:ok, server_transport, ["client ping"], @empty} =
             decode_server_frames(server_transport, rest)

    assert {:ok, server_transport, server_frame} =
             encode_server_frame(server_transport, "server pong")

    assert {:ok, {noise, ["server pong"]}} = Noise.decode_frames(noise, server_frame)

    assert {:ok, {_noise, second_client_frame}} = Noise.encode_frame(noise, "second ping")
    refute String.starts_with?(second_client_frame, @noise_header)

    assert {:ok, _server_transport, ["second ping"], @empty} =
             decode_server_frames(server_transport, second_client_frame)
  end

  test "process_server_hello rejects an invalid certificate chain" do
    client_ephemeral_key_pair = x25519_key_pair(7)
    client_noise_key_pair = x25519_key_pair(8)
    root_key_pair = x25519_key_pair(9)
    intermediate_key_pair = x25519_key_pair(10)
    server_static_key_pair = x25519_key_pair(11)

    trusted_cert = %{serial: 0, public_key: root_key_pair.public}

    assert {:ok, noise} =
             Noise.new(
               ephemeral_key_pair: client_ephemeral_key_pair,
               trusted_cert: trusted_cert
             )

    assert {:ok, {_noise, client_hello}} = Noise.client_hello(noise)

    assert {:ok, server_hello, _server_state} =
             build_server_hello(client_hello,
               root_key_pair: root_key_pair,
               intermediate_key_pair: intermediate_key_pair,
               server_static_key_pair: server_static_key_pair,
               issuer_serial: trusted_cert.serial + 1
             )

    assert {:error, :invalid_certificate} =
             Noise.process_server_hello(noise, server_hello, client_noise_key_pair)
  end

  test "decode_frames buffers partial transport frames and releases them in order" do
    {noise, server_transport} = complete_handshake()

    assert {:ok, server_transport, frame1} = encode_server_frame(server_transport, "one")
    assert {:ok, _server_transport, frame2} = encode_server_frame(server_transport, "two")
    combined = frame1 <> frame2

    <<part1::binary-size(2), part2::binary>> = combined

    assert {:ok, {noise, []}} = Noise.decode_frames(noise, part1)
    assert {:ok, {_noise, ["one", "two"]}} = Noise.decode_frames(noise, part2)
  end

  defp complete_handshake do
    client_ephemeral_key_pair = x25519_key_pair(12)
    client_noise_key_pair = x25519_key_pair(13)
    root_key_pair = x25519_key_pair(14)
    intermediate_key_pair = x25519_key_pair(15)
    server_static_key_pair = x25519_key_pair(16)

    trusted_cert = %{serial: 0, public_key: root_key_pair.public}

    {:ok, noise} =
      Noise.new(
        ephemeral_key_pair: client_ephemeral_key_pair,
        trusted_cert: trusted_cert
      )

    {:ok, {noise, client_hello}} = Noise.client_hello(noise)

    {:ok, server_hello, server_state} =
      build_server_hello(client_hello,
        root_key_pair: root_key_pair,
        intermediate_key_pair: intermediate_key_pair,
        server_static_key_pair: server_static_key_pair,
        issuer_serial: trusted_cert.serial
      )

    {:ok, noise} = Noise.process_server_hello(noise, server_hello, client_noise_key_pair)
    {:ok, {noise, client_finish}} = Noise.client_finish(noise, "payload")
    {:ok, %{transport: server_transport}} = process_client_finish(server_state, client_finish)

    {noise, server_transport}
  end

  defp build_server_hello(client_hello_binary, opts) do
    root_key_pair = Keyword.fetch!(opts, :root_key_pair)
    intermediate_key_pair = Keyword.fetch!(opts, :intermediate_key_pair)
    server_static_key_pair = Keyword.fetch!(opts, :server_static_key_pair)
    issuer_serial = Keyword.fetch!(opts, :issuer_serial)

    server_ephemeral_key_pair =
      Keyword.get_lazy(opts, :server_ephemeral_key_pair, fn -> x25519_key_pair(91) end)

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

  defp process_client_finish(server_state, client_finish_binary) do
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

  defp decode_server_frames(transport, buffer), do: decode_server_frames(transport, buffer, [])

  defp decode_server_frames(transport, <<length::24-big, rest::binary>>, acc)
       when byte_size(rest) >= length do
    <<ciphertext::binary-size(length), tail::binary>> = rest
    {:ok, transport, plaintext} = transport_decrypt(transport, ciphertext)
    decode_server_frames(transport, tail, [plaintext | acc])
  end

  defp decode_server_frames(transport, buffer, acc) do
    {:ok, transport, Enum.reverse(acc), buffer}
  end

  defp encode_server_frame(transport, plaintext) do
    {:ok, transport, ciphertext} = transport_encrypt(transport, plaintext)
    {:ok, transport, <<byte_size(ciphertext)::24-big, ciphertext::binary>>}
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

  defp transport_encrypt(transport, plaintext) do
    iv = generate_iv(transport.write_counter)
    {:ok, ciphertext} = Crypto.aes_gcm_encrypt(transport.enc_key, iv, plaintext, @empty)
    {:ok, %{transport | write_counter: transport.write_counter + 1}, ciphertext}
  end

  defp transport_decrypt(transport, ciphertext) do
    iv = generate_iv(transport.read_counter)
    {:ok, plaintext} = Crypto.aes_gcm_decrypt(transport.dec_key, iv, ciphertext, @empty)
    {:ok, %{transport | read_counter: transport.read_counter + 1}, plaintext}
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

  defp x25519_key_pair(seed),
    do: Crypto.generate_key_pair(:x25519, private_key: <<seed::unsigned-big-256>>)

  defp generate_iv(counter), do: <<0::64, counter::32-big>>
end
