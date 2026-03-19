defmodule BaileysEx.Message.HistorySync do
  @moduledoc """
  History-sync download and payload processing.

  This module mirrors Baileys' history helper boundary: resolve the notification
  payload, inflate it, decode the minimal HistorySync proto surface, and return
  the chats/contacts/messages/mapping data needed by the messaging runtime.
  """

  alias BaileysEx.Protocol.JID, as: JIDUtil
  alias BaileysEx.Protocol.Proto.Conversation
  alias BaileysEx.Protocol.Proto.HistorySync, as: HistorySyncProto
  alias BaileysEx.Protocol.Proto.HistorySyncMsg
  alias BaileysEx.Protocol.Proto.Message
  alias BaileysEx.Protocol.Proto.Pushname

  @type context :: %{
          optional(:history_sync_download_fun) => (map(), map() ->
                                                     {:ok, binary()} | {:error, term()}),
          optional(:inflate_fun) => (binary() -> {:ok, binary()} | {:error, term()}),
          optional(atom()) => term()
        }

  @doc """
  Processes a history sync notification, downloading and inflating the payload if necessary.
  """
  @spec process_notification(map(), map(), context()) :: {:ok, map()} | {:error, term()}
  def process_notification(
        %Message.HistorySyncNotification{} = notification,
        _received_message,
        context
      ) do
    with {:ok, encoded_payload} <- resolve_payload(notification, context),
         {:ok, inflated_payload} <- inflate_payload(encoded_payload, context),
         {:ok, history_sync} <- HistorySyncProto.decode(inflated_payload) do
      {:ok,
       history_sync
       |> process_history_sync()
       |> Map.put(:peer_data_request_session_id, notification.peer_data_request_session_id)}
    end
  end

  defp resolve_payload(%{initial_hist_bootstrap_inline_payload: payload}, _context)
       when is_binary(payload),
       do: {:ok, payload}

  defp resolve_payload(%Message.HistorySyncNotification{} = notification, context) do
    case context[:history_sync_download_fun] do
      fun when is_function(fun, 2) -> fun.(notification, context)
      _ -> {:error, :history_sync_download_fun_not_configured}
    end
  end

  defp inflate_payload(payload, %{inflate_fun: fun}) when is_function(fun, 1), do: fun.(payload)

  defp inflate_payload(payload, _context) when is_binary(payload) do
    {:ok, :zlib.uncompress(payload)}
  rescue
    _error -> {:error, :inflate_failed}
  end

  defp process_history_sync(%HistorySyncProto{sync_type: sync_type} = history_sync)
       when sync_type in [:INITIAL_BOOTSTRAP, :RECENT, :FULL, :ON_DEMAND] do
    {chats, contacts, messages, lid_pn_mappings} =
      Enum.reduce(
        history_sync.conversations,
        {[], [], [], Enum.reverse(explicit_mappings(history_sync))},
        fn conversation, {chats, contacts, messages, mappings} ->
          chat = conversation_to_chat(conversation)
          contact = conversation_to_contact(conversation)
          conversation_messages = conversation_messages(conversation)

          {
            [chat | chats],
            [contact | contacts],
            Enum.reverse(conversation_messages, messages),
            Enum.reverse(conversation_lid_pn_mappings(conversation), mappings)
          }
        end
      )

    %{
      chats: Enum.reverse(chats),
      contacts: Enum.reverse(contacts),
      messages: Enum.reverse(messages),
      lid_pn_mappings: lid_pn_mappings |> Enum.reverse() |> Enum.uniq(),
      sync_type: sync_type,
      progress: history_sync.progress
    }
  end

  defp process_history_sync(%HistorySyncProto{
         sync_type: :PUSH_NAME,
         pushnames: pushnames,
         progress: progress
       }) do
    %{
      chats: [],
      contacts: Enum.map(pushnames, &pushname_to_contact/1),
      messages: [],
      lid_pn_mappings: [],
      sync_type: :PUSH_NAME,
      progress: progress
    }
  end

  defp process_history_sync(%HistorySyncProto{sync_type: sync_type, progress: progress}) do
    %{
      chats: [],
      contacts: [],
      messages: [],
      lid_pn_mappings: [],
      sync_type: sync_type,
      progress: progress
    }
  end

  defp explicit_mappings(%HistorySyncProto{} = history_sync) do
    Enum.flat_map(history_sync.phone_number_to_lid_mappings, fn
      %{lid_jid: lid, pn_jid: pn} when is_binary(lid) and is_binary(pn) -> [%{lid: lid, pn: pn}]
      _other -> []
    end)
  end

  defp conversation_to_chat(%Conversation{} = conversation) do
    %{
      id: conversation.id,
      conversation_timestamp:
        conversation.conversation_timestamp || conversation.last_msg_timestamp,
      unread_count: conversation.unread_count,
      name: conversation.display_name || conversation.name || conversation.username
    }
    |> compact_map()
  end

  defp conversation_to_contact(%Conversation{} = conversation) do
    %{
      id: conversation.id,
      name: conversation.display_name || conversation.name || conversation.username,
      lid: conversation.lid_jid,
      phone_number: conversation.pn_jid
    }
    |> compact_map()
  end

  defp pushname_to_contact(%Pushname{} = pushname) do
    %{id: pushname.id, notify: pushname.pushname} |> compact_map()
  end

  defp conversation_messages(%Conversation{} = conversation) do
    conversation.messages
    |> List.wrap()
    |> Enum.flat_map(fn
      %HistorySyncMsg{message: message} when not is_nil(message) -> [message]
      _other -> []
    end)
  end

  defp conversation_lid_pn_mappings(
         %Conversation{id: chat_id, pn_jid: pn_jid, lid_jid: lid_jid} = conversation
       ) do
    case mapping_from_address_fields(chat_id, pn_jid, lid_jid) do
      nil -> mapping_from_message_fallback(chat_id, conversation.messages)
      mapping -> [mapping]
    end
  end

  defp mapping_from_address_fields(chat_id, pn_jid, lid_jid) do
    cond do
      is_binary(chat_id) and is_binary(pn_jid) and lid_chat_id?(chat_id) ->
        %{lid: chat_id, pn: pn_jid}

      is_binary(chat_id) and is_binary(lid_jid) and pn_chat_id?(chat_id) ->
        %{lid: lid_jid, pn: chat_id}

      true ->
        nil
    end
  end

  defp mapping_from_message_fallback(chat_id, messages) when is_binary(chat_id) do
    case {lid_chat_id?(chat_id), extract_pn_from_messages(messages)} do
      {true, pn} when is_binary(pn) -> [%{lid: chat_id, pn: pn}]
      _ -> []
    end
  end

  defp extract_pn_from_messages(messages) do
    Enum.find_value(messages, fn
      %HistorySyncMsg{
        message: %{key: %{from_me: true}, user_receipt: [%{user_jid: user_jid} | _rest]}
      }
      when is_binary(user_jid) ->
        case pn_chat_id?(user_jid) do
          true -> user_jid
          _ -> nil
        end

      _other ->
        nil
    end)
  end

  defp lid_chat_id?(jid), do: JIDUtil.lid?(jid) or JIDUtil.hosted_lid?(jid)

  defp pn_chat_id?(jid), do: JIDUtil.user?(jid) or JIDUtil.hosted_pn?(jid)

  defp compact_map(map) do
    Enum.reduce(map, %{}, fn
      {_key, nil}, acc -> acc
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end
end
