use crate::error::NifError;
use rustler::{Atom, Binary, Env, NewBinary, NifResult, Resource, ResourceArc};
use snow::{params::NoiseParams, Builder};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Mutex;

mod atoms {
    rustler::atoms! {
        ok,
    }
}

/// Noise protocol pattern used by `WhatsApp`.
const NOISE_PATTERN: &str = "Noise_XX_25519_AESGCM_SHA256";

/// Maximum message size for Noise protocol (64 KiB).
/// snow uses a 65535-byte buffer internally.
const MAX_MSG_SIZE: usize = 65535;

/// Global counter tracking live `NoiseSession` instances.
/// Incremented on creation, decremented on `Drop`. Used by leak verification tests.
static LIVE_SESSION_COUNT: AtomicUsize = AtomicUsize::new(0);

/// Internal state machine for the Noise session.
/// Transitions from Handshake to Transport after the XX pattern completes.
enum NoiseState {
    Handshake(Box<snow::HandshakeState>),
    Transport(snow::TransportState),
    /// Temporary placeholder during in-place state transitions.
    /// Never observed by callers — exists only to satisfy Rust ownership rules
    /// when moving the value out of the Mutex to call `into_transport_mode()`.
    Transitioning,
}

/// Opaque Noise session resource held by Elixir via `ResourceArc`.
///
/// Uses `Mutex` for safe concurrent access (required by Rustler's `Resource` trait).
/// Tracks live instance count via `LIVE_SESSION_COUNT` for leak verification.
pub struct NoiseSession {
    state: Mutex<NoiseState>,
}

impl NoiseSession {
    fn new(state: NoiseState) -> Self {
        LIVE_SESSION_COUNT.fetch_add(1, Ordering::SeqCst);
        Self {
            state: Mutex::new(state),
        }
    }
}

impl Drop for NoiseSession {
    fn drop(&mut self) {
        LIVE_SESSION_COUNT.fetch_sub(1, Ordering::SeqCst);
    }
}

#[rustler::resource_impl]
impl Resource for NoiseSession {}

fn noise_params() -> Result<NoiseParams, NifError> {
    NOISE_PATTERN.parse().map_err(NifError::InvalidNoisePattern)
}

#[derive(Clone, Copy)]
enum SessionRole {
    Initiator,
    Responder,
}

fn init_session(
    prologue: Binary,
    local_private_key: Option<Binary>,
    local_ephemeral_private_key: Option<Binary>,
    role: SessionRole,
) -> NifResult<ResourceArc<NoiseSession>> {
    let params = noise_params()?;
    let private_key = local_private_key_bytes(local_private_key)?;
    let ephemeral_private_key = optional_private_key_bytes(
        local_ephemeral_private_key,
        "invalid local ephemeral private key size",
    )?;

    let builder = Builder::new(params)
        .prologue(prologue.as_slice())
        .local_private_key(&private_key);

    let builder = match ephemeral_private_key.as_ref() {
        Some(ephemeral_private_key) => {
            builder.fixed_ephemeral_key_for_testing_only(ephemeral_private_key)
        }
        None => builder,
    };

    let handshake = match role {
        SessionRole::Initiator => builder.build_initiator().map_err(NifError::SnowInit)?,
        SessionRole::Responder => builder.build_responder().map_err(NifError::SnowInit)?,
    };

    Ok(ResourceArc::new(NoiseSession::new(NoiseState::Handshake(
        Box::new(handshake),
    ))))
}

/// Return the number of live `NoiseSession` instances for leak verification.
#[rustler::nif(name = "noise_session_count")]
fn session_count() -> usize {
    LIVE_SESSION_COUNT.load(Ordering::SeqCst)
}

/// Initialize a Noise XX initiator session.
///
/// Creates a new `HandshakeState` with the XX pattern (Curve25519, AES-256-GCM, SHA-256).
/// The prologue is mixed into the handshake hash but not transmitted — both sides
/// must use the same prologue for the handshake to succeed.
///
/// Baileys rc9 uses the `WhatsApp` prologue `<<87, 65, 6, 3>>` (`"WA"` plus version bytes).
#[rustler::nif(name = "noise_init")]
fn init(
    prologue: Binary,
    local_private_key: Option<Binary>,
    local_ephemeral_private_key: Option<Binary>,
) -> NifResult<ResourceArc<NoiseSession>> {
    init_session(
        prologue,
        local_private_key,
        local_ephemeral_private_key,
        SessionRole::Initiator,
    )
}

/// Initialize a Noise XX responder session (used only in tests).
///
/// Same as `init` but builds a responder instead of initiator.
#[rustler::nif(name = "noise_init_responder")]
fn init_responder(
    prologue: Binary,
    local_private_key: Option<Binary>,
    local_ephemeral_private_key: Option<Binary>,
) -> NifResult<ResourceArc<NoiseSession>> {
    init_session(
        prologue,
        local_private_key,
        local_ephemeral_private_key,
        SessionRole::Responder,
    )
}

/// Return a validated local private key, generating one when the caller omits it.
fn local_private_key_bytes(local_private_key: Option<Binary>) -> Result<Vec<u8>, NifError> {
    match local_private_key {
        Some(private_key) => {
            let bytes = private_key.as_slice();

            if bytes.len() == 32 {
                Ok(bytes.to_vec())
            } else {
                Err(NifError::InvalidKeySize("invalid local private key size"))
            }
        }
        None => Ok(Builder::new(noise_params()?)
            .generate_keypair()
            .map_err(NifError::KeypairGeneration)?
            .private),
    }
}

/// Return an optional validated fixed private key for deterministic test sessions.
fn optional_private_key_bytes(
    private_key: Option<Binary>,
    error_message: &'static str,
) -> Result<Option<Vec<u8>>, NifError> {
    match private_key {
        Some(private_key) => {
            let bytes = private_key.as_slice();

            if bytes.len() == 32 {
                Ok(Some(bytes.to_vec()))
            } else {
                Err(NifError::InvalidKeySize(error_message))
            }
        }
        None => Ok(None),
    }
}

/// Write a handshake message.
///
/// Advances the Noise handshake state machine by producing an outgoing message.
/// The payload is encrypted and included in the handshake message.
/// Returns the handshake message bytes to send to the peer.
#[expect(
    clippy::needless_pass_by_value,
    reason = "Rustler NIF entry points currently receive `ResourceArc` arguments by value"
)]
#[rustler::nif(name = "noise_handshake_write")]
fn handshake_write<'a>(
    env: Env<'a>,
    session: ResourceArc<NoiseSession>,
    payload: Binary<'a>,
) -> NifResult<Binary<'a>> {
    let mut guard = session.state.lock().map_err(|_| NifError::MutexPoisoned)?;

    match &mut *guard {
        NoiseState::Handshake(hs) => {
            let mut buf = vec![0u8; MAX_MSG_SIZE];
            let len = hs
                .write_message(payload.as_slice(), &mut buf)
                .map_err(NifError::HandshakeWrite)?;

            let mut out = NewBinary::new(env, len);
            out.as_mut_slice().copy_from_slice(&buf[..len]);
            Ok(out.into())
        }
        NoiseState::Transport(_) => Err(NifError::HandshakeWriteInTransport.into()),
        NoiseState::Transitioning => Err(NifError::SessionTransitioning.into()),
    }
}

/// Read a handshake message from the peer.
///
/// Advances the Noise handshake state machine by processing an incoming message.
/// Returns the decrypted payload from the handshake message.
#[expect(
    clippy::needless_pass_by_value,
    reason = "Rustler NIF entry points currently receive `ResourceArc` arguments by value"
)]
#[rustler::nif(name = "noise_handshake_read")]
fn handshake_read<'a>(
    env: Env<'a>,
    session: ResourceArc<NoiseSession>,
    message: Binary<'a>,
) -> NifResult<Binary<'a>> {
    let mut guard = session.state.lock().map_err(|_| NifError::MutexPoisoned)?;

    match &mut *guard {
        NoiseState::Handshake(hs) => {
            let mut buf = vec![0u8; MAX_MSG_SIZE];
            let len = hs
                .read_message(message.as_slice(), &mut buf)
                .map_err(NifError::HandshakeRead)?;

            let mut out = NewBinary::new(env, len);
            out.as_mut_slice().copy_from_slice(&buf[..len]);
            Ok(out.into())
        }
        NoiseState::Transport(_) => Err(NifError::HandshakeReadInTransport.into()),
        NoiseState::Transitioning => Err(NifError::SessionTransitioning.into()),
    }
}

/// Transition the session from Handshake to Transport mode.
///
/// Must be called after the handshake is complete (all XX pattern messages exchanged).
/// After this call, `encrypt` and `decrypt` become available, and `handshake_write`/
/// `handshake_read` will return errors.
#[expect(
    clippy::needless_pass_by_value,
    reason = "Rustler NIF entry points currently receive `ResourceArc` arguments by value"
)]
#[rustler::nif(name = "noise_finish")]
fn finish(session: ResourceArc<NoiseSession>) -> NifResult<Atom> {
    let mut guard = session.state.lock().map_err(|_| NifError::MutexPoisoned)?;

    // Take the current state out, replacing with Transitioning temporarily
    let state = std::mem::replace(&mut *guard, NoiseState::Transitioning);

    match state {
        NoiseState::Handshake(hs) => {
            let transport = (*hs).into_transport_mode().map_err(NifError::Finish)?;
            *guard = NoiseState::Transport(transport);
            Ok(atoms::ok())
        }
        NoiseState::Transport(t) => {
            // Already in transport mode — restore state and report error
            *guard = NoiseState::Transport(t);
            Err(NifError::AlreadyInTransport.into())
        }
        NoiseState::Transitioning => Err(NifError::SessionTransitioning.into()),
    }
}

/// Encrypt a plaintext message using the transport session.
///
/// The Noise transport state maintains an internal counter for nonce generation.
/// Each call advances the write counter. Returns ciphertext with appended auth tag.
#[expect(
    clippy::needless_pass_by_value,
    reason = "Rustler NIF entry points currently receive `ResourceArc` arguments by value"
)]
#[rustler::nif(name = "noise_encrypt")]
fn encrypt<'a>(
    env: Env<'a>,
    session: ResourceArc<NoiseSession>,
    plaintext: Binary<'a>,
) -> NifResult<Binary<'a>> {
    let mut guard = session.state.lock().map_err(|_| NifError::MutexPoisoned)?;

    match &mut *guard {
        NoiseState::Transport(ts) => {
            let mut buf = vec![0u8; plaintext.len() + 16];
            let len = ts
                .write_message(plaintext.as_slice(), &mut buf)
                .map_err(NifError::Encrypt)?;

            let mut out = NewBinary::new(env, len);
            out.as_mut_slice().copy_from_slice(&buf[..len]);
            Ok(out.into())
        }
        NoiseState::Handshake(_) => Err(NifError::EncryptInHandshake.into()),
        NoiseState::Transitioning => Err(NifError::SessionTransitioning.into()),
    }
}

/// Decrypt a ciphertext message using the transport session.
///
/// The Noise transport state maintains an internal counter for nonce generation.
/// Each call advances the read counter. Returns the decrypted plaintext.
#[expect(
    clippy::needless_pass_by_value,
    reason = "Rustler NIF entry points currently receive `ResourceArc` arguments by value"
)]
#[rustler::nif(name = "noise_decrypt")]
fn decrypt<'a>(
    env: Env<'a>,
    session: ResourceArc<NoiseSession>,
    ciphertext: Binary<'a>,
) -> NifResult<Binary<'a>> {
    let mut guard = session.state.lock().map_err(|_| NifError::MutexPoisoned)?;

    match &mut *guard {
        NoiseState::Transport(ts) => {
            let mut buf = vec![0u8; ciphertext.len()];
            let len = ts
                .read_message(ciphertext.as_slice(), &mut buf)
                .map_err(NifError::Decrypt)?;

            let mut out = NewBinary::new(env, len);
            out.as_mut_slice().copy_from_slice(&buf[..len]);
            Ok(out.into())
        }
        NoiseState::Handshake(_) => Err(NifError::DecryptInHandshake.into()),
        NoiseState::Transitioning => Err(NifError::SessionTransitioning.into()),
    }
}
