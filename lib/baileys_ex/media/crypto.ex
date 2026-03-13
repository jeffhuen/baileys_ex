defmodule BaileysEx.Media.Crypto do
  @moduledoc """
  Media encryption and decryption for WhatsApp CDN payloads.
  """

  alias BaileysEx.Crypto, as: CoreCrypto
  alias BaileysEx.Media.Types

  @type encrypt_result :: %{
          encrypted_path: String.t(),
          media_key: binary(),
          file_sha256: binary(),
          file_enc_sha256: binary(),
          file_length: non_neg_integer()
        }

  @chunk_size 64 * 1024
  @block_size 16
  @mac_size 10

  @spec encrypt(binary() | Enumerable.t(), Types.media_type(), keyword()) ::
          {:ok, encrypt_result()} | {:error, term()}
  @doc """
  Encrypt media into a temporary file while computing the WhatsApp media hashes
  and MAC in a single pass.
  """
  def encrypt(input, media_type, opts \\ []) do
    media_key = Keyword.get_lazy(opts, :media_key, fn -> CoreCrypto.random_bytes(32) end)

    %{iv: iv, cipher_key: cipher_key, mac_key: mac_key} =
      CoreCrypto.expand_media_key(media_key, media_type)

    encrypted_path =
      Keyword.get_lazy(opts, :encrypted_path, fn -> tmp_path(media_type, opts[:tmp_dir]) end)

    File.mkdir_p!(Path.dirname(encrypted_path))

    case File.open(encrypted_path, [:write, :binary]) do
      {:ok, device} ->
        try do
          {:ok, state} = init_encrypt_state(device, iv, cipher_key, mac_key)
          {:ok, state} = stream_encrypt(input, state)
          finalize_encrypt(state, encrypted_path, media_key)
        after
          File.close(device)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec decrypt(binary(), binary(), Types.media_type()) :: {:ok, binary()} | {:error, term()}
  @doc """
  Decrypt downloaded media after verifying its WhatsApp media MAC.
  """
  def decrypt(encrypted_data, media_key, media_type)
      when is_binary(encrypted_data) and is_binary(media_key) do
    %{iv: iv, cipher_key: cipher_key, mac_key: mac_key} =
      CoreCrypto.expand_media_key(media_key, media_type)

    with {:ok, ciphertext, mac} <- split_ciphertext_and_mac(encrypted_data),
         :ok <- verify_mac(iv, ciphertext, mac, mac_key) do
      CoreCrypto.aes_cbc_decrypt(cipher_key, iv, ciphertext)
    end
  end

  defp init_encrypt_state(device, iv, cipher_key, mac_key) do
    {:ok,
     %{
       device: device,
       cipher_state: :crypto.crypto_init(:aes_256_cbc, cipher_key, iv, true),
       plain_hash: :crypto.hash_init(:sha256),
       enc_hash: :crypto.hash_init(:sha256),
       mac_state: :crypto.mac_init(:hmac, :sha256, mac_key) |> :crypto.mac_update(iv),
       carry: <<>>,
       file_length: 0
     }}
  end

  defp stream_encrypt(input, state) do
    {:ok, Enum.reduce(to_chunks(input), state, &process_encrypt_chunk/2)}
  end

  defp process_encrypt_chunk(chunk, state) when is_binary(chunk) do
    data = state.carry <> chunk
    encrypt_size = div(byte_size(data), @block_size) * @block_size
    <<to_encrypt::binary-size(encrypt_size), carry::binary>> = data

    state =
      %{
        state
        | plain_hash: :crypto.hash_update(state.plain_hash, chunk),
          file_length: state.file_length + byte_size(chunk),
          carry: carry
      }

    case to_encrypt do
      <<>> ->
        state

      _ ->
        encrypted = :crypto.crypto_update(state.cipher_state, to_encrypt)
        write_encrypted_chunk(encrypted, state)
    end
  end

  defp finalize_encrypt(state, encrypted_path, media_key) do
    padding = CoreCrypto.pkcs7_pad(state.carry, @block_size)

    encrypted =
      :crypto.crypto_update(state.cipher_state, padding) <>
        :crypto.crypto_final(state.cipher_state)

    state = write_encrypted_chunk(encrypted, %{state | carry: <<>>})
    mac = :crypto.mac_final(state.mac_state) |> binary_part(0, @mac_size)
    :ok = IO.binwrite(state.device, mac)
    plain_sha256 = :crypto.hash_final(state.plain_hash)
    file_enc_sha256 = :crypto.hash_update(state.enc_hash, mac) |> :crypto.hash_final()

    {:ok,
     %{
       encrypted_path: encrypted_path,
       media_key: media_key,
       file_sha256: plain_sha256,
       file_enc_sha256: file_enc_sha256,
       file_length: state.file_length
     }}
  end

  defp write_encrypted_chunk(encrypted, state) do
    :ok = IO.binwrite(state.device, encrypted)

    %{
      state
      | enc_hash: :crypto.hash_update(state.enc_hash, encrypted),
        mac_state: :crypto.mac_update(state.mac_state, encrypted)
    }
  end

  defp split_ciphertext_and_mac(encrypted_data) when byte_size(encrypted_data) > @mac_size do
    ciphertext_size = byte_size(encrypted_data) - @mac_size
    <<ciphertext::binary-size(ciphertext_size), mac::binary-size(@mac_size)>> = encrypted_data
    {:ok, ciphertext, mac}
  end

  defp split_ciphertext_and_mac(_encrypted_data), do: {:error, :invalid_media_payload}

  defp verify_mac(iv, ciphertext, mac, mac_key) do
    computed = CoreCrypto.hmac_sha256(mac_key, iv <> ciphertext) |> binary_part(0, @mac_size)

    if :crypto.hash_equals(computed, mac) do
      :ok
    else
      {:error, :mac_mismatch}
    end
  end

  defp to_chunks(input) when is_binary(input) do
    Stream.unfold(input, fn
      <<>> -> nil
      data when byte_size(data) <= @chunk_size -> {data, <<>>}
      <<chunk::binary-size(@chunk_size), rest::binary>> -> {chunk, rest}
    end)
  end

  defp to_chunks(%File.Stream{} = stream), do: stream
  defp to_chunks(input), do: input

  defp tmp_path(media_type, nil) do
    Path.join(
      System.tmp_dir!(),
      "#{Atom.to_string(media_type)}-#{System.unique_integer([:positive])}.enc"
    )
  end

  defp tmp_path(media_type, tmp_dir) do
    Path.join(tmp_dir, "#{Atom.to_string(media_type)}-#{System.unique_integer([:positive])}.enc")
  end
end
