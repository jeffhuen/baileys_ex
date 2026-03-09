defmodule BaileysEx.Signal.Group.SenderKeyName do
  @moduledoc false

  alias BaileysEx.Signal.Address

  @type t :: %__MODULE__{
          group_id: String.t(),
          sender: Address.t()
        }

  @enforce_keys [:group_id, :sender]
  defstruct [:group_id, :sender]

  @spec new(String.t(), Address.t()) :: t()
  def new(group_id, %Address{} = sender), do: %__MODULE__{group_id: group_id, sender: sender}

  @spec serialize(t()) :: String.t()
  def serialize(%__MODULE__{
        group_id: group_id,
        sender: %Address{name: name, device_id: device_id}
      }) do
    "#{group_id}::#{name}::#{device_id}"
  end
end
