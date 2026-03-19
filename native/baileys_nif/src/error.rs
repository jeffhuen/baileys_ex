#[derive(Debug)]
pub(crate) enum NifError {
    InvalidNoisePattern(snow::Error),
    InvalidKeySize(&'static str),
    KeypairGeneration(snow::Error),
    SnowInit(snow::Error),
    MutexPoisoned,
    HandshakeWrite(snow::Error),
    HandshakeWriteInTransport,
    HandshakeRead(snow::Error),
    HandshakeReadInTransport,
    SessionTransitioning,
    Finish(snow::Error),
    AlreadyInTransport,
    EncryptInHandshake,
    Encrypt(snow::Error),
    DecryptInHandshake,
    Decrypt(snow::Error),
    PrivateKeyMustBe32Bytes,
}

impl std::fmt::Display for NifError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidNoisePattern(error) => write!(f, "invalid noise pattern: {error}"),
            Self::InvalidKeySize(message) => f.write_str(message),
            Self::KeypairGeneration(error) => write!(f, "keypair gen failed: {error}"),
            Self::SnowInit(error) => write!(f, "snow init failed: {error}"),
            Self::MutexPoisoned => f.write_str("mutex poisoned"),
            Self::HandshakeWrite(error) => write!(f, "handshake write failed: {error}"),
            Self::HandshakeWriteInTransport => {
                f.write_str("cannot write handshake: already in transport mode")
            }
            Self::HandshakeRead(error) => write!(f, "handshake read failed: {error}"),
            Self::HandshakeReadInTransport => {
                f.write_str("cannot read handshake: already in transport mode")
            }
            Self::SessionTransitioning => f.write_str("session is transitioning"),
            Self::Finish(error) => write!(f, "finish failed: {error}"),
            Self::AlreadyInTransport => f.write_str("already in transport mode"),
            Self::EncryptInHandshake => f.write_str("cannot encrypt: still in handshake mode"),
            Self::Encrypt(error) => write!(f, "encrypt failed: {error}"),
            Self::DecryptInHandshake => f.write_str("cannot decrypt: still in handshake mode"),
            Self::Decrypt(error) => write!(f, "decrypt failed: {error}"),
            Self::PrivateKeyMustBe32Bytes => f.write_str("private key must be 32 bytes"),
        }
    }
}

impl std::error::Error for NifError {}

impl From<NifError> for rustler::Error {
    fn from(error: NifError) -> Self {
        Self::RaiseTerm(Box::new(error.to_string()))
    }
}
