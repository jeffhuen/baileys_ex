defmodule BaileysEx.Native do
  @moduledoc false

  use Rustler, otp_app: :baileys_ex, crate: "baileys_nif"

  # Noise NIFs
  def noise_init(_prologue), do: :erlang.nif_error(:nif_not_loaded)
  def noise_init_responder(_prologue), do: :erlang.nif_error(:nif_not_loaded)
  def noise_handshake_write(_session, _payload), do: :erlang.nif_error(:nif_not_loaded)
  def noise_handshake_read(_session, _message), do: :erlang.nif_error(:nif_not_loaded)
  def noise_finish(_session), do: :erlang.nif_error(:nif_not_loaded)
  def noise_encrypt(_session, _plaintext), do: :erlang.nif_error(:nif_not_loaded)
  def noise_decrypt(_session, _ciphertext), do: :erlang.nif_error(:nif_not_loaded)

  # XEdDSA NIFs
  def xeddsa_sign(_private_key, _message), do: :erlang.nif_error(:nif_not_loaded)
  def xeddsa_verify(_public_key, _message, _signature), do: :erlang.nif_error(:nif_not_loaded)
end
