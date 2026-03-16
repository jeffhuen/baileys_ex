defmodule BaileysEx.Feature.ChatTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Feature.Chat

  test "archive, mute, pin, and link-preview privacy map to Baileys patch shapes" do
    parent = self()

    push_fun = fn patch ->
      send(parent, {:patch, patch})
      {:ok, patch}
    end

    last_messages = [
      %{
        key: %{id: "msg-1", remote_jid: "15550001111@s.whatsapp.net", from_me: true},
        message_timestamp: 1_710_000_000
      }
    ]

    assert {:ok, %{index: ["archive", "15550001111@s.whatsapp.net"], type: :regular_low}} =
             Chat.archive(push_fun, "15550001111@s.whatsapp.net", true, last_messages)

    assert_receive {:patch,
                    %{
                      sync_action: %{
                        archive_chat_action: %{archived: true, message_range: %{messages: [_]}}
                      },
                      api_version: 3,
                      operation: :set
                    }}

    assert {:ok, %{index: ["mute", "15550001111@s.whatsapp.net"], type: :regular_high}} =
             Chat.mute(push_fun, "15550001111@s.whatsapp.net", 1_710_086_400)

    assert_receive {:patch,
                    %{
                      sync_action: %{
                        mute_action: %{muted: true, mute_end_timestamp: 1_710_086_400}
                      }
                    }}

    assert {:ok, %{index: ["mute", "15550001111@s.whatsapp.net"], type: :regular_high}} =
             Chat.mute(push_fun, "15550001111@s.whatsapp.net", nil)

    assert_receive {:patch,
                    %{
                      sync_action: %{
                        mute_action: %{muted: false, mute_end_timestamp: nil}
                      }
                    }}

    assert {:ok, %{index: ["mute", "15550001111@s.whatsapp.net"], type: :regular_high}} =
             Chat.mute(push_fun, "15550001111@s.whatsapp.net", 0)

    assert_receive {:patch,
                    %{
                      sync_action: %{
                        mute_action: %{muted: false, mute_end_timestamp: nil}
                      }
                    }}

    assert {:ok, %{index: ["pin_v1", "15550001111@s.whatsapp.net"], type: :regular_low}} =
             Chat.pin(push_fun, "15550001111@s.whatsapp.net", true)

    assert_receive {:patch, %{sync_action: %{pin_action: %{pinned: true}}, api_version: 5}}

    assert {:ok, %{index: ["setting_disableLinkPreviews"], type: :regular}} =
             Chat.update_link_previews(push_fun, true)

    assert_receive {:patch,
                    %{
                      sync_action: %{
                        privacy_setting_disable_link_previews_action: %{
                          is_previews_disabled: true
                        }
                      },
                      api_version: 8
                    }}
  end

  test "star, delete, clear, mark_read, and delete_message_for_me produce expected patches" do
    parent = self()

    push_fun = fn patch ->
      send(parent, {:patch, patch})
      {:ok, patch}
    end

    last_messages = [
      %{
        key: %{id: "msg-1", remote_jid: "15550001111@s.whatsapp.net", from_me: false},
        message_timestamp: 1_710_000_000
      }
    ]

    assert {:ok, %{index: ["star", "15550001111@s.whatsapp.net", "msg-1", "0", "0"]}} =
             Chat.star(
               push_fun,
               "15550001111@s.whatsapp.net",
               [%{id: "msg-1", from_me: false}],
               true
             )

    assert_receive {:patch, %{sync_action: %{star_action: %{starred: true}}}}

    assert {:ok, %{index: ["deleteChat", "15550001111@s.whatsapp.net", "1"]}} =
             Chat.delete(push_fun, "15550001111@s.whatsapp.net", last_messages)

    assert_receive {:patch,
                    %{
                      sync_action: %{
                        delete_chat_action: %{
                          message_range: %{
                            last_message_timestamp: 1_710_000_000,
                            messages: [
                              %{
                                :key => %{
                                  "id" => "msg-1",
                                  "remote_jid" => "15550001111@s.whatsapp.net",
                                  "from_me" => false,
                                  :id => "msg-1",
                                  :remote_jid => "15550001111@s.whatsapp.net",
                                  :from_me => false
                                },
                                "key" => %{
                                  "id" => "msg-1",
                                  "remote_jid" => "15550001111@s.whatsapp.net",
                                  "from_me" => false,
                                  :id => "msg-1",
                                  :remote_jid => "15550001111@s.whatsapp.net",
                                  :from_me => false
                                },
                                "message_timestamp" => 1_710_000_000,
                                :message_timestamp => 1_710_000_000
                              }
                            ]
                          }
                        }
                      }
                    }}

    assert {:ok, %{index: ["clearChat", "15550001111@s.whatsapp.net", "1", "0"]}} =
             Chat.clear(push_fun, "15550001111@s.whatsapp.net", last_messages)

    assert_receive {:patch,
                    %{
                      sync_action: %{
                        clear_chat_action: %{
                          message_range: %{
                            last_message_timestamp: 1_710_000_000,
                            messages: [
                              %{
                                :key => %{
                                  "id" => "msg-1",
                                  "remote_jid" => "15550001111@s.whatsapp.net",
                                  "from_me" => false,
                                  :id => "msg-1",
                                  :remote_jid => "15550001111@s.whatsapp.net",
                                  :from_me => false
                                },
                                "key" => %{
                                  "id" => "msg-1",
                                  "remote_jid" => "15550001111@s.whatsapp.net",
                                  "from_me" => false,
                                  :id => "msg-1",
                                  :remote_jid => "15550001111@s.whatsapp.net",
                                  :from_me => false
                                },
                                "message_timestamp" => 1_710_000_000,
                                :message_timestamp => 1_710_000_000
                              }
                            ]
                          }
                        }
                      }
                    }}

    assert {:ok, %{index: ["markChatAsRead", "15550001111@s.whatsapp.net"]}} =
             Chat.mark_read(push_fun, "15550001111@s.whatsapp.net", true, last_messages)

    assert_receive {:patch, %{sync_action: %{mark_chat_as_read_action: %{read: true}}}}

    assert {:ok,
            %{index: ["deleteMessageForMe", "15550001111@s.whatsapp.net", "msg-1", "0", "0"]}} =
             Chat.delete_message_for_me(
               push_fun,
               "15550001111@s.whatsapp.net",
               %{id: "msg-1", from_me: false},
               1_710_000_000,
               true
             )

    assert_receive {:patch,
                    %{
                      sync_action: %{
                        delete_message_for_me_action: %{
                          delete_media: true,
                          message_timestamp: 1_710_000_000
                        }
                      }
                    }}
  end

  test "chat operations propagate push-patch errors" do
    assert {:error, :denied} =
             Chat.pin(fn _patch -> {:error, :denied} end, "15550001111@s.whatsapp.net", true)
  end
end
