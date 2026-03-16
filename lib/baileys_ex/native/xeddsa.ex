defmodule BaileysEx.Native.XEdDSA do
  @moduledoc """
  XEdDSA signing/verification via curve25519-dalek NIF.

  Required for WhatsApp wire compatibility: identity keys are Curve25519
  (Montgomery form) but must produce Ed25519-compatible signatures for
  signed pre-keys and sender key messages.
  """

  alias BaileysEx.Native

  @doc "Signs a message using the XEdDSA signature scheme."
  @spec sign(binary(), binary()) :: {:ok, binary()}
  def sign(private_key, message), do: {:ok, Native.xeddsa_sign(private_key, message)}

  @doc "Verifies an XEdDSA signature over a given message."
  @spec verify(binary(), binary(), binary()) :: boolean()
  def verify(public_key, message, signature),
    do: Native.xeddsa_verify(public_key, message, signature)
end
