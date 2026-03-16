defmodule BaileysEx.WAM.BinaryInfo do
  @moduledoc """
  Ordered WAM buffer input matching Baileys rc9's `BinaryInfo`.
  """

  @typedoc "Scalar values accepted by the WAM encoder."
  @type value :: integer() | float() | boolean() | String.t() | nil

  @typedoc """
  Ordered WAM key/value pairs.

  Lists preserve the same insertion order Baileys gets from JavaScript objects.
  """
  @type ordered_values :: [{String.t() | atom(), value()}]

  @typedoc "One WAM event entry to encode into the buffer."
  @type event_input :: %{
          required(:name) => String.t() | atom(),
          optional(:props) => ordered_values(),
          optional(:globals) => ordered_values()
        }

  @type t :: %__MODULE__{
          protocol_version: non_neg_integer(),
          sequence: non_neg_integer(),
          events: [event_input()]
        }

  @enforce_keys [:protocol_version, :sequence, :events]
  defstruct protocol_version: 5, sequence: 0, events: []

  @doc "Create a new WAM buffer."
  @spec new(keyword()) :: t()
  def new(opts \\ []) when is_list(opts) do
    %__MODULE__{
      protocol_version: Keyword.get(opts, :protocol_version, 5),
      sequence: Keyword.get(opts, :sequence, 0),
      events: Keyword.get(opts, :events, [])
    }
  end
end
