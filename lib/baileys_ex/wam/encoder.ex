defmodule BaileysEx.WAM.Encoder do
  @moduledoc """
  Pure Elixir WAM encoder matching Baileys rc9's `src/WAM/encode.ts`.
  """

  import Bitwise

  alias BaileysEx.WAM.BinaryInfo
  alias BaileysEx.WAM.Definitions

  @flag_byte 8
  @flag_global 0
  @flag_event 1
  @flag_field 2
  @flag_extended 4

  @doc "Encode a `BinaryInfo` struct into a WAM binary payload."
  @spec encode(BinaryInfo.t()) :: binary()
  def encode(%BinaryInfo{} = binary_info) do
    [encode_header(binary_info) | encode_events(binary_info.events)]
    |> IO.iodata_to_binary()
  end

  defp encode_header(%BinaryInfo{protocol_version: protocol_version, sequence: sequence}) do
    <<"WAM", protocol_version, 1, sequence::16-big, 0>>
  end

  defp encode_events(events) do
    Enum.flat_map(events, &encode_event/1)
  end

  defp encode_event(%{name: name} = event_input) do
    definition = Definitions.event!(name)
    globals = encode_globals(Map.get(event_input, :globals, []))
    props = Map.get(event_input, :props, [])
    props_length = length(props)

    event_flag =
      if any_present_value?(props), do: @flag_event, else: @flag_event ||| @flag_extended

    [
      globals,
      serialize_data(definition.id, -definition.weight, event_flag),
      encode_props(props, definition.props, props_length)
    ]
  end

  defp encode_globals(globals) do
    Enum.map(globals, fn {name, value} ->
      definition = Definitions.global!(name)
      serialize_data(definition.id, normalize_value(value), @flag_global)
    end)
  end

  defp encode_props(props, prop_definitions, props_length) do
    props
    |> Enum.with_index()
    |> Enum.map(fn {{name, value}, index} ->
      definition = Map.fetch!(prop_definitions, normalize_name(name))
      flag = if index < props_length - 1, do: @flag_event, else: @flag_field ||| @flag_extended
      serialize_data(definition.id, normalize_value(value), flag)
    end)
  end

  defp serialize_data(key, nil, @flag_global), do: serialize_header(key, @flag_global)

  defp serialize_data(_key, nil, _flag) do
    raise ArgumentError, "WAM event fields do not support nil values"
  end

  defp serialize_data(key, value, flag) when is_integer(value) do
    cond do
      value in [0, 1] ->
        serialize_header(key, flag ||| (value + 1) <<< 4)

      -128 <= value and value < 128 ->
        [serialize_header(key, flag ||| 3 <<< 4), <<value::signed-little-integer-size(8)>>]

      -32_768 <= value and value < 32_768 ->
        [serialize_header(key, flag ||| 4 <<< 4), <<value::signed-little-integer-size(16)>>]

      -2_147_483_648 <= value and value < 2_147_483_648 ->
        [serialize_header(key, flag ||| 5 <<< 4), <<value::signed-little-integer-size(32)>>]

      true ->
        [serialize_header(key, flag ||| 7 <<< 4), <<value::float-little-size(64)>>]
    end
  end

  defp serialize_data(key, value, flag) when is_float(value) do
    [serialize_header(key, flag ||| 7 <<< 4), <<value::float-little-size(64)>>]
  end

  defp serialize_data(key, value, flag) when is_binary(value) do
    utf8_bytes = byte_size(value)

    cond do
      utf8_bytes < 256 ->
        [serialize_header(key, flag ||| 8 <<< 4), <<utf8_bytes>>, value]

      utf8_bytes < 65_536 ->
        [serialize_header(key, flag ||| 9 <<< 4), <<utf8_bytes::unsigned-little-size(16)>>, value]

      true ->
        [
          serialize_header(key, flag ||| 10 <<< 4),
          <<utf8_bytes::unsigned-little-size(32)>>,
          value
        ]
    end
  end

  defp serialize_header(key, flag) when key < 256, do: <<flag, key>>
  defp serialize_header(key, flag), do: <<flag ||| @flag_byte, key::unsigned-little-size(16)>>

  defp any_present_value?(props) do
    Enum.any?(props, fn {_name, value} -> not is_nil(value) end)
  end

  defp normalize_value(true), do: 1
  defp normalize_value(false), do: 0
  defp normalize_value(value), do: value

  defp normalize_name(name) when is_atom(name), do: Atom.to_string(name)
  defp normalize_name(name) when is_binary(name), do: name
end
