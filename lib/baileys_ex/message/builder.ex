defmodule BaileysEx.Message.Builder do
  @moduledoc """
  Constructs WAProto message structs from user-facing Elixir maps.
  """

  alias BaileysEx.JID
  alias BaileysEx.Message.Parser
  alias BaileysEx.Protocol.JID, as: JIDUtil
  alias BaileysEx.Protocol.Proto.Message
  alias BaileysEx.Protocol.Proto.MessageContextInfo
  alias BaileysEx.Protocol.Proto.MessageKey

  @url_regex ~r/https?:\/\/\S+/i

  @doc """
  Builds a WAProto `Message` struct given an Elixir content mapping.
  """
  @spec build(map(), keyword()) :: struct()
  def build(content, opts \\ [])

  def build(%{edit: key} = content, opts) do
    inner =
      content
      |> Map.delete(:edit)
      |> build(opts)

    %Message{
      protocol_message: %Message.ProtocolMessage{
        key: build_message_key(key),
        type: :MESSAGE_EDIT,
        edited_message: inner,
        timestamp_ms: map_get_lazy(content, :timestamp_ms, fn -> now_ms(opts) end)
      }
    }
  end

  def build(%{view_once: true} = content, opts) do
    inner =
      content
      |> Map.delete(:view_once)
      |> build(opts)

    %Message{view_once_message: %Message.FutureProofMessage{message: inner}}
  end

  def build(%{text: text} = content, opts) when is_binary(text) do
    preview = link_preview_for(content, opts)

    %Message{
      extended_text_message: %Message.ExtendedTextMessage{
        text: text,
        context_info: build_context_info(content),
        matched_text: preview_value(preview, :matched_text, "matched-text"),
        canonical_url: preview_value(preview, :canonical_url, "canonical-url"),
        title: preview_value(preview, :title),
        description: preview_value(preview, :description),
        background_argb: content[:background_color],
        font: content[:font]
      }
    }
  end

  def build(%{image: _image} = content, _opts) do
    upload = content[:media_upload] || %{}

    %Message{
      image_message: %Message.ImageMessage{
        url: upload[:media_url] || upload[:url],
        mimetype: content[:mimetype],
        caption: content[:caption],
        file_sha256: upload[:file_sha256],
        file_length: upload[:file_length],
        height: upload[:height],
        width: upload[:width],
        media_key: upload[:media_key],
        file_enc_sha256: upload[:file_enc_sha256],
        direct_path: upload[:direct_path],
        media_key_timestamp: upload[:media_key_timestamp],
        jpeg_thumbnail: upload[:jpeg_thumbnail],
        context_info: build_context_info(content)
      }
    }
  end

  def build(%{video: _video} = content, _opts) do
    upload = content[:media_upload] || %{}

    video_message = %Message.VideoMessage{
      url: upload[:media_url] || upload[:url],
      mimetype: content[:mimetype],
      file_sha256: upload[:file_sha256],
      file_length: upload[:file_length],
      seconds: content[:seconds],
      media_key: upload[:media_key],
      caption: content[:caption],
      gif_playback: content[:gif_playback] || false,
      height: upload[:height],
      width: upload[:width],
      file_enc_sha256: upload[:file_enc_sha256],
      direct_path: upload[:direct_path],
      media_key_timestamp: upload[:media_key_timestamp],
      jpeg_thumbnail: upload[:jpeg_thumbnail],
      context_info: build_context_info(content)
    }

    if content[:ptv] do
      %Message{ptv_message: video_message}
    else
      %Message{video_message: video_message}
    end
  end

  def build(%{audio: _audio} = content, _opts) do
    upload = content[:media_upload] || %{}

    %Message{
      audio_message: %Message.AudioMessage{
        url: upload[:media_url] || upload[:url],
        mimetype: content[:mimetype],
        file_sha256: upload[:file_sha256],
        file_length: upload[:file_length],
        ptt: content[:ptt] || false,
        seconds: content[:seconds],
        media_key: upload[:media_key],
        file_enc_sha256: upload[:file_enc_sha256],
        direct_path: upload[:direct_path],
        media_key_timestamp: upload[:media_key_timestamp],
        context_info: build_context_info(content),
        waveform: upload[:waveform]
      }
    }
  end

  def build(%{document: _document} = content, _opts) do
    upload = content[:media_upload] || %{}

    %Message{
      document_message: %Message.DocumentMessage{
        url: upload[:media_url] || upload[:url],
        mimetype: content[:mimetype] || "application/octet-stream",
        title: content[:title],
        file_sha256: upload[:file_sha256],
        file_length: upload[:file_length],
        media_key: upload[:media_key],
        file_name: content[:file_name] || "file",
        file_enc_sha256: upload[:file_enc_sha256],
        direct_path: upload[:direct_path],
        media_key_timestamp: upload[:media_key_timestamp],
        jpeg_thumbnail: upload[:jpeg_thumbnail],
        caption: content[:caption],
        thumbnail_height: upload[:height],
        thumbnail_width: upload[:width],
        context_info: build_context_info(content)
      }
    }
  end

  def build(%{sticker: _sticker} = content, _opts) do
    upload = content[:media_upload] || %{}

    %Message{
      sticker_message: %Message.StickerMessage{
        url: upload[:media_url] || upload[:url],
        file_sha256: upload[:file_sha256],
        file_enc_sha256: upload[:file_enc_sha256],
        media_key: upload[:media_key],
        mimetype: content[:mimetype] || "image/webp",
        height: upload[:height],
        width: upload[:width],
        direct_path: upload[:direct_path],
        file_length: upload[:file_length],
        media_key_timestamp: upload[:media_key_timestamp],
        is_animated: content[:is_animated] || false,
        png_thumbnail: upload[:png_thumbnail],
        context_info: build_context_info(content)
      }
    }
  end

  def build(%{react: %{key: key, text: emoji} = react}, opts) do
    %Message{
      reaction_message: %Message.ReactionMessage{
        key: build_message_key(key),
        text: emoji,
        sender_timestamp_ms: map_get_lazy(react, :sender_timestamp_ms, fn -> now_ms(opts) end)
      }
    }
  end

  def build(%{poll: %{name: name, values: values} = poll}, _opts) do
    poll_message = %Message.PollCreationMessage{
      enc_key: Map.get(poll, :enc_key),
      name: name,
      options: Enum.map(values, &%Message.PollCreationMessage.Option{option_name: &1}),
      selectable_options_count: Map.get(poll, :selectable_count, 0)
    }

    secret =
      %MessageContextInfo{
        message_secret:
          map_get_lazy(poll, :message_secret, fn -> :crypto.strong_rand_bytes(32) end)
      }

    cond do
      poll[:to_announcement_group] ->
        %Message{poll_creation_message_v2: poll_message, message_context_info: secret}

      poll_message.selectable_options_count == 1 ->
        %Message{poll_creation_message_v3: poll_message, message_context_info: secret}

      true ->
        %Message{poll_creation_message: poll_message, message_context_info: secret}
    end
  end

  def build(%{contacts: %{display_name: display_name, contacts: [single]}}, _opts)
      when is_map(single) do
    %Message{
      contact_message: %Message.ContactMessage{
        display_name: single[:display_name] || display_name,
        vcard: Map.fetch!(single, :vcard)
      }
    }
  end

  def build(%{contacts: %{display_name: display_name, contacts: contacts}}, _opts)
      when is_list(contacts) do
    %Message{
      contacts_array_message: %Message.ContactsArrayMessage{
        display_name: display_name,
        contacts:
          Enum.map(contacts, fn contact ->
            %Message.ContactMessage{
              display_name: contact[:display_name],
              vcard: Map.fetch!(contact, :vcard)
            }
          end)
      }
    }
  end

  def build(%{location: location}, _opts) when is_map(location) do
    %Message{
      location_message: %Message.LocationMessage{
        degrees_latitude: location.latitude,
        degrees_longitude: location.longitude,
        name: location[:name],
        address: location[:address],
        url: location[:url],
        accuracy_in_meters: location[:accuracy],
        context_info: build_context_info(location)
      }
    }
  end

  def build(%{live_location: location}, _opts) when is_map(location) do
    %Message{
      live_location_message: %Message.LiveLocationMessage{
        degrees_latitude: location.latitude,
        degrees_longitude: location.longitude,
        accuracy_in_meters: location[:accuracy],
        speed_in_mps: location[:speed],
        degrees_clockwise_from_magnetic_north: location[:heading],
        sequence_number: location[:sequence_number],
        context_info: build_context_info(location)
      }
    }
  end

  def build(%{delete: key}, _opts) do
    %Message{
      protocol_message: %Message.ProtocolMessage{
        key: build_message_key(key),
        type: :REVOKE
      }
    }
  end

  def build(%{forward: original} = content, _opts) do
    force_forward? = Map.get(content, :force, false)
    forward_message(original, force_forward?)
  end

  def build(%{disappearing_messages_in_chat: expiration}, _opts) do
    ephemeral_expiration =
      case expiration do
        true -> 86_400
        false -> 0
        value -> value || 0
      end

    %Message{
      protocol_message: %Message.ProtocolMessage{
        type: :EPHEMERAL_SETTING,
        ephemeral_expiration: ephemeral_expiration
      }
    }
  end

  def build(%{pin: %{key: key, type: type, time: duration} = pin}, opts) do
    %Message{
      pin_in_chat_message: %Message.PinInChatMessage{
        key: build_message_key(key),
        type: if(type == :pin, do: :PIN_FOR_ALL, else: :UNPIN_FOR_ALL),
        sender_timestamp_ms: map_get_lazy(pin, :sender_timestamp_ms, fn -> now_ms(opts) end)
      },
      message_context_info: %MessageContextInfo{
        message_add_on_duration_in_secs: if(type == :pin, do: duration || 86_400, else: 0)
      }
    }
  end

  def build(%{group_invite: %{group_jid: group_jid, invite_code: invite_code} = invite}, _opts) do
    %Message{
      group_invite_message: %Message.GroupInviteMessage{
        group_jid: jid_to_string(group_jid),
        invite_code: invite_code,
        invite_expiration: invite[:invite_expiration],
        group_name: invite[:group_name] || invite[:subject],
        jpeg_thumbnail: invite[:jpeg_thumbnail],
        caption: invite[:caption] || invite[:text]
      }
    }
  end

  def build(%{product: %{title: _title} = product}, _opts) do
    %Message{
      product_message: %Message.ProductMessage{
        product: %Message.ProductMessage.ProductSnapshot{
          product_image: product[:product_image],
          product_id: product[:product_id],
          title: product[:title],
          description: product[:description],
          currency_code: product[:currency_code],
          price_amount_1000: product[:price_amount_1000],
          url: product[:url]
        },
        business_owner_jid: jid_to_string(product[:business_owner_jid]),
        body: product[:body],
        footer: product[:footer]
      }
    }
  end

  def build(%{button_reply: %{display_text: text, id: id, type: :template}}, _opts) do
    %Message{
      template_button_reply_message: %Message.TemplateButtonReplyMessage{
        selected_display_text: text,
        selected_id: id
      }
    }
  end

  def build(%{button_reply: %{display_text: text, id: id}}, _opts) do
    %Message{
      buttons_response_message: %Message.ButtonsResponseMessage{
        selected_display_text: text,
        selected_button_id: id,
        type: :DISPLAY_TEXT
      }
    }
  end

  def build(%{list_reply: %{title: title, row_id: row_id}}, _opts) do
    %Message{
      list_response_message: %Message.ListResponseMessage{
        title: title,
        list_type: :SINGLE_SELECT,
        single_select_reply: %Message.ListResponseMessage.SingleSelectReply{
          selected_row_id: row_id
        }
      }
    }
  end

  def build(%{share_phone_number: true}, _opts) do
    %Message{
      protocol_message: %Message.ProtocolMessage{
        type: :SHARE_PHONE_NUMBER
      }
    }
  end

  def build(%{request_phone_number: true}, _opts) do
    %Message{
      request_phone_number_message: %Message.RequestPhoneNumberMessage{}
    }
  end

  def build(%{limit_sharing: sharing_limited} = _content, opts)
      when is_boolean(sharing_limited) do
    %Message{
      protocol_message: %Message.ProtocolMessage{
        type: :LIMIT_SHARING,
        limit_sharing: %Message.LimitSharing{
          sharing_limited: sharing_limited,
          trigger: :CHAT_SETTING,
          limit_sharing_setting_timestamp: now_ms(opts),
          initiated_by_me: true
        }
      }
    }
  end

  def build(%{event: %{name: name} = event}, _opts) do
    %Message{
      event_message: %Message.EventMessage{
        name: name,
        description: event[:description],
        start_time: to_unix(event[:start_time]),
        is_canceled: event[:is_cancelled] || false,
        extra_guests_allowed: event[:extra_guests_allowed] || false,
        location:
          event[:location] &&
            build(%{location: event[:location]}).location_message
      },
      message_context_info: %MessageContextInfo{
        message_secret:
          map_get_lazy(event, :message_secret, fn -> :crypto.strong_rand_bytes(32) end)
      }
    }
  end

  defp forward_message(%{message: %Message{} = message} = original, force_forward?) do
    message
    |> clone_message()
    |> Parser.normalize_content()
    |> ensure_forwardable_message()
    |> increment_forwarding_score(Map.get(original, :key, %{}), force_forward?)
  end

  defp clone_message(%Message{} = message) do
    message
    |> :erlang.term_to_binary()
    |> :erlang.binary_to_term()
  end

  defp ensure_forwardable_message(%Message{conversation: text} = message) when is_binary(text) do
    %Message{
      message
      | conversation: nil,
        extended_text_message: %Message.ExtendedTextMessage{text: text}
    }
  end

  defp ensure_forwardable_message(%Message{} = message), do: message

  defp increment_forwarding_score(%Message{} = message, key, force_forward?) do
    content_type = Parser.get_content_type(message)
    content = Map.fetch!(message, content_type)

    context_info =
      case Map.get(content, :context_info) do
        %Message.ContextInfo{} = existing -> existing
        _ -> %Message.ContextInfo{}
      end

    current_score = context_info.forwarding_score || 0
    from_me = Map.get(key, :from_me, Map.get(key, "from_me", false))
    increment = if(from_me && !force_forward?, do: 0, else: 1)

    updated_context = %Message.ContextInfo{
      context_info
      | forwarding_score: current_score + increment,
        is_forwarded: current_score + increment > 0
    }

    put_in(message, [Access.key(content_type), Access.key(:context_info)], updated_context)
  end

  defp link_preview_for(content, opts) do
    content[:link_preview] || maybe_generate_link_preview(content[:text], opts[:get_url_info])
  end

  defp maybe_generate_link_preview(text, get_url_info)
       when is_binary(text) and is_function(get_url_info, 1) do
    case Regex.run(@url_regex, text) do
      [url | _] -> get_url_info.(url)
      _ -> nil
    end
  rescue
    _error -> nil
  end

  defp maybe_generate_link_preview(_text, _get_url_info), do: nil

  defp preview_value(preview, atom_key, string_key \\ nil)

  defp preview_value(nil, _atom_key, _string_key), do: nil

  defp preview_value(preview, atom_key, string_key) when is_map(preview) do
    Map.get(preview, atom_key) || (string_key && Map.get(preview, string_key))
  end

  defp build_context_info(content) do
    base =
      %Message.ContextInfo{
        stanza_id: get_in(content, [:quoted, :key, :id]),
        participant:
          jid_to_string(
            get_in(content, [:quoted, :key, :participant]) ||
              get_in(content, [:quoted, :key, :remote_jid])
          ),
        quoted_message: get_in(content, [:quoted, :message]),
        remote_jid: jid_to_string(get_in(content, [:quoted, :key, :remote_jid])),
        mentioned_jid: Enum.map(content[:mentions] || [], &jid_to_string/1),
        expiration: content[:ephemeral_expiration],
        is_forwarded: content[:is_forwarded] || false,
        forwarding_score: content[:forwarding_score]
      }

    case content[:context_info] do
      %Message.ContextInfo{} = extra -> Map.merge(base, extra)
      extra when is_map(extra) -> struct(base, Map.new(extra))
      _ -> base
    end
  end

  defp build_message_key(%MessageKey{} = key), do: key

  defp build_message_key(%{} = key) do
    %MessageKey{
      id: key[:id] || key["id"],
      remote_jid: jid_to_string(key[:remote_jid] || key["remote_jid"]),
      from_me: key[:from_me] || key["from_me"] || false,
      participant: jid_to_string(key[:participant] || key["participant"])
    }
  end

  defp jid_to_string(nil), do: nil
  defp jid_to_string(%JID{} = jid), do: JIDUtil.to_string(jid)
  defp jid_to_string(jid) when is_binary(jid), do: jid

  defp now_ms(opts) do
    case opts[:now_ms] do
      fun when is_function(fun, 0) -> fun.()
      value when is_integer(value) -> value
      _ -> System.os_time(:millisecond)
    end
  end

  defp map_get_lazy(map, key, fun) when is_map(map) and is_function(fun, 0) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> fun.()
    end
  end

  defp to_unix(%DateTime{} = datetime), do: DateTime.to_unix(datetime)
  defp to_unix(value) when is_integer(value), do: value
  defp to_unix(_value), do: nil
end
