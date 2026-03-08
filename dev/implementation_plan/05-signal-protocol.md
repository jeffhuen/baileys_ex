# Phase 5: Signal Protocol (redesign around libsignal-protocol NIF)

> **Status note:** This phase document is not source-of-truth yet. The detailed task
> breakdown below predates the repo's current "wrap, don't reimplement" direction and
> should be treated as historical research, not an approved implementation recipe.
> Before Phase 5 starts, rewrite this phase around a `libsignal-protocol` (or
> equivalent) Rustler wrapper that matches Baileys' `src/Signal/libsignal.ts`
> behavior and also exposes the verification primitive Phase 4 needs for Noise
> certificate validation.

**Goal:** Provide a Signal layer backed by a battle-tested native implementation,
keeping persistence, orchestration, and BEAM concurrency in Elixir.

**Depends on:** Phase 1 (Foundation), Phase 2 (Crypto)
**Parallel with:** Phase 4 (Noise NIF)
**Blocks:** Phase 7 (Auth), Phase 8 (Messaging)

---

## Historical Draft Architecture

This section describes the older pure-Elixir draft. Keep it only as background
research until the phase is rewritten around the libsignal-backed approach above.

**No process needed.** Signal operations are stateless functions that take session
state as structs and return updated structs. The connection Store (GenServer + ETS)
handles persistence. Session updates are serialized through the Store's GenServer
to prevent ratchet state corruption from concurrent operations.

---

## Task 5.1: XEdDSA NIF

### Why this NIF exists

WhatsApp identity keys are Curve25519 (Montgomery form). The same key must be used
for BOTH Diffie-Hellman key exchange AND signing (signed pre-keys, sender key messages).
This requires XEdDSA — converting Montgomery keys to Edwards form for signing.

Erlang `:crypto` does Ed25519 and X25519 separately but cannot convert between the
key forms. This is the ONLY operation that requires native code.

### Rust implementation

File: `native/baileys_nif/src/xeddsa.rs` (~80 lines)

```rust
use curve25519_dalek::constants::ED25519_BASEPOINT_POINT;
use curve25519_dalek::edwards::CompressedEdwardsY;
use curve25519_dalek::montgomery::MontgomeryPoint;
use curve25519_dalek::scalar::Scalar;
use rustler::Binary;
use sha2::{Digest, Sha512};

/// XEdDSA sign: produce Ed25519-compatible signature using Curve25519 private key
/// Spec: https://signal.org/docs/specifications/xeddsa/
#[rustler::nif]
fn xeddsa_sign(private_key: Binary, message: Binary) -> Result<Binary, String> {
    // private_key: 32-byte Curve25519 private scalar
    // message: arbitrary bytes to sign
    // returns: 64-byte signature (R || S)

    let privkey: [u8; 32] = private_key.as_slice().try_into()
        .map_err(|_| "private key must be 32 bytes")?;

    let a = Scalar::from_bytes_mod_order(privkey);
    let big_a = &a * &ED25519_BASEPOINT_POINT;

    // Check sign bit and conditionally negate (calculate_key_pair from spec)
    let (a_adj, big_a_adj) = if big_a.compress().as_bytes()[31] & 0x80 != 0 {
        (-a, -big_a)
    } else {
        (a, big_a)
    };

    let big_a_bytes = big_a_adj.compress().to_bytes();

    // Randomized nonce (XEdDSA uses random Z, not deterministic like Ed25519)
    let mut random_bytes = [0u8; 64];
    getrandom::fill(&mut random_bytes).map_err(|e| e.to_string())?;

    // r = SHA-512(0xFE || a || msg || Z) mod q
    let nonce_hash = Sha512::new()
        .chain_update([0xFE_u8])  // XEdDSA domain separator
        .chain_update(a_adj.as_bytes())
        .chain_update(message.as_slice())
        .chain_update(&random_bytes)
        .finalize();
    let r = Scalar::from_bytes_mod_order_wide(&nonce_hash.into());

    // R = r * B
    let big_r = &r * &ED25519_BASEPOINT_POINT;
    let big_r_bytes = big_r.compress().to_bytes();

    // h = SHA-512(R || A || msg) mod q
    let h_hash = Sha512::new()
        .chain_update(&big_r_bytes)
        .chain_update(&big_a_bytes)
        .chain_update(message.as_slice())
        .finalize();
    let h = Scalar::from_bytes_mod_order_wide(&h_hash.into());

    // s = r + h * a mod q
    let s = r + h * a_adj;

    // signature = R || s
    let mut sig = [0u8; 64];
    sig[..32].copy_from_slice(&big_r_bytes);
    sig[32..].copy_from_slice(s.as_bytes());
    Ok(sig.to_vec().into())
}

/// XEdDSA verify: verify Ed25519-compatible signature against Curve25519 public key
#[rustler::nif]
fn xeddsa_verify(public_key: Binary, message: Binary, signature: Binary) -> bool {
    // public_key: 32-byte Curve25519 public key (Montgomery u-coordinate)
    // Conversion: y = (u - 1) / (u + 1) mod p (birational map)

    let pubkey: [u8; 32] = match public_key.as_slice().try_into() {
        Ok(k) => k,
        Err(_) => return false,
    };
    let sig: [u8; 64] = match signature.as_slice().try_into() {
        Ok(s) => s,
        Err(_) => return false,
    };

    // Montgomery → Edwards conversion (sign bit = 0)
    let mont_point = MontgomeryPoint(pubkey);
    let big_a = match mont_point.to_edwards(0) {
        Some(point) => point,
        None => return false,
    };
    let big_a_bytes = big_a.compress().to_bytes();

    let big_r_bytes: [u8; 32] = sig[..32].try_into().unwrap();
    let s_bytes: [u8; 32] = sig[32..].try_into().unwrap();

    let big_r = match CompressedEdwardsY(big_r_bytes).decompress() {
        Some(point) => point,
        None => return false,
    };
    let s = match Scalar::from_canonical_bytes(s_bytes).into() {
        Some(scalar) => scalar,
        None => return false,
    };

    // h = SHA-512(R || A || msg) mod q
    let h_hash = Sha512::new()
        .chain_update(&big_r_bytes)
        .chain_update(&big_a_bytes)
        .chain_update(message.as_slice())
        .finalize();
    let h = Scalar::from_bytes_mod_order_wide(&h_hash.into());

    // Verify: s*B == R + h*A
    let check = &s * &ED25519_BASEPOINT_POINT - &h * &big_a;
    check == big_r
}
```

### Cargo.toml additions

```toml
curve25519-dalek = { version = "4", features = ["digest"] }
sha2 = "0.10"
getrandom = "0.2"
```

**Crate justification:**
- `curve25519-dalek` — 35M+ downloads, maintained by dalek-cryptography org, used by Tor/Zcash
- `sha2` — 25M+ downloads, RustCrypto project
- `getrandom` — 117M+ downloads, standard random source

### Elixir wrapper

File: `lib/baileys_ex/native/xeddsa.ex`

```elixir
defmodule BaileysEx.Native.XEdDSA do
  use Rustler, otp_app: :baileys_ex, crate: "baileys_nif"

  @spec sign(binary(), binary()) :: {:ok, binary()} | {:error, String.t()}
  def sign(_private_key, _message), do: :erlang.nif_error(:nif_not_loaded)

  @spec verify(binary(), binary(), binary()) :: boolean()
  def verify(_public_key, _message, _signature), do: :erlang.nif_error(:nif_not_loaded)
end
```

### Tests

- Sign/verify roundtrip with randomly generated Curve25519 keys
- Cross-validate: sign in Rust NIF, verify with Baileys (and vice versa)
- Known test vectors from XEdDSA spec
- Invalid signature rejection
- Wrong key rejection
- 32-byte key enforcement

---

## Task 5.2: Signal Crypto Helpers

File: extend `lib/baileys_ex/crypto.ex`

Add Signal-specific key derivation functions:

```elixir
# --- Signal Protocol KDFs ---

@doc """
KDF_CK: derive message key and next chain key from current chain key.
Used in both 1:1 Double Ratchet and Group Sender Keys.
  - message_key = HMAC-SHA256(chain_key, <<0x01>>)
  - next_chain_key = HMAC-SHA256(chain_key, <<0x02>>)
"""
def kdf_ck(chain_key) do
  message_key = hmac_sha256(chain_key, <<0x01>>)
  next_chain_key = hmac_sha256(chain_key, <<0x02>>)
  {next_chain_key, message_key}
end

@doc """
KDF_RK: root key derivation for Double Ratchet DH ratchet step.
  HKDF(dh_output, salt: root_key, info: "WhisperRatchet") → 64 bytes
  First 32 bytes = new root key, last 32 bytes = new chain key.
"""
def kdf_rk(root_key, dh_output) do
  {:ok, output} = hkdf(dh_output, "WhisperRatchet", 64, root_key)
  <<new_root_key::binary-32, new_chain_key::binary-32>> = output
  {new_root_key, new_chain_key}
end

@doc """
Derive group message key (IV + cipher key) from chain key derivative.
  HKDF(seed, salt: 32_zero_bytes, info: "WhisperGroup") → 64 bytes
  bytes 0-15 = IV
  bytes 16-47 = cipher key (assembled across HKDF output blocks)
  bytes 48-63 = discarded
"""
def derive_group_message_key(seed) do
  {:ok, output} = hkdf(seed, "WhisperGroup", 48, <<0::256>>)
  <<iv::binary-16, cipher_key::binary-32>> = output
  %{iv: iv, cipher_key: cipher_key}
end

@doc """
Derive message keys for 1:1 encryption from the raw message key.
  HKDF(message_key, salt: 32_zero_bytes, info: "WhisperMessageKeys") → 80 bytes
  bytes 0-31 = AES-CBC cipher key
  bytes 32-47 = HMAC-SHA256 MAC key
  bytes 48-63 = AES-CBC IV
  bytes 64-79 = discarded (in some implementations)
NOTE: Exact split may differ — cross-validate with Baileys.
"""
def derive_message_keys(message_key) do
  {:ok, output} = hkdf(message_key, "WhisperMessageKeys", 80, <<0::256>>)
  <<cipher_key::binary-32, mac_key::binary-32, iv::binary-16>> = output
  %{cipher_key: cipher_key, mac_key: mac_key, iv: iv}
end

@doc """
Curve25519 key pair generation, matching Baileys format.
Returns %{public: <<32 bytes>>, private: <<32 bytes>>}
(public key WITHOUT 0x05 prefix — prefix added only for wire format)
"""
def generate_curve25519_key_pair do
  {pub, priv} = :crypto.generate_key(:ecdh, :x25519)
  %{public: pub, private: priv}
end

@doc "Curve25519 ECDH shared secret"
def curve25519_dh(my_private, their_public) do
  :crypto.compute_key(:ecdh, their_public, my_private, :x25519)
end

@doc "Prepend 0x05 version byte to 32-byte Curve25519 public key"
def signal_pub_key(<<5, _::binary-32>> = key), do: key
def signal_pub_key(<<key::binary-32>>), do: <<5, key::binary>>
```

---

## Task 5.3: X3DH Key Agreement

File: `lib/baileys_ex/signal/x3dh.ex` (~120 lines)

Reference: https://signal.org/docs/specifications/x3dh/

### Data structures

```elixir
defmodule BaileysEx.Signal.X3DH do
  @moduledoc """
  X3DH (Extended Triple Diffie-Hellman) key agreement.

  Establishes a shared secret between initiator (Alice) and responder (Bob)
  using Bob's pre-key bundle published on the server.
  """

  @type pre_key_bundle :: %{
    registration_id: non_neg_integer(),
    identity_key: binary(),       # 32-byte Curve25519 public key
    signed_pre_key: %{
      key_id: non_neg_integer(),
      public: binary(),           # 32-byte Curve25519 public key
      signature: binary()         # 64-byte XEdDSA signature
    },
    pre_key: %{                   # optional one-time pre-key
      key_id: non_neg_integer(),
      public: binary()
    } | nil
  }
end
```

### Algorithm

```elixir
@doc """
Initiate X3DH session from a pre-key bundle (Alice's perspective).

1. Verify signed pre-key signature using XEdDSA
2. Generate ephemeral key pair
3. Compute 3 or 4 DH operations
4. Derive shared secret via HKDF
5. Return initial Double Ratchet state

Returns {:ok, %{session_state, ephemeral_key}} or {:error, reason}
"""
def initiate(our_identity, bundle) do
  # Verify signed pre-key signature (XEdDSA)
  spk_pub_with_prefix = Crypto.signal_pub_key(bundle.signed_pre_key.public)
  unless Native.XEdDSA.verify(
    bundle.identity_key,
    spk_pub_with_prefix,
    bundle.signed_pre_key.signature
  ) do
    {:error, :invalid_signature}
  end

  # Generate ephemeral key pair
  ephemeral = Crypto.generate_curve25519_key_pair()

  # DH1 = DH(IK_A, SPK_B) — our identity, their signed pre-key
  dh1 = Crypto.curve25519_dh(our_identity.private, bundle.signed_pre_key.public)

  # DH2 = DH(EK_A, IK_B) — our ephemeral, their identity
  dh2 = Crypto.curve25519_dh(ephemeral.private, bundle.identity_key)

  # DH3 = DH(EK_A, SPK_B) — our ephemeral, their signed pre-key
  dh3 = Crypto.curve25519_dh(ephemeral.private, bundle.signed_pre_key.public)

  # DH4 = DH(EK_A, OPK_B) — our ephemeral, their one-time pre-key (if exists)
  dh4 = if bundle.pre_key, do: Crypto.curve25519_dh(ephemeral.private, bundle.pre_key.public)

  # Concatenate DH results
  dh_concat = if dh4, do: dh1 <> dh2 <> dh3 <> dh4, else: dh1 <> dh2 <> dh3

  # Derive shared secret
  # HKDF with info="WhisperText", salt=not specified (empty or zeros — verify with Baileys)
  {:ok, shared_secret} = Crypto.hkdf(dh_concat, "WhisperText", 32)

  # Build initial Double Ratchet state
  session = Ratchet.init_as_alice(
    shared_secret,
    our_identity,
    ephemeral,
    bundle
  )

  {:ok, %{
    session: session,
    ephemeral_key: ephemeral,
    pre_key_id: bundle.pre_key && bundle.pre_key.key_id,
    signed_pre_key_id: bundle.signed_pre_key.key_id,
    registration_id: bundle.registration_id
  }}
end
```

---

## Task 5.4: Double Ratchet

File: `lib/baileys_ex/signal/ratchet.ex` (~300 lines)

Reference: https://signal.org/docs/specifications/doubleratchet/

### Session state struct

```elixir
defmodule BaileysEx.Signal.Ratchet do
  @max_skip 2000  # max skipped message keys to store

  defmodule State do
    @type t :: %__MODULE__{
      dh_self: %{public: binary(), private: binary()},  # our current ratchet key pair
      dh_remote: binary() | nil,      # their current ratchet public key
      root_key: binary(),             # 32-byte root key
      chain_key_send: binary() | nil, # 32-byte sending chain key
      chain_key_recv: binary() | nil, # 32-byte receiving chain key
      n_send: non_neg_integer(),      # message number (sending)
      n_recv: non_neg_integer(),      # message number (receiving)
      pn: non_neg_integer(),          # previous sending chain length
      skipped: %{{binary(), non_neg_integer()} => binary()},  # {dh_pub, n} => message_key
      our_identity_key: %{public: binary(), private: binary()},
      their_identity_key: binary(),
      registration_id: non_neg_integer()
    }

    defstruct [
      :dh_self, :dh_remote, :root_key,
      :chain_key_send, :chain_key_recv,
      :our_identity_key, :their_identity_key,
      :registration_id,
      n_send: 0, n_recv: 0, pn: 0,
      skipped: %{}
    ]
  end
end
```

### Init as Alice (after X3DH)

```elixir
def init_as_alice(shared_secret, our_identity, our_ephemeral, bundle) do
  # Alice performs an immediate DH ratchet step
  dh_self = Crypto.generate_curve25519_key_pair()
  dh_output = Crypto.curve25519_dh(dh_self.private, bundle.signed_pre_key.public)
  {root_key, chain_key_send} = Crypto.kdf_rk(shared_secret, dh_output)

  %State{
    dh_self: dh_self,
    dh_remote: bundle.signed_pre_key.public,
    root_key: root_key,
    chain_key_send: chain_key_send,
    chain_key_recv: nil,
    our_identity_key: our_identity,
    their_identity_key: bundle.identity_key,
    registration_id: bundle.registration_id
  }
end
```

### Encrypt

```elixir
@doc "Encrypt a plaintext message using the current session state."
def encrypt(%State{} = state, plaintext) do
  # Step sending chain key
  {next_ck, message_key} = Crypto.kdf_ck(state.chain_key_send)

  # Derive encryption keys from message key
  keys = Crypto.derive_message_keys(message_key)

  # Build WhisperMessage header
  header = %{
    ratchet_key: state.dh_self.public,
    counter: state.n_send,
    previous_counter: state.pn
  }

  # Encrypt: AES-256-CBC
  {:ok, ciphertext} = Crypto.aes_cbc_encrypt(keys.cipher_key, keys.iv, plaintext)

  # Compute MAC
  # MAC input = sender_identity || receiver_identity || version_byte || serialized_header_and_ciphertext
  # MAC is HMAC-SHA256, truncated to 8 bytes
  mac_input = build_mac_input(state, header, ciphertext)
  mac = Crypto.hmac_sha256(keys.mac_key, mac_input) |> binary_part(0, 8)

  # Update state
  new_state = %{state | chain_key_send: next_ck, n_send: state.n_send + 1}

  # Determine message type
  # First message in a session is a PreKeyWhisperMessage
  message_type = if needs_pre_key_message?(state), do: :pkmsg, else: :msg

  {:ok, new_state, %{
    type: message_type,
    header: header,
    ciphertext: ciphertext,
    mac: mac
  }}
end
```

### Decrypt

```elixir
@doc "Decrypt a received message, handling DH ratchet steps and skipped keys."
def decrypt(%State{} = state, header, ciphertext, mac) do
  # Check skipped message keys first
  skip_key = {header.ratchet_key, header.counter}
  case Map.pop(state.skipped, skip_key) do
    {nil, _} ->
      # Not a skipped message — proceed with ratchet
      decrypt_with_ratchet(state, header, ciphertext, mac)

    {message_key, new_skipped} ->
      # Found a skipped key — decrypt directly
      state = %{state | skipped: new_skipped}
      decrypt_with_key(state, message_key, header, ciphertext, mac)
  end
end

defp decrypt_with_ratchet(state, header, ciphertext, mac) do
  state =
    if header.ratchet_key != state.dh_remote do
      # New ratchet key — perform DH ratchet step
      state
      |> skip_message_keys(header.previous_counter)
      |> dh_ratchet_step(header.ratchet_key)
    else
      state
    end

  # Skip any missed messages in current chain
  state = skip_message_keys(state, header.counter)

  # Step receiving chain key
  {next_ck, message_key} = Crypto.kdf_ck(state.chain_key_recv)
  state = %{state | chain_key_recv: next_ck, n_recv: state.n_recv + 1}

  decrypt_with_key(state, message_key, header, ciphertext, mac)
end

defp dh_ratchet_step(state, their_new_key) do
  # Receive ratchet
  dh_output = Crypto.curve25519_dh(state.dh_self.private, their_new_key)
  {root_key, chain_key_recv} = Crypto.kdf_rk(state.root_key, dh_output)

  # Send ratchet
  dh_self = Crypto.generate_curve25519_key_pair()
  dh_output = Crypto.curve25519_dh(dh_self.private, their_new_key)
  {root_key, chain_key_send} = Crypto.kdf_rk(root_key, dh_output)

  %{state |
    dh_self: dh_self,
    dh_remote: their_new_key,
    root_key: root_key,
    chain_key_send: chain_key_send,
    chain_key_recv: chain_key_recv,
    pn: state.n_send,
    n_send: 0,
    n_recv: 0
  }
end

defp skip_message_keys(state, until) when state.n_recv >= until, do: state
defp skip_message_keys(state, until) do
  if until - state.n_recv > @max_skip do
    raise "Too many skipped messages"
  end

  Enum.reduce(state.n_recv..(until - 1), state, fn _n, state ->
    {next_ck, mk} = Crypto.kdf_ck(state.chain_key_recv)
    skip_key = {state.dh_remote, state.n_recv}
    %{state |
      chain_key_recv: next_ck,
      n_recv: state.n_recv + 1,
      skipped: Map.put(state.skipped, skip_key, mk)
    }
  end)
end

defp decrypt_with_key(state, message_key, header, ciphertext, mac) do
  keys = Crypto.derive_message_keys(message_key)

  # Verify MAC
  expected_mac_input = build_mac_input(state, header, ciphertext)
  expected_mac = Crypto.hmac_sha256(keys.mac_key, expected_mac_input) |> binary_part(0, 8)

  if mac != expected_mac do
    {:error, :bad_mac}
  else
    case Crypto.aes_cbc_decrypt(keys.cipher_key, keys.iv, ciphertext) do
      {:ok, plaintext} -> {:ok, state, plaintext}
      {:error, _} -> {:error, :decrypt_failed}
    end
  end
end
```

---

## Task 5.5: Session Management

File: `lib/baileys_ex/signal/session.ex` (~200 lines)

### Session record (multiple sessions per peer)

```elixir
defmodule BaileysEx.Signal.Session do
  @moduledoc """
  Manages multiple Double Ratchet sessions per peer.

  Each peer can have multiple sessions (e.g., when both sides send initial
  messages simultaneously). Only one is "active" — the most recent.
  Old sessions are kept to decrypt late-arriving messages.
  """

  @max_sessions 40

  defstruct sessions: [],    # list of {session_id, Ratchet.State}
            active_id: nil   # session_id of the active session

  @doc "Check if any open session exists"
  def has_open_session?(%__MODULE__{sessions: []}), do: false
  def has_open_session?(_), do: true

  @doc "Get the active session state"
  def get_active(%__MODULE__{sessions: sessions, active_id: id}) do
    Enum.find_value(sessions, fn
      {^id, state} -> state
      _ -> nil
    end)
  end

  @doc "Update the active session state"
  def put_active(record, state) do
    sessions = Enum.map(record.sessions, fn
      {id, _} when id == record.active_id -> {id, state}
      other -> other
    end)
    %{record | sessions: sessions}
  end

  @doc "Add a new session, making it active"
  def add_session(record, session_id, state) do
    sessions = [{session_id, state} | record.sessions]
    sessions = if length(sessions) > @max_sessions do
      Enum.take(sessions, @max_sessions)
    else
      sessions
    end
    %{record | sessions: sessions, active_id: session_id}
  end

  @doc "Serialize session record for persistence"
  def serialize(%__MODULE__{} = record) do
    :erlang.term_to_binary(record)
  end

  @doc "Deserialize session record"
  def deserialize(binary) when is_binary(binary) do
    :erlang.binary_to_term(binary)
  end
end
```

---

## Task 5.6: Session Cipher (orchestrator)

File: `lib/baileys_ex/signal/session_cipher.ex` (~180 lines)

```elixir
defmodule BaileysEx.Signal.SessionCipher do
  @moduledoc """
  High-level encrypt/decrypt that orchestrates sessions and ratchets.
  This is the equivalent of libsignal's SessionCipher.
  """

  alias BaileysEx.Signal.{Session, Ratchet, Proto}

  @doc "Encrypt data for a peer. Returns {:ok, type, ciphertext} or {:error, reason}"
  def encrypt(session_record, data) do
    state = Session.get_active(session_record)
    {:ok, new_state, encrypted} = Ratchet.encrypt(state, data)
    session_record = Session.put_active(session_record, new_state)

    # Serialize to wire format
    whisper_msg = Proto.encode_whisper_message(encrypted)

    case encrypted.type do
      :pkmsg ->
        pkmsg = Proto.encode_pre_key_whisper_message(new_state, whisper_msg)
        {:ok, session_record, :pkmsg, pkmsg}

      :msg ->
        {:ok, session_record, :msg, whisper_msg}
    end
  end

  @doc "Decrypt a PreKeyWhisperMessage (first message in a session)"
  def decrypt_pre_key_message(session_record, store, ciphertext) do
    # Parse PreKeyWhisperMessage
    {:ok, pkmsg} = Proto.decode_pre_key_whisper_message(ciphertext)

    # Build session from the pre-key data
    {:ok, session_record, state} =
      SessionBuilder.process_pre_key_message(session_record, store, pkmsg)

    # Decrypt the embedded WhisperMessage
    {:ok, whisper} = Proto.decode_whisper_message(pkmsg.message)
    {:ok, new_state, plaintext} =
      Ratchet.decrypt(state, whisper.header, whisper.ciphertext, whisper.mac)

    session_record = Session.put_active(session_record, new_state)
    {:ok, session_record, plaintext}
  end

  @doc "Decrypt a regular WhisperMessage"
  def decrypt_message(session_record, ciphertext) do
    {:ok, whisper} = Proto.decode_whisper_message(ciphertext)
    state = Session.get_active(session_record)

    {:ok, new_state, plaintext} =
      Ratchet.decrypt(state, whisper.header, whisper.ciphertext, whisper.mac)

    session_record = Session.put_active(session_record, new_state)
    {:ok, session_record, plaintext}
  end
end
```

---

## Task 5.7: Session Builder

File: `lib/baileys_ex/signal/session_builder.ex` (~120 lines)

```elixir
defmodule BaileysEx.Signal.SessionBuilder do
  @moduledoc """
  Establishes new sessions from pre-key bundles (outgoing)
  and from incoming PreKeyWhisperMessages.
  """

  @doc """
  Initialize outgoing session from a pre-key bundle fetched from the server.
  This is called when we want to send to someone for the first time.
  Equivalent to libsignal.SessionBuilder.initOutgoing().
  """
  def init_outgoing(session_record, our_identity, bundle) do
    {:ok, x3dh_result} = X3DH.initiate(our_identity, bundle)
    session_id = :crypto.strong_rand_bytes(16)
    Session.add_session(session_record, session_id, x3dh_result.session)
  end

  @doc """
  Process an incoming PreKeyWhisperMessage to establish a session.
  Performs the Bob-side X3DH computation.
  """
  def process_pre_key_message(session_record, store, pkmsg) do
    # Load our keys
    our_identity = store.get_identity_key_pair()
    our_signed_pre_key = store.get_signed_pre_key(pkmsg.signed_pre_key_id)
    our_pre_key = if pkmsg.pre_key_id, do: store.get_pre_key(pkmsg.pre_key_id)

    # Bob-side X3DH
    # DH1 = DH(SPK_B, IK_A)
    dh1 = Crypto.curve25519_dh(our_signed_pre_key.private, pkmsg.identity_key)
    # DH2 = DH(IK_B, EK_A)
    dh2 = Crypto.curve25519_dh(our_identity.private, pkmsg.base_key)
    # DH3 = DH(SPK_B, EK_A)
    dh3 = Crypto.curve25519_dh(our_signed_pre_key.private, pkmsg.base_key)
    # DH4 = DH(OPK_B, EK_A) if pre-key was used
    dh4 = if our_pre_key, do: Crypto.curve25519_dh(our_pre_key.private, pkmsg.base_key)

    dh_concat = if dh4, do: dh1 <> dh2 <> dh3 <> dh4, else: dh1 <> dh2 <> dh3
    {:ok, shared_secret} = Crypto.hkdf(dh_concat, "WhisperText", 32)

    # Initialize session as Bob
    state = Ratchet.init_as_bob(shared_secret, our_identity, our_signed_pre_key, pkmsg)

    # Consume one-time pre-key
    if pkmsg.pre_key_id, do: store.remove_pre_key(pkmsg.pre_key_id)

    session_id = :crypto.strong_rand_bytes(16)
    session_record = Session.add_session(session_record, session_id, state)

    {:ok, session_record, state}
  end
end
```

---

## Task 5.8: Group Messaging (Sender Keys)

Port directly from Baileys TypeScript (`src/Signal/Group/`).

### Files:

```
lib/baileys_ex/signal/group/
├── sender_chain_key.ex                  # Chain key ratcheting (~40 lines)
├── sender_message_key.ex                # Message key derivation (~30 lines)
├── sender_key_state.ex                  # Per-session state (~80 lines)
├── sender_key_record.ex                 # Multi-state container (~60 lines)
├── sender_key_message.ex                # Encrypted message envelope (~60 lines)
├── sender_key_distribution_message.ex   # Key distribution message (~40 lines)
├── group_cipher.ex                      # High-level encrypt/decrypt (~100 lines)
└── group_session.ex                     # Session create/process (~50 lines)
```

### Key constants (from Baileys):

```elixir
@current_version 3
@version_byte ((@current_version <<< 4) ||| @current_version) &&& 0xFF  # 0x33
@message_key_seed <<0x01>>
@chain_key_seed <<0x02>>
@max_message_keys 2000
@max_states 5
@signature_length 64
@key_prefix <<0x05>>  # Curve25519 public key version byte
```

### SenderChainKey

```elixir
defmodule BaileysEx.Signal.Group.SenderChainKey do
  defstruct [:iteration, :seed]

  def message_key(%__MODULE__{seed: seed, iteration: iteration}) do
    derivative = Crypto.hmac_sha256(seed, <<0x01>>)
    SenderMessageKey.new(iteration, derivative)
  end

  def next(%__MODULE__{seed: seed, iteration: iteration}) do
    next_seed = Crypto.hmac_sha256(seed, <<0x02>>)
    %__MODULE__{iteration: iteration + 1, seed: next_seed}
  end
end
```

### SenderMessageKey

```elixir
defmodule BaileysEx.Signal.Group.SenderMessageKey do
  defstruct [:iteration, :iv, :cipher_key, :seed]

  def new(iteration, seed) do
    %{iv: iv, cipher_key: cipher_key} = Crypto.derive_group_message_key(seed)
    %__MODULE__{iteration: iteration, iv: iv, cipher_key: cipher_key, seed: seed}
  end
end
```

### GroupCipher

```elixir
defmodule BaileysEx.Signal.Group.GroupCipher do
  @doc "Encrypt plaintext for a group using our sender key"
  def encrypt(sender_key_record, plaintext) do
    state = SenderKeyRecord.get_latest_state(sender_key_record)
    chain_key = SenderKeyState.get_chain_key(state)

    # Get target iteration (0 stays at 0, otherwise advance by 1)
    target_iter = if chain_key.iteration == 0, do: 0, else: chain_key.iteration + 1
    {state, message_key} = get_sender_key(state, target_iter)

    # AES-256-CBC encrypt
    {:ok, ciphertext} = Crypto.aes_cbc_encrypt(message_key.cipher_key, message_key.iv, plaintext)

    # Create SenderKeyMessage with XEdDSA signature
    signing_key_private = SenderKeyState.get_signing_key_private(state)
    skm = SenderKeyMessage.new(
      SenderKeyState.get_key_id(state),
      message_key.iteration,
      ciphertext,
      signing_key_private
    )

    # Update record with ratcheted chain key
    sender_key_record = SenderKeyRecord.update_state(sender_key_record, state)
    {:ok, sender_key_record, SenderKeyMessage.serialize(skm)}
  end

  @doc "Decrypt a group message from a peer"
  def decrypt(sender_key_record, sender_key_message_bytes) do
    skm = SenderKeyMessage.deserialize(sender_key_message_bytes)
    state = SenderKeyRecord.get_state_by_id(sender_key_record, skm.key_id)

    # Verify XEdDSA signature
    signing_key_public = SenderKeyState.get_signing_key_public(state)
    unless SenderKeyMessage.verify_signature(skm, signing_key_public) do
      {:error, :invalid_signature}
    end

    {state, message_key} = get_sender_key(state, skm.iteration)

    # AES-256-CBC decrypt
    {:ok, plaintext} = Crypto.aes_cbc_decrypt(message_key.cipher_key, message_key.iv, skm.ciphertext)

    sender_key_record = SenderKeyRecord.update_state(sender_key_record, state)
    {:ok, sender_key_record, plaintext}
  end

  # Ratchet chain key forward to target iteration, caching intermediate keys
  defp get_sender_key(state, target_iteration) do
    chain_key = SenderKeyState.get_chain_key(state)
    current = chain_key.iteration

    cond do
      current > target_iteration ->
        # Out of order — check cached keys
        case SenderKeyState.remove_message_key(state, target_iteration) do
          {:ok, state, message_key} -> {state, message_key}
          :error -> raise "Old counter: #{target_iteration} < #{current}"
        end

      target_iteration - current > @max_message_keys ->
        raise "Over #{@max_message_keys} messages into the future!"

      true ->
        # Ratchet forward, caching intermediate keys
        {state, _chain_key} =
          Enum.reduce(current..(target_iteration - 1), {state, chain_key}, fn _i, {state, ck} ->
            mk = SenderChainKey.message_key(ck)
            state = SenderKeyState.add_message_key(state, mk)
            {state, SenderChainKey.next(ck)}
          end)

        # Get the target key
        chain_key = SenderKeyState.get_chain_key(state)
        message_key = SenderChainKey.message_key(chain_key)
        state = SenderKeyState.set_chain_key(state, SenderChainKey.next(chain_key))
        {state, message_key}
    end
  end
end
```

### SenderKeyMessage wire format

```elixir
defmodule BaileysEx.Signal.Group.SenderKeyMessage do
  @version_byte 0x33
  @signature_length 64

  defstruct [:key_id, :iteration, :ciphertext, :signature, :serialized]

  @doc "Create and sign a new SenderKeyMessage"
  def new(key_id, iteration, ciphertext, signing_key_private) do
    # Encode protobuf
    proto_bytes = Proto.encode_sender_key_message(%{
      id: key_id, iteration: iteration, ciphertext: ciphertext
    })
    message = <<@version_byte, proto_bytes::binary>>

    # XEdDSA signature over version_byte || protobuf
    signature = Native.XEdDSA.sign(signing_key_private, message)

    %__MODULE__{
      key_id: key_id,
      iteration: iteration,
      ciphertext: ciphertext,
      signature: signature,
      serialized: <<message::binary, signature::binary>>
    }
  end

  @doc "Deserialize from wire format"
  def deserialize(<<@version_byte, rest::binary>> = data) do
    proto_size = byte_size(rest) - @signature_length
    <<proto_bytes::binary-size(proto_size), signature::binary-64>> = rest

    decoded = Proto.decode_sender_key_message(proto_bytes)

    %__MODULE__{
      key_id: decoded.id,
      iteration: decoded.iteration,
      ciphertext: decoded.ciphertext,
      signature: signature,
      serialized: data
    }
  end

  def verify_signature(%__MODULE__{serialized: data, signature: sig}, public_key) do
    message = binary_part(data, 0, byte_size(data) - @signature_length)
    # Strip 0x05 prefix if present for XEdDSA verify
    pub = case public_key do
      <<5, key::binary-32>> -> key
      <<key::binary-32>> -> key
    end
    Native.XEdDSA.verify(pub, message, sig)
  end
end
```

---

## Task 5.9: Signal Protobuf Definitions

File: `priv/proto/signal.proto`

These are separate from WAProto.proto — they define the Signal protocol wire format.

```protobuf
syntax = "proto2";
package signal;

message WhisperMessage {
  optional bytes ratchetKey = 1;
  optional uint32 counter = 2;
  optional uint32 previousCounter = 3;
  optional bytes ciphertext = 4;
}

message PreKeyWhisperMessage {
  optional uint32 preKeyId = 1;
  optional bytes baseKey = 2;
  optional bytes identityKey = 3;
  optional bytes message = 4;
  optional uint32 registrationId = 5;
  optional uint32 signedPreKeyId = 6;
}

message SenderKeyMessage {
  optional uint32 id = 1;
  optional uint32 iteration = 2;
  optional bytes ciphertext = 3;
}

message SenderKeyDistributionMessage {
  optional uint32 id = 1;
  optional uint32 iteration = 2;
  optional bytes chainKey = 3;
  optional bytes signingKey = 4;
}
```

Generate Elixir modules via `protox`.

File: `lib/baileys_ex/signal/proto.ex` — wrapper with encode/decode + wire format handling

```elixir
defmodule BaileysEx.Signal.Proto do
  @version_byte 0x33

  @doc "Encode WhisperMessage with version byte and MAC"
  def encode_whisper_message(encrypted) do
    proto = Signal.WhisperMessage.encode(%Signal.WhisperMessage{
      ratchetKey: Crypto.signal_pub_key(encrypted.header.ratchet_key),
      counter: encrypted.header.counter,
      previousCounter: encrypted.header.previous_counter,
      ciphertext: encrypted.ciphertext
    })
    # Wire format: version_byte || proto || mac(8 bytes)
    <<@version_byte, proto::binary, encrypted.mac::binary-8>>
  end

  @doc "Decode WhisperMessage from wire format"
  def decode_whisper_message(<<@version_byte, rest::binary>>) do
    # Last 8 bytes = MAC, rest = protobuf
    proto_size = byte_size(rest) - 8
    <<proto_bytes::binary-size(proto_size), mac::binary-8>> = rest
    decoded = Signal.WhisperMessage.decode(proto_bytes)

    {:ok, %{
      header: %{
        ratchet_key: strip_key_prefix(decoded.ratchetKey),
        counter: decoded.counter,
        previous_counter: decoded.previousCounter
      },
      ciphertext: decoded.ciphertext,
      mac: mac
    }}
  end

  @doc "Encode PreKeyWhisperMessage"
  def encode_pre_key_whisper_message(state, whisper_message_bytes) do
    proto = Signal.PreKeyWhisperMessage.encode(%Signal.PreKeyWhisperMessage{
      registrationId: state.registration_id,
      preKeyId: state.pending_pre_key_id,
      signedPreKeyId: state.signed_pre_key_id,
      baseKey: Crypto.signal_pub_key(state.base_key),
      identityKey: Crypto.signal_pub_key(state.our_identity_key.public),
      message: whisper_message_bytes
    })
    <<@version_byte, proto::binary>>
  end

  @doc "Decode PreKeyWhisperMessage"
  def decode_pre_key_whisper_message(<<version, rest::binary>>) do
    if (version &&& 0x0F) != 3, do: {:error, :unsupported_version}

    decoded = Signal.PreKeyWhisperMessage.decode(rest)
    {:ok, %{
      registration_id: decoded.registrationId,
      pre_key_id: decoded.preKeyId,
      signed_pre_key_id: decoded.signedPreKeyId,
      base_key: strip_key_prefix(decoded.baseKey),
      identity_key: strip_key_prefix(decoded.identityKey),
      message: decoded.message
    }}
  end

  defp strip_key_prefix(<<5, key::binary-32>>), do: key
  defp strip_key_prefix(<<key::binary-32>>), do: key
end
```

---

## Task 5.10: Store Behaviour

File: `lib/baileys_ex/signal/store.ex`

```elixir
defmodule BaileysEx.Signal.Store do
  @moduledoc """
  Behaviour for Signal protocol session and key persistence.
  Default implementation uses the Connection.Store (GenServer + ETS).
  """

  @callback get_identity_key_pair() :: %{public: binary(), private: binary()}
  @callback get_registration_id() :: non_neg_integer()
  @callback get_pre_key(id :: non_neg_integer()) :: %{public: binary(), private: binary()} | nil
  @callback get_signed_pre_key(id :: non_neg_integer()) :: %{public: binary(), private: binary()} | nil
  @callback remove_pre_key(id :: non_neg_integer()) :: :ok
  @callback load_session(address :: String.t()) :: Session.t() | nil
  @callback store_session(address :: String.t(), session :: Session.t()) :: :ok
  @callback load_sender_key(key_name :: String.t()) :: SenderKeyRecord.t() | nil
  @callback store_sender_key(key_name :: String.t(), record :: SenderKeyRecord.t()) :: :ok
  @callback get_identity(address :: String.t()) :: binary() | nil
  @callback save_identity(address :: String.t(), identity_key :: binary()) :: boolean()
  @callback is_trusted_identity?(address :: String.t(), identity_key :: binary()) :: boolean()
end
```

---

## Task 5.11: Key Helper

File: `lib/baileys_ex/signal/key_helper.ex` (~40 lines)

```elixir
defmodule BaileysEx.Signal.KeyHelper do
  def generate_identity_key_pair, do: Crypto.generate_curve25519_key_pair()
  def generate_registration_id, do: :rand.uniform(16380) + 1

  def generate_pre_keys(start_id, count) do
    Enum.map(start_id..(start_id + count - 1), fn id ->
      %{key_id: id, key_pair: Crypto.generate_curve25519_key_pair()}
    end)
  end

  def generate_signed_pre_key(identity_key, key_id) do
    key_pair = Crypto.generate_curve25519_key_pair()
    pub_with_prefix = Crypto.signal_pub_key(key_pair.public)
    signature = Native.XEdDSA.sign(identity_key.private, pub_with_prefix)
    %{key_id: key_id, key_pair: key_pair, signature: signature}
  end

  def generate_sender_key, do: :crypto.strong_rand_bytes(32)
  def generate_sender_key_id, do: :rand.uniform(2_147_483_647)

  def generate_sender_signing_key do
    Crypto.generate_curve25519_key_pair()
  end
end
```

---

## Testing Strategy

### 5.12 XEdDSA NIF tests

```
test/baileys_ex/native/xeddsa_test.exs
```
- Roundtrip: sign then verify with same key pair
- Known test vectors from XEdDSA spec
- Cross-validate: capture Baileys sign output, verify in Elixir (and vice versa)
- Invalid signature rejection
- Different key rejection
- Edge cases: all-zero message, very large message

### 5.13 Crypto KDF tests

```
test/baileys_ex/crypto_test.exs (extend)
```
- `kdf_ck` produces correct chain key and message key
- `kdf_rk` produces correct root key and chain key
- `derive_group_message_key` produces correct IV and cipher key
- Cross-validate all against Baileys output for same inputs

### 5.14 Double Ratchet tests

```
test/baileys_ex/signal/ratchet_test.exs
```
- Alice↔Bob basic exchange (alternating messages)
- Out-of-order message decryption (skipped keys)
- DH ratchet step triggers correctly on direction change
- Max skip enforcement (>2000 raises)
- Session state serialization roundtrip

### 5.15 X3DH tests

```
test/baileys_ex/signal/x3dh_test.exs
```
- Session establishment with one-time pre-key
- Session establishment without one-time pre-key
- Invalid signature detection
- Both sides derive same shared secret

### 5.16 Group cipher tests

```
test/baileys_ex/signal/group/group_cipher_test.exs
```
- Encrypt/decrypt roundtrip
- Out-of-order message decryption
- Multiple sender key states
- Signature verification
- Chain key ratcheting matches Baileys output

### 5.17 End-to-end integration tests

```
test/baileys_ex/signal/integration_test.exs
```
- Full flow: key generation → X3DH → send PreKeyWhisperMessage → decrypt → reply → decrypt
- Group flow: create distribution message → process → encrypt → decrypt
- Wire format compatibility with Baileys (encode in one, decode in other)

---

## Acceptance Criteria

- [ ] XEdDSA sign/verify roundtrip works
- [ ] XEdDSA cross-validates with Baileys (sign in one, verify in other)
- [ ] X3DH session establishment produces matching shared secrets on both sides
- [ ] Double Ratchet encrypt/decrypt works for multi-message exchanges
- [ ] Skipped message key caching works (out-of-order delivery)
- [ ] DH ratchet step triggers correctly on direction changes
- [ ] Group cipher encrypt/decrypt roundtrip works
- [ ] Group chain key ratcheting matches Baileys exactly
- [ ] Wire format (protobuf + version byte + MAC) matches Baileys
- [ ] WhisperMessage serialization matches Baileys
- [ ] PreKeyWhisperMessage serialization matches Baileys
- [ ] SenderKeyMessage serialization + signature matches Baileys
- [ ] SenderKeyDistributionMessage serialization matches Baileys
- [ ] Store behaviour works with ETS-backed implementation
- [ ] Session record supports multiple sessions per peer
- [ ] No Rust NIF except XEdDSA (verify no :crypto gaps)

## Files Created/Modified

- `native/baileys_nif/src/xeddsa.rs` — XEdDSA sign/verify (~80 lines)
- `native/baileys_nif/Cargo.toml` — add curve25519-dalek, sha2, getrandom
- `lib/baileys_ex/native/xeddsa.ex` — NIF wrapper
- `lib/baileys_ex/crypto.ex` — extend with Signal KDFs
- `lib/baileys_ex/signal/x3dh.ex` — X3DH key agreement
- `lib/baileys_ex/signal/ratchet.ex` — Double Ratchet algorithm
- `lib/baileys_ex/signal/session.ex` — Session record management
- `lib/baileys_ex/signal/session_cipher.ex` — Orchestrator
- `lib/baileys_ex/signal/session_builder.ex` — Session establishment
- `lib/baileys_ex/signal/key_helper.ex` — Key generation utilities
- `lib/baileys_ex/signal/store.ex` — Store behaviour
- `lib/baileys_ex/signal/proto.ex` — Wire format encode/decode
- `lib/baileys_ex/signal/group/sender_chain_key.ex`
- `lib/baileys_ex/signal/group/sender_message_key.ex`
- `lib/baileys_ex/signal/group/sender_key_state.ex`
- `lib/baileys_ex/signal/group/sender_key_record.ex`
- `lib/baileys_ex/signal/group/sender_key_message.ex`
- `lib/baileys_ex/signal/group/sender_key_distribution_message.ex`
- `lib/baileys_ex/signal/group/group_cipher.ex`
- `lib/baileys_ex/signal/group/group_session.ex`
- `priv/proto/signal.proto`
- `test/baileys_ex/native/xeddsa_test.exs`
- `test/baileys_ex/signal/ratchet_test.exs`
- `test/baileys_ex/signal/x3dh_test.exs`
- `test/baileys_ex/signal/session_cipher_test.exs`
- `test/baileys_ex/signal/group/group_cipher_test.exs`
- `test/baileys_ex/signal/integration_test.exs`
