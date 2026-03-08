defmodule BaileysEx.Native.XEdDSA do
  @moduledoc """
  XEdDSA signing/verification via curve25519-dalek NIF.

  Required for WhatsApp wire compatibility: identity keys are Curve25519
  (Montgomery form) but must produce Ed25519-compatible signatures for
  signed pre-keys and sender key messages.
  """

  use Rustler, otp_app: :baileys_ex, crate: "baileys_nif"

  @spec sign(binary(), binary()) :: {:ok, binary()} | {:error, term()}
  def sign(_private_key, _message), do: :erlang.nif_error(:nif_not_loaded)

  @spec verify(binary(), binary(), binary()) :: boolean()
  def verify(_public_key, _message, _signature), do: :erlang.nif_error(:nif_not_loaded)
end
