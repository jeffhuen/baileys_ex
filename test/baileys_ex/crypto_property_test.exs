defmodule BaileysEx.CryptoPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias BaileysEx.Crypto

  # ============================================================================
  # AES-256-GCM roundtrip
  # ============================================================================

  property "AES-GCM encrypt/decrypt roundtrip for arbitrary data" do
    check all(
            key <- binary(length: 32),
            iv <- binary(length: 12),
            plaintext <- binary(min_length: 0, max_length: 10_000),
            aad <- binary(min_length: 0, max_length: 100)
          ) do
      {:ok, ciphertext} = Crypto.aes_gcm_encrypt(key, iv, plaintext, aad)
      assert {:ok, ^plaintext} = Crypto.aes_gcm_decrypt(key, iv, ciphertext, aad)
    end
  end

  property "AES-GCM ciphertext is plaintext_length + 16 bytes (tag)" do
    check all(
            key <- binary(length: 32),
            iv <- binary(length: 12),
            plaintext <- binary(min_length: 0, max_length: 1_000)
          ) do
      {:ok, ciphertext} = Crypto.aes_gcm_encrypt(key, iv, plaintext)
      assert byte_size(ciphertext) == byte_size(plaintext) + 16
    end
  end

  # ============================================================================
  # AES-256-CBC roundtrip
  # ============================================================================

  property "AES-CBC encrypt/decrypt roundtrip" do
    check all(
            key <- binary(length: 32),
            iv <- binary(length: 16),
            plaintext <- binary(min_length: 0, max_length: 10_000)
          ) do
      {:ok, ciphertext} = Crypto.aes_cbc_encrypt(key, iv, plaintext)
      assert {:ok, ^plaintext} = Crypto.aes_cbc_decrypt(key, iv, ciphertext)
    end
  end

  property "AES-CBC ciphertext is always block-aligned" do
    check all(
            key <- binary(length: 32),
            iv <- binary(length: 16),
            plaintext <- binary(min_length: 0, max_length: 1_000)
          ) do
      {:ok, ciphertext} = Crypto.aes_cbc_encrypt(key, iv, plaintext)
      assert rem(byte_size(ciphertext), 16) == 0
      assert byte_size(ciphertext) > byte_size(plaintext)
    end
  end

  # ============================================================================
  # AES-256-CTR roundtrip
  # ============================================================================

  property "AES-CTR encrypt/decrypt roundtrip" do
    check all(
            key <- binary(length: 32),
            iv <- binary(length: 16),
            plaintext <- binary(min_length: 0, max_length: 10_000)
          ) do
      {:ok, ciphertext} = Crypto.aes_ctr_encrypt(key, iv, plaintext)
      assert {:ok, ^plaintext} = Crypto.aes_ctr_decrypt(key, iv, ciphertext)
    end
  end

  # ============================================================================
  # HMAC determinism
  # ============================================================================

  property "HMAC-SHA256 is deterministic (same input -> same output)" do
    check all(
            key <- binary(min_length: 1, max_length: 128),
            data <- binary(min_length: 0, max_length: 1_000)
          ) do
      result1 = Crypto.hmac_sha256(key, data)
      result2 = Crypto.hmac_sha256(key, data)
      assert result1 == result2
      assert byte_size(result1) == 32
    end
  end

  property "HMAC-SHA512 is deterministic and 64 bytes" do
    check all(
            key <- binary(min_length: 1, max_length: 128),
            data <- binary(min_length: 0, max_length: 1_000)
          ) do
      result1 = Crypto.hmac_sha512(key, data)
      result2 = Crypto.hmac_sha512(key, data)
      assert result1 == result2
      assert byte_size(result1) == 64
    end
  end

  # ============================================================================
  # HKDF output length
  # ============================================================================

  property "HKDF output length matches requested length" do
    check all(
            ikm <- binary(min_length: 1, max_length: 64),
            info <- binary(min_length: 0, max_length: 64),
            length <- integer(1..255)
          ) do
      {:ok, output} = Crypto.hkdf(ikm, info, length)
      assert byte_size(output) == length
    end
  end

  property "HKDF is deterministic" do
    check all(
            ikm <- binary(min_length: 1, max_length: 64),
            salt <- binary(min_length: 0, max_length: 32),
            info <- binary(min_length: 0, max_length: 32),
            length <- integer(1..128)
          ) do
      {:ok, output1} = Crypto.hkdf(ikm, info, length, salt)
      {:ok, output2} = Crypto.hkdf(ikm, info, length, salt)
      assert output1 == output2
    end
  end

  # ============================================================================
  # Curve25519 ECDH symmetry
  # ============================================================================

  property "Curve25519 ECDH shared secret is symmetric (A*B == B*A)" do
    check all(_ <- constant(:ok), max_runs: 20) do
      alice = Crypto.generate_key_pair(:x25519)
      bob = Crypto.generate_key_pair(:x25519)

      {:ok, shared_ab} = Crypto.shared_secret(alice.private, bob.public)
      {:ok, shared_ba} = Crypto.shared_secret(bob.private, alice.public)

      assert shared_ab == shared_ba
      assert byte_size(shared_ab) == 32
    end
  end

  # ============================================================================
  # PKCS7 padding roundtrip
  # ============================================================================

  property "PKCS7 pad/unpad roundtrip for any data" do
    check all(data <- binary(min_length: 0, max_length: 1_000)) do
      padded = Crypto.pkcs7_pad(data, 16)
      assert rem(byte_size(padded), 16) == 0
      assert {:ok, ^data} = Crypto.pkcs7_unpad(padded, 16)
    end
  end

  property "PKCS7 padding adds between 1 and block_size bytes" do
    check all(
            data <- binary(min_length: 0, max_length: 500),
            block_size <- member_of([8, 16, 32])
          ) do
      padded = Crypto.pkcs7_pad(data, block_size)
      pad_amount = byte_size(padded) - byte_size(data)
      assert pad_amount >= 1
      assert pad_amount <= block_size
    end
  end

  # ============================================================================
  # Ed25519 sign/verify roundtrip
  # ============================================================================

  property "Ed25519 sign/verify roundtrip for arbitrary messages" do
    check all(message <- binary(min_length: 0, max_length: 1_000), max_runs: 20) do
      pair = Crypto.generate_key_pair(:ed25519)
      signature = Crypto.ed25519_sign(pair.private, message)
      assert byte_size(signature) == 64
      assert Crypto.ed25519_verify(pair.public, message, signature)
    end
  end
end
