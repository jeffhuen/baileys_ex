defmodule BaileysEx.Feature.AppStateTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Feature.AppState

  test "push_patch/5 builds Baileys-aligned chat patches with timestamp inside sync_action" do
    assert {:ok,
            %{
              index: ["mute", "15550001111@s.whatsapp.net"],
              type: :regular_high,
              api_version: 2,
              operation: :set,
              sync_action: %{
                timestamp: 1_710_111_222_333,
                mute_action: %{muted: true, mute_end_timestamp: 1_710_086_400}
              }
            }} =
             AppState.push_patch(
               fn patch -> {:ok, patch} end,
               :mute,
               "15550001111@s.whatsapp.net",
               1_710_086_400,
               timestamp: 1_710_111_222_333
             )
  end

  test "push_patch/5 builds an unmute patch when duration is nil" do
    assert {:ok,
            %{
              sync_action: %{
                timestamp: 1_710_111_222_333,
                mute_action: %{muted: false, mute_end_timestamp: nil}
              }
            }} =
             AppState.push_patch(
               fn patch -> {:ok, patch} end,
               :mute,
               "15550001111@s.whatsapp.net",
               nil,
               timestamp: 1_710_111_222_333
             )
  end

  test "build_patch/4 raises when last message data is incomplete" do
    assert_raise ArgumentError, "incomplete key: missing id", fn ->
      AppState.build_patch(:archive, "15550001111@s.whatsapp.net", %{
        archive: true,
        last_messages: [
          %{
            key: %{remote_jid: "15550001111@s.whatsapp.net"},
            message_timestamp: 1_710_000_000
          }
        ]
      })
    end

    assert_raise ArgumentError, "expected participant on non-from-me group message", fn ->
      AppState.build_patch(:archive, "120363001234567890@g.us", %{
        archive: true,
        last_messages: [
          %{
            key: %{id: "msg-1", remote_jid: "120363001234567890@g.us", from_me: false},
            message_timestamp: 1_710_000_000
          }
        ]
      })
    end
  end

  test "build_patch/4 covers push-name, contact, and quick-reply Baileys patch shapes" do
    assert %{
             index: ["setting_pushName"],
             type: :critical_block,
             api_version: 1,
             operation: :set,
             sync_action: %{
               timestamp: 1_710_111_222_333,
               push_name_setting: %{name: "Ada Lovelace"}
             }
           } =
             AppState.build_patch(:push_name_setting, "", "Ada Lovelace",
               timestamp: 1_710_111_222_333
             )

    assert %{
             index: ["contact", "15550001111@s.whatsapp.net"],
             type: :critical_unblock_low,
             api_version: 2,
             operation: :set,
             sync_action: %{
               timestamp: 1_710_111_222_333,
               contact_action: %{full_name: "Ada Lovelace", pn_jid: "15550001111@s.whatsapp.net"}
             }
           } =
             AppState.build_patch(
               :contact,
               "15550001111@s.whatsapp.net",
               %{
                 full_name: "Ada Lovelace",
                 pn_jid: "15550001111@s.whatsapp.net"
               },
               timestamp: 1_710_111_222_333
             )

    assert %{
             index: ["contact", "15550001111@s.whatsapp.net"],
             type: :critical_unblock_low,
             api_version: 2,
             operation: :remove,
             sync_action: %{timestamp: 1_710_111_222_333, contact_action: %{}}
           } =
             AppState.build_patch(:contact, "15550001111@s.whatsapp.net", nil,
               timestamp: 1_710_111_222_333
             )

    assert %{
             index: ["quick_reply", "1710111222"],
             type: :regular,
             api_version: 2,
             operation: :set,
             sync_action: %{
               timestamp: 1_710_111_222_333,
               quick_reply_action: %{
                 shortcut: "/hi",
                 message: "Hello there",
                 keywords: [],
                 count: 0,
                 deleted: false
               }
             }
           } =
             AppState.build_patch(:quick_reply, "", %{shortcut: "/hi", message: "Hello there"},
               timestamp: 1_710_111_222_333
             )
  end

  test "build_patch/4 covers label edit and association Baileys patch shapes" do
    assert %{
             index: ["label_edit", "label-1"],
             type: :regular,
             api_version: 3,
             operation: :set,
             sync_action: %{
               timestamp: 1_710_111_222_333,
               label_edit_action: %{
                 name: "Important",
                 color: 4,
                 predefined_id: 7,
                 deleted: false
               }
             }
           } =
             AppState.build_patch(
               :add_label,
               "",
               %{
                 id: "label-1",
                 name: "Important",
                 color: 4,
                 predefined_id: 7,
                 deleted: false
               },
               timestamp: 1_710_111_222_333
             )

    assert %{
             index: ["label_jid", "label-1", "15550001111@s.whatsapp.net"],
             sync_action: %{label_association_action: %{labeled: true}}
           } =
             AppState.build_patch(
               :add_chat_label,
               "15550001111@s.whatsapp.net",
               %{label_id: "label-1"},
               timestamp: 1_710_111_222_333
             )

    assert %{
             index: ["label_jid", "label-1", "15550001111@s.whatsapp.net"],
             sync_action: %{label_association_action: %{labeled: false}}
           } =
             AppState.build_patch(
               :remove_chat_label,
               "15550001111@s.whatsapp.net",
               %{label_id: "label-1"},
               timestamp: 1_710_111_222_333
             )

    assert %{
             index: [
               "label_message",
               "label-1",
               "15550001111@s.whatsapp.net",
               "wamid-1",
               "0",
               "0"
             ],
             sync_action: %{label_association_action: %{labeled: true}}
           } =
             AppState.build_patch(
               :add_message_label,
               "15550001111@s.whatsapp.net",
               %{label_id: "label-1", message_id: "wamid-1"},
               timestamp: 1_710_111_222_333
             )

    assert %{
             index: [
               "label_message",
               "label-1",
               "15550001111@s.whatsapp.net",
               "wamid-1",
               "0",
               "0"
             ],
             sync_action: %{label_association_action: %{labeled: false}}
           } =
             AppState.build_patch(
               :remove_message_label,
               "15550001111@s.whatsapp.net",
               %{label_id: "label-1", message_id: "wamid-1"},
               timestamp: 1_710_111_222_333
             )
  end

  test "build_patch/4 omits disable_link_previews fields when the setting is false" do
    patch =
      AppState.build_patch(:disable_link_previews, "", false, timestamp: 1_710_111_222_333)

    assert patch.index == ["setting_disableLinkPreviews"]
    assert patch.type == :regular
    assert patch.api_version == 8
    assert patch.operation == :set

    assert patch.sync_action.privacy_setting_disable_link_previews_action == %{}
  end
end
