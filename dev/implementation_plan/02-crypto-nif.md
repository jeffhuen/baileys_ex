# Phase 2: Crypto (Pure Elixir / Erlang :crypto)

**Goal:** Implement all cryptographic primitives using Erlang's built-in `:crypto`
module and pure Elixir. **No Rust NIF needed** — OTP 28's `:crypto` covers everything.

**Depends on:** Phase 1 (Foundation)
**Parallel with:** Phase 3 (Protocol Layer), Phase 4 (Noise NIF), Phase 5 (Signal NIF)
**Blocks:** Phase 7 (Auth), Phase 9 (Media)

---

## Design Decisions

**Why NOT a Rust NIF for crypto?**
Erlang's `:crypto` module (backed by OpenSSL/LibreSSL) natively supports all 12
operations we need. It's battle-tested, zero-dependency, and avoids NIF boundary
overhead. Rust NIFs are reserved for crates that have no Elixir/Erlang equivalent
(Signal protocol, Noise protocol).

**HKDF is the only gap.**
`:crypto` doesn't expose HKDF directly, but it's trivially implemented as two
rounds of HMAC (extract + expand per RFC 5869). We implement it in pure Elixir
using `:crypto.mac/4`.

---

## Tasks

### 2.1 Core crypto module

File: `lib/baileys_ex/crypto.ex`

```elixir
defmodule BaileysEx.Crypto do
  @moduledoc "Cryptographic primitives wrapping Erlang :crypto"

  # --- AES ---

  def aes_gcm_encrypt(key, iv, plaintext, aad \\ <<>>) do
    {ciphertext, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, aad, true)
    {:ok, ciphertext <> tag}
  end

  def aes_gcm_decrypt(key, iv, ciphertext_with_tag, aad \\ <<>>) do
    tag_size = 16
    ciphertext_size = byte_size(ciphertext_with_tag) - tag_size
    <<ciphertext::binary-size(ciphertext_size), tag::binary-size(tag_size)>> = ciphertext_with_tag
    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, aad, tag, false) do
      :error -> {:error, :decrypt_failed}
      plaintext -> {:ok, plaintext}
    end
  end

  def aes_cbc_encrypt(key, iv, plaintext) do
    {:ok, :crypto.crypto_one_time(:aes_256_cbc, key, iv, plaintext, encrypt: true, padding: :pkcs_padding)}
  end

  def aes_cbc_decrypt(key, iv, ciphertext) do
    {:ok, :crypto.crypto_one_time(:aes_256_cbc, key, iv, ciphertext, encrypt: false, padding: :pkcs_padding)}
  rescue
    _ -> {:error, :decrypt_failed}
  end

  def aes_ctr_encrypt(key, iv, plaintext) do
    {:ok, :crypto.crypto_one_time(:aes_256_ctr, key, iv, plaintext, true)}
  end

  def aes_ctr_decrypt(key, iv, ciphertext) do
    {:ok, :crypto.crypto_one_time(:aes_256_ctr, key, iv, ciphertext, false)}
  end

  # --- Hashing ---

  def sha256(data), do: :crypto.hash(:sha256, data)
  def md5(data), do: :crypto.hash(:md5, data)

  # --- HMAC ---

  def hmac_sha256(key, data), do: :crypto.mac(:hmac, :sha256, key, data)
  def hmac_sha512(key, data), do: :crypto.mac(:hmac, :sha512, key, data)

  # --- HKDF (RFC 5869 — pure Elixir using :crypto HMAC) ---

  def hkdf(ikm, info, length, salt \\ <<>>) do
    prk = hkdf_extract(salt, ikm)
    {:ok, hkdf_expand(prk, info, length)}
  end

  defp hkdf_extract(<<>>, ikm), do: :crypto.mac(:hmac, :sha256, <<0::256>>, ikm)
  defp hkdf_extract(salt, ikm), do: :crypto.mac(:hmac, :sha256, salt, ikm)

  defp hkdf_expand(prk, info, length) do
    hash_len = 32  # SHA-256 output
    n = ceil(length / hash_len)

    {okm, _} =
      Enum.reduce(1..n, {<<>>, <<>>}, fn i, {acc, prev} ->
        t = :crypto.mac(:hmac, :sha256, prk, prev <> info <> <<i>>)
        {acc <> t, t}
      end)

    binary_part(okm, 0, length)
  end

  # --- Key Derivation ---

  def pbkdf2_sha256(password, salt, iterations, length) do
    {:ok, :crypto.pbkdf2_hmac(:sha256, password, salt, iterations, length)}
  end

  # --- Curve25519 / Ed25519 ---

  def generate_key_pair(:x25519) do
    {pub, priv} = :crypto.generate_key(:ecdh, :x25519)
    %{public: pub, private: priv}
  end

  def generate_key_pair(:ed25519) do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    %{public: pub, private: priv}
  end

  def shared_secret(my_private, their_public) do
    {:ok, :crypto.compute_key(:ecdh, their_public, my_private, :x25519)}
  end

  def ed25519_sign(private_key, message) do
    :crypto.sign(:eddsa, :none, message, [private_key, :ed25519])
  end

  def ed25519_verify(public_key, message, signature) do
    :crypto.verify(:eddsa, :none, message, signature, [public_key, :ed25519])
  end

  # --- Random ---

  def random_bytes(n), do: :crypto.strong_rand_bytes(n)

  # --- WhatsApp-specific helpers ---

  @doc "Generate a signed key pair for Signal protocol"
  def signed_key_pair(identity_key) do
    key_pair = generate_key_pair(:x25519)
    signature = ed25519_sign(identity_key.private, key_pair.public)
    %{public: key_pair.public, private: key_pair.private, signature: signature}
  end

  @doc "Expand media key using HKDF (32 bytes → 112 bytes)"
  def expand_media_key(media_key, media_type) do
    info = media_hkdf_info(media_type)
    {:ok, expanded} = hkdf(media_key, info, 112)
    <<iv::binary-16, cipher_key::binary-32, mac_key::binary-32, ref_key::binary-32>> = expanded
    %{iv: iv, cipher_key: cipher_key, mac_key: mac_key, ref_key: ref_key}
  end

  defp media_hkdf_info(:image), do: "WhatsApp Image Keys"
  defp media_hkdf_info(:video), do: "WhatsApp Video Keys"
  defp media_hkdf_info(:audio), do: "WhatsApp Audio Keys"
  defp media_hkdf_info(:document), do: "WhatsApp Document Keys"
  defp media_hkdf_info(:sticker), do: "WhatsApp Image Keys"
end
```

### 2.2 Test with known test vectors

File: `test/baileys_ex/crypto_test.exs`

- AES-GCM: NIST test vectors
- AES-CBC: NIST test vectors
- HMAC-SHA256: RFC 4231 test vectors
- HKDF: RFC 5869 test vectors
- Curve25519: RFC 7748 test vectors
- Ed25519: RFC 8032 test vectors
- PBKDF2: RFC 6070 test vectors
- Media crypto: test vectors derived from Baileys (encrypt with Baileys, decrypt with BaileysEx)

### 2.3 Property-based tests

File: `test/baileys_ex/crypto_property_test.exs`

```elixir
property "AES-GCM roundtrip" do
  check all key <- binary(length: 32),
            iv <- binary(length: 12),
            plaintext <- binary(min_length: 1, max_length: 10_000),
            aad <- binary(min_length: 0, max_length: 100) do
    {:ok, ciphertext} = Crypto.aes_gcm_encrypt(key, iv, plaintext, aad)
    assert {:ok, ^plaintext} = Crypto.aes_gcm_decrypt(key, iv, ciphertext, aad)
  end
end

property "HKDF produces correct length output" do
  check all ikm <- binary(length: 32),
            info <- binary(min_length: 0, max_length: 64),
            length <- integer(1..255) do
    {:ok, output} = Crypto.hkdf(ikm, info, length)
    assert byte_size(output) == length
  end
end
```

---

## Acceptance Criteria

- [ ] All crypto functions work with Erlang `:crypto` (no NIF dependency)
- [ ] NIST/RFC test vectors pass for every algorithm
- [ ] HKDF implementation matches RFC 5869 test vectors
- [ ] Property-based roundtrip tests pass
- [ ] Typespecs on all public functions
- [ ] `mix test test/baileys_ex/crypto_test.exs` passes
- [ ] Media key expansion matches Baileys output for same input

## Files Created/Modified

- `lib/baileys_ex/crypto.ex` — All crypto primitives (pure Elixir + :crypto)
- `test/baileys_ex/crypto_test.exs` — Test vector tests
- `test/baileys_ex/crypto_property_test.exs` — Property tests
