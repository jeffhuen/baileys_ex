defmodule BaileysEx.Syncd.ActionMapperTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Syncd.ActionMapper
  alias BaileysEx.Protocol.Proto.Syncd

  @me %{name: "Test User", id: "me@s.whatsapp.net"}
  @jid "user@s.whatsapp.net"

  defp make_mutation(value, index) do
    %{
      sync_action: %Syncd.SyncActionData{
        index: nil,
        value: value,
        version: 2
      },
      index: index
    }
  end

  defp default_value(overrides \\ %{}) do
    Map.merge(%Syncd.SyncActionValue{timestamp: 1_710_000_000}, overrides)
  end

  describe "process_sync_action/3 — mute" do
    test "muted chat emits chats_update with mute_end_time" do
      mutation =
        make_mutation(
          default_value(%{
            mute_action: %Syncd.MuteAction{muted: true, mute_end_timestamp: 1_710_086_400}
          }),
          ["mute", @jid]
        )

      assert [{:chats_update, [%{id: @jid, mute_end_time: 1_710_086_400}]}] =
               ActionMapper.process_sync_action(mutation, @me)
    end

    test "unmuted chat emits chats_update with nil mute_end_time" do
      mutation =
        make_mutation(
          default_value(%{mute_action: %Syncd.MuteAction{muted: false}}),
          ["mute", @jid]
        )

      assert [{:chats_update, [%{id: @jid, mute_end_time: nil}]}] =
               ActionMapper.process_sync_action(mutation, @me)
    end

    test "initial sync mute emits a conditional function" do
      mutation =
        make_mutation(
          default_value(%{
            mute_action: %Syncd.MuteAction{muted: true, mute_end_timestamp: 1_710_086_400}
          }),
          ["mute", @jid]
        )

      assert [{:chats_update, [%{conditional: condition}]}] =
               ActionMapper.process_sync_action(mutation, @me, initial_sync: true)

      assert is_function(condition, 1)
      assert condition.(%{}) == nil

      assert condition.(%{
               historySets: %{chats: %{@jid => %{last_message_recv_timestamp: 1_710_000_000}}},
               chatUpserts: %{}
             }) == true
    end
  end

  describe "process_sync_action/3 — archive" do
    test "archived chat emits chats_update" do
      mutation =
        make_mutation(
          default_value(%{archive_chat_action: %Syncd.ArchiveChatAction{archived: true}}),
          ["archive", @jid]
        )

      [event] = ActionMapper.process_sync_action(mutation, @me)
      assert {:chats_update, [%{id: @jid, archived: true}]} = event
    end

    test "unarchived chat from type field" do
      mutation =
        make_mutation(
          default_value(%{archive_chat_action: nil}),
          ["unarchive", @jid]
        )

      [event] = ActionMapper.process_sync_action(mutation, @me)
      assert {:chats_update, [%{id: @jid, archived: false}]} = event
    end
  end

  describe "process_sync_action/3 — mark_read" do
    test "marking read emits unread_count 0" do
      mutation =
        make_mutation(
          default_value(%{mark_chat_as_read_action: %Syncd.MarkChatAsReadAction{read: true}}),
          ["markChatAsRead", @jid]
        )

      [event] = ActionMapper.process_sync_action(mutation, @me)
      assert {:chats_update, [%{id: @jid, unread_count: 0}]} = event
    end

    test "marking unread emits unread_count -1" do
      mutation =
        make_mutation(
          default_value(%{mark_chat_as_read_action: %Syncd.MarkChatAsReadAction{read: false}}),
          ["markChatAsRead", @jid]
        )

      [event] = ActionMapper.process_sync_action(mutation, @me)
      assert {:chats_update, [%{id: @jid, unread_count: -1}]} = event
    end

    test "initial sync read emits nil unread_count" do
      mutation =
        make_mutation(
          default_value(%{mark_chat_as_read_action: %Syncd.MarkChatAsReadAction{read: true}}),
          ["markChatAsRead", @jid]
        )

      [event] = ActionMapper.process_sync_action(mutation, @me, initial_sync: true)
      assert {:chats_update, [%{id: @jid, unread_count: nil}]} = event
    end

    test "initial sync mark_read conditional drops stale updates" do
      mutation =
        make_mutation(
          default_value(%{
            mark_chat_as_read_action: %Syncd.MarkChatAsReadAction{
              read: true,
              message_range: %Syncd.SyncActionMessageRange{last_message_timestamp: 100}
            }
          }),
          ["markChatAsRead", @jid]
        )

      assert [{:chats_update, [%{conditional: condition}]}] =
               ActionMapper.process_sync_action(mutation, @me, initial_sync: true)

      assert condition.(%{
               historySets: %{chats: %{@jid => %{last_message_recv_timestamp: 150}}},
               chatUpserts: %{}
             }) == false

      assert condition.(%{
               historySets: %{chats: %{@jid => %{last_message_recv_timestamp: 100}}},
               chatUpserts: %{}
             }) == true
    end

    test "initial sync mark_read ignores conversation timestamp fallbacks" do
      mutation =
        make_mutation(
          default_value(%{
            mark_chat_as_read_action: %Syncd.MarkChatAsReadAction{
              read: true,
              message_range: %Syncd.SyncActionMessageRange{last_message_timestamp: 100}
            }
          }),
          ["markChatAsRead", @jid]
        )

      assert [{:chats_update, [%{conditional: condition}]}] =
               ActionMapper.process_sync_action(mutation, @me, initial_sync: true)

      assert condition.(%{
               historySets: %{chats: %{@jid => %{conversation_timestamp: 150}}},
               chatUpserts: %{}
             }) == true
    end
  end

  describe "process_sync_action/3 — delete_message_for_me" do
    test "emits messages_delete with correct keys" do
      mutation =
        make_mutation(
          default_value(%{
            delete_message_for_me_action: %Syncd.DeleteMessageForMeAction{
              delete_media: false,
              message_timestamp: 1_710_000_000
            }
          }),
          ["deleteMessageForMe", @jid, "msg123", "1"]
        )

      assert [{:messages_delete, %{keys: [%{remote_jid: @jid, id: "msg123", from_me: true}]}}] =
               ActionMapper.process_sync_action(mutation, @me)
    end
  end

  describe "process_sync_action/3 — contact" do
    test "contact action emits contacts_upsert" do
      mutation =
        make_mutation(
          default_value(%{
            contact_action: %Syncd.ContactAction{
              full_name: "John Doe",
              lid_jid: "lid123@lid"
            }
          }),
          ["contact", @jid]
        )

      events = ActionMapper.process_sync_action(mutation, @me)
      assert Enum.any?(events, fn {type, _} -> type == :contacts_upsert end)
    end

    test "contact with LID and PN emits lid_mapping_update" do
      mutation =
        make_mutation(
          default_value(%{
            contact_action: %Syncd.ContactAction{
              full_name: "John",
              lid_jid: "lid123@lid"
            }
          }),
          ["contact", @jid]
        )

      events = ActionMapper.process_sync_action(mutation, @me)
      assert Enum.any?(events, fn {type, _} -> type == :lid_mapping_update end)
    end

    test "contact emits contacts before lid mapping updates" do
      mutation =
        make_mutation(
          default_value(%{
            contact_action: %Syncd.ContactAction{
              full_name: "John",
              lid_jid: "lid123@lid"
            }
          }),
          ["contact", @jid]
        )

      assert [
               {:contacts_upsert, [%{id: @jid, name: "John"}]},
               {:lid_mapping_update, %{lid: "lid123@lid", pn: @jid}}
             ] = ActionMapper.process_sync_action(mutation, @me)
    end
  end

  describe "process_sync_action/3 — push_name" do
    test "different name emits creds_update" do
      mutation =
        make_mutation(
          default_value(%{push_name_setting: %Syncd.PushNameSetting{name: "New Name"}}),
          ["setting_pushName"]
        )

      assert [{:creds_update, %{me: %{name: "New Name"}}}] =
               ActionMapper.process_sync_action(mutation, @me)
    end

    test "same name emits nothing" do
      mutation =
        make_mutation(
          default_value(%{push_name_setting: %Syncd.PushNameSetting{name: "Test User"}}),
          ["setting_pushName"]
        )

      assert [] = ActionMapper.process_sync_action(mutation, @me)
    end
  end

  describe "process_sync_action/3 — pin" do
    test "pinned emits chats_update with timestamp" do
      mutation =
        make_mutation(
          default_value(%{pin_action: %Syncd.PinAction{pinned: true}}),
          ["pin_v1", @jid]
        )

      [event] = ActionMapper.process_sync_action(mutation, @me)
      assert {:chats_update, [%{id: @jid, pinned: 1_710_000_000}]} = event
    end

    test "pinned with missing timestamp coerces to 0 like Baileys" do
      mutation =
        make_mutation(
          default_value(%{pin_action: %Syncd.PinAction{pinned: true}, timestamp: nil}),
          ["pin_v1", @jid]
        )

      [event] = ActionMapper.process_sync_action(mutation, @me)
      assert {:chats_update, [%{id: @jid, pinned: 0}]} = event
    end

    test "unpinned emits chats_update with nil" do
      mutation =
        make_mutation(
          default_value(%{pin_action: %Syncd.PinAction{pinned: false}}),
          ["pin_v1", @jid]
        )

      [event] = ActionMapper.process_sync_action(mutation, @me)
      assert {:chats_update, [%{id: @jid, pinned: nil}]} = event
    end

    test "initial sync pin emits a conditional function" do
      mutation =
        make_mutation(
          default_value(%{pin_action: %Syncd.PinAction{pinned: true}}),
          ["pin_v1", @jid]
        )

      assert [{:chats_update, [%{conditional: condition}]}] =
               ActionMapper.process_sync_action(mutation, @me, initial_sync: true)

      assert is_function(condition, 1)
      assert condition.(%{}) == nil

      assert condition.(%{
               historySets: %{chats: %{@jid => %{last_message_recv_timestamp: 1_710_000_000}}},
               chatUpserts: %{}
             }) == true
    end
  end

  describe "process_sync_action/3 — star" do
    test "starred message emits messages_update" do
      mutation =
        make_mutation(
          default_value(%{star_action: %Syncd.StarAction{starred: true}}),
          ["star", @jid, "msg1", "1", "0"]
        )

      [event] = ActionMapper.process_sync_action(mutation, @me)

      assert {:messages_update,
              [%{key: %{remote_jid: @jid, id: "msg1", from_me: true}, update: %{starred: true}}]} =
               event
    end
  end

  describe "process_sync_action/3 — delete_chat" do
    test "emits chats_delete when not initial sync" do
      mutation =
        make_mutation(
          default_value(%{delete_chat_action: %Syncd.DeleteChatAction{}}),
          ["deleteChat", @jid, "1"]
        )

      assert [{:chats_delete, [@jid]}] = ActionMapper.process_sync_action(mutation, @me)
    end

    test "skips during initial sync" do
      mutation =
        make_mutation(
          default_value(%{delete_chat_action: %Syncd.DeleteChatAction{}}),
          ["deleteChat", @jid, "1"]
        )

      assert [] = ActionMapper.process_sync_action(mutation, @me, initial_sync: true)
    end
  end

  describe "process_sync_action/3 — labels" do
    test "label edit emits labels_edit" do
      mutation =
        make_mutation(
          default_value(%{
            label_edit_action: %Syncd.LabelEditAction{name: "Work", color: 3, deleted: false}
          }),
          ["label_edit", "5"]
        )

      [event] = ActionMapper.process_sync_action(mutation, @me)
      assert {:labels_edit, %{id: "5", name: "Work", color: 3, deleted: false}} = event
    end

    test "chat label association emits labels_association for Baileys label_jid indexes" do
      mutation =
        make_mutation(
          default_value(%{
            label_association_action: %Syncd.LabelAssociationAction{labeled: true}
          }),
          ["label_jid", "5", @jid]
        )

      [event] = ActionMapper.process_sync_action(mutation, @me)

      assert {:labels_association,
              %{type: :add, association: %{type: :chat, chat_id: @jid, label_id: "5"}}} = event
    end

    test "message label association keeps the message id from the label_message index" do
      mutation =
        make_mutation(
          default_value(%{
            label_association_action: %Syncd.LabelAssociationAction{labeled: false}
          }),
          ["label_message", "5", @jid, "wamid-1", "0", "0"]
        )

      [event] = ActionMapper.process_sync_action(mutation, @me)

      assert {:labels_association,
              %{
                type: :remove,
                association: %{
                  type: :message,
                  chat_id: @jid,
                  message_id: "wamid-1",
                  label_id: "5"
                }
              }} = event
    end
  end

  describe "process_sync_action/3 — settings" do
    test "locale setting emits settings_update" do
      mutation =
        make_mutation(
          default_value(%{locale_setting: %Syncd.LocaleSetting{locale: "en_US"}}),
          ["setting_locale"]
        )

      assert [{:settings_update, %{setting: :locale, value: "en_US"}}] =
               ActionMapper.process_sync_action(mutation, @me)
    end

    test "lock_chat emits chats_lock" do
      mutation =
        make_mutation(
          default_value(%{lock_chat_action: %Syncd.LockChatAction{locked: true}}),
          ["lockChat", @jid]
        )

      assert [{:chats_lock, %{id: @jid, locked: true}}] =
               ActionMapper.process_sync_action(mutation, @me)
    end

    test "unarchive_chats_setting emits creds_update" do
      mutation =
        make_mutation(
          default_value(%{
            unarchive_chats_setting: %Syncd.UnarchiveChatsSetting{unarchive_chats: true}
          }),
          ["setting_unarchiveChats"]
        )

      assert [{:creds_update, %{account_settings: %{unarchive_chats: true}}}] =
               ActionMapper.process_sync_action(mutation, @me)
    end

    test "pn_for_lid emits lid_mapping_update" do
      mutation =
        make_mutation(
          default_value(%{
            pn_for_lid_chat_action: %Syncd.PnForLidChatAction{pn_jid: @jid}
          }),
          ["pnForLid", "lid@lid"]
        )

      assert [{:lid_mapping_update, %{lid: "lid@lid", pn: @jid}}] =
               ActionMapper.process_sync_action(mutation, @me)
    end

    test "link preview privacy emits settings_update" do
      mutation =
        make_mutation(
          default_value(%{
            privacy_setting_disable_link_previews_action:
              %Syncd.PrivacySettingDisableLinkPreviewsAction{is_previews_disabled: true}
          }),
          ["setting_disableLinkPreviews"]
        )

      [event] = ActionMapper.process_sync_action(mutation, @me)
      assert {:settings_update, %{setting: :disable_link_previews}} = event
    end
  end

  describe "process_sync_action/3 — lid_contact" do
    test "emits contacts_upsert with lid" do
      lid = "lid123@lid"

      mutation =
        make_mutation(
          default_value(%{
            lid_contact_action: %Syncd.LidContactAction{full_name: "LID Contact"}
          }),
          ["lidContact", lid]
        )

      [event] = ActionMapper.process_sync_action(mutation, @me)
      assert {:contacts_upsert, [%{id: ^lid, name: "LID Contact", lid: ^lid}]} = event
    end
  end

  describe "process_sync_action/3 — unrecognized" do
    test "returns empty list for unknown action" do
      mutation = make_mutation(default_value(), ["unknown_type", @jid])
      assert [] = ActionMapper.process_sync_action(mutation, @me)
    end
  end

  describe "process_contact_action/2" do
    test "returns contacts_upsert for PN user" do
      action = %Syncd.ContactAction{full_name: "John Doe"}
      results = ActionMapper.process_contact_action(action, @jid)
      assert [{:contacts_upsert, [%{id: @jid, name: "John Doe"}]}] = results
    end

    test "returns empty for nil id" do
      action = %Syncd.ContactAction{full_name: "John"}
      assert [] = ActionMapper.process_contact_action(action, nil)
    end

    test "includes lid_mapping_update when LID and PN available" do
      action = %Syncd.ContactAction{full_name: "John", lid_jid: "lid@lid"}
      results = ActionMapper.process_contact_action(action, @jid)
      assert Enum.any?(results, fn {type, _} -> type == :lid_mapping_update end)
    end

    test "returns results in Baileys order" do
      action = %Syncd.ContactAction{full_name: "John", lid_jid: "lid@lid"}

      assert [
               {:contacts_upsert, [%{id: @jid, name: "John", lid: "lid@lid"}]},
               {:lid_mapping_update, %{lid: "lid@lid", pn: @jid}}
             ] = ActionMapper.process_contact_action(action, @jid)
    end
  end

  describe "emit_sync_action_results/2" do
    test "calls emit function for each result" do
      results = [
        {:contacts_upsert, [%{id: @jid, name: "John"}]},
        {:lid_mapping_update, %{lid: "lid@lid", pn: @jid}}
      ]

      me = self()
      emit_fn = fn event -> send(me, {:emitted, event}) end

      ActionMapper.emit_sync_action_results(emit_fn, results)

      assert_received {:emitted, {:contacts_upsert, _}}
      assert_received {:emitted, {:lid_mapping_update, _}}
    end
  end
end
