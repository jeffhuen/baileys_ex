# Phase 4: Noise Protocol

**Goal:** Implement the WhatsApp/Baileys Noise handler correctly.

That means mirroring `dev/reference/Baileys-master/src/Utils/noise-handler.ts`:
protobuf handshake messages, certificate validation, handshake hash/key mixing,
and transport framing all belong to the high-level protocol layer. A raw `snow`
NIF can still exist as a low-level helper, but it is not the WhatsApp handshake API.

**Depends on:** Phase 1 (Foundation)
**Parallel with:** Phase 5 (Signal Protocol / signature verification layer)
**Blocks:** Phase 6 (Connection)

---

## Design Decisions

**Mirror Baileys, not generic raw XX.**
WhatsApp does use `Noise_XX_25519_AESGCM_SHA256`, but the wire flow is not "send raw XX
messages over the socket." Baileys wraps the handshake in `HandshakeMessage` protobufs,
validates `CertChain`, and manages transport counters itself. Follow that structure.

**Keep the NIF boundary sharp.**
The low-level `BaileysEx.Native.Noise` module may expose a raw `snow` session for
experiments or focused tests, but the real `BaileysEx.Protocol.Noise` module owns the
WhatsApp-specific state machine. Recoverable failures belong there as tagged tuples.

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
fn noise_init(prologue: Binary) -> NifResult<ResourceArc<NoiseSession>> {
    // WhatsApp uses: Noise_XX_25519_AESGCM_SHA256
    let builder = Builder::new("Noise_XX_25519_AESGCM_SHA256".parse().unwrap())
        .prologue(prologue.as_slice())
        .build_initiator()?;
    Ok(ResourceArc::new(NoiseSession(Mutex::new(builder))))
}

#[rustler::nif]
fn noise_handshake_write(
    state: ResourceArc<NoiseSession>,
    payload: Binary,
) -> NifResult<Binary> {
    // Write handshake message. State advances in-place.
}

#[rustler::nif]
fn noise_handshake_read(
    state: ResourceArc<NoiseSession>,
    message: Binary,
) -> NifResult<Binary> {
    // Read handshake message. State advances in-place.
}

#[rustler::nif]
fn noise_handshake_finish(
    state: ResourceArc<NoiseSession>,
) -> NifResult<Atom> {
    // Transition to transport mode in-place
}

// --- Transport ---

#[rustler::nif]
fn noise_encrypt(
    state: ResourceArc<NoiseSession>,
    plaintext: Binary,
) -> NifResult<Binary> {
    // Encrypt a frame. Counter managed internally.
}

#[rustler::nif]
fn noise_decrypt(
    state: ResourceArc<NoiseSession>,
    ciphertext: Binary,
) -> NifResult<Binary> {
    // Decrypt a frame. Counter managed internally.
}

#[rustler::nif]
fn noise_get_remote_static(
    state: ResourceArc<NoiseSession>,
) -> NifResult<Option<Binary>> {
    // Get remote's static public key after handshake step 2
}
```

### 4.2 Elixir Noise wrapper

File: `lib/baileys_ex/native/noise.ex`

```elixir
defmodule BaileysEx.Native.Noise do
  use Rustler, otp_app: :baileys_ex, crate: "baileys_nif"

  @type session :: reference()

  @spec init(binary()) :: session()
  def init(_prologue), do: :erlang.nif_error(:nif_not_loaded)

  @spec init_responder(binary()) :: session()
  def init_responder(_prologue), do: :erlang.nif_error(:nif_not_loaded)

  @spec handshake_write(session(), binary()) :: binary()
  def handshake_write(_state, _payload), do: :erlang.nif_error(:nif_not_loaded)

  @spec handshake_read(session(), binary()) :: binary()
  def handshake_read(_state, _message), do: :erlang.nif_error(:nif_not_loaded)

  @spec finish(session()) :: :ok
  def finish(_state), do: :erlang.nif_error(:nif_not_loaded)

  @spec encrypt(session(), binary()) :: binary()
  def encrypt(_state, _plaintext), do: :erlang.nif_error(:nif_not_loaded)

  @spec decrypt(session(), binary()) :: binary()
  def decrypt(_state, _ciphertext), do: :erlang.nif_error(:nif_not_loaded)
end
```

### 4.3 Higher-level Noise protocol module

File: `lib/baileys_ex/protocol/noise.ex`

Orchestrates the WhatsApp-specific Noise handshake flow:

```elixir
defmodule BaileysEx.Protocol.Noise do
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts \\ [])

  @spec client_hello(t()) :: {:ok, {t(), binary()}} | {:error, term()}
  def client_hello(state)

  @spec process_server_hello(t(), binary(), key_pair()) :: {:ok, t()} | {:error, term()}
  def process_server_hello(state, server_hello, noise_key_pair)

  @spec client_finish(t(), binary()) :: {:ok, {t(), binary()}} | {:error, term()}
  def client_finish(state, client_payload)

  @spec encode_frame(t(), binary()) :: {:ok, {t(), binary()}} | {:error, term()}
  def encode_frame(state, plaintext)

  @spec decode_frames(t(), binary()) :: {:ok, {t(), [binary()]}} | {:error, term()}
  def decode_frames(state, buffer_chunk)
end
```

### 4.3a Certificate Validation (GAP-21)

After the server hello is decrypted, its payload contains an encrypted `CertChain`.
Mirror Baileys `src/Utils/noise-handler.ts` exactly before proceeding to
`client_finish/2`. This requires the same Signal-style signature verification
primitive Baileys uses for `Curve.verify(...)`; do not substitute plain
`:crypto.verify/5` unless it has been cross-validated against Baileys for these
certificate signatures.

```elixir
defp validate_cert_chain(payload) do
  {:ok, cert_chain} = Proto.CertChain.decode(payload)
  %{intermediate: intermediate, leaf: leaf} = cert_chain

  {:ok, details} = Proto.CertChain.NoiseCertificate.Details.decode(intermediate.details)

  verify_leaf =
    Signal.Curve.verify(details.key, leaf.details, leaf.signature)

  verify_intermediate =
    Signal.Curve.verify(
      WA_CERT_DETAILS.PUBLIC_KEY,
      intermediate.details,
      intermediate.signature
    )

  issuer_matches =
    details.issuer_serial == WA_CERT_DETAILS.SERIAL

  if verify_leaf and verify_intermediate and issuer_matches do
    :ok
  else
    {:error, :invalid_certificate}
  end
end
```

Validation requirements from the reference:
- Decrypt the server payload and decode `proto.CertChain`
- Verify the leaf signature using the intermediate certificate's public key
- Verify the intermediate signature using `WA_CERT_DETAILS.PUBLIC_KEY`
- Check `issuer_serial == WA_CERT_DETAILS.SERIAL`
- Abort the handshake on any validation failure

Implementation note:
- This step depends on Phase 3 proto support for `HandshakeMessage`/`CertChain`
- It also depends on Phase 5 exposing a Baileys-compatible `Curve.verify` equivalent
  from the Signal/native layer (preferred via `libsignal-protocol`, fallback via a
  narrowly scoped helper NIF if required)

```elixir
# Returns :ok | {:error, :invalid_certificate}

defp validate_cert_chain(_payload) do
  # Returns :ok | {:error, :invalid_certificate}
end
```

### 4.4 Tests

- `client_hello/1` encodes the ephemeral public key into `HandshakeMessage`
- Full client-side handshake against a synthetic server that mirrors the Baileys algorithm
- Transport encrypt/decrypt roundtrip after `client_finish/2`
- Frame buffering and counter advancement in `decode_frames/2`
- Certificate validation: valid cert passes, wrong issuer/signature rejects the handshake
- Raw `ResourceArc` lifecycle smoke test: repeated create/use/drop without crashes

### 4.5 Native Resource Hardening

`ResourceArc` safety has two distinct concerns and they should not be conflated:

1. **Functional lifecycle correctness**: resources can be created, used, transitioned,
   and dropped repeatedly without crashes or cross-session corruption.
2. **Native memory leak freedom**: long-running repeated resource churn does not retain
   unreachable native allocations over time.

The first point is covered by the ExUnit smoke test and concurrent handshake
coverage. The second is validated by a dedicated native teardown check rather
than generic BEAM-only assertions: the Rust NIF tracks live `NoiseSession`
instances with an `AtomicUsize`, decrements the counter in `Drop`, exposes the
count through `Noise.session_count/0`, and verifies in test that spawned-process
resources return to baseline after process exit and garbage collection.

Implemented verification work:
- Run repeated create/use/drop workloads against the raw NIF boundary.
- Track live `ResourceArc` instances in Rust and assert deterministic teardown
  through `Noise.session_count/0`.
- Verify a spawned process can create multiple sessions and that the live count
  returns to baseline after the process exits and BEAM cleanup runs.

---

## Acceptance Criteria

- [x] Noise XX handshake completes successfully in test
- [x] Transport encrypt/decrypt roundtrip works
- [x] ResourceArc lifecycle is smoke-tested via repeated create/use/drop without crashes
- [x] Concurrent handshakes work (multiple ResourceArcs simultaneously)
- [x] High-level error handling: `BaileysEx.Protocol.Noise` returns `{:error, reason}` on bad data
- [x] Certificate chain validated after server hello processing (GAP-21)
- [x] Native leak verification completes via Rust-side session counting and deterministic `Drop` teardown checks for `ResourceArc`

Implementation note:
- A repeated create/use/drop smoke test exercises raw `ResourceArc` lifecycle.
- `Noise.session_count/0` exposes the Rust-side live-session counter so teardown
  is asserted directly rather than inferred from BEAM process state alone.

## Files Created/Modified

- `native/baileys_nif/src/noise.rs` — Rust implementation
- `lib/baileys_ex/native/noise.ex` — NIF wrapper
- `lib/baileys_ex/protocol/noise.ex` — WhatsApp Noise flow
- `test/baileys_ex/protocol/noise_test.exs`
