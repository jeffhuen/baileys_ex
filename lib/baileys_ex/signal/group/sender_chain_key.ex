defmodule BaileysEx.Signal.Group.SenderChainKey do
  @moduledoc false

  alias BaileysEx.Crypto
  alias BaileysEx.Signal.Group.SenderMessageKey

  @message_key_seed <<1>>
  @chain_key_seed <<2>>

  @type t :: %__MODULE__{
          iteration: non_neg_integer(),
          seed: binary()
        }

  @enforce_keys [:iteration, :seed]
  defstruct [:iteration, :seed]

  @spec new(non_neg_integer(), binary()) :: t()
  def new(iteration, seed), do: %__MODULE__{iteration: iteration, seed: seed}

  @spec sender_message_key(t()) :: SenderMessageKey.t()
  def sender_message_key(%__MODULE__{iteration: iteration, seed: seed}) do
    SenderMessageKey.new(iteration, Crypto.hmac_sha256(seed, @message_key_seed))
  end

  @spec next(t()) :: t()
  def next(%__MODULE__{iteration: iteration, seed: seed}) do
    %__MODULE__{iteration: iteration + 1, seed: Crypto.hmac_sha256(seed, @chain_key_seed)}
  end
end
