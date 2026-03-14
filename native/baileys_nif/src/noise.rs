use rustler::{Atom, Binary, Env, NewBinary, NifResult, Resource, ResourceArc};
use snow::{params::NoiseParams, Builder};
use std::sync::Mutex;

mod atoms {
    rustler::atoms! {
        ok,
    }
}

/// Noise protocol pattern used by WhatsApp.
const NOISE_PATTERN: &str = "Noise_XX_25519_AESGCM_SHA256";

/// Maximum message size for Noise protocol (64 KiB).
/// snow uses a 65535-byte buffer internally.
const MAX_MSG_SIZE: usize = 65535;

/// Internal state machine for the Noise session.
/// Transitions from Handshake to Transport after the XX pattern completes.
enum NoiseState {
    Handshake(snow::HandshakeState),
    Transport(snow::TransportState),
    /// Temporary placeholder during in-place state transitions.
    /// Never observed by callers — exists only to satisfy Rust ownership rules
    /// when moving the value out of the Mutex to call `into_transport_mode()`.
    Transitioning,
}

/// Opaque Noise session resource held by Elixir via ResourceArc.
///
/// Uses Mutex for safe concurrent access (required by Rustler's Resource trait).
pub struct NoiseSession {
    state: Mutex<NoiseState>,
}

#[rustler::resource_impl]
impl Resource for NoiseSession {}

/// Initialize a Noise XX initiator session.
///
/// Creates a new HandshakeState with the XX pattern (Curve25519, AES-256-GCM, SHA-256).
/// The prologue is mixed into the handshake hash but not transmitted — both sides
/// must use the same prologue for the handshake to succeed.
///
/// WhatsApp prologue: <<87, 65, 6, 2>> ("WA" + version bytes).
#[rustler::nif(name = "noise_init")]
fn init(
    prologue: Binary,
    local_private_key: Option<Binary>,
    local_ephemeral_private_key: Option<Binary>,
) -> NifResult<ResourceArc<NoiseSession>> {
    let params: NoiseParams = NOISE_PATTERN.parse().expect("valid noise pattern");
    let builder = Builder::new(params.clone());
    let private_key = local_private_key_bytes(&builder, local_private_key)?;
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

    let hs = builder
        .build_initiator()
        .map_err(|e| rustler::Error::RaiseTerm(Box::new(format!("snow init failed: {e}"))))?;

    Ok(ResourceArc::new(NoiseSession {
        state: Mutex::new(NoiseState::Handshake(hs)),
    }))
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
    let params: NoiseParams = NOISE_PATTERN.parse().expect("valid noise pattern");
    let builder = Builder::new(params.clone());
    let private_key = local_private_key_bytes(&builder, local_private_key)?;
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

    let hs = builder
        .build_responder()
        .map_err(|e| rustler::Error::RaiseTerm(Box::new(format!("snow init failed: {e}"))))?;

    Ok(ResourceArc::new(NoiseSession {
        state: Mutex::new(NoiseState::Handshake(hs)),
    }))
}

fn local_private_key_bytes(
    builder: &Builder<'_>,
    local_private_key: Option<Binary>,
) -> NifResult<Vec<u8>> {
    match local_private_key {
        Some(private_key) => {
            let bytes = private_key.as_slice();

            if bytes.len() != 32 {
                Err(rustler::Error::RaiseTerm(Box::new(
                    "invalid local private key size",
                )))
            } else {
                Ok(bytes.to_vec())
            }
        }
        None => Ok(builder
            .generate_keypair()
            .map_err(|e| rustler::Error::RaiseTerm(Box::new(format!("keypair gen failed: {e}"))))?
            .private),
    }
}

fn optional_private_key_bytes(
    private_key: Option<Binary>,
    error_message: &'static str,
) -> NifResult<Option<Vec<u8>>> {
    match private_key {
        Some(private_key) => {
            let bytes = private_key.as_slice();

            if bytes.len() != 32 {
                Err(rustler::Error::RaiseTerm(Box::new(error_message)))
            } else {
                Ok(Some(bytes.to_vec()))
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
#[rustler::nif(name = "noise_handshake_write")]
fn handshake_write<'a>(
    env: Env<'a>,
    session: ResourceArc<NoiseSession>,
    payload: Binary<'a>,
) -> NifResult<Binary<'a>> {
    let mut guard = session
        .state
        .lock()
        .map_err(|_| rustler::Error::RaiseTerm(Box::new("mutex poisoned")))?;

    match &mut *guard {
        NoiseState::Handshake(hs) => {
            let mut buf = vec![0u8; MAX_MSG_SIZE];
            let len = hs
                .write_message(payload.as_slice(), &mut buf)
                .map_err(|e| {
                    rustler::Error::RaiseTerm(Box::new(format!("handshake write failed: {e}")))
                })?;

            let mut out = NewBinary::new(env, len);
            out.as_mut_slice().copy_from_slice(&buf[..len]);
            Ok(out.into())
        }
        NoiseState::Transport(_) => Err(rustler::Error::RaiseTerm(Box::new(
            "cannot write handshake: already in transport mode",
        ))),
        NoiseState::Transitioning => Err(rustler::Error::RaiseTerm(Box::new(
            "session is transitioning",
        ))),
    }
}

/// Read a handshake message from the peer.
///
/// Advances the Noise handshake state machine by processing an incoming message.
/// Returns the decrypted payload from the handshake message.
#[rustler::nif(name = "noise_handshake_read")]
fn handshake_read<'a>(
    env: Env<'a>,
    session: ResourceArc<NoiseSession>,
    message: Binary<'a>,
) -> NifResult<Binary<'a>> {
    let mut guard = session
        .state
        .lock()
        .map_err(|_| rustler::Error::RaiseTerm(Box::new("mutex poisoned")))?;

    match &mut *guard {
        NoiseState::Handshake(hs) => {
            let mut buf = vec![0u8; MAX_MSG_SIZE];
            let len = hs.read_message(message.as_slice(), &mut buf).map_err(|e| {
                rustler::Error::RaiseTerm(Box::new(format!("handshake read failed: {e}")))
            })?;

            let mut out = NewBinary::new(env, len);
            out.as_mut_slice().copy_from_slice(&buf[..len]);
            Ok(out.into())
        }
        NoiseState::Transport(_) => Err(rustler::Error::RaiseTerm(Box::new(
            "cannot read handshake: already in transport mode",
        ))),
        NoiseState::Transitioning => Err(rustler::Error::RaiseTerm(Box::new(
            "session is transitioning",
        ))),
    }
}

/// Transition the session from Handshake to Transport mode.
///
/// Must be called after the handshake is complete (all XX pattern messages exchanged).
/// After this call, `encrypt` and `decrypt` become available, and `handshake_write`/
/// `handshake_read` will return errors.
#[rustler::nif(name = "noise_finish")]
fn finish(session: ResourceArc<NoiseSession>) -> NifResult<Atom> {
    let mut guard = session
        .state
        .lock()
        .map_err(|_| rustler::Error::RaiseTerm(Box::new("mutex poisoned")))?;

    // Take the current state out, replacing with Transitioning temporarily
    let state = std::mem::replace(&mut *guard, NoiseState::Transitioning);

    match state {
        NoiseState::Handshake(hs) => {
            let transport = hs.into_transport_mode().map_err(|e| {
                // HandshakeState was consumed — session is now unusable on error.
                rustler::Error::RaiseTerm(Box::new(format!("finish failed: {e}")))
            })?;
            *guard = NoiseState::Transport(transport);
            Ok(atoms::ok())
        }
        NoiseState::Transport(t) => {
            // Already in transport mode — restore state and report error
            *guard = NoiseState::Transport(t);
            Err(rustler::Error::RaiseTerm(Box::new(
                "already in transport mode",
            )))
        }
        NoiseState::Transitioning => Err(rustler::Error::RaiseTerm(Box::new(
            "session is transitioning",
        ))),
    }
}

/// Encrypt a plaintext message using the transport session.
///
/// The Noise transport state maintains an internal counter for nonce generation.
/// Each call advances the write counter. Returns ciphertext with appended auth tag.
#[rustler::nif(name = "noise_encrypt")]
fn encrypt<'a>(
    env: Env<'a>,
    session: ResourceArc<NoiseSession>,
    plaintext: Binary<'a>,
) -> NifResult<Binary<'a>> {
    let mut guard = session
        .state
        .lock()
        .map_err(|_| rustler::Error::RaiseTerm(Box::new("mutex poisoned")))?;

    match &mut *guard {
        NoiseState::Transport(ts) => {
            let mut buf = vec![0u8; MAX_MSG_SIZE];
            let len = ts
                .write_message(plaintext.as_slice(), &mut buf)
                .map_err(|e| rustler::Error::RaiseTerm(Box::new(format!("encrypt failed: {e}"))))?;

            let mut out = NewBinary::new(env, len);
            out.as_mut_slice().copy_from_slice(&buf[..len]);
            Ok(out.into())
        }
        NoiseState::Handshake(_) => Err(rustler::Error::RaiseTerm(Box::new(
            "cannot encrypt: still in handshake mode",
        ))),
        NoiseState::Transitioning => Err(rustler::Error::RaiseTerm(Box::new(
            "session is transitioning",
        ))),
    }
}

/// Decrypt a ciphertext message using the transport session.
///
/// The Noise transport state maintains an internal counter for nonce generation.
/// Each call advances the read counter. Returns the decrypted plaintext.
#[rustler::nif(name = "noise_decrypt")]
fn decrypt<'a>(
    env: Env<'a>,
    session: ResourceArc<NoiseSession>,
    ciphertext: Binary<'a>,
) -> NifResult<Binary<'a>> {
    let mut guard = session
        .state
        .lock()
        .map_err(|_| rustler::Error::RaiseTerm(Box::new("mutex poisoned")))?;

    match &mut *guard {
        NoiseState::Transport(ts) => {
            let mut buf = vec![0u8; MAX_MSG_SIZE];
            let len = ts
                .read_message(ciphertext.as_slice(), &mut buf)
                .map_err(|e| rustler::Error::RaiseTerm(Box::new(format!("decrypt failed: {e}"))))?;

            let mut out = NewBinary::new(env, len);
            out.as_mut_slice().copy_from_slice(&buf[..len]);
            Ok(out.into())
        }
        NoiseState::Handshake(_) => Err(rustler::Error::RaiseTerm(Box::new(
            "cannot decrypt: still in handshake mode",
        ))),
        NoiseState::Transitioning => Err(rustler::Error::RaiseTerm(Box::new(
            "session is transitioning",
        ))),
    }
}
