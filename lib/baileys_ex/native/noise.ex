defmodule BaileysEx.Native.Noise do
  @moduledoc """
  Low-level raw Noise XX NIF wrapping the `snow` crate.

  This is not the WhatsApp protocol surface. Baileys' real handshake flow is
  protobuf-wrapped and certificate-aware, so the reference-aligned
  implementation lives in `BaileysEx.Protocol.Noise`.

  Keep this wrapper sharp and limited: it exposes the underlying raw XX state
  machine for low-level tests and experiments, while the WhatsApp-specific
  choreography stays at the protocol layer.

  The session lifecycle is:

  1. `init/1` -- create an initiator handshake session with a prologue
  2. `handshake_write/2` / `handshake_read/2` -- exchange XX pattern messages
  3. `finish/1` -- transition to transport mode
  4. `encrypt/2` / `decrypt/2` -- transport-level frame encryption

  The session is held as an opaque NIF resource (ResourceArc). State transitions
  happen in-place behind a mutex -- the same reference is used throughout.
  """

  alias BaileysEx.Native

  @typedoc "Opaque NIF resource representing a Noise protocol session."
  @type session :: reference()

  @doc """
  Initialize a Noise XX initiator session.

  The `prologue` is mixed into the handshake hash for channel binding.
  Both sides must use the same prologue for the handshake to succeed.

  Returns an opaque session reference for use with `handshake_write/2`.
  """
  @spec init(binary(), keyword()) :: session()
  def init(prologue, opts \\ []) do
    Native.noise_init(
      prologue,
      Keyword.get(opts, :private_key),
      Keyword.get(opts, :ephemeral_private_key)
    )
  end

  @doc """
  Initialize a Noise XX responder session.

  Used for testing full handshake flows. Production WhatsApp connections
  only use the initiator side -- the server is the responder.
  """
  @spec init_responder(binary(), keyword()) :: session()
  def init_responder(prologue, opts \\ []) do
    Native.noise_init_responder(
      prologue,
      Keyword.get(opts, :private_key),
      Keyword.get(opts, :ephemeral_private_key)
    )
  end

  @doc """
  Write the next handshake message.

  Advances the handshake state machine and produces an outgoing message
  containing the encrypted `payload`. Returns the message bytes to send.

  Raises if the session is already in transport mode.
  """
  @spec handshake_write(session(), binary()) :: binary()
  def handshake_write(session, payload), do: Native.noise_handshake_write(session, payload)

  @doc """
  Read a handshake message from the peer.

  Advances the handshake state machine by processing an incoming `message`.
  Returns the decrypted payload extracted from the message.

  Raises if the session is already in transport mode.
  """
  @spec handshake_read(session(), binary()) :: binary()
  def handshake_read(session, message), do: Native.noise_handshake_read(session, message)

  @doc """
  Transition the session from Handshake to Transport mode.

  Must be called after all three XX pattern messages have been exchanged.
  After this call, `encrypt/2` and `decrypt/2` become available.

  The same session reference is reused -- the internal state transitions in-place.
  """
  @spec finish(session()) :: :ok
  def finish(session), do: Native.noise_finish(session)

  @doc """
  Encrypt a plaintext frame using the transport session.

  The session maintains an internal write counter for nonce generation.
  Each call advances the counter. Returns ciphertext with appended auth tag.

  Raises if the session is still in handshake mode.
  """
  @spec encrypt(session(), binary()) :: binary()
  def encrypt(session, plaintext), do: Native.noise_encrypt(session, plaintext)

  @doc """
  Decrypt a ciphertext frame using the transport session.

  The session maintains an internal read counter for nonce generation.
  Each call advances the counter. Returns the decrypted plaintext.

  Raises if the session is still in handshake mode.
  """
  @spec decrypt(session(), binary()) :: binary()
  def decrypt(session, ciphertext), do: Native.noise_decrypt(session, ciphertext)
end
