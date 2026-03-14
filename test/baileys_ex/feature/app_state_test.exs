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
end
