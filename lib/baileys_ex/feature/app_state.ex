defmodule BaileysEx.Feature.AppState do
  @moduledoc """
  App-state patch construction helpers.

  Phase 10 starts by exposing the Baileys-aligned patch surface that chat, label,
  contact, and quick-reply operations depend on. Full Syncd encoding, encryption,
  and server roundtrips land later in the phase without changing this API.
  """

  @type operation :: :set | :remove
  @type patch_type ::
          :critical_block | :critical_unblock_low | :regular_high | :regular_low | :regular

  @type patch :: %{
          required(:sync_action) => map(),
          required(:index) => [String.t()],
          required(:type) => patch_type(),
          required(:api_version) => pos_integer(),
          required(:operation) => operation()
        }

  alias BaileysEx.Protocol.JID

  @doc """
  Build a Baileys-style app-state patch for the given action and pass it to the
  provided transport callback when one is supplied.
  """
  @spec push_patch(term(), atom(), String.t(), term(), keyword()) ::
          {:ok, patch()} | {:error, term()}
  def push_patch(conn, action, jid, value, opts \\ []) when is_atom(action) and is_binary(jid) do
    patch = build_patch(action, jid, value, opts)

    case conn do
      fun when is_function(fun, 1) ->
        case fun.(patch) do
          {:ok, _result} -> {:ok, patch}
          :ok -> {:ok, patch}
          {:error, _reason} = error -> error
          _other -> {:ok, patch}
        end

      _ ->
        {:ok, patch}
    end
  end

  @doc """
  Construct the app-state patch structure without sending it.
  """
  @spec build_patch(atom(), String.t(), term(), keyword()) :: patch()
  def build_patch(action, jid, value, opts \\ []) when is_atom(action) and is_binary(jid) do
    timestamp = Keyword.get_lazy(opts, :timestamp, fn -> System.os_time(:millisecond) end)

    action
    |> patch_for(jid, value)
    |> put_in([:sync_action, :timestamp], timestamp)
  end

  defp patch_for(:mute, jid, duration) do
    %{
      sync_action: %{
        mute_action: %{
          muted: is_integer(duration) and duration > 0,
          mute_end_timestamp: if(is_integer(duration) and duration > 0, do: duration)
        }
      },
      index: ["mute", jid],
      type: :regular_high,
      api_version: 2,
      operation: :set
    }
  end

  defp patch_for(:archive, jid, %{archive: archive?, last_messages: last_messages}) do
    %{
      sync_action: %{
        archive_chat_action: %{
          archived: !!archive?,
          message_range: message_range(last_messages)
        }
      },
      index: ["archive", jid],
      type: :regular_low,
      api_version: 3,
      operation: :set
    }
  end

  defp patch_for(:mark_read, jid, %{read: read?, last_messages: last_messages}) do
    %{
      sync_action: %{
        mark_chat_as_read_action: %{
          read: !!read?,
          message_range: message_range(last_messages)
        }
      },
      index: ["markChatAsRead", jid],
      type: :regular_low,
      api_version: 3,
      operation: :set
    }
  end

  defp patch_for(:delete_for_me, jid, %{
         key: key,
         timestamp: timestamp,
         delete_media: delete_media
       }) do
    %{
      sync_action: %{
        delete_message_for_me_action: %{
          delete_media: !!delete_media,
          message_timestamp: timestamp
        }
      },
      index: ["deleteMessageForMe", jid, key[:id] || key["id"], from_me_index(key), "0"],
      type: :regular_high,
      api_version: 3,
      operation: :set
    }
  end

  defp patch_for(:clear, jid, %{last_messages: last_messages}) do
    %{
      sync_action: %{
        clear_chat_action: %{
          message_range: message_range(last_messages)
        }
      },
      index: ["clearChat", jid, "1", "0"],
      type: :regular_high,
      api_version: 6,
      operation: :set
    }
  end

  defp patch_for(:pin, jid, pin?) do
    %{
      sync_action: %{
        pin_action: %{
          pinned: !!pin?
        }
      },
      index: ["pin_v1", jid],
      type: :regular_low,
      api_version: 5,
      operation: :set
    }
  end

  defp patch_for(:disable_link_previews, _jid, disabled?) do
    %{
      sync_action: %{
        privacy_setting_disable_link_previews_action: %{
          is_previews_disabled: !!disabled?
        }
      },
      index: ["setting_disableLinkPreviews"],
      type: :regular,
      api_version: 8,
      operation: :set
    }
  end

  defp patch_for(:star, jid, %{messages: [first | _rest], star: star?}) do
    %{
      sync_action: %{
        star_action: %{
          starred: !!star?
        }
      },
      index: ["star", jid, first[:id] || first["id"], from_me_index(first), "0"],
      type: :regular_low,
      api_version: 2,
      operation: :set
    }
  end

  defp patch_for(:delete, jid, %{last_messages: last_messages}) do
    %{
      sync_action: %{
        delete_chat_action: %{
          message_range: message_range(last_messages)
        }
      },
      index: ["deleteChat", jid, "1"],
      type: :regular_high,
      api_version: 6,
      operation: :set
    }
  end

  defp patch_for(action, _jid, _value) do
    raise ArgumentError, "unsupported app-state patch action: #{inspect(action)}"
  end

  defp message_range(last_messages) when is_list(last_messages) do
    last_message = List.last(last_messages)
    normalized_messages = Enum.map(last_messages, &normalize_last_message/1)

    %{
      last_message_timestamp: last_message && Map.get(last_message, :message_timestamp),
      messages: normalized_messages
    }
  end

  defp message_range(%{} = range), do: range

  defp normalize_last_message(%{} = message) do
    key = message_key!(message)
    id = required_key!(key, :id)
    remote_jid = required_key!(key, :remote_jid)
    from_me = Map.get(key, :from_me, Map.get(key, "from_me", false))
    participant = validate_participant(key, remote_jid, from_me)
    timestamp = message_timestamp!(message)

    normalized_key =
      normalized_key(key, id, remote_jid, from_me, participant)

    message
    |> put_message_key(normalized_key)
    |> put_message_timestamp(timestamp)
  end

  defp from_me_index(%{} = key) do
    if Map.get(key, :from_me, Map.get(key, "from_me", false)), do: "1", else: "0"
  end

  defp maybe_put_key(%{} = key, _field, nil), do: key

  defp maybe_put_key(%{} = key, field, value) do
    key
    |> Map.put(field, value)
    |> Map.put(Atom.to_string(field), value)
  end

  defp put_required_key(%{} = key, field, value) do
    key
    |> Map.put(field, value)
    |> Map.put(Atom.to_string(field), value)
  end

  defp message_key!(%{} = message) do
    Map.get(message, :key) || Map.get(message, "key") || raise ArgumentError, "missing key"
  end

  defp required_key!(%{} = key, field) do
    Map.get(key, field) || Map.get(key, Atom.to_string(field)) ||
      raise ArgumentError, "incomplete key: missing #{field}"
  end

  defp validate_participant(%{} = key, remote_jid, from_me) do
    participant = Map.get(key, :participant) || Map.get(key, "participant")

    if String.ends_with?(remote_jid, "@g.us") and not from_me and is_nil(participant) do
      raise ArgumentError, "expected participant on non-from-me group message"
    end

    case participant do
      value when is_binary(value) -> JID.normalized_user(value)
      _ -> nil
    end
  end

  defp message_timestamp!(%{} = message) do
    case Map.get(message, :message_timestamp) || Map.get(message, "message_timestamp") do
      timestamp when is_integer(timestamp) -> timestamp
      _ -> raise ArgumentError, "missing timestamp in last message list"
    end
  end

  defp normalized_key(key, id, remote_jid, from_me, participant) do
    key
    |> put_required_key(:id, id)
    |> put_required_key(:remote_jid, remote_jid)
    |> put_required_key(:from_me, from_me)
    |> maybe_put_key(:participant, participant)
  end

  defp put_message_key(%{} = message, normalized_key) do
    message
    |> Map.put(:key, normalized_key)
    |> Map.put("key", normalized_key)
  end

  defp put_message_timestamp(%{} = message, timestamp) do
    message
    |> Map.put(:message_timestamp, timestamp)
    |> Map.put("message_timestamp", timestamp)
  end
end
