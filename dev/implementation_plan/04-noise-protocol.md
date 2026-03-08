# Phase 4: Noise Protocol NIF

**Goal:** Wrap the `snow` Rust crate via NIF to implement WhatsApp's Noise protocol
handshake and transport encryption.

**Depends on:** Phase 2 (Crypto NIF)
**Parallel with:** Phase 5 (Signal NIF)
**Blocks:** Phase 6 (Connection)

---

## Design Decisions

**Use `snow` crate, not custom implementation.**
`snow` is the mature Rust implementation of the Noise Protocol Framework. WhatsApp uses
`Noise_XX_25519_AESGCM_SHA256` (XX handshake pattern with Curve25519, AES-GCM, SHA-256).

**ResourceArc for handshake state.**
The Noise handshake is a multi-step state machine. Rather than serializing/deserializing
state across the NIF boundary on each call, hold the state in Rust via `ResourceArc`.
Elixir holds an opaque reference.

**Two phases: handshake → transport.**
After handshake completes, the `HandshakeState` transitions to a `TransportState` with
separate encrypt/decrypt ciphers. The NIF returns a new ResourceArc for the transport phase.

---

## Tasks

### 4.1 Implement noise.rs

Use an enum wrapper to handle the handshake → transport state transition cleanly
within a single ResourceArc (pattern confirmed by Rustler research):

```rust
use rustler::ResourceArc;
use snow::{Builder, HandshakeState, TransportState};
use std::sync::Mutex;

/// Single enum holding either handshake or transport state.
/// Transitions in-place behind the Mutex.
enum NoiseState {
    Handshake(HandshakeState),
    Transport(TransportState),
    /// Temporary state during transition (avoids ownership issues)
    Transitioning,
}

#[derive(rustler::Resource)]
struct NoiseSession(Mutex<NoiseState>);

// --- Handshake ---

#[rustler::nif]
fn noise_init(prologue: Binary) -> NifResult<ResourceArc<NoiseHandshake>> {
    // WhatsApp uses: Noise_XX_25519_AESGCM_SHA256
    let builder = Builder::new("Noise_XX_25519_AESGCM_SHA256".parse().unwrap())
        .prologue(prologue.as_slice())
        .build_initiator()?;
    Ok(ResourceArc::new(NoiseHandshake(Mutex::new(builder))))
}

#[rustler::nif]
fn noise_handshake_write(
    state: ResourceArc<NoiseHandshake>,
    payload: Binary,
) -> NifResult<(ResourceArc<NoiseHandshake>, Binary)> {
    // Write handshake message, return updated state + output
}

#[rustler::nif]
fn noise_handshake_read(
    state: ResourceArc<NoiseHandshake>,
    message: Binary,
) -> NifResult<(ResourceArc<NoiseHandshake>, Binary)> {
    // Read handshake message, return updated state + decrypted payload
}

#[rustler::nif]
fn noise_handshake_finish(
    state: ResourceArc<NoiseHandshake>,
) -> NifResult<ResourceArc<NoiseTransport>> {
    // Transition to transport mode, return transport state
}

// --- Transport ---

#[rustler::nif]
fn noise_encrypt(
    state: ResourceArc<NoiseTransport>,
    plaintext: Binary,
) -> NifResult<Binary> {
    // Encrypt a frame. Counter managed internally.
}

#[rustler::nif]
fn noise_decrypt(
    state: ResourceArc<NoiseTransport>,
    ciphertext: Binary,
) -> NifResult<Binary> {
    // Decrypt a frame. Counter managed internally.
}

#[rustler::nif]
fn noise_get_remote_static(
    state: ResourceArc<NoiseHandshake>,
) -> NifResult<Option<Binary>> {
    // Get remote's static public key after handshake step 2
}
```

### 4.2 Elixir Noise wrapper

File: `lib/baileys_ex/native/noise.ex`

```elixir
defmodule BaileysEx.Native.Noise do
  use Rustler, otp_app: :baileys_ex, crate: "baileys_nif"

  @spec init(binary()) :: {:ok, reference()} | {:error, term()}
  def init(_prologue), do: :erlang.nif_error(:nif_not_loaded)

  @spec handshake_write(reference(), binary()) :: {:ok, reference(), binary()} | {:error, term()}
  def handshake_write(_state, _payload), do: :erlang.nif_error(:nif_not_loaded)

  @spec handshake_read(reference(), binary()) :: {:ok, reference(), binary()} | {:error, term()}
  def handshake_read(_state, _message), do: :erlang.nif_error(:nif_not_loaded)

  @spec finish(reference()) :: {:ok, reference()} | {:error, term()}
  def finish(_state), do: :erlang.nif_error(:nif_not_loaded)

  @spec encrypt(reference(), binary()) :: {:ok, binary()} | {:error, term()}
  def encrypt(_state, _plaintext), do: :erlang.nif_error(:nif_not_loaded)

  @spec decrypt(reference(), binary()) :: {:ok, binary()} | {:error, term()}
  def decrypt(_state, _ciphertext), do: :erlang.nif_error(:nif_not_loaded)
end
```

### 4.3 Higher-level Noise protocol module

File: `lib/baileys_ex/protocol/noise.ex`

Orchestrates the WhatsApp-specific Noise handshake flow:

```elixir
defmodule BaileysEx.Protocol.Noise do
  @wa_header <<87, 65, 6, 2>>  # "WA" + version bytes

  def new_handshake do
    {:ok, state} = Native.Noise.init(@wa_header)
    state
  end

  def process_handshake(state, :step1) do
    # Client → Server: ephemeral key
    {:ok, state, message} = Native.Noise.handshake_write(state, <<>>)
    {:continue, state, message}
  end

  def process_handshake(state, {:step2, server_hello}) do
    # Server → Client: ephemeral + static + payload
    {:ok, state, payload} = Native.Noise.handshake_read(state, server_hello)
    # payload contains server's certificate chain
    {:continue, state, payload}
  end

  def process_handshake(state, {:step3, client_payload}) do
    # Client → Server: static + payload (registration/login)
    {:ok, state, message} = Native.Noise.handshake_write(state, client_payload)
    {:ok, transport} = Native.Noise.finish(state)
    {:done, transport, message}
  end

  def encrypt_frame(transport, data) do
    Native.Noise.encrypt(transport, data)
  end

  def decrypt_frame(transport, data) do
    Native.Noise.decrypt(transport, data)
  end
end
```

### 4.3a Certificate Validation (GAP-21)

After the Noise XX handshake step 2, the server's response includes a certificate
chain (NoiseCertificate protobuf). Validate before proceeding to step 3.

```elixir
# In BaileysEx.Protocol.Noise, extend process_handshake step 2:

def process_handshake(state, {:step2, server_hello}) do
  {:ok, state, payload} = Native.Noise.handshake_read(state, server_hello)
  # payload contains NoiseCertificate protobuf
  {:ok, cert} = Proto.NoiseCertificate.decode(payload)
  :ok = validate_certificate(cert)
  {:continue, state, payload}
end

defp validate_certificate(cert) do
  # 1. Decode cert.details (CertificateDetails protobuf)
  # 2. Verify cert.signature over cert.details using known WA static key
  # 3. Check cert.details.issuer_serial matches expected issuer
  # 4. Check cert.details.not_before <= now <= cert.details.not_after
  # Returns :ok | {:error, :invalid_certificate}
end
```

### 4.4 Tests

- Handshake with known test vectors (derive from Noise spec test vectors)
- Full handshake simulation (initiator ↔ responder)
- Transport encrypt/decrypt roundtrip
- Frame counter advancement (decrypt after N encrypt calls)
- Error cases: corrupted handshake data, wrong keys
- Certificate validation: valid cert passes, expired/wrong-issuer rejected

---

## Acceptance Criteria

- [ ] Noise XX handshake completes successfully in test
- [ ] Transport encrypt/decrypt roundtrip works
- [ ] ResourceArc lifecycle: no memory leaks (create, use, drop)
- [ ] Concurrent handshakes work (multiple ResourceArcs simultaneously)
- [ ] Error handling: bad data returns `{:error, reason}` not crash
- [ ] Certificate chain validated after Noise handshake step 2 (GAP-21)

## Files Created/Modified

- `native/baileys_nif/src/noise.rs` — Rust implementation
- `lib/baileys_ex/native/noise.ex` — NIF wrapper
- `lib/baileys_ex/protocol/noise.ex` — WhatsApp Noise flow
- `test/baileys_ex/protocol/noise_test.exs`
