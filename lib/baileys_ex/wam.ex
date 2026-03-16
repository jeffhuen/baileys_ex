defmodule BaileysEx.WAM do
  @moduledoc """
  WhatsApp Analytics/Metrics helpers backed by the Baileys rc9 event registry.
  """

  alias BaileysEx.WAM.BinaryInfo
  alias BaileysEx.WAM.Encoder

  @typedoc "Scalar values accepted by the WAM encoder."
  @type value :: BinaryInfo.value()

  @typedoc "Ordered WAM key/value pairs."
  @type ordered_values :: BinaryInfo.ordered_values()

  @typedoc "One event entry for a WAM buffer."
  @type event_input :: BinaryInfo.event_input()

  @doc "Create a new WAM buffer."
  @spec new(keyword()) :: BinaryInfo.t()
  def new(opts \\ []), do: BinaryInfo.new(opts)

  @doc "Build an ordered WAM event payload."
  @spec event(String.t() | atom(), ordered_values(), ordered_values()) :: event_input()
  def event(name, props \\ [], globals \\ []) when is_list(props) and is_list(globals) do
    %{name: name, props: props, globals: globals}
  end

  @doc "Append a WAM event entry to the buffer."
  @spec put_event(BinaryInfo.t(), event_input()) :: BinaryInfo.t()
  def put_event(%BinaryInfo{} = binary_info, %{name: _name} = event_input) do
    %{binary_info | events: binary_info.events ++ [event_input]}
  end

  @doc "Append a named WAM event to the buffer."
  @spec put_event(BinaryInfo.t(), String.t() | atom(), ordered_values(), ordered_values()) ::
          BinaryInfo.t()
  def put_event(%BinaryInfo{} = binary_info, name, props, globals \\ [])
      when is_list(props) and is_list(globals) do
    put_event(binary_info, event(name, props, globals))
  end

  @doc "Clear buffered events while preserving the current sequence."
  @spec clear_events(BinaryInfo.t()) :: BinaryInfo.t()
  def clear_events(%BinaryInfo{} = binary_info), do: %{binary_info | events: []}

  @doc "Increment the WAM buffer sequence."
  @spec increment_sequence(BinaryInfo.t()) :: BinaryInfo.t()
  def increment_sequence(%BinaryInfo{} = binary_info) do
    %{binary_info | sequence: binary_info.sequence + 1}
  end

  @doc "Encode a WAM buffer into the rc9 binary wire format."
  @spec encode(BinaryInfo.t()) :: binary()
  def encode(%BinaryInfo{} = binary_info), do: Encoder.encode(binary_info)
end
