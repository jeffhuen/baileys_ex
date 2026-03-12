defmodule BaileysEx.Message.Reporting do
  @moduledoc false

  alias BaileysEx.BinaryNode
  alias BaileysEx.Crypto
  alias BaileysEx.Protocol.Proto.Message
  alias BaileysEx.Protocol.Proto.MessageContextInfo
  alias BaileysEx.Protocol.Proto.Wire

  @enc_secret_report_token "Report Token"

  @reporting_fields [
    %{f: 1},
    %{
      f: 3,
      s: [%{f: 2}, %{f: 3}, %{f: 8}, %{f: 11}, %{f: 17, s: [%{f: 21}, %{f: 22}]}, %{f: 25}]
    },
    %{f: 4, s: [%{f: 1}, %{f: 16}, %{f: 17, s: [%{f: 21}, %{f: 22}]}]},
    %{f: 5, s: [%{f: 3}, %{f: 4}, %{f: 5}, %{f: 16}, %{f: 17, s: [%{f: 21}, %{f: 22}]}]},
    %{f: 6, s: [%{f: 1}, %{f: 17, s: [%{f: 21}, %{f: 22}]}, %{f: 30}]},
    %{f: 7, s: [%{f: 2}, %{f: 7}, %{f: 10}, %{f: 17, s: [%{f: 21}, %{f: 22}]}, %{f: 20}]},
    %{f: 8, s: [%{f: 2}, %{f: 7}, %{f: 9}, %{f: 17, s: [%{f: 21}, %{f: 22}]}, %{f: 21}]},
    %{
      f: 9,
      s: [%{f: 2}, %{f: 6}, %{f: 7}, %{f: 13}, %{f: 17, s: [%{f: 21}, %{f: 22}]}, %{f: 20}]
    },
    %{f: 12, s: [%{f: 1}, %{f: 2}, %{f: 14, m: true}, %{f: 15}]},
    %{f: 18, s: [%{f: 6}, %{f: 16}, %{f: 17, s: [%{f: 21}, %{f: 22}]}]},
    %{f: 26, s: [%{f: 4}, %{f: 5}, %{f: 8}, %{f: 13}, %{f: 17, s: [%{f: 21}, %{f: 22}]}]},
    %{f: 28, s: [%{f: 1}, %{f: 2}, %{f: 4}, %{f: 5}, %{f: 6}, %{f: 7, s: [%{f: 21}, %{f: 22}]}]},
    %{f: 37, s: [%{f: 1, m: true}]},
    %{
      f: 49,
      s: [
        %{f: 2},
        %{f: 3, s: [%{f: 1}, %{f: 2}]},
        %{f: 5, s: [%{f: 21}, %{f: 22}]},
        %{f: 8, s: [%{f: 1}, %{f: 2}]}
      ]
    },
    %{f: 53, s: [%{f: 1, m: true}]},
    %{f: 55, s: [%{f: 1, m: true}]},
    %{f: 58, s: [%{f: 1, m: true}]},
    %{f: 59, s: [%{f: 1, m: true}]},
    %{
      f: 60,
      s: [
        %{f: 2},
        %{f: 3, s: [%{f: 1}, %{f: 2}]},
        %{f: 5, s: [%{f: 21}, %{f: 22}]},
        %{f: 8, s: [%{f: 1}, %{f: 2}]}
      ]
    },
    %{
      f: 64,
      s: [
        %{f: 2},
        %{f: 3, s: [%{f: 1}, %{f: 2}]},
        %{f: 5, s: [%{f: 21}, %{f: 22}]},
        %{f: 8, s: [%{f: 1}, %{f: 2}]}
      ]
    },
    %{
      f: 66,
      s: [%{f: 2}, %{f: 6}, %{f: 7}, %{f: 13}, %{f: 17, s: [%{f: 21}, %{f: 22}]}, %{f: 20}]
    },
    %{f: 74, s: [%{f: 1, m: true}]},
    %{f: 87, s: [%{f: 1, m: true}]},
    %{f: 88, s: [%{f: 1}, %{f: 2, s: [%{f: 1}]}, %{f: 3, s: [%{f: 21}, %{f: 22}]}]},
    %{f: 92, s: [%{f: 1, m: true}]},
    %{f: 93, s: [%{f: 1, m: true}]},
    %{f: 94, s: [%{f: 1, m: true}]}
  ]

  @spec should_include_reporting_token?(Message.t()) :: boolean()
  def should_include_reporting_token?(%Message{} = message) do
    is_nil(message.reaction_message) and
      is_nil(message.enc_reaction_message) and
      is_nil(message.enc_event_response_message) and
      is_nil(message.poll_update_message)
  end

  @spec reporting_node(Message.t(), map()) :: BinaryNode.t() | nil
  def reporting_node(%Message{} = message, key) when is_map(key) do
    with true <- should_include_reporting_token?(message),
         %MessageContextInfo{message_secret: secret} when is_binary(secret) <-
           message.message_context_info,
         id when is_binary(id) <- key[:id] || key["id"],
         content when is_binary(content) and content != "" <-
           extract_reporting_token_content(Message.encode(message), compiled_reporting_fields()) do
      from =
        if(key_author_from_me?(key),
          do: key_remote_jid(key),
          else: key_participant_or_remote(key)
        )

      to =
        if(key_author_from_me?(key),
          do: key_participant_or_remote(key),
          else: key_remote_jid(key)
        )

      reporting_secret = reporting_secret(id, from, to, secret)
      token = Crypto.hmac_sha256(reporting_secret, content) |> binary_part(0, 16)

      %BinaryNode{
        tag: "reporting",
        attrs: %{},
        content: [
          %BinaryNode{
            tag: "reporting_token",
            attrs: %{"v" => "2"},
            content: {:binary, token}
          }
        ]
      }
    else
      _ -> nil
    end
  end

  def reporting_node(_message, _key), do: nil

  defp key_author_from_me?(key), do: key[:from_me] || key["from_me"] || false
  defp key_remote_jid(key), do: key[:remote_jid] || key["remote_jid"]

  defp key_participant_or_remote(key) do
    key[:participant] || key["participant"] || key[:remote_jid] || key["remote_jid"]
  end

  defp reporting_secret(id, from, to, secret) do
    use_case_secret = IO.iodata_to_binary([id, from, to, @enc_secret_report_token])
    with_zero_key = Crypto.hmac_sha256(<<0::256>>, secret)
    Crypto.hmac_sha256(with_zero_key, use_case_secret)
  end

  defp compiled_reporting_fields do
    compile_reporting_fields(@reporting_fields)
  end

  defp compile_reporting_fields(fields) do
    Enum.reduce(fields, %{}, fn field, acc ->
      Map.put(acc, field.f, %{
        m: Map.get(field, :m, false),
        children:
          case Map.get(field, :s) do
            children when is_list(children) -> compile_reporting_fields(children)
            _ -> %{}
          end
      })
    end)
  end

  defp extract_reporting_token_content(data, cfg) when is_binary(data) do
    do_extract_reporting_token_content(data, cfg, [])
  end

  defp do_extract_reporting_token_content(<<>>, _cfg, acc) do
    acc
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
    |> IO.iodata_to_binary()
  end

  defp do_extract_reporting_token_content(binary, cfg, acc) do
    with {:ok, field_num, wire_type, rest} <- Wire.decode_key(binary),
         field_cfg <- Map.get(cfg, field_num),
         {:ok, encoded_field, tail} <-
           consume_field(binary, field_num, wire_type, rest, field_cfg) do
      next_acc = if encoded_field == nil, do: acc, else: [{field_num, encoded_field} | acc]
      do_extract_reporting_token_content(tail, cfg, next_acc)
    else
      _ -> <<>>
    end
  end

  defp consume_field(_original, _field_num, 0, rest, nil) do
    with {:ok, _value, tail} <- Wire.decode_varint(rest) do
      {:ok, nil, tail}
    end
  end

  defp consume_field(_original, _field_num, 1, <<_value::binary-size(8), tail::binary>>, nil),
    do: {:ok, nil, tail}

  defp consume_field(_original, _field_num, 5, <<_value::binary-size(4), tail::binary>>, nil),
    do: {:ok, nil, tail}

  defp consume_field(_original, _field_num, 2, rest, nil) do
    with {:ok, _value, tail} <- Wire.decode_bytes(rest) do
      {:ok, nil, tail}
    end
  end

  defp consume_field(original, _field_num, 0, rest, _field_cfg) do
    with {:ok, _value, tail} <- Wire.decode_varint(rest) do
      {:ok, slice(original, tail), tail}
    end
  end

  defp consume_field(
         original,
         _field_num,
         1,
         <<_value::binary-size(8), tail::binary>>,
         _field_cfg
       ),
       do: {:ok, slice(original, tail), tail}

  defp consume_field(
         original,
         _field_num,
         5,
         <<_value::binary-size(4), tail::binary>>,
         _field_cfg
       ),
       do: {:ok, slice(original, tail), tail}

  defp consume_field(original, field_num, 2, rest, %{m: preserve?, children: children}) do
    with {:ok, value, tail} <- Wire.decode_bytes(rest) do
      if preserve? or map_size(children) > 0 do
        encode_nested_field(field_num, value, children, tail)
      else
        {:ok, slice(original, tail), tail}
      end
    end
  end

  defp consume_field(_original, _field_num, _wire_type, _rest, _field_cfg),
    do: {:error, :unsupported_wire}

  defp encode_nested_field(field_num, value, children, tail) do
    nested = extract_reporting_token_content(value, children)

    if nested == <<>> do
      {:ok, nil, tail}
    else
      encoded = Wire.encode_key(field_num, 2) <> Wire.encode_varint(byte_size(nested)) <> nested
      {:ok, encoded, tail}
    end
  end

  defp slice(original, tail) do
    size = byte_size(original) - byte_size(tail)
    binary_part(original, 0, size)
  end
end
