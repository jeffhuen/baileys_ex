defmodule BaileysEx.Signal.Group.SenderKeyState do
  @moduledoc false

  alias BaileysEx.Signal.Curve
  alias BaileysEx.Signal.Group.SenderChainKey
  alias BaileysEx.Signal.Group.SenderMessageKey

  @max_message_keys 2000

  @type structure :: %{
          sender_key_id: non_neg_integer(),
          sender_chain_key: %{
            iteration: non_neg_integer(),
            seed: binary()
          },
          sender_signing_key: %{
            public: binary(),
            private: binary() | nil
          },
          sender_message_keys: [
            %{
              iteration: non_neg_integer(),
              seed: binary()
            }
          ]
        }

  @type t :: %__MODULE__{
          sender_key_id: non_neg_integer(),
          sender_chain_key: SenderChainKey.t(),
          sender_signing_key: %{
            public: binary(),
            private: binary() | nil
          },
          sender_message_keys: [SenderMessageKey.t()]
        }

  @enforce_keys [:sender_key_id, :sender_chain_key, :sender_signing_key, :sender_message_keys]
  defstruct [:sender_key_id, :sender_chain_key, :sender_signing_key, :sender_message_keys]

  @spec new(non_neg_integer(), non_neg_integer(), binary(), %{
          public: binary(),
          private: binary() | nil
        }) :: t()
  def new(id, iteration, chain_key, signing_key) do
    %__MODULE__{
      sender_key_id: id,
      sender_chain_key: SenderChainKey.new(iteration, chain_key),
      sender_signing_key: %{public: signing_key.public, private: signing_key[:private]},
      sender_message_keys: []
    }
  end

  @spec from_structure(map()) :: t()
  def from_structure(
        %{
          sender_key_id: id,
          sender_chain_key: %{iteration: iteration, seed: seed},
          sender_signing_key: signing_key
        } = structure
      ) do
    sender_message_keys =
      structure
      |> Map.get(:sender_message_keys, [])
      |> Enum.map(fn %{iteration: iteration, seed: seed} ->
        SenderMessageKey.new(iteration, seed)
      end)

    %__MODULE__{
      sender_key_id: id,
      sender_chain_key: SenderChainKey.new(iteration, seed),
      sender_signing_key: %{public: signing_key.public, private: signing_key[:private]},
      sender_message_keys: sender_message_keys
    }
  end

  @spec to_structure(t()) :: structure()
  def to_structure(%__MODULE__{} = state) do
    %{
      sender_key_id: state.sender_key_id,
      sender_chain_key: %{
        iteration: state.sender_chain_key.iteration,
        seed: state.sender_chain_key.seed
      },
      sender_signing_key: state.sender_signing_key,
      sender_message_keys:
        Enum.map(state.sender_message_keys, fn key ->
          %{iteration: key.iteration, seed: key.seed}
        end)
    }
  end

  @spec signing_key_public(t()) :: binary()
  def signing_key_public(%__MODULE__{sender_signing_key: %{public: public_key}}) do
    case Curve.generate_signal_pub_key(public_key) do
      {:ok, prefixed} -> prefixed
      {:error, :invalid_public_key} -> public_key
    end
  end

  @spec signing_key_private(t()) :: binary() | nil
  def signing_key_private(%__MODULE__{sender_signing_key: %{private: private_key}}),
    do: private_key

  @spec has_sender_message_key?(t(), non_neg_integer()) :: boolean()
  def has_sender_message_key?(%__MODULE__{sender_message_keys: message_keys}, iteration) do
    Enum.any?(message_keys, &(&1.iteration == iteration))
  end

  @spec add_sender_message_key(t(), SenderMessageKey.t()) :: t()
  def add_sender_message_key(
        %__MODULE__{sender_message_keys: message_keys} = state,
        %SenderMessageKey{} = key
      ) do
    trimmed =
      (message_keys ++ [key])
      |> Enum.take(-@max_message_keys)

    %{state | sender_message_keys: trimmed}
  end

  @spec remove_sender_message_key(t(), non_neg_integer()) :: {t(), SenderMessageKey.t() | nil}
  def remove_sender_message_key(%__MODULE__{sender_message_keys: message_keys} = state, iteration) do
    {matches, remaining} = Enum.split_with(message_keys, &(&1.iteration == iteration))
    {%{state | sender_message_keys: remaining}, List.first(matches)}
  end

  @spec put_sender_chain_key(t(), SenderChainKey.t()) :: t()
  def put_sender_chain_key(%__MODULE__{} = state, %SenderChainKey{} = chain_key) do
    %{state | sender_chain_key: chain_key}
  end
end
