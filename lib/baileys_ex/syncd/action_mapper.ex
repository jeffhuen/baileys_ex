defmodule BaileysEx.Syncd.ActionMapper do
  @moduledoc """
  Maps decoded Syncd mutations to application events.

  Examines the `SyncActionValue` in each decoded mutation and emits the
  corresponding event (chats update, messages delete, contacts upsert, etc.).

  Ports `processSyncAction` from `chat-utils.ts:758-974` and
  `processContactAction`/`emitSyncActionResults` from `sync-action-utils.ts`.
  """

  alias BaileysEx.Protocol.JID

  @type sync_action_result ::
          {:contacts_upsert, [map()]}
          | {:lid_mapping_update, map()}

  @type event ::
          {:chats_update, [map()]}
          | {:chats_delete, [String.t()]}
          | {:chats_lock, map()}
          | {:messages_delete, map()}
          | {:messages_update, [map()]}
          | {:contacts_upsert, [map()]}
          | {:creds_update, map()}
          | {:labels_edit, map()}
          | {:labels_association, map()}
          | {:settings_update, map()}
          | {:lid_mapping_update, map()}

  @doc """
  Process a single decoded sync action mutation and return events to emit.

  Returns a list of events (may be empty for unrecognized actions).

  Ports `processSyncAction` from `chat-utils.ts:758-974`.

  ## Parameters

    * `mutation` — decoded mutation with `:sync_action` (SyncActionData) and `:index` (parsed JSON array)
    * `me` — current user's contact info `%{name: ..., id: ...}`
    * `opts` — optional:
      - `:initial_sync` — boolean, whether this is initial app state sync
      - `:account_settings` — `%{unarchive_chats: boolean()}` for initial sync logic
  """
  @spec process_sync_action(map(), map(), keyword()) :: [event()]
  def process_sync_action(mutation, me, opts \\ []) do
    dispatch_sync_action(
      mutation.sync_action.value,
      mutation.index,
      me,
      %{
        initial_sync: Keyword.get(opts, :initial_sync, false),
        account_settings: Keyword.get(opts, :account_settings)
      }
    )
  end

  @doc """
  Process a contact action and return events to emit.

  Always emits `contacts_upsert`. Optionally emits `lid_mapping_update`
  if both LID and PN are available.

  Ports `processContactAction` from `sync-action-utils.ts:22-64`.
  """
  @spec process_contact_action(map(), String.t() | nil) :: [sync_action_result()]
  def process_contact_action(_action, nil), do: []

  def process_contact_action(action, id) do
    # PN user = @s.whatsapp.net, LID user = @lid
    id_is_pn = JID.user?(id)
    phone_number = if id_is_pn, do: id, else: action.pn_jid

    contact = %{
      id: id,
      name: action.full_name || action.first_name || action.username,
      lid: action.lid_jid,
      phone_number: phone_number
    }

    results = [{:contacts_upsert, [contact]}]

    if action.lid_jid && JID.lid?(action.lid_jid) && id_is_pn do
      results ++ [{:lid_mapping_update, %{lid: action.lid_jid, pn: id}}]
    else
      results
    end
  end

  @doc """
  Dispatch sync action results to an event emitter callback.

  Ports `emitSyncActionResults` from `sync-action-utils.ts:66-74`.
  """
  @spec emit_sync_action_results((event() -> any()), [sync_action_result()]) :: :ok
  def emit_sync_action_results(emit_fn, results) do
    Enum.each(results, fn result -> emit_fn.(result) end)
  end

  # ============================================================================
  # Private action processors
  # ============================================================================

  defp process_mute(mute_action, id, is_initial_sync) do
    mute_end_time =
      if mute_action.muted do
        mute_action.mute_end_timestamp
      else
        nil
      end

    [
      {:chats_update,
       [
         %{
           id: id,
           mute_end_time: mute_end_time,
           conditional: build_conditional(is_initial_sync, id, nil)
         }
       ]}
    ]
  end

  defp process_archive(archive_action, type, id, is_initial_sync, account_settings) do
    is_archived =
      if archive_action do
        archive_action.archived
      else
        type == "archive"
      end

    msg_range =
      if account_settings && !account_settings[:unarchive_chats] do
        nil
      else
        archive_action && archive_action.message_range
      end

    [
      {:chats_update,
       [
         %{
           id: id,
           archived: is_archived,
           conditional: build_conditional(is_initial_sync, id, msg_range)
         }
       ]}
    ]
  end

  defp process_mark_read(mark_read_action, id, is_initial_sync) do
    is_null_update = is_initial_sync and mark_read_action.read

    unread_count =
      cond do
        is_null_update -> nil
        mark_read_action.read -> 0
        true -> -1
      end

    [
      {:chats_update,
       [
         %{
           id: id,
           unread_count: unread_count,
           conditional: build_conditional(is_initial_sync, id, mark_read_action.message_range)
         }
       ]}
    ]
  end

  defp process_delete_for_me(id, msg_id, from_me) do
    [{:messages_delete, %{keys: [%{remote_jid: id, id: msg_id, from_me: from_me == "1"}]}}]
  end

  defp process_push_name(push_name_setting, me) do
    name = push_name_setting.name

    if name && me[:name] != name do
      [{:creds_update, %{me: Map.merge(me, %{name: name})}}]
    else
      []
    end
  end

  defp process_pin(pin_action, timestamp, id, is_initial_sync) do
    pinned = if(pin_action.pinned, do: timestamp || 0, else: nil)

    [
      {:chats_update,
       [
         %{
           id: id,
           pinned: pinned,
           conditional: build_conditional(is_initial_sync, id, nil)
         }
       ]}
    ]
  end

  defp process_unarchive_setting(setting) do
    [{:creds_update, %{account_settings: %{unarchive_chats: !!setting.unarchive_chats}}}]
  end

  defp process_star(star_action, index, id, msg_id, from_me) do
    starred =
      case star_action do
        %{starred: s} when is_boolean(s) -> s
        _ -> List.last(index) == "1"
      end

    [
      {:messages_update,
       [
         %{
           key: %{remote_jid: id, id: msg_id, from_me: from_me == "1"},
           update: %{starred: starred}
         }
       ]}
    ]
  end

  defp process_delete_chat(id, is_initial_sync) do
    if is_initial_sync do
      []
    else
      [{:chats_delete, [id]}]
    end
  end

  defp process_label_edit(label_edit, id) do
    [
      {:labels_edit,
       %{
         id: id,
         name: label_edit.name,
         color: label_edit.color,
         deleted: label_edit.deleted,
         predefined_id: if(label_edit.predefined_id, do: to_string(label_edit.predefined_id))
       }}
    ]
  end

  defp process_label_association(label_assoc, type, index) do
    assoc_type = if label_assoc.labeled, do: :add, else: :remove

    association =
      if type == "label_jid" do
        %{type: :chat, chat_id: Enum.at(index, 2), label_id: Enum.at(index, 1)}
      else
        %{
          type: :message,
          chat_id: Enum.at(index, 2),
          message_id: Enum.at(index, 3),
          label_id: Enum.at(index, 1)
        }
      end

    [{:labels_association, %{type: assoc_type, association: association}}]
  end

  defp process_lid_contact(lid_contact, id) do
    [
      {:contacts_upsert,
       [
         %{
           id: id,
           name: lid_contact.full_name || lid_contact.first_name || lid_contact.username,
           lid: id,
           phone_number: nil
         }
       ]}
    ]
  end

  defp build_conditional(false, _id, _msg_range), do: nil

  defp build_conditional(true, id, msg_range) do
    fn data -> evaluate_conditional(lookup_chat(data, id), msg_range) end
  end

  defp lookup_chat(data, id) when is_map(data) and is_binary(id) do
    get_in(data, [:historySets, :chats, id]) ||
      get_in(data, [:history_sets, :chats, id]) ||
      get_in(data, [:chatUpserts, id]) ||
      get_in(data, [:chat_upserts, id])
  end

  defp lookup_chat(_data, _id), do: nil

  defp valid_patch_based_on_message_range?(chat, msg_range) when is_map(chat) do
    message_range_timestamp(msg_range) >= chat_last_message_timestamp(chat)
  end

  defp dispatch_sync_action(%{mute_action: mute_action}, [_type, id | _rest], _me, context)
       when not is_nil(mute_action) do
    process_mute(mute_action, id, context.initial_sync)
  end

  defp dispatch_sync_action(
         %{archive_chat_action: archive_action},
         [type, id | _rest],
         _me,
         context
       )
       when not is_nil(archive_action) do
    process_archive(
      archive_action,
      type,
      id,
      context.initial_sync,
      context.account_settings
    )
  end

  defp dispatch_sync_action(_action, [type, id | _rest], _me, context)
       when type in ["archive", "unarchive"] do
    process_archive(nil, type, id, context.initial_sync, context.account_settings)
  end

  defp dispatch_sync_action(
         %{mark_chat_as_read_action: mark_read_action},
         [_type, id | _rest],
         _me,
         context
       )
       when not is_nil(mark_read_action) do
    process_mark_read(mark_read_action, id, context.initial_sync)
  end

  defp dispatch_sync_action(
         %{delete_message_for_me_action: delete_action},
         [_type, id, msg_id, from_me | _rest],
         _me,
         _context
       )
       when not is_nil(delete_action) do
    process_delete_for_me(id, msg_id, from_me)
  end

  defp dispatch_sync_action(
         _action,
         ["deleteMessageForMe", id, msg_id, from_me | _rest],
         _me,
         _context
       ),
       do: process_delete_for_me(id, msg_id, from_me)

  defp dispatch_sync_action(%{contact_action: contact_action}, [_type, id | _rest], _me, _context)
       when not is_nil(contact_action) do
    process_contact_action(contact_action, id)
  end

  defp dispatch_sync_action(
         %{push_name_setting: push_name_setting},
         _index,
         me,
         _context
       )
       when not is_nil(push_name_setting) do
    process_push_name(push_name_setting, me)
  end

  defp dispatch_sync_action(
         %{pin_action: pin_action, timestamp: timestamp},
         [_type, id | _rest],
         _me,
         context
       )
       when not is_nil(pin_action) do
    process_pin(pin_action, timestamp, id, context.initial_sync)
  end

  defp dispatch_sync_action(
         %{unarchive_chats_setting: setting},
         _index,
         _me,
         _context
       )
       when not is_nil(setting) do
    process_unarchive_setting(setting)
  end

  defp dispatch_sync_action(
         %{star_action: star_action},
         [_type, id, msg_id, from_me | _rest] = index,
         _me,
         _context
       )
       when not is_nil(star_action) do
    process_star(star_action, index, id, msg_id, from_me)
  end

  defp dispatch_sync_action(
         _action,
         ["star", id, msg_id, from_me | _rest] = index,
         _me,
         _context
       ),
       do: process_star(nil, index, id, msg_id, from_me)

  defp dispatch_sync_action(
         %{delete_chat_action: delete_chat_action},
         [_type, id | _rest],
         _me,
         context
       )
       when not is_nil(delete_chat_action) do
    process_delete_chat(id, context.initial_sync)
  end

  defp dispatch_sync_action(_action, ["deleteChat", id | _rest], _me, context),
    do: process_delete_chat(id, context.initial_sync)

  defp dispatch_sync_action(
         %{label_edit_action: label_edit_action},
         [_type, id | _rest],
         _me,
         _context
       )
       when not is_nil(label_edit_action) do
    process_label_edit(label_edit_action, id)
  end

  defp dispatch_sync_action(
         %{label_association_action: label_association_action},
         [type | _rest] = index,
         _me,
         _context
       )
       when not is_nil(label_association_action) do
    process_label_association(label_association_action, type, index)
  end

  defp dispatch_sync_action(
         %{locale_setting: %{locale: locale}},
         _index,
         _me,
         _context
       )
       when is_binary(locale) do
    [{:settings_update, %{setting: :locale, value: locale}}]
  end

  defp dispatch_sync_action(
         %{time_format_action: time_format_action},
         _index,
         _me,
         _context
       )
       when not is_nil(time_format_action) do
    [{:settings_update, %{setting: :time_format, value: time_format_action}}]
  end

  defp dispatch_sync_action(
         %{pn_for_lid_chat_action: %{pn_jid: pn_jid}},
         [_type, id | _rest],
         _me,
         _context
       )
       when is_binary(pn_jid) do
    [{:lid_mapping_update, %{lid: id, pn: pn_jid}}]
  end

  defp dispatch_sync_action(
         %{privacy_setting_relay_all_calls: relay_all_calls},
         _index,
         _me,
         _context
       )
       when not is_nil(relay_all_calls) do
    [{:settings_update, %{setting: :privacy_setting_relay_all_calls, value: relay_all_calls}}]
  end

  defp dispatch_sync_action(
         %{status_privacy: status_privacy},
         _index,
         _me,
         _context
       )
       when not is_nil(status_privacy) do
    [{:settings_update, %{setting: :status_privacy, value: status_privacy}}]
  end

  defp dispatch_sync_action(
         %{lock_chat_action: %{locked: locked}},
         [_type, id | _rest],
         _me,
         _context
       ) do
    [{:chats_lock, %{id: id, locked: !!locked}}]
  end

  defp dispatch_sync_action(
         %{privacy_setting_disable_link_previews_action: disable_link_previews},
         _index,
         _me,
         _context
       )
       when not is_nil(disable_link_previews) do
    [{:settings_update, %{setting: :disable_link_previews, value: disable_link_previews}}]
  end

  defp dispatch_sync_action(
         %{notification_activity_setting_action: %{notification_activity_setting: setting}},
         _index,
         _me,
         _context
       )
       when not is_nil(setting) do
    [{:settings_update, %{setting: :notification_activity_setting, value: setting}}]
  end

  defp dispatch_sync_action(
         %{lid_contact_action: lid_contact_action},
         [_type, id | _rest],
         _me,
         _context
       )
       when not is_nil(lid_contact_action) do
    process_lid_contact(lid_contact_action, id)
  end

  defp dispatch_sync_action(
         %{privacy_setting_channels_personalised_recommendation_action: recommendation},
         _index,
         _me,
         _context
       )
       when not is_nil(recommendation) do
    [{:settings_update, %{setting: :channels_personalised_recommendation, value: recommendation}}]
  end

  defp dispatch_sync_action(_action, _index, _me, _context), do: []

  defp evaluate_conditional(nil, _msg_range), do: nil
  defp evaluate_conditional(_chat, nil), do: true

  defp evaluate_conditional(chat, msg_range),
    do: valid_patch_based_on_message_range?(chat, msg_range)

  defp message_range_timestamp(msg_range) do
    msg_range.last_message_timestamp || msg_range.last_system_message_timestamp || 0
  end

  defp chat_last_message_timestamp(chat) do
    chat
    |> Enum.find_value(0, fn
      {:last_message_recv_timestamp, value} when is_integer(value) -> value
      {"last_message_recv_timestamp", value} when is_integer(value) -> value
      {:lastMessageRecvTimestamp, value} when is_integer(value) -> value
      {"lastMessageRecvTimestamp", value} when is_integer(value) -> value
      _ -> nil
    end)
  end
end
