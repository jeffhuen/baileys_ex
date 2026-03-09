defmodule BaileysEx.Signal.Group.SenderMessageKey do
  @moduledoc false

  alias BaileysEx.Crypto

  @whisper_group "WhisperGroup"
  @zero_salt <<0::256>>

  @type t :: %__MODULE__{
          iteration: non_neg_integer(),
          iv: binary(),
          cipher_key: binary(),
          seed: binary()
        }

  @enforce_keys [:iteration, :iv, :cipher_key, :seed]
  defstruct [:iteration, :iv, :cipher_key, :seed]

  @spec new(non_neg_integer(), binary()) :: t()
  def new(iteration, seed) do
    {:ok, derived} = Crypto.hkdf(seed, @whisper_group, 48, @zero_salt)
    <<iv::binary-size(16), cipher_key::binary-size(32)>> = derived
    %__MODULE__{iteration: iteration, iv: iv, cipher_key: cipher_key, seed: seed}
  end
end
