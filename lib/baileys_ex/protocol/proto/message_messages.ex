# credo:disable-for-this-file Credo.Check.Warning.StructFieldAmount

defmodule BaileysEx.Protocol.Proto.MessageSupport do
  @moduledoc false

  alias BaileysEx.Protocol.Proto.Wire

  def encode_fields(struct, specs) do
    Enum.reduce(specs, <<>>, fn {field, spec}, acc ->
      acc <> encode_field(Map.get(struct, field), spec)
    end)
  end

  def decode_fields(binary, struct, specs) do
    field_map = Map.new(specs, fn {field, spec} -> {field_number(spec), {field, spec}} end)

    with {:ok, decoded} <- do_decode_fields(binary, struct, field_map) do
      {:ok, reverse_repeated_fields(decoded, specs)}
    end
  end

  defp do_decode_fields(<<>>, struct, _field_map), do: {:ok, struct}

  defp do_decode_fields(binary, struct, field_map) do
    case Wire.decode_key(binary) do
      {:ok, field_number, wire_type, rest} ->
        case Map.get(field_map, field_number) do
          nil ->
            Wire.skip_and_continue(wire_type, rest, struct, &do_decode_fields(&1, &2, field_map))

          {field, spec} ->
            decode_field(rest, struct, field, spec, wire_type, field_map)
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp encode_field(nil, _spec), do: <<>>

  defp encode_field(value, {:string, field_number}), do: Wire.encode_bytes(field_number, value)
  defp encode_field(value, {:bytes, field_number}), do: Wire.encode_bytes(field_number, value)
  defp encode_field(value, {:bool, field_number}), do: Wire.encode_bool(field_number, value)
  defp encode_field(value, {:uint, field_number}), do: Wire.encode_uint(field_number, value)
  defp encode_field(value, {:int, field_number}), do: Wire.encode_uint(field_number, value)
  defp encode_field(value, {:int64, field_number}), do: Wire.encode_uint(field_number, value)
  defp encode_field(value, {:fixed32, field_number}), do: Wire.encode_fixed32(field_number, value)
  defp encode_field(value, {:float, field_number}), do: Wire.encode_float(field_number, value)
  defp encode_field(value, {:double, field_number}), do: Wire.encode_double(field_number, value)

  defp encode_field(value, {:enum, field_number, mapping}) when is_atom(value) do
    Wire.encode_uint(field_number, Map.fetch!(mapping, value))
  end

  defp encode_field(value, {:enum, field_number, _mapping}) when is_integer(value) do
    Wire.encode_uint(field_number, value)
  end

  defp encode_field(value, {:message, field_number, module}) do
    Wire.encode_bytes(field_number, module.encode(value))
  end

  defp encode_field(values, {:repeated_string, field_number}) when is_list(values) do
    Enum.reduce(values, <<>>, fn value, acc -> acc <> Wire.encode_bytes(field_number, value) end)
  end

  defp encode_field(values, {:repeated_bytes, field_number}) when is_list(values) do
    Enum.reduce(values, <<>>, fn value, acc -> acc <> Wire.encode_bytes(field_number, value) end)
  end

  defp encode_field(values, {:repeated_message, field_number, module}) when is_list(values) do
    Enum.reduce(values, <<>>, fn value, acc ->
      acc <> Wire.encode_bytes(field_number, module.encode(value))
    end)
  end

  defp decode_field(rest, struct, field, {:string, _field_number}, 2, field_map) do
    Wire.continue_bytes(
      rest,
      struct,
      &Map.put(&1, field, &2),
      &do_decode_fields(&1, &2, field_map)
    )
  end

  defp decode_field(rest, struct, field, {:bytes, _field_number}, 2, field_map) do
    Wire.continue_bytes(
      rest,
      struct,
      &Map.put(&1, field, &2),
      &do_decode_fields(&1, &2, field_map)
    )
  end

  defp decode_field(rest, struct, field, {:bool, _field_number}, 0, field_map) do
    Wire.continue_varint(
      rest,
      struct,
      &Map.put(&1, field, &2 != 0),
      &do_decode_fields(&1, &2, field_map)
    )
  end

  defp decode_field(rest, struct, field, {:uint, _field_number}, 0, field_map) do
    Wire.continue_varint(
      rest,
      struct,
      &Map.put(&1, field, &2),
      &do_decode_fields(&1, &2, field_map)
    )
  end

  defp decode_field(rest, struct, field, {:int, _field_number}, 0, field_map) do
    Wire.continue_varint(
      rest,
      struct,
      &Map.put(&1, field, &2),
      &do_decode_fields(&1, &2, field_map)
    )
  end

  defp decode_field(rest, struct, field, {:int64, _field_number}, 0, field_map) do
    Wire.continue_varint(
      rest,
      struct,
      &Map.put(&1, field, &2),
      &do_decode_fields(&1, &2, field_map)
    )
  end

  defp decode_field(rest, struct, field, {:fixed32, _field_number}, 5, field_map) do
    Wire.continue_fixed32(
      rest,
      struct,
      &Map.put(&1, field, &2),
      &do_decode_fields(&1, &2, field_map)
    )
  end

  defp decode_field(rest, struct, field, {:float, _field_number}, 5, field_map) do
    Wire.continue_float(
      rest,
      struct,
      &Map.put(&1, field, &2),
      &do_decode_fields(&1, &2, field_map)
    )
  end

  defp decode_field(rest, struct, field, {:double, _field_number}, 1, field_map) do
    Wire.continue_double(
      rest,
      struct,
      &Map.put(&1, field, &2),
      &do_decode_fields(&1, &2, field_map)
    )
  end

  defp decode_field(rest, struct, field, {:enum, _field_number, mapping}, 0, field_map) do
    reverse_mapping = Map.new(mapping, fn {key, value} -> {value, key} end)

    Wire.continue_varint(
      rest,
      struct,
      &Map.put(&1, field, Map.get(reverse_mapping, &2, &2)),
      &do_decode_fields(&1, &2, field_map)
    )
  end

  defp decode_field(rest, struct, field, {:message, _field_number, module}, 2, field_map) do
    Wire.continue_nested_bytes(
      rest,
      struct,
      &module.decode/1,
      &Map.put(&1, field, &2),
      &do_decode_fields(&1, &2, field_map)
    )
  end

  defp decode_field(rest, struct, field, {:repeated_string, _field_number}, 2, field_map) do
    Wire.continue_bytes(
      rest,
      struct,
      &Map.update!(&1, field, fn values -> [&2 | values] end),
      &do_decode_fields(&1, &2, field_map)
    )
  end

  defp decode_field(rest, struct, field, {:repeated_bytes, _field_number}, 2, field_map) do
    Wire.continue_bytes(
      rest,
      struct,
      &Map.update!(&1, field, fn values -> [&2 | values] end),
      &do_decode_fields(&1, &2, field_map)
    )
  end

  defp decode_field(rest, struct, field, {:repeated_message, _field_number, module}, 2, field_map) do
    Wire.continue_nested_bytes(
      rest,
      struct,
      &module.decode/1,
      &Map.update!(&1, field, fn values -> [&2 | values] end),
      &do_decode_fields(&1, &2, field_map)
    )
  end

  defp decode_field(rest, struct, _field, _spec, wire_type, field_map) do
    Wire.skip_and_continue(wire_type, rest, struct, &do_decode_fields(&1, &2, field_map))
  end

  defp reverse_repeated_fields(struct, specs) do
    Enum.reduce(specs, struct, fn
      {field, {:repeated_string, _field_number}}, acc ->
        Map.update!(acc, field, &Enum.reverse/1)

      {field, {:repeated_bytes, _field_number}}, acc ->
        Map.update!(acc, field, &Enum.reverse/1)

      {field, {:repeated_message, _field_number, _module}}, acc ->
        Map.update!(acc, field, &Enum.reverse/1)

      _spec, acc ->
        acc
    end)
  end

  defp field_number({_, field_number}), do: field_number
  defp field_number({_, field_number, _mapping_or_module}), do: field_number
end

defmodule BaileysEx.Protocol.Proto.MessageKey do
  @moduledoc false

  alias BaileysEx.Protocol.Proto.MessageSupport

  defstruct remote_jid: nil, from_me: nil, id: nil, participant: nil

  @type t :: %__MODULE__{
          remote_jid: String.t() | nil,
          from_me: boolean() | nil,
          id: String.t() | nil,
          participant: String.t() | nil
        }

  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = message_key) do
    MessageSupport.encode_fields(message_key,
      remote_jid: {:string, 1},
      from_me: {:bool, 2},
      id: {:string, 3},
      participant: {:string, 4}
    )
  end

  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(binary) do
    MessageSupport.decode_fields(binary, %__MODULE__{},
      remote_jid: {:string, 1},
      from_me: {:bool, 2},
      id: {:string, 3},
      participant: {:string, 4}
    )
  end
end

defmodule BaileysEx.Protocol.Proto.MessageContextInfo do
  @moduledoc false

  alias BaileysEx.Protocol.Proto.MessageSupport

  defstruct message_secret: nil, message_add_on_duration_in_secs: nil

  @type t :: %__MODULE__{
          message_secret: binary() | nil,
          message_add_on_duration_in_secs: non_neg_integer() | nil
        }

  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = message_context_info) do
    MessageSupport.encode_fields(message_context_info,
      message_secret: {:bytes, 3},
      message_add_on_duration_in_secs: {:uint, 5}
    )
  end

  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(binary) do
    MessageSupport.decode_fields(binary, %__MODULE__{},
      message_secret: {:bytes, 3},
      message_add_on_duration_in_secs: {:uint, 5}
    )
  end
end

defmodule BaileysEx.Protocol.Proto.Message do
  @moduledoc false

  alias BaileysEx.Protocol.Proto.MessageContextInfo
  alias BaileysEx.Protocol.Proto.MessageKey
  alias BaileysEx.Protocol.Proto.MessageSupport

  defmodule ContextInfo do
    @moduledoc false

    alias BaileysEx.Protocol.Proto.Message
    alias BaileysEx.Protocol.Proto.MessageKey
    alias BaileysEx.Protocol.Proto.MessageSupport

    defstruct stanza_id: nil,
              participant: nil,
              quoted_message: nil,
              remote_jid: nil,
              mentioned_jid: [],
              forwarding_score: nil,
              is_forwarded: nil,
              placeholder_key: nil,
              expiration: nil

    @type t :: %__MODULE__{
            stanza_id: String.t() | nil,
            participant: String.t() | nil,
            quoted_message: Message.t() | nil,
            remote_jid: String.t() | nil,
            mentioned_jid: [String.t()],
            forwarding_score: non_neg_integer() | nil,
            is_forwarded: boolean() | nil,
            placeholder_key: MessageKey.t() | nil,
            expiration: non_neg_integer() | nil
          }

    @spec encode(t()) :: binary()
    def encode(%__MODULE__{} = context_info) do
      MessageSupport.encode_fields(context_info,
        stanza_id: {:string, 1},
        participant: {:string, 2},
        quoted_message: {:message, 3, Message},
        remote_jid: {:string, 4},
        mentioned_jid: {:repeated_string, 15},
        forwarding_score: {:uint, 21},
        is_forwarded: {:bool, 22},
        placeholder_key: {:message, 24, MessageKey},
        expiration: {:uint, 25}
      )
    end

    @spec decode(binary()) :: {:ok, t()} | {:error, term()}
    def decode(binary) do
      MessageSupport.decode_fields(binary, %__MODULE__{},
        stanza_id: {:string, 1},
        participant: {:string, 2},
        quoted_message: {:message, 3, Message},
        remote_jid: {:string, 4},
        mentioned_jid: {:repeated_string, 15},
        forwarding_score: {:uint, 21},
        is_forwarded: {:bool, 22},
        placeholder_key: {:message, 24, MessageKey},
        expiration: {:uint, 25}
      )
    end
  end

  defmodule ExtendedTextMessage do
    @moduledoc false

    alias BaileysEx.Protocol.Proto.Message.ContextInfo
    alias BaileysEx.Protocol.Proto.MessageSupport

    defstruct text: nil,
              matched_text: nil,
              canonical_url: nil,
              description: nil,
              title: nil,
              background_argb: nil,
              font: nil,
              context_info: nil

    @type t :: %__MODULE__{
            text: String.t() | nil,
            matched_text: String.t() | nil,
            canonical_url: String.t() | nil,
            description: String.t() | nil,
            title: String.t() | nil,
            background_argb: non_neg_integer() | nil,
            font: non_neg_integer() | nil,
            context_info: ContextInfo.t() | nil
          }

    @spec encode(t()) :: binary()
    def encode(%__MODULE__{} = extended_text_message) do
      MessageSupport.encode_fields(extended_text_message,
        text: {:string, 1},
        matched_text: {:string, 2},
        description: {:string, 5},
        title: {:string, 6},
        background_argb: {:uint, 8},
        font: {:uint, 9},
        context_info: {:message, 17, ContextInfo}
      )
    end

    @spec decode(binary()) :: {:ok, t()} | {:error, term()}
    def decode(binary) do
      MessageSupport.decode_fields(binary, %__MODULE__{},
        text: {:string, 1},
        matched_text: {:string, 2},
        description: {:string, 5},
        title: {:string, 6},
        background_argb: {:uint, 8},
        font: {:uint, 9},
        context_info: {:message, 17, ContextInfo}
      )
    end
  end

  defmodule ImageMessage do
    @moduledoc false

    alias BaileysEx.Protocol.Proto.Message.ContextInfo
    alias BaileysEx.Protocol.Proto.MessageSupport

    @media_key_domain_values %{
      UNSET: 0,
      E2EE_CHAT: 1,
      STATUS: 2,
      CAPI: 3,
      BOT: 4
    }

    defstruct url: nil,
              mimetype: nil,
              caption: nil,
              file_sha256: nil,
              file_length: nil,
              height: nil,
              width: nil,
              media_key: nil,
              file_enc_sha256: nil,
              direct_path: nil,
              media_key_timestamp: nil,
              jpeg_thumbnail: nil,
              context_info: nil,
              view_once: nil,
              thumbnail_direct_path: nil,
              thumbnail_sha256: nil,
              thumbnail_enc_sha256: nil,
              static_url: nil,
              accessibility_label: nil,
              qr_url: nil,
              media_key_domain: nil

    @type t :: %__MODULE__{
            url: String.t() | nil,
            mimetype: String.t() | nil,
            caption: String.t() | nil,
            file_sha256: binary() | nil,
            file_length: non_neg_integer() | nil,
            height: non_neg_integer() | nil,
            width: non_neg_integer() | nil,
            media_key: binary() | nil,
            file_enc_sha256: binary() | nil,
            direct_path: String.t() | nil,
            media_key_timestamp: integer() | nil,
            jpeg_thumbnail: binary() | nil,
            context_info: ContextInfo.t() | nil,
            view_once: boolean() | nil,
            thumbnail_direct_path: String.t() | nil,
            thumbnail_sha256: binary() | nil,
            thumbnail_enc_sha256: binary() | nil,
            static_url: String.t() | nil,
            accessibility_label: String.t() | nil,
            qr_url: String.t() | nil,
            media_key_domain: atom() | integer() | nil
          }

    @spec encode(t()) :: binary()
    def encode(%__MODULE__{} = image_message) do
      MessageSupport.encode_fields(image_message,
        url: {:string, 1},
        mimetype: {:string, 2},
        caption: {:string, 3},
        file_sha256: {:bytes, 4},
        file_length: {:uint, 5},
        height: {:uint, 6},
        width: {:uint, 7},
        media_key: {:bytes, 8},
        file_enc_sha256: {:bytes, 9},
        direct_path: {:string, 11},
        media_key_timestamp: {:int64, 12},
        jpeg_thumbnail: {:bytes, 16},
        context_info: {:message, 17, ContextInfo},
        view_once: {:bool, 25},
        thumbnail_direct_path: {:string, 26},
        thumbnail_sha256: {:bytes, 27},
        thumbnail_enc_sha256: {:bytes, 28},
        static_url: {:string, 29},
        accessibility_label: {:string, 32},
        media_key_domain: {:enum, 33, @media_key_domain_values},
        qr_url: {:string, 34}
      )
    end

    @spec decode(binary()) :: {:ok, t()} | {:error, term()}
    def decode(binary) do
      MessageSupport.decode_fields(binary, %__MODULE__{},
        url: {:string, 1},
        mimetype: {:string, 2},
        caption: {:string, 3},
        file_sha256: {:bytes, 4},
        file_length: {:uint, 5},
        height: {:uint, 6},
        width: {:uint, 7},
        media_key: {:bytes, 8},
        file_enc_sha256: {:bytes, 9},
        direct_path: {:string, 11},
        media_key_timestamp: {:int64, 12},
        jpeg_thumbnail: {:bytes, 16},
        context_info: {:message, 17, ContextInfo},
        view_once: {:bool, 25},
        thumbnail_direct_path: {:string, 26},
        thumbnail_sha256: {:bytes, 27},
        thumbnail_enc_sha256: {:bytes, 28},
        static_url: {:string, 29},
        accessibility_label: {:string, 32},
        media_key_domain: {:enum, 33, @media_key_domain_values},
        qr_url: {:string, 34}
      )
    end
  end

  defmodule VideoMessage do
    @moduledoc false

    alias BaileysEx.Protocol.Proto.Message.ContextInfo
    alias BaileysEx.Protocol.Proto.MessageSupport

    @media_key_domain_values %{
      UNSET: 0,
      E2EE_CHAT: 1,
      STATUS: 2,
      CAPI: 3,
      BOT: 4
    }

    defstruct url: nil,
              mimetype: nil,
              file_sha256: nil,
              file_length: nil,
              seconds: nil,
              media_key: nil,
              caption: nil,
              gif_playback: nil,
              height: nil,
              width: nil,
              file_enc_sha256: nil,
              direct_path: nil,
              media_key_timestamp: nil,
              jpeg_thumbnail: nil,
              context_info: nil,
              streaming_sidecar: nil,
              view_once: nil,
              thumbnail_direct_path: nil,
              thumbnail_sha256: nil,
              thumbnail_enc_sha256: nil,
              static_url: nil,
              accessibility_label: nil,
              media_key_domain: nil

    @type t :: %__MODULE__{
            url: String.t() | nil,
            mimetype: String.t() | nil,
            file_sha256: binary() | nil,
            file_length: non_neg_integer() | nil,
            seconds: non_neg_integer() | nil,
            media_key: binary() | nil,
            caption: String.t() | nil,
            gif_playback: boolean() | nil,
            height: non_neg_integer() | nil,
            width: non_neg_integer() | nil,
            file_enc_sha256: binary() | nil,
            direct_path: String.t() | nil,
            media_key_timestamp: integer() | nil,
            jpeg_thumbnail: binary() | nil,
            context_info: ContextInfo.t() | nil,
            streaming_sidecar: binary() | nil,
            view_once: boolean() | nil,
            thumbnail_direct_path: String.t() | nil,
            thumbnail_sha256: binary() | nil,
            thumbnail_enc_sha256: binary() | nil,
            static_url: String.t() | nil,
            accessibility_label: String.t() | nil,
            media_key_domain: atom() | integer() | nil
          }

    @spec encode(t()) :: binary()
    def encode(%__MODULE__{} = video_message) do
      MessageSupport.encode_fields(video_message,
        url: {:string, 1},
        mimetype: {:string, 2},
        file_sha256: {:bytes, 3},
        file_length: {:uint, 4},
        seconds: {:uint, 5},
        media_key: {:bytes, 6},
        caption: {:string, 7},
        gif_playback: {:bool, 8},
        height: {:uint, 9},
        width: {:uint, 10},
        file_enc_sha256: {:bytes, 11},
        direct_path: {:string, 13},
        media_key_timestamp: {:int64, 14},
        jpeg_thumbnail: {:bytes, 16},
        context_info: {:message, 17, ContextInfo},
        streaming_sidecar: {:bytes, 18},
        view_once: {:bool, 20},
        thumbnail_direct_path: {:string, 21},
        thumbnail_sha256: {:bytes, 22},
        thumbnail_enc_sha256: {:bytes, 23},
        static_url: {:string, 24},
        accessibility_label: {:string, 26},
        media_key_domain: {:enum, 32, @media_key_domain_values}
      )
    end

    @spec decode(binary()) :: {:ok, t()} | {:error, term()}
    def decode(binary) do
      MessageSupport.decode_fields(binary, %__MODULE__{},
        url: {:string, 1},
        mimetype: {:string, 2},
        file_sha256: {:bytes, 3},
        file_length: {:uint, 4},
        seconds: {:uint, 5},
        media_key: {:bytes, 6},
        caption: {:string, 7},
        gif_playback: {:bool, 8},
        height: {:uint, 9},
        width: {:uint, 10},
        file_enc_sha256: {:bytes, 11},
        direct_path: {:string, 13},
        media_key_timestamp: {:int64, 14},
        jpeg_thumbnail: {:bytes, 16},
        context_info: {:message, 17, ContextInfo},
        streaming_sidecar: {:bytes, 18},
        view_once: {:bool, 20},
        thumbnail_direct_path: {:string, 21},
        thumbnail_sha256: {:bytes, 22},
        thumbnail_enc_sha256: {:bytes, 23},
        static_url: {:string, 24},
        accessibility_label: {:string, 26},
        media_key_domain: {:enum, 32, @media_key_domain_values}
      )
    end
  end

  defmodule AudioMessage do
    @moduledoc false

    alias BaileysEx.Protocol.Proto.Message.ContextInfo
    alias BaileysEx.Protocol.Proto.MessageSupport

    @media_key_domain_values %{
      UNSET: 0,
      E2EE_CHAT: 1,
      STATUS: 2,
      CAPI: 3,
      BOT: 4
    }

    defstruct url: nil,
              mimetype: nil,
              file_sha256: nil,
              file_length: nil,
              seconds: nil,
              ptt: nil,
              media_key: nil,
              file_enc_sha256: nil,
              direct_path: nil,
              media_key_timestamp: nil,
              context_info: nil,
              streaming_sidecar: nil,
              waveform: nil,
              background_argb: nil,
              view_once: nil,
              accessibility_label: nil,
              media_key_domain: nil

    @type t :: %__MODULE__{
            url: String.t() | nil,
            mimetype: String.t() | nil,
            file_sha256: binary() | nil,
            file_length: non_neg_integer() | nil,
            ptt: boolean() | nil,
            seconds: non_neg_integer() | nil,
            media_key: binary() | nil,
            file_enc_sha256: binary() | nil,
            direct_path: String.t() | nil,
            media_key_timestamp: integer() | nil,
            context_info: ContextInfo.t() | nil,
            streaming_sidecar: binary() | nil,
            waveform: binary() | nil,
            background_argb: non_neg_integer() | nil,
            view_once: boolean() | nil,
            accessibility_label: String.t() | nil,
            media_key_domain: atom() | integer() | nil
          }

    @spec encode(t()) :: binary()
    def encode(%__MODULE__{} = audio_message) do
      MessageSupport.encode_fields(audio_message,
        url: {:string, 1},
        mimetype: {:string, 2},
        file_sha256: {:bytes, 3},
        file_length: {:uint, 4},
        seconds: {:uint, 5},
        ptt: {:bool, 6},
        media_key: {:bytes, 7},
        file_enc_sha256: {:bytes, 8},
        direct_path: {:string, 9},
        media_key_timestamp: {:int64, 10},
        context_info: {:message, 17, ContextInfo},
        streaming_sidecar: {:bytes, 18},
        waveform: {:bytes, 19},
        background_argb: {:fixed32, 20},
        view_once: {:bool, 21},
        accessibility_label: {:string, 22},
        media_key_domain: {:enum, 23, @media_key_domain_values}
      )
    end

    @spec decode(binary()) :: {:ok, t()} | {:error, term()}
    def decode(binary) do
      MessageSupport.decode_fields(binary, %__MODULE__{},
        url: {:string, 1},
        mimetype: {:string, 2},
        file_sha256: {:bytes, 3},
        file_length: {:uint, 4},
        seconds: {:uint, 5},
        ptt: {:bool, 6},
        media_key: {:bytes, 7},
        file_enc_sha256: {:bytes, 8},
        direct_path: {:string, 9},
        media_key_timestamp: {:int64, 10},
        context_info: {:message, 17, ContextInfo},
        streaming_sidecar: {:bytes, 18},
        waveform: {:bytes, 19},
        background_argb: {:fixed32, 20},
        view_once: {:bool, 21},
        accessibility_label: {:string, 22},
        media_key_domain: {:enum, 23, @media_key_domain_values}
      )
    end
  end

  defmodule DocumentMessage do
    @moduledoc false

    alias BaileysEx.Protocol.Proto.Message.ContextInfo
    alias BaileysEx.Protocol.Proto.MessageSupport

    @media_key_domain_values %{
      UNSET: 0,
      E2EE_CHAT: 1,
      STATUS: 2,
      CAPI: 3,
      BOT: 4
    }

    defstruct url: nil,
              mimetype: nil,
              title: nil,
              file_sha256: nil,
              file_length: nil,
              page_count: nil,
              media_key: nil,
              file_name: nil,
              file_enc_sha256: nil,
              direct_path: nil,
              media_key_timestamp: nil,
              contact_vcard: nil,
              thumbnail_direct_path: nil,
              thumbnail_sha256: nil,
              thumbnail_enc_sha256: nil,
              jpeg_thumbnail: nil,
              context_info: nil,
              thumbnail_height: nil,
              thumbnail_width: nil,
              caption: nil,
              accessibility_label: nil,
              media_key_domain: nil

    @type t :: %__MODULE__{
            url: String.t() | nil,
            mimetype: String.t() | nil,
            title: String.t() | nil,
            file_sha256: binary() | nil,
            file_length: non_neg_integer() | nil,
            page_count: non_neg_integer() | nil,
            media_key: binary() | nil,
            file_name: String.t() | nil,
            file_enc_sha256: binary() | nil,
            direct_path: String.t() | nil,
            media_key_timestamp: integer() | nil,
            contact_vcard: boolean() | nil,
            thumbnail_direct_path: String.t() | nil,
            thumbnail_sha256: binary() | nil,
            thumbnail_enc_sha256: binary() | nil,
            jpeg_thumbnail: binary() | nil,
            thumbnail_height: non_neg_integer() | nil,
            thumbnail_width: non_neg_integer() | nil,
            caption: String.t() | nil,
            context_info: ContextInfo.t() | nil,
            accessibility_label: String.t() | nil,
            media_key_domain: atom() | integer() | nil
          }

    @spec encode(t()) :: binary()
    def encode(%__MODULE__{} = document_message) do
      MessageSupport.encode_fields(document_message,
        url: {:string, 1},
        mimetype: {:string, 2},
        title: {:string, 3},
        file_sha256: {:bytes, 4},
        file_length: {:uint, 5},
        page_count: {:uint, 6},
        media_key: {:bytes, 7},
        file_name: {:string, 8},
        file_enc_sha256: {:bytes, 9},
        direct_path: {:string, 10},
        media_key_timestamp: {:int64, 11},
        contact_vcard: {:bool, 12},
        thumbnail_direct_path: {:string, 13},
        thumbnail_sha256: {:bytes, 14},
        thumbnail_enc_sha256: {:bytes, 15},
        jpeg_thumbnail: {:bytes, 16},
        context_info: {:message, 17, ContextInfo},
        thumbnail_height: {:uint, 18},
        thumbnail_width: {:uint, 19},
        caption: {:string, 20},
        accessibility_label: {:string, 21},
        media_key_domain: {:enum, 22, @media_key_domain_values}
      )
    end

    @spec decode(binary()) :: {:ok, t()} | {:error, term()}
    def decode(binary) do
      MessageSupport.decode_fields(binary, %__MODULE__{},
        url: {:string, 1},
        mimetype: {:string, 2},
        title: {:string, 3},
        file_sha256: {:bytes, 4},
        file_length: {:uint, 5},
        page_count: {:uint, 6},
        media_key: {:bytes, 7},
        file_name: {:string, 8},
        file_enc_sha256: {:bytes, 9},
        direct_path: {:string, 10},
        media_key_timestamp: {:int64, 11},
        contact_vcard: {:bool, 12},
        thumbnail_direct_path: {:string, 13},
        thumbnail_sha256: {:bytes, 14},
        thumbnail_enc_sha256: {:bytes, 15},
        jpeg_thumbnail: {:bytes, 16},
        context_info: {:message, 17, ContextInfo},
        thumbnail_height: {:uint, 18},
        thumbnail_width: {:uint, 19},
        caption: {:string, 20},
        accessibility_label: {:string, 21},
        media_key_domain: {:enum, 22, @media_key_domain_values}
      )
    end
  end

  defmodule StickerMessage do
    @moduledoc false

    alias BaileysEx.Protocol.Proto.Message.ContextInfo
    alias BaileysEx.Protocol.Proto.MessageSupport

    @media_key_domain_values %{
      UNSET: 0,
      E2EE_CHAT: 1,
      STATUS: 2,
      CAPI: 3,
      BOT: 4
    }

    defstruct url: nil,
              file_sha256: nil,
              file_enc_sha256: nil,
              media_key: nil,
              mimetype: nil,
              height: nil,
              width: nil,
              direct_path: nil,
              file_length: nil,
              media_key_timestamp: nil,
              first_frame_length: nil,
              first_frame_sidecar: nil,
              is_animated: nil,
              png_thumbnail: nil,
              context_info: nil,
              sticker_sent_ts: nil,
              is_avatar: nil,
              is_ai_sticker: nil,
              is_lottie: nil,
              accessibility_label: nil,
              media_key_domain: nil

    @type t :: %__MODULE__{
            url: String.t() | nil,
            file_sha256: binary() | nil,
            file_enc_sha256: binary() | nil,
            media_key: binary() | nil,
            mimetype: String.t() | nil,
            height: non_neg_integer() | nil,
            width: non_neg_integer() | nil,
            direct_path: String.t() | nil,
            file_length: non_neg_integer() | nil,
            media_key_timestamp: integer() | nil,
            first_frame_length: non_neg_integer() | nil,
            first_frame_sidecar: binary() | nil,
            is_animated: boolean() | nil,
            png_thumbnail: binary() | nil,
            context_info: ContextInfo.t() | nil,
            sticker_sent_ts: integer() | nil,
            is_avatar: boolean() | nil,
            is_ai_sticker: boolean() | nil,
            is_lottie: boolean() | nil,
            accessibility_label: String.t() | nil,
            media_key_domain: atom() | integer() | nil
          }

    @spec encode(t()) :: binary()
    def encode(%__MODULE__{} = sticker_message) do
      MessageSupport.encode_fields(sticker_message,
        url: {:string, 1},
        file_sha256: {:bytes, 2},
        file_enc_sha256: {:bytes, 3},
        media_key: {:bytes, 4},
        mimetype: {:string, 5},
        height: {:uint, 6},
        width: {:uint, 7},
        direct_path: {:string, 8},
        file_length: {:uint, 9},
        media_key_timestamp: {:int64, 10},
        first_frame_length: {:uint, 11},
        first_frame_sidecar: {:bytes, 12},
        is_animated: {:bool, 13},
        png_thumbnail: {:bytes, 16},
        context_info: {:message, 17, ContextInfo},
        sticker_sent_ts: {:int64, 18},
        is_avatar: {:bool, 19},
        is_ai_sticker: {:bool, 20},
        is_lottie: {:bool, 21},
        accessibility_label: {:string, 22},
        media_key_domain: {:enum, 23, @media_key_domain_values}
      )
    end

    @spec decode(binary()) :: {:ok, t()} | {:error, term()}
    def decode(binary) do
      MessageSupport.decode_fields(binary, %__MODULE__{},
        url: {:string, 1},
        file_sha256: {:bytes, 2},
        file_enc_sha256: {:bytes, 3},
        media_key: {:bytes, 4},
        mimetype: {:string, 5},
        height: {:uint, 6},
        width: {:uint, 7},
        direct_path: {:string, 8},
        file_length: {:uint, 9},
        media_key_timestamp: {:int64, 10},
        first_frame_length: {:uint, 11},
        first_frame_sidecar: {:bytes, 12},
        is_animated: {:bool, 13},
        png_thumbnail: {:bytes, 16},
        context_info: {:message, 17, ContextInfo},
        sticker_sent_ts: {:int64, 18},
        is_avatar: {:bool, 19},
        is_ai_sticker: {:bool, 20},
        is_lottie: {:bool, 21},
        accessibility_label: {:string, 22},
        media_key_domain: {:enum, 23, @media_key_domain_values}
      )
    end
  end

  defmodule ReactionMessage do
    @moduledoc false

    alias BaileysEx.Protocol.Proto.MessageKey
    alias BaileysEx.Protocol.Proto.MessageSupport

    defstruct key: nil, text: nil, sender_timestamp_ms: nil

    @type t :: %__MODULE__{
            key: MessageKey.t() | nil,
            text: String.t() | nil,
            sender_timestamp_ms: non_neg_integer() | nil
          }

    @spec encode(t()) :: binary()
    def encode(%__MODULE__{} = reaction_message) do
      MessageSupport.encode_fields(reaction_message,
        key: {:message, 1, MessageKey},
        text: {:string, 2},
        sender_timestamp_ms: {:int64, 4}
      )
    end

    @spec decode(binary()) :: {:ok, t()} | {:error, term()}
    def decode(binary) do
      MessageSupport.decode_fields(binary, %__MODULE__{},
        key: {:message, 1, MessageKey},
        text: {:string, 2},
        sender_timestamp_ms: {:int64, 4}
      )
    end
  end

  defmodule PollEncValue do
    @moduledoc false

    alias BaileysEx.Protocol.Proto.MessageSupport

    defstruct enc_payload: nil, enc_iv: nil

    @type t :: %__MODULE__{enc_payload: binary() | nil, enc_iv: binary() | nil}

    @spec encode(t()) :: binary()
    def encode(%__MODULE__{} = poll_enc_value) do
      MessageSupport.encode_fields(poll_enc_value,
        enc_payload: {:bytes, 1},
        enc_iv: {:bytes, 2}
      )
    end

    @spec decode(binary()) :: {:ok, t()} | {:error, term()}
    def decode(binary) do
      MessageSupport.decode_fields(binary, %__MODULE__{},
        enc_payload: {:bytes, 1},
        enc_iv: {:bytes, 2}
      )
    end
  end

  defmodule PollVoteMessage do
    @moduledoc false

    alias BaileysEx.Protocol.Proto.MessageSupport

    defstruct selected_options: []

    @type t :: %__MODULE__{selected_options: [binary()]}

    @spec encode(t()) :: binary()
    def encode(%__MODULE__{} = poll_vote_message) do
      MessageSupport.encode_fields(poll_vote_message,
        selected_options: {:repeated_bytes, 1}
      )
    end

    @spec decode(binary()) :: {:ok, t()} | {:error, term()}
    def decode(binary) do
      MessageSupport.decode_fields(binary, %__MODULE__{}, selected_options: {:repeated_bytes, 1})
    end
  end

  defmodule PollUpdateMessageMetadata do
    @moduledoc false

    defstruct []

    @type t :: %__MODULE__{}

    @spec encode(t()) :: binary()
    def encode(%__MODULE__{}), do: <<>>

    @spec decode(binary()) :: {:ok, t()} | {:error, term()}
    def decode(binary) when is_binary(binary), do: {:ok, %__MODULE__{}}
  end

  defmodule PollUpdateMessage do
    @moduledoc false

    alias BaileysEx.Protocol.Proto.MessageSupport

    defstruct poll_creation_message_key: nil,
              vote: nil,
              metadata: nil,
              sender_timestamp_ms: nil

    @type t :: %__MODULE__{
            poll_creation_message_key: MessageKey.t() | nil,
            vote: PollEncValue.t() | PollVoteMessage.t() | nil,
            metadata: PollUpdateMessageMetadata.t() | nil,
            sender_timestamp_ms: integer() | nil
          }

    @spec encode(t()) :: binary()
    def encode(%__MODULE__{} = poll_update_message) do
      MessageSupport.encode_fields(poll_update_message,
        poll_creation_message_key: {:message, 1, MessageKey},
        vote: {:message, 2, PollEncValue},
        metadata: {:message, 3, PollUpdateMessageMetadata},
        sender_timestamp_ms: {:int64, 4}
      )
    end

    @spec decode(binary()) :: {:ok, t()} | {:error, term()}
    def decode(binary) do
      MessageSupport.decode_fields(binary, %__MODULE__{},
        poll_creation_message_key: {:message, 1, MessageKey},
        vote: {:message, 2, PollEncValue},
        metadata: {:message, 3, PollUpdateMessageMetadata},
        sender_timestamp_ms: {:int64, 4}
      )
    end
  end

  defmodule EncReactionMessage do
    @moduledoc false

    alias BaileysEx.Protocol.Proto.MessageSupport

    defstruct target_message_key: nil, enc_payload: nil, enc_iv: nil

    @type t :: %__MODULE__{
            target_message_key: MessageKey.t() | nil,
            enc_payload: binary() | nil,
            enc_iv: binary() | nil
          }

    @spec encode(t()) :: binary()
    def encode(%__MODULE__{} = enc_reaction_message) do
      MessageSupport.encode_fields(enc_reaction_message,
        target_message_key: {:message, 1, MessageKey},
        enc_payload: {:bytes, 2},
        enc_iv: {:bytes, 3}
      )
    end

    @spec decode(binary()) :: {:ok, t()} | {:error, term()}
    def decode(binary) do
      MessageSupport.decode_fields(binary, %__MODULE__{},
        target_message_key: {:message, 1, MessageKey},
        enc_payload: {:bytes, 2},
        enc_iv: {:bytes, 3}
      )
    end
  end

  defmodule SenderKeyDistributionMessage do
    @moduledoc false

    alias BaileysEx.Protocol.Proto.MessageSupport

    defstruct group_id: nil, axolotl_sender_key_distribution_message: nil

    @type t :: %__MODULE__{
            group_id: String.t() | nil,
            axolotl_sender_key_distribution_message: binary() | nil
          }

    @spec encode(t()) :: binary()
    def encode(%__MODULE__{} = sender_key_distribution_message) do
      MessageSupport.encode_fields(sender_key_distribution_message,
        group_id: {:string, 1},
        axolotl_sender_key_distribution_message: {:bytes, 2}
      )
    end

    @spec decode(binary()) :: {:ok, t()} | {:error, term()}
    def decode(binary) do
      MessageSupport.decode_fields(binary, %__MODULE__{},
        group_id: {:string, 1},
        axolotl_sender_key_distribution_message: {:bytes, 2}
      )
    end
  end

  defmodule PollCreationMessage do
    @moduledoc false

    alias BaileysEx.Protocol.Proto.Message.ContextInfo
    alias BaileysEx.Protocol.Proto.MessageSupport

    defmodule Option do
      @moduledoc false

      alias BaileysEx.Protocol.Proto.MessageSupport

      defstruct option_name: nil, option_hash: nil

      @type t :: %__MODULE__{option_name: String.t() | nil, option_hash: String.t() | nil}

      @spec encode(t()) :: binary()
      def encode(%__MODULE__{} = option) do
        MessageSupport.encode_fields(option,
          option_name: {:string, 1},
          option_hash: {:string, 2}
        )
      end

      @spec decode(binary()) :: {:ok, t()} | {:error, term()}
      def decode(binary) do
        MessageSupport.decode_fields(binary, %__MODULE__{},
          option_name: {:string, 1},
          option_hash: {:string, 2}
        )
      end
    end

    defstruct enc_key: nil,
              name: nil,
              options: [],
              selectable_options_count: nil,
              context_info: nil

    @type t :: %__MODULE__{
            enc_key: binary() | nil,
            name: String.t() | nil,
            options: [Option.t()],
            selectable_options_count: non_neg_integer() | nil,
            context_info: ContextInfo.t() | nil
          }

    @spec encode(t()) :: binary()
    def encode(%__MODULE__{} = poll_creation_message) do
      MessageSupport.encode_fields(poll_creation_message,
        enc_key: {:bytes, 1},
        name: {:string, 2},
        options: {:repeated_message, 3, Option},
        selectable_options_count: {:uint, 4},
        context_info: {:message, 5, ContextInfo}
      )
    end

    @spec decode(binary()) :: {:ok, t()} | {:error, term()}
    def decode(binary) do
      MessageSupport.decode_fields(binary, %__MODULE__{},
        enc_key: {:bytes, 1},
        name: {:string, 2},
        options: {:repeated_message, 3, Option},
        selectable_options_count: {:uint, 4},
        context_info: {:message, 5, ContextInfo}
      )
    end
  end

  defmodule ContactMessage do
    @moduledoc false

    alias BaileysEx.Protocol.Proto.Message.ContextInfo
    alias BaileysEx.Protocol.Proto.MessageSupport

    defstruct display_name: nil, vcard: nil, context_info: nil

    @type t :: %__MODULE__{
            display_name: String.t() | nil,
            vcard: String.t() | nil,
            context_info: ContextInfo.t() | nil
          }

    @spec encode(t()) :: binary()
    def encode(%__MODULE__{} = contact_message) do
      MessageSupport.encode_fields(contact_message,
        display_name: {:string, 1},
        vcard: {:string, 16},
        context_info: {:message, 17, ContextInfo}
      )
    end

    @spec decode(binary()) :: {:ok, t()} | {:error, term()}
    def decode(binary) do
      MessageSupport.decode_fields(binary, %__MODULE__{},
        display_name: {:string, 1},
        vcard: {:string, 16},
        context_info: {:message, 17, ContextInfo}
      )
    end
  end

  defmodule ContactsArrayMessage do
    @moduledoc false

    alias BaileysEx.Protocol.Proto.Message.ContactMessage
    alias BaileysEx.Protocol.Proto.Message.ContextInfo
    alias BaileysEx.Protocol.Proto.MessageSupport

    defstruct display_name: nil, contacts: [], context_info: nil

    @type t :: %__MODULE__{
            display_name: String.t() | nil,
            contacts: [ContactMessage.t()],
            context_info: ContextInfo.t() | nil
          }

    @spec encode(t()) :: binary()
    def encode(%__MODULE__{} = contacts_array_message) do
      MessageSupport.encode_fields(contacts_array_message,
        display_name: {:string, 1},
        contacts: {:repeated_message, 2, ContactMessage},
        context_info: {:message, 17, ContextInfo}
      )
    end

    @spec decode(binary()) :: {:ok, t()} | {:error, term()}
    def decode(binary) do
      MessageSupport.decode_fields(binary, %__MODULE__{},
        display_name: {:string, 1},
        contacts: {:repeated_message, 2, ContactMessage},
        context_info: {:message, 17, ContextInfo}
      )
    end
  end

  defmodule LocationMessage do
    @moduledoc false

    alias BaileysEx.Protocol.Proto.Message.ContextInfo
    alias BaileysEx.Protocol.Proto.MessageSupport

    defstruct degrees_latitude: nil,
              degrees_longitude: nil,
              name: nil,
              address: nil,
              url: nil,
              accuracy_in_meters: nil,
              context_info: nil

    @type t :: %__MODULE__{
            degrees_latitude: non_neg_integer() | float() | nil,
            degrees_longitude: non_neg_integer() | float() | nil,
            name: String.t() | nil,
            address: String.t() | nil,
            url: String.t() | nil,
            accuracy_in_meters: non_neg_integer() | nil,
            context_info: ContextInfo.t() | nil
          }

    @spec encode(t()) :: binary()
    def encode(%__MODULE__{} = location_message) do
      MessageSupport.encode_fields(location_message,
        degrees_latitude: {:double, 1},
        degrees_longitude: {:double, 2},
        name: {:string, 3},
        address: {:string, 4},
        url: {:string, 5},
        accuracy_in_meters: {:uint, 7},
        context_info: {:message, 17, ContextInfo}
      )
    end

    @spec decode(binary()) :: {:ok, t()} | {:error, term()}
    def decode(binary) do
      MessageSupport.decode_fields(binary, %__MODULE__{},
        degrees_latitude: {:double, 1},
        degrees_longitude: {:double, 2},
        name: {:string, 3},
        address: {:string, 4},
        url: {:string, 5},
        accuracy_in_meters: {:uint, 7},
        context_info: {:message, 17, ContextInfo}
      )
    end
  end

  defmodule LiveLocationMessage do
    @moduledoc false

    alias BaileysEx.Protocol.Proto.Message.ContextInfo
    alias BaileysEx.Protocol.Proto.MessageSupport

    defstruct degrees_latitude: nil,
              degrees_longitude: nil,
              accuracy_in_meters: nil,
              speed_in_mps: nil,
              degrees_clockwise_from_magnetic_north: nil,
              sequence_number: nil,
              context_info: nil

    @type t :: %__MODULE__{
            degrees_latitude: non_neg_integer() | float() | nil,
            degrees_longitude: non_neg_integer() | float() | nil,
            accuracy_in_meters: non_neg_integer() | nil,
            speed_in_mps: non_neg_integer() | nil,
            degrees_clockwise_from_magnetic_north: non_neg_integer() | nil,
            sequence_number: non_neg_integer() | nil,
            context_info: ContextInfo.t() | nil
          }

    @spec encode(t()) :: binary()
    def encode(%__MODULE__{} = live_location_message) do
      MessageSupport.encode_fields(live_location_message,
        degrees_latitude: {:double, 1},
        degrees_longitude: {:double, 2},
        accuracy_in_meters: {:uint, 3},
        speed_in_mps: {:float, 4},
        degrees_clockwise_from_magnetic_north: {:uint, 5},
        sequence_number: {:int64, 7},
        context_info: {:message, 17, ContextInfo}
      )
    end

    @spec decode(binary()) :: {:ok, t()} | {:error, term()}
    def decode(binary) do
      MessageSupport.decode_fields(binary, %__MODULE__{},
        degrees_latitude: {:double, 1},
        degrees_longitude: {:double, 2},
        accuracy_in_meters: {:uint, 3},
        speed_in_mps: {:float, 4},
        degrees_clockwise_from_magnetic_north: {:uint, 5},
        sequence_number: {:int64, 7},
        context_info: {:message, 17, ContextInfo}
      )
    end
  end

  defmodule HistorySyncNotification do
    @moduledoc false

    alias BaileysEx.Protocol.Proto.MessageSupport

    @sync_type_values %{
      INITIAL_BOOTSTRAP: 0,
      INITIAL_STATUS_V3: 1,
      FULL: 2,
      RECENT: 3,
      PUSH_NAME: 4,
      NON_BLOCKING_DATA: 5,
      ON_DEMAND: 6,
      NO_HISTORY: 7,
      MESSAGE_ACCESS_STATUS: 8
    }

    defstruct file_sha256: nil,
              file_length: nil,
              media_key: nil,
              file_enc_sha256: nil,
              direct_path: nil,
              sync_type: nil,
              chunk_order: nil,
              original_message_id: nil,
              progress: nil,
              oldest_msg_in_chunk_timestamp_sec: nil,
              initial_hist_bootstrap_inline_payload: nil,
              peer_data_request_session_id: nil,
              enc_handle: nil

    @type t :: %__MODULE__{
            file_sha256: binary() | nil,
            file_length: non_neg_integer() | nil,
            media_key: binary() | nil,
            file_enc_sha256: binary() | nil,
            direct_path: String.t() | nil,
            sync_type: atom() | integer() | nil,
            chunk_order: non_neg_integer() | nil,
            original_message_id: String.t() | nil,
            progress: non_neg_integer() | nil,
            oldest_msg_in_chunk_timestamp_sec: non_neg_integer() | nil,
            initial_hist_bootstrap_inline_payload: binary() | nil,
            peer_data_request_session_id: String.t() | nil,
            enc_handle: String.t() | nil
          }

    @spec encode(t()) :: binary()
    def encode(%__MODULE__{} = history_sync_notification) do
      MessageSupport.encode_fields(history_sync_notification,
        file_sha256: {:bytes, 1},
        file_length: {:uint, 2},
        media_key: {:bytes, 3},
        file_enc_sha256: {:bytes, 4},
        direct_path: {:string, 5},
        sync_type: {:enum, 6, @sync_type_values},
        chunk_order: {:uint, 7},
        original_message_id: {:string, 8},
        progress: {:uint, 9},
        oldest_msg_in_chunk_timestamp_sec: {:int64, 10},
        initial_hist_bootstrap_inline_payload: {:bytes, 11},
        peer_data_request_session_id: {:string, 12},
        enc_handle: {:string, 14}
      )
    end

    @spec decode(binary()) :: {:ok, t()} | {:error, term()}
    def decode(binary) do
      MessageSupport.decode_fields(binary, %__MODULE__{},
        file_sha256: {:bytes, 1},
        file_length: {:uint, 2},
        media_key: {:bytes, 3},
        file_enc_sha256: {:bytes, 4},
        direct_path: {:string, 5},
        sync_type: {:enum, 6, @sync_type_values},
        chunk_order: {:uint, 7},
        original_message_id: {:string, 8},
        progress: {:uint, 9},
        oldest_msg_in_chunk_timestamp_sec: {:int64, 10},
        initial_hist_bootstrap_inline_payload: {:bytes, 11},
        peer_data_request_session_id: {:string, 12},
        enc_handle: {:string, 14}
      )
    end
  end

  defmodule MemberLabel do
    @moduledoc false

    alias BaileysEx.Protocol.Proto.MessageSupport

    defstruct label: nil, label_timestamp: nil

    @type t :: %__MODULE__{
            label: String.t() | nil,
            label_timestamp: non_neg_integer() | nil
          }

    @spec encode(t()) :: binary()
    def encode(%__MODULE__{} = member_label) do
      MessageSupport.encode_fields(member_label,
        label: {:string, 1},
        label_timestamp: {:int64, 2}
      )
    end

    @spec decode(binary()) :: {:ok, t()} | {:error, term()}
    def decode(binary) do
      MessageSupport.decode_fields(binary, %__MODULE__{},
        label: {:string, 1},
        label_timestamp: {:int64, 2}
      )
    end
  end

  defmodule LimitSharing do
    @moduledoc false

    alias BaileysEx.Protocol.Proto.MessageSupport

    @trigger_type_values %{UNKNOWN: 0, CHAT_SETTING: 1, BIZ_SUPPORTS_FB_HOSTING: 2}

    defstruct sharing_limited: nil,
              trigger: nil,
              limit_sharing_setting_timestamp: nil,
              initiated_by_me: nil

    @type t :: %__MODULE__{
            sharing_limited: boolean() | nil,
            trigger: atom() | integer() | nil,
            limit_sharing_setting_timestamp: non_neg_integer() | nil,
            initiated_by_me: boolean() | nil
          }

    @spec encode(t()) :: binary()
    def encode(%__MODULE__{} = limit_sharing) do
      MessageSupport.encode_fields(limit_sharing,
        sharing_limited: {:bool, 1},
        trigger: {:enum, 2, @trigger_type_values},
        limit_sharing_setting_timestamp: {:int64, 3},
        initiated_by_me: {:bool, 4}
      )
    end

    @spec decode(binary()) :: {:ok, t()} | {:error, term()}
    def decode(binary) do
      MessageSupport.decode_fields(binary, %__MODULE__{},
        sharing_limited: {:bool, 1},
        trigger: {:enum, 2, @trigger_type_values},
        limit_sharing_setting_timestamp: {:int64, 3},
        initiated_by_me: {:bool, 4}
      )
    end
  end

  defmodule LIDMigrationMapping do
    @moduledoc false

    alias BaileysEx.Protocol.Proto.MessageSupport

    defstruct pn: nil, assigned_lid: nil, latest_lid: nil

    @type t :: %__MODULE__{
            pn: non_neg_integer() | nil,
            assigned_lid: non_neg_integer() | nil,
            latest_lid: non_neg_integer() | nil
          }

    @spec encode(t()) :: binary()
    def encode(%__MODULE__{} = mapping) do
      MessageSupport.encode_fields(mapping,
        pn: {:int64, 1},
        assigned_lid: {:int64, 2},
        latest_lid: {:int64, 3}
      )
    end

    @spec decode(binary()) :: {:ok, t()} | {:error, term()}
    def decode(binary) do
      MessageSupport.decode_fields(binary, %__MODULE__{},
        pn: {:int64, 1},
        assigned_lid: {:int64, 2},
        latest_lid: {:int64, 3}
      )
    end
  end

  defmodule LIDMigrationMappingSyncMessage do
    @moduledoc false

    alias BaileysEx.Protocol.Proto.MessageSupport

    defstruct encoded_mapping_payload: nil

    @type t :: %__MODULE__{encoded_mapping_payload: binary() | nil}

    @spec encode(t()) :: binary()
    def encode(%__MODULE__{} = sync_message) do
      MessageSupport.encode_fields(sync_message,
        encoded_mapping_payload: {:bytes, 1}
      )
    end

    @spec decode(binary()) :: {:ok, t()} | {:error, term()}
    def decode(binary) do
      MessageSupport.decode_fields(binary, %__MODULE__{}, encoded_mapping_payload: {:bytes, 1})
    end
  end

  defmodule LIDMigrationMappingSyncPayload do
    @moduledoc false

    alias BaileysEx.Protocol.Proto.Message.LIDMigrationMapping
    alias BaileysEx.Protocol.Proto.MessageSupport

    defstruct pn_to_lid_mappings: [], chat_db_migration_timestamp: nil

    @type t :: %__MODULE__{
            pn_to_lid_mappings: [LIDMigrationMapping.t()],
            chat_db_migration_timestamp: non_neg_integer() | nil
          }

    @spec encode(t()) :: binary()
    def encode(%__MODULE__{} = payload) do
      MessageSupport.encode_fields(payload,
        pn_to_lid_mappings: {:repeated_message, 1, LIDMigrationMapping},
        chat_db_migration_timestamp: {:int64, 2}
      )
    end

    @spec decode(binary()) :: {:ok, t()} | {:error, term()}
    def decode(binary) do
      MessageSupport.decode_fields(binary, %__MODULE__{},
        pn_to_lid_mappings: {:repeated_message, 1, LIDMigrationMapping},
        chat_db_migration_timestamp: {:int64, 2}
      )
    end
  end

  defmodule PeerDataOperationRequestMessage do
    @moduledoc false

    defmodule HistorySyncOnDemandRequest do
      @moduledoc false

      alias BaileysEx.Protocol.Proto.MessageSupport

      defstruct chat_jid: nil,
                oldest_msg_id: nil,
                oldest_msg_from_me: nil,
                on_demand_msg_count: nil,
                oldest_msg_timestamp_ms: nil,
                account_lid: nil

      @type t :: %__MODULE__{
              chat_jid: String.t() | nil,
              oldest_msg_id: String.t() | nil,
              oldest_msg_from_me: boolean() | nil,
              on_demand_msg_count: non_neg_integer() | nil,
              oldest_msg_timestamp_ms: integer() | nil,
              account_lid: String.t() | nil
            }

      @spec encode(t()) :: binary()
      def encode(%__MODULE__{} = request) do
        MessageSupport.encode_fields(request,
          chat_jid: {:string, 1},
          oldest_msg_id: {:string, 2},
          oldest_msg_from_me: {:bool, 3},
          on_demand_msg_count: {:uint, 4},
          oldest_msg_timestamp_ms: {:int64, 5},
          account_lid: {:string, 6}
        )
      end

      @spec decode(binary()) :: {:ok, t()} | {:error, term()}
      def decode(binary) do
        MessageSupport.decode_fields(binary, %__MODULE__{},
          chat_jid: {:string, 1},
          oldest_msg_id: {:string, 2},
          oldest_msg_from_me: {:bool, 3},
          on_demand_msg_count: {:uint, 4},
          oldest_msg_timestamp_ms: {:int64, 5},
          account_lid: {:string, 6}
        )
      end
    end

    defmodule PlaceholderMessageResendRequest do
      @moduledoc false

      alias BaileysEx.Protocol.Proto.MessageKey
      alias BaileysEx.Protocol.Proto.MessageSupport

      defstruct message_key: nil

      @type t :: %__MODULE__{message_key: MessageKey.t() | nil}

      @spec encode(t()) :: binary()
      def encode(%__MODULE__{} = request) do
        MessageSupport.encode_fields(request,
          message_key: {:message, 1, MessageKey}
        )
      end

      @spec decode(binary()) :: {:ok, t()} | {:error, term()}
      def decode(binary) do
        MessageSupport.decode_fields(binary, %__MODULE__{},
          message_key: {:message, 1, MessageKey}
        )
      end
    end

    alias BaileysEx.Protocol.Proto.Message.PeerDataOperationRequestMessage.HistorySyncOnDemandRequest

    alias BaileysEx.Protocol.Proto.Message.PeerDataOperationRequestMessage.PlaceholderMessageResendRequest

    alias BaileysEx.Protocol.Proto.MessageSupport

    @type_values %{
      UPLOAD_STICKER: 0,
      SEND_RECENT_STICKER_BOOTSTRAP: 1,
      GENERATE_LINK_PREVIEW: 2,
      HISTORY_SYNC_ON_DEMAND: 3,
      PLACEHOLDER_MESSAGE_RESEND: 4
    }

    defstruct peer_data_operation_request_type: nil,
              history_sync_on_demand_request: nil,
              placeholder_message_resend_request: []

    @type t :: %__MODULE__{
            peer_data_operation_request_type: atom() | integer() | nil,
            history_sync_on_demand_request: HistorySyncOnDemandRequest.t() | nil,
            placeholder_message_resend_request: [PlaceholderMessageResendRequest.t()]
          }

    @spec encode(t()) :: binary()
    def encode(%__MODULE__{} = request) do
      MessageSupport.encode_fields(request,
        peer_data_operation_request_type: {:enum, 1, @type_values},
        history_sync_on_demand_request: {:message, 4, HistorySyncOnDemandRequest},
        placeholder_message_resend_request:
          {:repeated_message, 5, PlaceholderMessageResendRequest}
      )
    end

    @spec decode(binary()) :: {:ok, t()} | {:error, term()}
    def decode(binary) do
      MessageSupport.decode_fields(binary, %__MODULE__{},
        peer_data_operation_request_type: {:enum, 1, @type_values},
        history_sync_on_demand_request: {:message, 4, HistorySyncOnDemandRequest},
        placeholder_message_resend_request:
          {:repeated_message, 5, PlaceholderMessageResendRequest}
      )
    end
  end

  defmodule PeerDataOperationRequestResponseMessage do
    @moduledoc false

    defmodule PeerDataOperationResult do
      @moduledoc false

      defmodule PlaceholderMessageResendResponse do
        @moduledoc false

        alias BaileysEx.Protocol.Proto.MessageSupport

        defstruct web_message_info_bytes: nil

        @type t :: %__MODULE__{web_message_info_bytes: binary() | nil}

        @spec encode(t()) :: binary()
        def encode(%__MODULE__{} = response) do
          MessageSupport.encode_fields(response,
            web_message_info_bytes: {:bytes, 1}
          )
        end

        @spec decode(binary()) :: {:ok, t()} | {:error, term()}
        def decode(binary) do
          MessageSupport.decode_fields(binary, %__MODULE__{}, web_message_info_bytes: {:bytes, 1})
        end
      end

      alias __MODULE__.PlaceholderMessageResendResponse
      alias BaileysEx.Protocol.Proto.MessageSupport

      defstruct placeholder_message_resend_response: nil

      @type t :: %__MODULE__{
              placeholder_message_resend_response: PlaceholderMessageResendResponse.t() | nil
            }

      @spec encode(t()) :: binary()
      def encode(%__MODULE__{} = result) do
        MessageSupport.encode_fields(result,
          placeholder_message_resend_response: {:message, 4, PlaceholderMessageResendResponse}
        )
      end

      @spec decode(binary()) :: {:ok, t()} | {:error, term()}
      def decode(binary) do
        MessageSupport.decode_fields(binary, %__MODULE__{},
          placeholder_message_resend_response: {:message, 4, PlaceholderMessageResendResponse}
        )
      end
    end

    alias BaileysEx.Protocol.Proto.Message.PeerDataOperationRequestResponseMessage.PeerDataOperationResult
    alias BaileysEx.Protocol.Proto.MessageSupport

    @type_values %{
      UPLOAD_STICKER: 0,
      SEND_RECENT_STICKER_BOOTSTRAP: 1,
      GENERATE_LINK_PREVIEW: 2,
      HISTORY_SYNC_ON_DEMAND: 3,
      PLACEHOLDER_MESSAGE_RESEND: 4
    }

    defstruct peer_data_operation_request_type: nil,
              stanza_id: nil,
              peer_data_operation_result: []

    @type t :: %__MODULE__{
            peer_data_operation_request_type: atom() | integer() | nil,
            stanza_id: String.t() | nil,
            peer_data_operation_result: [PeerDataOperationResult.t()]
          }

    @spec encode(t()) :: binary()
    def encode(%__MODULE__{} = response) do
      MessageSupport.encode_fields(response,
        peer_data_operation_request_type: {:enum, 1, @type_values},
        stanza_id: {:string, 2},
        peer_data_operation_result: {:repeated_message, 3, PeerDataOperationResult}
      )
    end

    @spec decode(binary()) :: {:ok, t()} | {:error, term()}
    def decode(binary) do
      MessageSupport.decode_fields(binary, %__MODULE__{},
        peer_data_operation_request_type: {:enum, 1, @type_values},
        stanza_id: {:string, 2},
        peer_data_operation_result: {:repeated_message, 3, PeerDataOperationResult}
      )
    end
  end

  defmodule AppStateSyncKeyData do
    @moduledoc false

    alias BaileysEx.Protocol.Proto.MessageSupport

    defstruct key_data: nil

    @type t :: %__MODULE__{key_data: binary() | nil}

    @spec encode(t()) :: binary()
    def encode(%__MODULE__{} = app_state_sync_key_data) do
      MessageSupport.encode_fields(app_state_sync_key_data,
        key_data: {:bytes, 1}
      )
    end

    @spec decode(binary()) :: {:ok, t()} | {:error, term()}
    def decode(binary) do
      MessageSupport.decode_fields(binary, %__MODULE__{}, key_data: {:bytes, 1})
    end
  end

  defmodule AppStateSyncKeyId do
    @moduledoc false

    alias BaileysEx.Protocol.Proto.MessageSupport

    defstruct key_id: nil

    @type t :: %__MODULE__{key_id: binary() | nil}

    @spec encode(t()) :: binary()
    def encode(%__MODULE__{} = app_state_sync_key_id) do
      MessageSupport.encode_fields(app_state_sync_key_id,
        key_id: {:bytes, 1}
      )
    end

    @spec decode(binary()) :: {:ok, t()} | {:error, term()}
    def decode(binary) do
      MessageSupport.decode_fields(binary, %__MODULE__{}, key_id: {:bytes, 1})
    end
  end

  defmodule AppStateSyncKey do
    @moduledoc false

    alias BaileysEx.Protocol.Proto.Message.AppStateSyncKeyData
    alias BaileysEx.Protocol.Proto.Message.AppStateSyncKeyId
    alias BaileysEx.Protocol.Proto.MessageSupport

    defstruct key_id: nil, key_data: nil

    @type t :: %__MODULE__{
            key_id: AppStateSyncKeyId.t() | nil,
            key_data: AppStateSyncKeyData.t() | nil
          }

    @spec encode(t()) :: binary()
    def encode(%__MODULE__{} = app_state_sync_key) do
      MessageSupport.encode_fields(app_state_sync_key,
        key_id: {:message, 1, AppStateSyncKeyId},
        key_data: {:message, 2, AppStateSyncKeyData}
      )
    end

    @spec decode(binary()) :: {:ok, t()} | {:error, term()}
    def decode(binary) do
      MessageSupport.decode_fields(binary, %__MODULE__{},
        key_id: {:message, 1, AppStateSyncKeyId},
        key_data: {:message, 2, AppStateSyncKeyData}
      )
    end
  end

  defmodule AppStateSyncKeyShare do
    @moduledoc false

    alias BaileysEx.Protocol.Proto.Message.AppStateSyncKey
    alias BaileysEx.Protocol.Proto.MessageSupport

    defstruct keys: []

    @type t :: %__MODULE__{keys: [AppStateSyncKey.t()]}

    @spec encode(t()) :: binary()
    def encode(%__MODULE__{} = app_state_sync_key_share) do
      MessageSupport.encode_fields(app_state_sync_key_share,
        keys: {:repeated_message, 1, AppStateSyncKey}
      )
    end

    @spec decode(binary()) :: {:ok, t()} | {:error, term()}
    def decode(binary) do
      MessageSupport.decode_fields(binary, %__MODULE__{},
        keys: {:repeated_message, 1, AppStateSyncKey}
      )
    end
  end

  defmodule ProtocolMessage do
    @moduledoc false

    alias BaileysEx.Protocol.Proto.Message
    alias BaileysEx.Protocol.Proto.Message.AppStateSyncKeyShare
    alias BaileysEx.Protocol.Proto.Message.HistorySyncNotification
    alias BaileysEx.Protocol.Proto.Message.LIDMigrationMappingSyncMessage
    alias BaileysEx.Protocol.Proto.Message.LimitSharing
    alias BaileysEx.Protocol.Proto.Message.MemberLabel
    alias BaileysEx.Protocol.Proto.Message.PeerDataOperationRequestMessage
    alias BaileysEx.Protocol.Proto.Message.PeerDataOperationRequestResponseMessage
    alias BaileysEx.Protocol.Proto.MessageKey
    alias BaileysEx.Protocol.Proto.MessageSupport

    @type_values %{
      REVOKE: 0,
      EPHEMERAL_SETTING: 3,
      HISTORY_SYNC_NOTIFICATION: 5,
      APP_STATE_SYNC_KEY_SHARE: 6,
      SHARE_PHONE_NUMBER: 11,
      MESSAGE_EDIT: 14,
      PEER_DATA_OPERATION_REQUEST_MESSAGE: 16,
      PEER_DATA_OPERATION_REQUEST_RESPONSE_MESSAGE: 17,
      LID_MIGRATION_MAPPING_SYNC: 22,
      LIMIT_SHARING: 27,
      GROUP_MEMBER_LABEL_CHANGE: 30
    }

    defstruct key: nil,
              type: nil,
              ephemeral_expiration: nil,
              ephemeral_setting_timestamp: nil,
              history_sync_notification: nil,
              app_state_sync_key_share: nil,
              peer_data_operation_request_message: nil,
              peer_data_operation_request_response_message: nil,
              edited_message: nil,
              timestamp_ms: nil,
              lid_migration_mapping_sync_message: nil,
              limit_sharing: nil,
              member_label: nil

    @type t :: %__MODULE__{
            key: MessageKey.t() | nil,
            type: atom() | integer() | nil,
            ephemeral_expiration: non_neg_integer() | nil,
            ephemeral_setting_timestamp: non_neg_integer() | nil,
            history_sync_notification: HistorySyncNotification.t() | nil,
            app_state_sync_key_share: AppStateSyncKeyShare.t() | nil,
            peer_data_operation_request_message: PeerDataOperationRequestMessage.t() | nil,
            peer_data_operation_request_response_message:
              PeerDataOperationRequestResponseMessage.t() | nil,
            edited_message: Message.t() | nil,
            timestamp_ms: non_neg_integer() | nil,
            lid_migration_mapping_sync_message: LIDMigrationMappingSyncMessage.t() | nil,
            limit_sharing: LimitSharing.t() | nil,
            member_label: MemberLabel.t() | nil
          }

    @spec encode(t()) :: binary()
    def encode(%__MODULE__{} = protocol_message) do
      MessageSupport.encode_fields(protocol_message,
        key: {:message, 1, MessageKey},
        type: {:enum, 2, @type_values},
        ephemeral_expiration: {:uint, 4},
        ephemeral_setting_timestamp: {:int64, 5},
        history_sync_notification: {:message, 6, HistorySyncNotification},
        app_state_sync_key_share: {:message, 7, AppStateSyncKeyShare},
        edited_message: {:message, 14, Message},
        timestamp_ms: {:int64, 15},
        peer_data_operation_request_message: {:message, 16, PeerDataOperationRequestMessage},
        peer_data_operation_request_response_message:
          {:message, 17, PeerDataOperationRequestResponseMessage},
        lid_migration_mapping_sync_message: {:message, 23, LIDMigrationMappingSyncMessage},
        limit_sharing: {:message, 24, LimitSharing},
        member_label: {:message, 27, MemberLabel}
      )
    end

    @spec decode(binary()) :: {:ok, t()} | {:error, term()}
    def decode(binary) do
      MessageSupport.decode_fields(binary, %__MODULE__{},
        key: {:message, 1, MessageKey},
        type: {:enum, 2, @type_values},
        ephemeral_expiration: {:uint, 4},
        ephemeral_setting_timestamp: {:int64, 5},
        history_sync_notification: {:message, 6, HistorySyncNotification},
        app_state_sync_key_share: {:message, 7, AppStateSyncKeyShare},
        edited_message: {:message, 14, Message},
        timestamp_ms: {:int64, 15},
        peer_data_operation_request_message: {:message, 16, PeerDataOperationRequestMessage},
        peer_data_operation_request_response_message:
          {:message, 17, PeerDataOperationRequestResponseMessage},
        lid_migration_mapping_sync_message: {:message, 23, LIDMigrationMappingSyncMessage},
        limit_sharing: {:message, 24, LimitSharing},
        member_label: {:message, 27, MemberLabel}
      )
    end
  end

  defmodule PinInChatMessage do
    @moduledoc false

    alias BaileysEx.Protocol.Proto.MessageKey
    alias BaileysEx.Protocol.Proto.MessageSupport

    @type_values %{PIN_FOR_ALL: 1, UNPIN_FOR_ALL: 2}

    defstruct key: nil, type: nil, sender_timestamp_ms: nil

    @type t :: %__MODULE__{
            key: MessageKey.t() | nil,
            type: atom() | integer() | nil,
            sender_timestamp_ms: non_neg_integer() | nil
          }

    @spec encode(struct()) :: binary()
    def encode(%__MODULE__{} = pin_in_chat_message) do
      MessageSupport.encode_fields(pin_in_chat_message,
        key: {:message, 1, MessageKey},
        type: {:enum, 2, @type_values},
        sender_timestamp_ms: {:int64, 3}
      )
    end

    @spec decode(binary()) :: {:ok, struct()} | {:error, term()}
    def decode(binary) do
      MessageSupport.decode_fields(binary, %__MODULE__{},
        key: {:message, 1, MessageKey},
        type: {:enum, 2, @type_values},
        sender_timestamp_ms: {:int64, 3}
      )
    end
  end

  defmodule GroupInviteMessage do
    @moduledoc false

    alias BaileysEx.Protocol.Proto.Message.ContextInfo
    alias BaileysEx.Protocol.Proto.MessageSupport

    defstruct group_jid: nil,
              invite_code: nil,
              invite_expiration: nil,
              group_name: nil,
              jpeg_thumbnail: nil,
              caption: nil,
              context_info: nil

    @type t :: %__MODULE__{
            group_jid: String.t() | nil,
            invite_code: String.t() | nil,
            invite_expiration: non_neg_integer() | nil,
            group_name: String.t() | nil,
            jpeg_thumbnail: binary() | nil,
            caption: String.t() | nil,
            context_info: ContextInfo.t() | nil
          }

    @spec encode(struct()) :: binary()
    def encode(%__MODULE__{} = group_invite_message) do
      MessageSupport.encode_fields(group_invite_message,
        group_jid: {:string, 1},
        invite_code: {:string, 2},
        invite_expiration: {:int64, 3},
        group_name: {:string, 4},
        jpeg_thumbnail: {:bytes, 5},
        caption: {:string, 6},
        context_info: {:message, 7, ContextInfo}
      )
    end

    @spec decode(binary()) :: {:ok, struct()} | {:error, term()}
    def decode(binary) do
      MessageSupport.decode_fields(binary, %__MODULE__{},
        group_jid: {:string, 1},
        invite_code: {:string, 2},
        invite_expiration: {:int64, 3},
        group_name: {:string, 4},
        jpeg_thumbnail: {:bytes, 5},
        caption: {:string, 6},
        context_info: {:message, 7, ContextInfo}
      )
    end
  end

  defmodule EventMessage do
    @moduledoc false

    alias BaileysEx.Protocol.Proto.Message.ContextInfo
    alias BaileysEx.Protocol.Proto.MessageSupport

    defstruct context_info: nil,
              is_canceled: nil,
              name: nil,
              description: nil,
              location: nil,
              start_time: nil,
              extra_guests_allowed: nil

    @type t :: %__MODULE__{
            context_info: ContextInfo.t() | nil,
            is_canceled: boolean() | nil,
            name: String.t() | nil,
            description: String.t() | nil,
            location: LocationMessage.t() | nil,
            start_time: non_neg_integer() | nil,
            extra_guests_allowed: boolean() | nil
          }

    @spec encode(struct()) :: binary()
    def encode(%__MODULE__{} = event_message) do
      MessageSupport.encode_fields(event_message,
        context_info: {:message, 1, ContextInfo},
        is_canceled: {:bool, 2},
        name: {:string, 3},
        description: {:string, 4},
        location: {:message, 5, LocationMessage},
        start_time: {:int64, 7},
        extra_guests_allowed: {:bool, 9}
      )
    end

    @spec decode(binary()) :: {:ok, struct()} | {:error, term()}
    def decode(binary) do
      MessageSupport.decode_fields(binary, %__MODULE__{},
        context_info: {:message, 1, ContextInfo},
        is_canceled: {:bool, 2},
        name: {:string, 3},
        description: {:string, 4},
        location: {:message, 5, LocationMessage},
        start_time: {:int64, 7},
        extra_guests_allowed: {:bool, 9}
      )
    end
  end

  defmodule EncEventResponseMessage do
    @moduledoc false

    alias BaileysEx.Protocol.Proto.MessageSupport

    defstruct event_creation_message_key: nil, enc_payload: nil, enc_iv: nil

    @type t :: %__MODULE__{
            event_creation_message_key: MessageKey.t() | nil,
            enc_payload: binary() | nil,
            enc_iv: binary() | nil
          }

    @spec encode(t()) :: binary()
    def encode(%__MODULE__{} = enc_event_response_message) do
      MessageSupport.encode_fields(enc_event_response_message,
        event_creation_message_key: {:message, 1, MessageKey},
        enc_payload: {:bytes, 2},
        enc_iv: {:bytes, 3}
      )
    end

    @spec decode(binary()) :: {:ok, t()} | {:error, term()}
    def decode(binary) do
      MessageSupport.decode_fields(binary, %__MODULE__{},
        event_creation_message_key: {:message, 1, MessageKey},
        enc_payload: {:bytes, 2},
        enc_iv: {:bytes, 3}
      )
    end
  end

  defmodule EventResponseMessage do
    @moduledoc false

    alias BaileysEx.Protocol.Proto.MessageSupport

    @response_values %{UNKNOWN: 0, GOING: 1, NOT_GOING: 2, MAYBE: 3}

    defstruct response: nil, timestamp_ms: nil, extra_guest_count: nil

    @type t :: %__MODULE__{
            response: atom() | integer() | nil,
            timestamp_ms: integer() | nil,
            extra_guest_count: integer() | nil
          }

    @spec encode(t()) :: binary()
    def encode(%__MODULE__{} = event_response_message) do
      MessageSupport.encode_fields(event_response_message,
        response: {:enum, 1, @response_values},
        timestamp_ms: {:int64, 2},
        extra_guest_count: {:int, 3}
      )
    end

    @spec decode(binary()) :: {:ok, t()} | {:error, term()}
    def decode(binary) do
      MessageSupport.decode_fields(binary, %__MODULE__{},
        response: {:enum, 1, @response_values},
        timestamp_ms: {:int64, 2},
        extra_guest_count: {:int, 3}
      )
    end
  end

  defmodule ProductMessage do
    @moduledoc false

    defmodule ProductSnapshot do
      @moduledoc false

      alias BaileysEx.Protocol.Proto.MessageSupport

      defstruct product_image: nil,
                product_id: nil,
                title: nil,
                description: nil,
                currency_code: nil,
                price_amount_1000: nil,
                url: nil

      @type t :: %__MODULE__{
              product_image: ImageMessage.t() | nil,
              product_id: String.t() | nil,
              title: String.t() | nil,
              description: String.t() | nil,
              currency_code: String.t() | nil,
              price_amount_1000: non_neg_integer() | nil,
              url: String.t() | nil
            }

      @spec encode(struct()) :: binary()
      def encode(%__MODULE__{} = product_snapshot) do
        MessageSupport.encode_fields(product_snapshot,
          product_image: {:message, 1, ImageMessage},
          product_id: {:string, 2},
          title: {:string, 3},
          description: {:string, 4},
          currency_code: {:string, 5},
          price_amount_1000: {:int64, 6},
          url: {:string, 8}
        )
      end

      @spec decode(binary()) :: {:ok, struct()} | {:error, term()}
      def decode(binary) do
        MessageSupport.decode_fields(binary, %__MODULE__{},
          product_image: {:message, 1, ImageMessage},
          product_id: {:string, 2},
          title: {:string, 3},
          description: {:string, 4},
          currency_code: {:string, 5},
          price_amount_1000: {:int64, 6},
          url: {:string, 8}
        )
      end
    end

    alias BaileysEx.Protocol.Proto.Message.ContextInfo
    alias BaileysEx.Protocol.Proto.MessageSupport

    defstruct product: nil,
              business_owner_jid: nil,
              body: nil,
              footer: nil,
              context_info: nil

    @type t :: %__MODULE__{
            product: ProductSnapshot.t() | nil,
            business_owner_jid: String.t() | nil,
            body: String.t() | nil,
            footer: String.t() | nil,
            context_info: ContextInfo.t() | nil
          }

    @spec encode(struct()) :: binary()
    def encode(%__MODULE__{} = product_message) do
      MessageSupport.encode_fields(product_message,
        product: {:message, 1, ProductSnapshot},
        business_owner_jid: {:string, 2},
        body: {:string, 5},
        footer: {:string, 6},
        context_info: {:message, 17, ContextInfo}
      )
    end

    @spec decode(binary()) :: {:ok, struct()} | {:error, term()}
    def decode(binary) do
      MessageSupport.decode_fields(binary, %__MODULE__{},
        product: {:message, 1, ProductSnapshot},
        business_owner_jid: {:string, 2},
        body: {:string, 5},
        footer: {:string, 6},
        context_info: {:message, 17, ContextInfo}
      )
    end
  end

  defmodule ButtonsResponseMessage do
    @moduledoc false

    alias BaileysEx.Protocol.Proto.Message.ContextInfo
    alias BaileysEx.Protocol.Proto.MessageSupport

    @type_values %{UNKNOWN: 0, DISPLAY_TEXT: 1}

    defstruct selected_button_id: nil,
              selected_display_text: nil,
              context_info: nil,
              type: nil

    @type t :: %__MODULE__{
            selected_button_id: String.t() | nil,
            selected_display_text: String.t() | nil,
            context_info: ContextInfo.t() | nil,
            type: atom() | integer() | nil
          }

    @spec encode(struct()) :: binary()
    def encode(%__MODULE__{} = buttons_response_message) do
      MessageSupport.encode_fields(buttons_response_message,
        selected_button_id: {:string, 1},
        selected_display_text: {:string, 2},
        context_info: {:message, 3, ContextInfo},
        type: {:enum, 4, @type_values}
      )
    end

    @spec decode(binary()) :: {:ok, struct()} | {:error, term()}
    def decode(binary) do
      MessageSupport.decode_fields(binary, %__MODULE__{},
        selected_button_id: {:string, 1},
        selected_display_text: {:string, 2},
        context_info: {:message, 3, ContextInfo},
        type: {:enum, 4, @type_values}
      )
    end
  end

  defmodule ButtonsMessage do
    @moduledoc false

    alias BaileysEx.Protocol.Proto.Message.ContextInfo
    alias BaileysEx.Protocol.Proto.MessageSupport

    defmodule Button do
      @moduledoc false

      alias BaileysEx.Protocol.Proto.MessageSupport

      defmodule ButtonText do
        @moduledoc false

        alias BaileysEx.Protocol.Proto.MessageSupport

        defstruct display_text: nil

        @type t :: %__MODULE__{display_text: String.t() | nil}

        @spec encode(struct()) :: binary()
        def encode(%__MODULE__{} = button_text) do
          MessageSupport.encode_fields(button_text, display_text: {:string, 1})
        end

        @spec decode(binary()) :: {:ok, struct()} | {:error, term()}
        def decode(binary) do
          MessageSupport.decode_fields(binary, %__MODULE__{}, display_text: {:string, 1})
        end
      end

      defmodule NativeFlowInfo do
        @moduledoc false

        alias BaileysEx.Protocol.Proto.MessageSupport

        defstruct name: nil, params_json: nil

        @type t :: %__MODULE__{name: String.t() | nil, params_json: String.t() | nil}

        @spec encode(struct()) :: binary()
        def encode(%__MODULE__{} = native_flow_info) do
          MessageSupport.encode_fields(native_flow_info,
            name: {:string, 1},
            params_json: {:string, 2}
          )
        end

        @spec decode(binary()) :: {:ok, struct()} | {:error, term()}
        def decode(binary) do
          MessageSupport.decode_fields(binary, %__MODULE__{},
            name: {:string, 1},
            params_json: {:string, 2}
          )
        end
      end

      @type_values %{UNKNOWN: 0, RESPONSE: 1, NATIVE_FLOW: 2}

      defstruct button_id: nil, button_text: nil, type: nil, native_flow_info: nil

      @type t :: %__MODULE__{
              button_id: String.t() | nil,
              button_text: ButtonText.t() | nil,
              type: atom() | integer() | nil,
              native_flow_info: NativeFlowInfo.t() | nil
            }

      @spec encode(struct()) :: binary()
      def encode(%__MODULE__{} = button) do
        MessageSupport.encode_fields(button,
          button_id: {:string, 1},
          button_text: {:message, 2, ButtonText},
          type: {:enum, 3, @type_values},
          native_flow_info: {:message, 4, NativeFlowInfo}
        )
      end

      @spec decode(binary()) :: {:ok, struct()} | {:error, term()}
      def decode(binary) do
        MessageSupport.decode_fields(binary, %__MODULE__{},
          button_id: {:string, 1},
          button_text: {:message, 2, ButtonText},
          type: {:enum, 3, @type_values},
          native_flow_info: {:message, 4, NativeFlowInfo}
        )
      end
    end

    @header_type_values %{
      UNKNOWN: 0,
      EMPTY: 1,
      TEXT: 2,
      DOCUMENT: 3,
      IMAGE: 4,
      VIDEO: 5,
      LOCATION: 6
    }

    defstruct text: nil,
              document_message: nil,
              image_message: nil,
              video_message: nil,
              location_message: nil,
              content_text: nil,
              footer_text: nil,
              context_info: nil,
              buttons: [],
              header_type: nil

    @type t :: %__MODULE__{
            text: String.t() | nil,
            document_message: DocumentMessage.t() | nil,
            image_message: ImageMessage.t() | nil,
            video_message: VideoMessage.t() | nil,
            location_message: LocationMessage.t() | nil,
            content_text: String.t() | nil,
            footer_text: String.t() | nil,
            context_info: ContextInfo.t() | nil,
            buttons: [Button.t()],
            header_type: atom() | integer() | nil
          }

    @spec encode(struct()) :: binary()
    def encode(%__MODULE__{} = buttons_message) do
      MessageSupport.encode_fields(buttons_message,
        text: {:string, 1},
        document_message: {:message, 2, DocumentMessage},
        image_message: {:message, 3, ImageMessage},
        video_message: {:message, 4, VideoMessage},
        location_message: {:message, 5, LocationMessage},
        content_text: {:string, 6},
        footer_text: {:string, 7},
        context_info: {:message, 8, ContextInfo},
        buttons: {:repeated_message, 9, Button},
        header_type: {:enum, 10, @header_type_values}
      )
    end

    @spec decode(binary()) :: {:ok, struct()} | {:error, term()}
    def decode(binary) do
      MessageSupport.decode_fields(binary, %__MODULE__{},
        text: {:string, 1},
        document_message: {:message, 2, DocumentMessage},
        image_message: {:message, 3, ImageMessage},
        video_message: {:message, 4, VideoMessage},
        location_message: {:message, 5, LocationMessage},
        content_text: {:string, 6},
        footer_text: {:string, 7},
        context_info: {:message, 8, ContextInfo},
        buttons: {:repeated_message, 9, Button},
        header_type: {:enum, 10, @header_type_values}
      )
    end
  end

  defmodule TemplateButtonReplyMessage do
    @moduledoc false

    alias BaileysEx.Protocol.Proto.Message.ContextInfo
    alias BaileysEx.Protocol.Proto.MessageSupport

    defstruct selected_id: nil, selected_display_text: nil, context_info: nil

    @type t :: %__MODULE__{
            selected_id: String.t() | nil,
            selected_display_text: String.t() | nil,
            context_info: ContextInfo.t() | nil
          }

    @spec encode(struct()) :: binary()
    def encode(%__MODULE__{} = template_button_reply_message) do
      MessageSupport.encode_fields(template_button_reply_message,
        selected_id: {:string, 1},
        selected_display_text: {:string, 2},
        context_info: {:message, 3, ContextInfo}
      )
    end

    @spec decode(binary()) :: {:ok, struct()} | {:error, term()}
    def decode(binary) do
      MessageSupport.decode_fields(binary, %__MODULE__{},
        selected_id: {:string, 1},
        selected_display_text: {:string, 2},
        context_info: {:message, 3, ContextInfo}
      )
    end
  end

  defmodule ListResponseMessage do
    @moduledoc false

    defmodule SingleSelectReply do
      @moduledoc false

      alias BaileysEx.Protocol.Proto.MessageSupport

      defstruct selected_row_id: nil

      @type t :: %__MODULE__{selected_row_id: String.t() | nil}

      @spec encode(struct()) :: binary()
      def encode(%__MODULE__{} = single_select_reply) do
        MessageSupport.encode_fields(single_select_reply, selected_row_id: {:string, 1})
      end

      @spec decode(binary()) :: {:ok, struct()} | {:error, term()}
      def decode(binary) do
        MessageSupport.decode_fields(binary, %__MODULE__{}, selected_row_id: {:string, 1})
      end
    end

    alias BaileysEx.Protocol.Proto.Message.ContextInfo
    alias BaileysEx.Protocol.Proto.MessageSupport

    @list_type_values %{UNKNOWN: 0, SINGLE_SELECT: 1}

    defstruct title: nil,
              list_type: nil,
              single_select_reply: nil,
              context_info: nil,
              description: nil

    @type t :: %__MODULE__{
            title: String.t() | nil,
            list_type: atom() | integer() | nil,
            single_select_reply: SingleSelectReply.t() | nil,
            context_info: ContextInfo.t() | nil,
            description: String.t() | nil
          }

    @spec encode(struct()) :: binary()
    def encode(%__MODULE__{} = list_response_message) do
      MessageSupport.encode_fields(list_response_message,
        title: {:string, 1},
        list_type: {:enum, 2, @list_type_values},
        single_select_reply: {:message, 3, SingleSelectReply},
        context_info: {:message, 4, ContextInfo},
        description: {:string, 5}
      )
    end

    @spec decode(binary()) :: {:ok, struct()} | {:error, term()}
    def decode(binary) do
      MessageSupport.decode_fields(binary, %__MODULE__{},
        title: {:string, 1},
        list_type: {:enum, 2, @list_type_values},
        single_select_reply: {:message, 3, SingleSelectReply},
        context_info: {:message, 4, ContextInfo},
        description: {:string, 5}
      )
    end
  end

  defmodule RequestPhoneNumberMessage do
    @moduledoc false

    alias BaileysEx.Protocol.Proto.Message.ContextInfo
    alias BaileysEx.Protocol.Proto.MessageSupport

    defstruct context_info: nil

    @type t :: %__MODULE__{context_info: ContextInfo.t() | nil}

    @spec encode(struct()) :: binary()
    def encode(%__MODULE__{} = request_phone_number_message) do
      MessageSupport.encode_fields(request_phone_number_message,
        context_info: {:message, 1, ContextInfo}
      )
    end

    @spec decode(binary()) :: {:ok, struct()} | {:error, term()}
    def decode(binary) do
      MessageSupport.decode_fields(binary, %__MODULE__{},
        context_info: {:message, 1, ContextInfo}
      )
    end
  end

  defmodule FutureProofMessage do
    @moduledoc false

    alias BaileysEx.Protocol.Proto.Message
    alias BaileysEx.Protocol.Proto.MessageSupport

    defstruct message: nil

    @type t :: %__MODULE__{message: Message.t() | nil}

    @spec encode(t()) :: binary()
    def encode(%__MODULE__{} = future_proof_message) do
      MessageSupport.encode_fields(future_proof_message,
        message: {:message, 1, Message}
      )
    end

    @spec decode(binary()) :: {:ok, t()} | {:error, term()}
    def decode(binary) do
      MessageSupport.decode_fields(binary, %__MODULE__{}, message: {:message, 1, Message})
    end
  end

  defmodule TemplateMessage do
    @moduledoc false

    alias BaileysEx.Protocol.Proto.Message.ContextInfo
    alias BaileysEx.Protocol.Proto.MessageSupport

    defmodule FourRowTemplate do
      @moduledoc false

      alias BaileysEx.Protocol.Proto.MessageSupport

      defstruct document_message: nil,
                highly_structured_message: nil,
                image_message: nil,
                video_message: nil,
                location_message: nil

      @type t :: %__MODULE__{
              document_message: DocumentMessage.t() | nil,
              highly_structured_message: term() | nil,
              image_message: ImageMessage.t() | nil,
              video_message: VideoMessage.t() | nil,
              location_message: LocationMessage.t() | nil
            }

      @spec encode(struct()) :: binary()
      def encode(%__MODULE__{} = four_row_template) do
        MessageSupport.encode_fields(four_row_template,
          document_message: {:message, 1, DocumentMessage},
          image_message: {:message, 3, ImageMessage},
          video_message: {:message, 4, VideoMessage},
          location_message: {:message, 5, LocationMessage}
        )
      end

      @spec decode(binary()) :: {:ok, struct()} | {:error, term()}
      def decode(binary) do
        MessageSupport.decode_fields(binary, %__MODULE__{},
          document_message: {:message, 1, DocumentMessage},
          image_message: {:message, 3, ImageMessage},
          video_message: {:message, 4, VideoMessage},
          location_message: {:message, 5, LocationMessage}
        )
      end
    end

    defmodule HydratedFourRowTemplate do
      @moduledoc false

      alias BaileysEx.Protocol.Proto.MessageSupport

      defstruct document_message: nil,
                hydrated_title_text: nil,
                image_message: nil,
                video_message: nil,
                location_message: nil,
                hydrated_content_text: nil,
                hydrated_footer_text: nil,
                hydrated_buttons: [],
                template_id: nil,
                mask_linked_devices: nil

      @type t :: %__MODULE__{
              document_message: DocumentMessage.t() | nil,
              hydrated_title_text: String.t() | nil,
              image_message: ImageMessage.t() | nil,
              video_message: VideoMessage.t() | nil,
              location_message: LocationMessage.t() | nil,
              hydrated_content_text: String.t() | nil,
              hydrated_footer_text: String.t() | nil,
              hydrated_buttons: [term()],
              template_id: String.t() | nil,
              mask_linked_devices: boolean() | nil
            }

      @spec encode(struct()) :: binary()
      def encode(%__MODULE__{} = hydrated_four_row_template) do
        MessageSupport.encode_fields(hydrated_four_row_template,
          document_message: {:message, 1, DocumentMessage},
          hydrated_title_text: {:string, 2},
          image_message: {:message, 3, ImageMessage},
          video_message: {:message, 4, VideoMessage},
          location_message: {:message, 5, LocationMessage},
          hydrated_content_text: {:string, 6},
          hydrated_footer_text: {:string, 7},
          template_id: {:string, 9},
          mask_linked_devices: {:bool, 10}
        )
      end

      @spec decode(binary()) :: {:ok, struct()} | {:error, term()}
      def decode(binary) do
        MessageSupport.decode_fields(binary, %__MODULE__{},
          document_message: {:message, 1, DocumentMessage},
          hydrated_title_text: {:string, 2},
          image_message: {:message, 3, ImageMessage},
          video_message: {:message, 4, VideoMessage},
          location_message: {:message, 5, LocationMessage},
          hydrated_content_text: {:string, 6},
          hydrated_footer_text: {:string, 7},
          template_id: {:string, 9},
          mask_linked_devices: {:bool, 10}
        )
      end
    end

    defstruct four_row_template: nil,
              hydrated_four_row_template: nil,
              context_info: nil,
              hydrated_template: nil,
              interactive_message_template: nil,
              template_id: nil

    @type t :: %__MODULE__{
            four_row_template: FourRowTemplate.t() | nil,
            hydrated_four_row_template: HydratedFourRowTemplate.t() | nil,
            context_info: ContextInfo.t() | nil,
            hydrated_template: HydratedFourRowTemplate.t() | nil,
            interactive_message_template: term() | nil,
            template_id: String.t() | nil
          }

    @spec encode(struct()) :: binary()
    def encode(%__MODULE__{} = template_message) do
      MessageSupport.encode_fields(template_message,
        four_row_template: {:message, 1, FourRowTemplate},
        hydrated_four_row_template: {:message, 2, HydratedFourRowTemplate},
        context_info: {:message, 3, ContextInfo},
        hydrated_template: {:message, 4, HydratedFourRowTemplate},
        template_id: {:string, 9}
      )
    end

    @spec decode(binary()) :: {:ok, struct()} | {:error, term()}
    def decode(binary) do
      MessageSupport.decode_fields(binary, %__MODULE__{},
        four_row_template: {:message, 1, FourRowTemplate},
        hydrated_four_row_template: {:message, 2, HydratedFourRowTemplate},
        context_info: {:message, 3, ContextInfo},
        hydrated_template: {:message, 4, HydratedFourRowTemplate},
        template_id: {:string, 9}
      )
    end
  end

  defmodule DeviceSentMessage do
    @moduledoc false

    alias BaileysEx.Protocol.Proto.Message
    alias BaileysEx.Protocol.Proto.MessageSupport

    defstruct destination_jid: nil, message: nil, phash: nil

    @type t :: %__MODULE__{
            destination_jid: String.t() | nil,
            message: Message.t() | nil,
            phash: String.t() | nil
          }

    @spec encode(struct()) :: binary()
    def encode(%__MODULE__{} = device_sent_message) do
      MessageSupport.encode_fields(device_sent_message,
        destination_jid: {:string, 1},
        message: {:message, 2, Message},
        phash: {:string, 3}
      )
    end

    @spec decode(binary()) :: {:ok, struct()} | {:error, term()}
    def decode(binary) do
      MessageSupport.decode_fields(binary, %__MODULE__{},
        destination_jid: {:string, 1},
        message: {:message, 2, Message},
        phash: {:string, 3}
      )
    end
  end

  defstruct conversation: nil,
            sender_key_distribution_message: nil,
            image_message: nil,
            contact_message: nil,
            location_message: nil,
            extended_text_message: nil,
            document_message: nil,
            audio_message: nil,
            video_message: nil,
            protocol_message: nil,
            contacts_array_message: nil,
            sticker_message: nil,
            group_invite_message: nil,
            template_button_reply_message: nil,
            product_message: nil,
            device_sent_message: nil,
            message_context_info: nil,
            view_once_message: nil,
            template_message: nil,
            list_response_message: nil,
            ephemeral_message: nil,
            buttons_message: nil,
            buttons_response_message: nil,
            reaction_message: nil,
            poll_creation_message: nil,
            poll_update_message: nil,
            document_with_caption_message: nil,
            request_phone_number_message: nil,
            enc_reaction_message: nil,
            view_once_message_v2: nil,
            edited_message: nil,
            view_once_message_v2_extension: nil,
            poll_creation_message_v2: nil,
            pin_in_chat_message: nil,
            poll_creation_message_v3: nil,
            ptv_message: nil,
            event_message: nil,
            enc_event_response_message: nil,
            live_location_message: nil,
            associated_child_message: nil,
            group_status_message: nil,
            group_status_message_v2: nil

  @type t :: %__MODULE__{
          conversation: String.t() | nil,
          sender_key_distribution_message: SenderKeyDistributionMessage.t() | nil,
          image_message: ImageMessage.t() | nil,
          contact_message: ContactMessage.t() | nil,
          location_message: LocationMessage.t() | nil,
          extended_text_message: ExtendedTextMessage.t() | nil,
          document_message: DocumentMessage.t() | nil,
          audio_message: AudioMessage.t() | nil,
          video_message: VideoMessage.t() | nil,
          protocol_message: ProtocolMessage.t() | nil,
          contacts_array_message: ContactsArrayMessage.t() | nil,
          sticker_message: StickerMessage.t() | nil,
          group_invite_message: GroupInviteMessage.t() | nil,
          template_button_reply_message: TemplateButtonReplyMessage.t() | nil,
          product_message: ProductMessage.t() | nil,
          device_sent_message: DeviceSentMessage.t() | nil,
          message_context_info: MessageContextInfo.t() | nil,
          view_once_message: FutureProofMessage.t() | nil,
          template_message: TemplateMessage.t() | nil,
          list_response_message: ListResponseMessage.t() | nil,
          ephemeral_message: FutureProofMessage.t() | nil,
          buttons_message: ButtonsMessage.t() | nil,
          buttons_response_message: ButtonsResponseMessage.t() | nil,
          reaction_message: ReactionMessage.t() | nil,
          poll_creation_message: PollCreationMessage.t() | nil,
          poll_update_message: PollUpdateMessage.t() | nil,
          document_with_caption_message: FutureProofMessage.t() | nil,
          request_phone_number_message: RequestPhoneNumberMessage.t() | nil,
          enc_reaction_message: EncReactionMessage.t() | nil,
          view_once_message_v2: FutureProofMessage.t() | nil,
          edited_message: FutureProofMessage.t() | nil,
          view_once_message_v2_extension: FutureProofMessage.t() | nil,
          poll_creation_message_v2: PollCreationMessage.t() | nil,
          pin_in_chat_message: PinInChatMessage.t() | nil,
          poll_creation_message_v3: PollCreationMessage.t() | nil,
          ptv_message: VideoMessage.t() | nil,
          event_message: EventMessage.t() | nil,
          enc_event_response_message: EncEventResponseMessage.t() | nil,
          live_location_message: LiveLocationMessage.t() | nil,
          associated_child_message: FutureProofMessage.t() | nil,
          group_status_message: FutureProofMessage.t() | nil,
          group_status_message_v2: FutureProofMessage.t() | nil
        }

  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = message) do
    MessageSupport.encode_fields(message,
      conversation: {:string, 1},
      sender_key_distribution_message: {:message, 2, SenderKeyDistributionMessage},
      image_message: {:message, 3, ImageMessage},
      contact_message: {:message, 4, ContactMessage},
      location_message: {:message, 5, LocationMessage},
      extended_text_message: {:message, 6, ExtendedTextMessage},
      document_message: {:message, 7, DocumentMessage},
      audio_message: {:message, 8, AudioMessage},
      video_message: {:message, 9, VideoMessage},
      protocol_message: {:message, 12, ProtocolMessage},
      contacts_array_message: {:message, 13, ContactsArrayMessage},
      sticker_message: {:message, 26, StickerMessage},
      group_invite_message: {:message, 28, GroupInviteMessage},
      template_button_reply_message: {:message, 29, TemplateButtonReplyMessage},
      product_message: {:message, 30, ProductMessage},
      device_sent_message: {:message, 31, DeviceSentMessage},
      message_context_info: {:message, 35, MessageContextInfo},
      template_message: {:message, 25, TemplateMessage},
      view_once_message: {:message, 37, FutureProofMessage},
      list_response_message: {:message, 39, ListResponseMessage},
      ephemeral_message: {:message, 40, FutureProofMessage},
      buttons_message: {:message, 42, ButtonsMessage},
      buttons_response_message: {:message, 43, ButtonsResponseMessage},
      reaction_message: {:message, 46, ReactionMessage},
      poll_creation_message: {:message, 49, PollCreationMessage},
      poll_update_message: {:message, 50, PollUpdateMessage},
      document_with_caption_message: {:message, 53, FutureProofMessage},
      request_phone_number_message: {:message, 54, RequestPhoneNumberMessage},
      enc_reaction_message: {:message, 56, EncReactionMessage},
      view_once_message_v2: {:message, 55, FutureProofMessage},
      edited_message: {:message, 58, FutureProofMessage},
      view_once_message_v2_extension: {:message, 59, FutureProofMessage},
      poll_creation_message_v2: {:message, 60, PollCreationMessage},
      pin_in_chat_message: {:message, 63, PinInChatMessage},
      poll_creation_message_v3: {:message, 64, PollCreationMessage},
      ptv_message: {:message, 66, VideoMessage},
      event_message: {:message, 75, EventMessage},
      enc_event_response_message: {:message, 76, EncEventResponseMessage},
      live_location_message: {:message, 18, LiveLocationMessage},
      associated_child_message: {:message, 91, FutureProofMessage},
      group_status_message: {:message, 96, FutureProofMessage},
      group_status_message_v2: {:message, 103, FutureProofMessage}
    )
  end

  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(binary) do
    MessageSupport.decode_fields(binary, %__MODULE__{},
      conversation: {:string, 1},
      sender_key_distribution_message: {:message, 2, SenderKeyDistributionMessage},
      image_message: {:message, 3, ImageMessage},
      contact_message: {:message, 4, ContactMessage},
      location_message: {:message, 5, LocationMessage},
      extended_text_message: {:message, 6, ExtendedTextMessage},
      document_message: {:message, 7, DocumentMessage},
      audio_message: {:message, 8, AudioMessage},
      video_message: {:message, 9, VideoMessage},
      protocol_message: {:message, 12, ProtocolMessage},
      contacts_array_message: {:message, 13, ContactsArrayMessage},
      sticker_message: {:message, 26, StickerMessage},
      group_invite_message: {:message, 28, GroupInviteMessage},
      template_button_reply_message: {:message, 29, TemplateButtonReplyMessage},
      product_message: {:message, 30, ProductMessage},
      device_sent_message: {:message, 31, DeviceSentMessage},
      message_context_info: {:message, 35, MessageContextInfo},
      template_message: {:message, 25, TemplateMessage},
      live_location_message: {:message, 18, LiveLocationMessage},
      view_once_message: {:message, 37, FutureProofMessage},
      list_response_message: {:message, 39, ListResponseMessage},
      ephemeral_message: {:message, 40, FutureProofMessage},
      buttons_message: {:message, 42, ButtonsMessage},
      buttons_response_message: {:message, 43, ButtonsResponseMessage},
      reaction_message: {:message, 46, ReactionMessage},
      poll_creation_message: {:message, 49, PollCreationMessage},
      poll_update_message: {:message, 50, PollUpdateMessage},
      document_with_caption_message: {:message, 53, FutureProofMessage},
      request_phone_number_message: {:message, 54, RequestPhoneNumberMessage},
      enc_reaction_message: {:message, 56, EncReactionMessage},
      view_once_message_v2: {:message, 55, FutureProofMessage},
      edited_message: {:message, 58, FutureProofMessage},
      view_once_message_v2_extension: {:message, 59, FutureProofMessage},
      poll_creation_message_v2: {:message, 60, PollCreationMessage},
      pin_in_chat_message: {:message, 63, PinInChatMessage},
      poll_creation_message_v3: {:message, 64, PollCreationMessage},
      ptv_message: {:message, 66, VideoMessage},
      event_message: {:message, 75, EventMessage},
      enc_event_response_message: {:message, 76, EncEventResponseMessage},
      associated_child_message: {:message, 91, FutureProofMessage},
      group_status_message: {:message, 96, FutureProofMessage},
      group_status_message_v2: {:message, 103, FutureProofMessage}
    )
  end
end

defmodule BaileysEx.Protocol.Proto.WebMessageInfo.UserReceipt do
  @moduledoc false

  alias BaileysEx.Protocol.Proto.MessageSupport

  defstruct user_jid: nil,
            receipt_timestamp: nil,
            read_timestamp: nil,
            played_timestamp: nil

  @type t :: %__MODULE__{
          user_jid: String.t() | nil,
          receipt_timestamp: non_neg_integer() | nil,
          read_timestamp: non_neg_integer() | nil,
          played_timestamp: non_neg_integer() | nil
        }

  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = receipt) do
    MessageSupport.encode_fields(receipt,
      user_jid: {:string, 1},
      receipt_timestamp: {:int64, 2},
      read_timestamp: {:int64, 3},
      played_timestamp: {:int64, 4}
    )
  end

  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(binary) do
    MessageSupport.decode_fields(binary, %__MODULE__{},
      user_jid: {:string, 1},
      receipt_timestamp: {:int64, 2},
      read_timestamp: {:int64, 3},
      played_timestamp: {:int64, 4}
    )
  end
end

defmodule BaileysEx.Protocol.Proto.WebMessageInfo do
  @moduledoc false

  alias BaileysEx.Protocol.Proto.Message
  alias BaileysEx.Protocol.Proto.MessageKey
  alias BaileysEx.Protocol.Proto.MessageSupport
  alias BaileysEx.Protocol.Proto.WebMessageInfo.UserReceipt

  defstruct key: nil,
            message: nil,
            message_timestamp: nil,
            participant: nil,
            push_name: nil,
            verified_biz_name: nil,
            user_receipt: []

  @type t :: %__MODULE__{
          key: MessageKey.t() | nil,
          message: Message.t() | nil,
          message_timestamp: non_neg_integer() | nil,
          participant: String.t() | nil,
          push_name: String.t() | nil,
          verified_biz_name: String.t() | nil,
          user_receipt: [UserReceipt.t()]
        }

  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = info) do
    MessageSupport.encode_fields(info,
      key: {:message, 1, MessageKey},
      message: {:message, 2, Message},
      message_timestamp: {:int64, 3},
      participant: {:string, 5},
      push_name: {:string, 19},
      verified_biz_name: {:string, 37},
      user_receipt: {:repeated_message, 40, UserReceipt}
    )
  end

  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(binary) do
    MessageSupport.decode_fields(binary, %__MODULE__{},
      key: {:message, 1, MessageKey},
      message: {:message, 2, Message},
      message_timestamp: {:int64, 3},
      participant: {:string, 5},
      push_name: {:string, 19},
      verified_biz_name: {:string, 37},
      user_receipt: {:repeated_message, 40, UserReceipt}
    )
  end
end
