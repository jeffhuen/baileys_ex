defmodule BaileysEx.Native.Noise do
  @moduledoc """
  Noise protocol NIF wrapping the `snow` crate.

  Handles transport-level encryption for the WhatsApp WebSocket connection.
  Uses the Noise XX pattern with Curve25519, AES-256-GCM, and SHA-256.
  """

  use Rustler, otp_app: :baileys_ex, crate: "baileys_nif"

  @spec init(binary()) :: {:ok, reference()} | {:error, term()}
  def init(_prologue), do: :erlang.nif_error(:nif_not_loaded)

  @spec handshake_write(reference(), binary()) :: {:ok, binary()} | {:error, term()}
  def handshake_write(_state, _payload), do: :erlang.nif_error(:nif_not_loaded)

  @spec handshake_read(reference(), binary()) :: {:ok, binary()} | {:error, term()}
  def handshake_read(_state, _message), do: :erlang.nif_error(:nif_not_loaded)

  @spec finish(reference()) :: {:ok, reference()} | {:error, term()}
  def finish(_state), do: :erlang.nif_error(:nif_not_loaded)

  @spec encrypt(reference(), binary()) :: {:ok, binary()} | {:error, term()}
  def encrypt(_state, _plaintext), do: :erlang.nif_error(:nif_not_loaded)

  @spec decrypt(reference(), binary()) :: {:ok, binary()} | {:error, term()}
  def decrypt(_state, _ciphertext), do: :erlang.nif_error(:nif_not_loaded)
end
