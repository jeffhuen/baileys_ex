defmodule BaileysEx.Signal.Group.SenderKeyRecord do
  @moduledoc false

  alias BaileysEx.Signal.Group.SenderKeyState

  @max_states 5

  @type t :: %__MODULE__{
          sender_key_states: [SenderKeyState.t()]
        }

  @enforce_keys [:sender_key_states]
  defstruct [:sender_key_states]

  @spec new() :: t()
  def new, do: %__MODULE__{sender_key_states: []}

  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{sender_key_states: states}), do: states == []

  @spec current_state(t()) :: SenderKeyState.t() | nil
  def current_state(%__MODULE__{sender_key_states: []}), do: nil
  def current_state(%__MODULE__{sender_key_states: states}), do: List.last(states)

  @spec state_for_key_id(t(), non_neg_integer()) :: SenderKeyState.t() | nil
  def state_for_key_id(%__MODULE__{sender_key_states: states}, key_id) do
    Enum.find(states, &(&1.sender_key_id == key_id))
  end

  @spec add_state(t(), non_neg_integer(), non_neg_integer(), binary(), binary()) :: t()
  def add_state(
        %__MODULE__{sender_key_states: states} = record,
        id,
        iteration,
        chain_key,
        signature_key
      ) do
    state = SenderKeyState.new(id, iteration, chain_key, %{public: signature_key, private: nil})
    %{record | sender_key_states: Enum.take(states ++ [state], -@max_states)}
  end

  @spec set_state(t(), non_neg_integer(), non_neg_integer(), binary(), %{
          public: binary(),
          private: binary()
        }) :: t()
  def set_state(%__MODULE__{} = record, id, iteration, chain_key, key_pair) do
    %{record | sender_key_states: [SenderKeyState.new(id, iteration, chain_key, key_pair)]}
  end

  @spec put_state(t(), SenderKeyState.t()) :: t()
  def put_state(%__MODULE__{sender_key_states: states} = record, %SenderKeyState{} = state) do
    updated_states = Enum.reject(states, &(&1.sender_key_id == state.sender_key_id)) ++ [state]

    %{record | sender_key_states: Enum.take(updated_states, -@max_states)}
  end
end
