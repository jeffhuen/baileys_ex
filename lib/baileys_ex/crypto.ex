defmodule BaileysEx.Crypto do
  @moduledoc """
  Cryptographic primitives for WhatsApp Web protocol communication.

  Provides a clean Elixir API wrapping Erlang's `:crypto` module for all symmetric
  and asymmetric operations: AES (GCM, CBC, CTR), HMAC, hashing, HKDF key derivation,
  PBKDF2, Curve25519 ECDH, and Ed25519 signing.

  HKDF (RFC 5869) is implemented in pure Elixir since OTP does not expose it directly.
  All other operations delegate to `:crypto` (backed by OpenSSL/LibreSSL).
  """

  # -- Types --

  @type key_pair :: %{public: binary(), private: binary()}

  @type media_keys :: %{
          iv: <<_::128>>,
          cipher_key: <<_::256>>,
          mac_key: <<_::256>>,
          ref_key: <<_::256>>
        }

  # ============================================================================
  # AES-256-GCM
  # ============================================================================

  @doc """
  Encrypt with AES-256-GCM. Returns `{:ok, ciphertext <> 16-byte tag}`.

  The 16-byte authentication tag is appended to the ciphertext, matching
  the WhatsApp wire format where tag is suffixed.
  """
  @spec aes_gcm_encrypt(<<_::256>>, binary(), binary(), binary()) ::
          {:ok, binary()}
  def aes_gcm_encrypt(key, iv, plaintext, aad \\ <<>>) do
    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, aad, true)

    {:ok, ciphertext <> tag}
  end

  @doc """
  Decrypt AES-256-GCM. Expects `ciphertext <> 16-byte tag` as input.

  Returns `{:ok, plaintext}` or `{:error, :decrypt_failed}` if authentication fails.
  """
  @spec aes_gcm_decrypt(<<_::256>>, binary(), binary(), binary()) ::
          {:ok, binary()} | {:error, :decrypt_failed}
  def aes_gcm_decrypt(key, iv, ciphertext_with_tag, aad \\ <<>>) do
    tag_size = 16
    ciphertext_size = byte_size(ciphertext_with_tag) - tag_size
    <<ciphertext::binary-size(ciphertext_size), tag::binary-size(tag_size)>> = ciphertext_with_tag

    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, aad, tag, false) do
      :error -> {:error, :decrypt_failed}
      plaintext -> {:ok, plaintext}
    end
  end

  # ============================================================================
  # AES-256-CBC (with PKCS7 padding)
  # ============================================================================

  @doc """
  Encrypt with AES-256-CBC and PKCS7 padding.
  """
  @spec aes_cbc_encrypt(<<_::256>>, <<_::128>>, binary()) :: {:ok, binary()}
  def aes_cbc_encrypt(key, iv, plaintext) do
    padded = pkcs7_pad(plaintext, 16)
    ciphertext = :crypto.crypto_one_time(:aes_256_cbc, key, iv, padded, encrypt: true)
    {:ok, ciphertext}
  end

  @doc """
  Decrypt AES-256-CBC and remove PKCS7 padding.

  Returns `{:error, :decrypt_failed}` on invalid padding.
  """
  @spec aes_cbc_decrypt(<<_::256>>, <<_::128>>, binary()) ::
          {:ok, binary()} | {:error, :decrypt_failed}
  def aes_cbc_decrypt(key, iv, ciphertext) do
    decrypted = :crypto.crypto_one_time(:aes_256_cbc, key, iv, ciphertext, encrypt: false)

    case pkcs7_unpad(decrypted, 16) do
      {:ok, plaintext} -> {:ok, plaintext}
      {:error, :invalid_padding} -> {:error, :decrypt_failed}
    end
  rescue
    _ -> {:error, :decrypt_failed}
  end

  # ============================================================================
  # AES-256-CTR
  # ============================================================================

  @doc """
  Encrypt with AES-256-CTR (stream cipher, no padding needed).
  """
  @spec aes_ctr_encrypt(<<_::256>>, <<_::128>>, binary()) :: {:ok, binary()}
  def aes_ctr_encrypt(key, iv, plaintext) do
    {:ok, :crypto.crypto_one_time(:aes_256_ctr, key, iv, plaintext, true)}
  end

  @doc """
  Decrypt AES-256-CTR (symmetric with encrypt).
  """
  @spec aes_ctr_decrypt(<<_::256>>, <<_::128>>, binary()) :: {:ok, binary()}
  def aes_ctr_decrypt(key, iv, ciphertext) do
    {:ok, :crypto.crypto_one_time(:aes_256_ctr, key, iv, ciphertext, false)}
  end

  # ============================================================================
  # Hashing
  # ============================================================================

  @doc "Compute SHA-256 digest."
  @spec sha256(iodata()) :: <<_::256>>
  def sha256(data), do: :crypto.hash(:sha256, data)

  @doc "Compute MD5 digest."
  @spec md5(iodata()) :: <<_::128>>
  def md5(data), do: :crypto.hash(:md5, data)

  # ============================================================================
  # HMAC
  # ============================================================================

  @doc "Compute HMAC-SHA256."
  @spec hmac_sha256(binary(), iodata()) :: <<_::256>>
  def hmac_sha256(key, data), do: :crypto.mac(:hmac, :sha256, key, data)

  @doc "Compute HMAC-SHA512."
  @spec hmac_sha512(binary(), iodata()) :: <<_::512>>
  def hmac_sha512(key, data), do: :crypto.mac(:hmac, :sha512, key, data)

  # ============================================================================
  # HKDF (RFC 5869 — pure Elixir using :crypto HMAC)
  # ============================================================================

  @doc """
  HMAC-based Key Derivation Function (RFC 5869) using SHA-256.

  Derives `length` bytes of keying material from input keying material (`ikm`),
  optional `salt`, and application-specific `info`.

  When `salt` is empty or omitted, a zero-filled salt of hash length (32 bytes) is used
  per the RFC specification.
  """
  @spec hkdf(binary(), binary(), pos_integer(), binary()) :: {:ok, binary()}
  def hkdf(ikm, info, length, salt \\ <<>>) do
    prk = hkdf_extract(salt, ikm)
    {:ok, hkdf_expand(prk, info, length)}
  end

  @doc """
  HKDF extract step: derive a pseudorandom key from input keying material.

  Uses HMAC-SHA256 with the given salt (or 32 zero bytes if salt is empty).
  """
  @spec hkdf_extract(binary(), binary()) :: <<_::256>>
  def hkdf_extract(<<>>, ikm), do: :crypto.mac(:hmac, :sha256, <<0::256>>, ikm)
  def hkdf_extract(salt, ikm), do: :crypto.mac(:hmac, :sha256, salt, ikm)

  @doc """
  HKDF expand step: expand a pseudorandom key to the desired length.

  Iteratively produces output blocks using HMAC-SHA256 with counter bytes.
  Maximum output length is 255 * 32 = 8160 bytes.
  """
  @spec hkdf_expand(<<_::256>>, binary(), pos_integer()) :: binary()
  def hkdf_expand(prk, info, length) when length > 0 and length <= 8160 do
    hash_len = 32
    n = div(length + hash_len - 1, hash_len)

    {okm, _} =
      Enum.reduce(1..n, {<<>>, <<>>}, fn i, {acc, prev} ->
        t = :crypto.mac(:hmac, :sha256, prk, prev <> info <> <<i>>)
        {acc <> t, t}
      end)

    binary_part(okm, 0, length)
  end

  # ============================================================================
  # PBKDF2
  # ============================================================================

  @doc """
  PBKDF2 key derivation with HMAC-SHA256.

  Used for pairing code derivation (131,072 iterations).
  """
  @spec pbkdf2_sha256(binary(), binary(), pos_integer(), pos_integer()) :: {:ok, binary()}
  def pbkdf2_sha256(password, salt, iterations, length) do
    {:ok, :crypto.pbkdf2_hmac(:sha256, password, salt, iterations, length)}
  end

  # ============================================================================
  # Curve25519 / Ed25519
  # ============================================================================

  @doc """
  Generate a key pair for the given curve.

  - `:x25519` — Curve25519 key pair for Diffie-Hellman key exchange
  - `:ed25519` — Ed25519 key pair for digital signatures
  """
  @spec generate_key_pair(:x25519 | :ed25519, keyword()) :: key_pair()
  def generate_key_pair(curve, opts \\ [])

  def generate_key_pair(:x25519, opts) do
    {pub, priv} =
      case opts[:private_key] do
        nil -> :crypto.generate_key(:ecdh, :x25519)
        private_key -> :crypto.generate_key(:ecdh, :x25519, private_key)
      end

    %{public: pub, private: priv}
  end

  def generate_key_pair(:ed25519, opts) do
    {pub, priv} =
      case opts[:private_key] do
        nil -> :crypto.generate_key(:eddsa, :ed25519)
        private_key -> :crypto.generate_key(:eddsa, :ed25519, private_key)
      end

    %{public: pub, private: priv}
  end

  @doc """
  Compute X25519 shared secret from a private key and a peer's public key.

  Returns `{:ok, shared_secret}` — a 32-byte value.
  """
  @spec shared_secret(binary(), binary()) :: {:ok, binary()}
  def shared_secret(my_private, their_public) do
    {:ok, :crypto.compute_key(:ecdh, their_public, my_private, :x25519)}
  end

  @doc "Sign a message with an Ed25519 private key."
  @spec ed25519_sign(binary(), binary()) :: binary()
  def ed25519_sign(private_key, message) do
    :crypto.sign(:eddsa, :none, message, [private_key, :ed25519])
  end

  @doc "Verify an Ed25519 signature. Returns `true` if valid, `false` otherwise."
  @spec ed25519_verify(binary(), binary(), binary()) :: boolean()
  def ed25519_verify(public_key, message, signature) do
    :crypto.verify(:eddsa, :none, message, signature, [public_key, :ed25519])
  end

  # ============================================================================
  # Random
  # ============================================================================

  @doc "Generate `n` cryptographically strong random bytes."
  @spec random_bytes(non_neg_integer()) :: binary()
  def random_bytes(n), do: :crypto.strong_rand_bytes(n)

  # ============================================================================
  # WhatsApp-specific helpers
  # ============================================================================

  @doc """
  Expand a 32-byte media key to 112 bytes using HKDF with a type-specific info string.

  Returns a map with `:iv` (16 bytes), `:cipher_key` (32 bytes),
  `:mac_key` (32 bytes), and `:ref_key` (32 bytes).
  """
  @spec expand_media_key(<<_::256>>, BaileysEx.Media.Types.media_type()) :: media_keys()
  def expand_media_key(media_key, media_type) do
    info = BaileysEx.Media.Types.hkdf_info(media_type)
    {:ok, expanded} = hkdf(media_key, info, 112)

    <<iv::binary-16, cipher_key::binary-32, mac_key::binary-32, ref_key::binary-32>> = expanded

    %{iv: iv, cipher_key: cipher_key, mac_key: mac_key, ref_key: ref_key}
  end

  # ============================================================================
  # PKCS7 Padding
  # ============================================================================

  @doc """
  Apply PKCS7 padding to align data to the given block size.

  Adds 1 to `block_size` bytes of padding, where each padding byte's value
  equals the number of padding bytes added.
  """
  @spec pkcs7_pad(binary(), pos_integer()) :: binary()
  def pkcs7_pad(data, block_size) do
    pad_len = block_size - rem(byte_size(data), block_size)
    data <> :binary.copy(<<pad_len>>, pad_len)
  end

  @doc """
  Remove PKCS7 padding. Returns `{:error, :invalid_padding}` if padding is malformed.
  """
  @spec pkcs7_unpad(binary(), pos_integer()) ::
          {:ok, binary()} | {:error, :invalid_padding}
  def pkcs7_unpad(data, block_size) do
    size = byte_size(data)

    if size == 0 or rem(size, block_size) != 0 do
      {:error, :invalid_padding}
    else
      unpad_pkcs7_block(data, size, block_size)
    end
  end

  defp unpad_pkcs7_block(data, size, block_size) do
    pad_len = :binary.last(data)

    if pad_len < 1 or pad_len > block_size do
      {:error, :invalid_padding}
    else
      validate_pkcs7_padding(data, size, pad_len)
    end
  end

  defp validate_pkcs7_padding(data, size, pad_len) do
    padding = binary_part(data, size - pad_len, pad_len)
    expected = :binary.copy(<<pad_len>>, pad_len)

    if padding == expected do
      {:ok, binary_part(data, 0, size - pad_len)}
    else
      {:error, :invalid_padding}
    end
  end

  # ============================================================================
  # Private helpers
  # ============================================================================
end
