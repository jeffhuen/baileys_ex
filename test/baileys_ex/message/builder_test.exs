defmodule BaileysEx.Message.BuilderTest do
  use ExUnit.Case, async: true

  alias BaileysEx.JID
  alias BaileysEx.Message.Builder
  alias BaileysEx.Protocol.Proto.Message
  alias BaileysEx.Protocol.Proto.Message.ContextInfo
  alias BaileysEx.Protocol.Proto.Message.FutureProofMessage
  alias BaileysEx.Protocol.Proto.Message.ProtocolMessage
  alias BaileysEx.Protocol.Proto.Message.ReactionMessage
  alias BaileysEx.Protocol.Proto.MessageContextInfo
  alias BaileysEx.Protocol.Proto.MessageKey

  test "builds plain text as extended text to match Baileys rc9" do
    assert %Message{
             extended_text_message: %Message.ExtendedTextMessage{text: "hello"}
           } = Builder.build(%{text: "hello"})
  end

  test "builds extended text when quote and mentions are present" do
    quoted = %Message{extended_text_message: %Message.ExtendedTextMessage{text: "quoted"}}

    assert %Message{
             extended_text_message: %Message.ExtendedTextMessage{
               text: "hello",
               context_info: %ContextInfo{
                 stanza_id: "abc",
                 participant: "15551234567@s.whatsapp.net",
                 quoted_message: ^quoted,
                 mentioned_jid: ["15557654321@s.whatsapp.net"]
               }
             }
           } =
             Builder.build(%{
               text: "hello",
               quoted: %{
                 key: %{id: "abc", participant: "15551234567@s.whatsapp.net"},
                 message: quoted
               },
               mentions: ["15557654321@s.whatsapp.net"]
             })
  end

  test "auto-generates a link preview when get_url_info is configured" do
    assert %Message{
             extended_text_message: %Message.ExtendedTextMessage{
               text: "see https://example.com",
               matched_text: "https://example.com",
               title: "Example",
               description: "Example site"
             }
           } =
             Builder.build(
               %{text: "see https://example.com"},
               get_url_info: fn "https://example.com" ->
                 %{
                   "matched-text" => "https://example.com",
                   title: "Example",
                   description: "Example site"
                 }
               end
             )
  end

  test "builds a reaction message" do
    assert %Message{
             reaction_message: %ReactionMessage{
               key: %MessageKey{id: "msg-1", remote_jid: "15551234567@s.whatsapp.net"},
               text: "🔥",
               sender_timestamp_ms: sender_timestamp_ms
             }
           } =
             Builder.build(%{
               react: %{
                 key: %{
                   id: "msg-1",
                   remote_jid: %JID{user: "15551234567", server: "s.whatsapp.net"}
                 },
                 text: "🔥"
               }
             })

    assert is_integer(sender_timestamp_ms)
  end

  test "builds single-select polls as poll creation v3 messages" do
    assert %Message{
             poll_creation_message_v3: %Message.PollCreationMessage{
               name: "Pick one",
               selectable_options_count: 1,
               options: [
                 %Message.PollCreationMessage.Option{option_name: "A"},
                 %Message.PollCreationMessage.Option{option_name: "B"}
               ]
             },
             message_context_info: %MessageContextInfo{message_secret: <<_::binary-size(32)>>}
           } =
             Builder.build(%{
               poll: %{name: "Pick one", values: ["A", "B"], selectable_count: 1}
             })
  end

  test "builds revoke protocol messages" do
    assert %Message{
             protocol_message: %ProtocolMessage{
               key: %MessageKey{id: "msg-1", remote_jid: "15551234567@s.whatsapp.net"},
               type: :REVOKE
             }
           } =
             Builder.build(%{
               delete: %{
                 id: "msg-1",
                 remote_jid: %JID{user: "15551234567", server: "s.whatsapp.net"}
               }
             })
  end

  test "forwards a message by preserving content and incrementing forwarding score" do
    original = %{
      message: %Message{
        extended_text_message: %Message.ExtendedTextMessage{
          text: "hello",
          context_info: %ContextInfo{forwarding_score: 1}
        }
      }
    }

    assert %Message{
             extended_text_message: %Message.ExtendedTextMessage{
               text: "hello",
               context_info: %ContextInfo{is_forwarded: true, forwarding_score: 2}
             }
           } = Builder.build(%{forward: original, force: false})
  end

  test "builds disappearing message settings, pin messages, and phone-number protocol messages" do
    assert %Message{
             protocol_message: %ProtocolMessage{
               type: :EPHEMERAL_SETTING,
               ephemeral_expiration: 86_400
             }
           } = Builder.build(%{disappearing_messages_in_chat: true})

    assert %Message{
             pin_in_chat_message: %Message.PinInChatMessage{type: :PIN_FOR_ALL},
             message_context_info: %MessageContextInfo{message_add_on_duration_in_secs: 7_200}
           } =
             Builder.build(%{
               pin: %{
                 key: %{id: "pin-1", remote_jid: "15551234567@s.whatsapp.net"},
                 type: :pin,
                 time: 7_200
               }
             })

    assert %Message{
             protocol_message: %ProtocolMessage{type: :SHARE_PHONE_NUMBER}
           } = Builder.build(%{share_phone_number: true})

    assert %Message{
             request_phone_number_message: %Message.RequestPhoneNumberMessage{}
           } = Builder.build(%{request_phone_number: true})
  end

  test "builds button and list reply messages" do
    assert %Message{
             template_button_reply_message: %Message.TemplateButtonReplyMessage{
               selected_display_text: "Tap",
               selected_id: "btn-1"
             }
           } =
             Builder.build(%{
               button_reply: %{display_text: "Tap", id: "btn-1", type: :template}
             })

    assert %Message{
             buttons_response_message: %Message.ButtonsResponseMessage{
               selected_display_text: "Tap",
               selected_button_id: "btn-2",
               type: :DISPLAY_TEXT
             }
           } = Builder.build(%{button_reply: %{display_text: "Tap", id: "btn-2"}})

    assert %Message{
             list_response_message: %Message.ListResponseMessage{
               title: "Choice",
               single_select_reply: %Message.ListResponseMessage.SingleSelectReply{
                 selected_row_id: "row-1"
               }
             }
           } = Builder.build(%{list_reply: %{title: "Choice", row_id: "row-1"}})
  end

  test "wraps a message in view once" do
    assert %Message{
             view_once_message: %FutureProofMessage{
               message: %Message{
                 extended_text_message: %Message.ExtendedTextMessage{text: "secret"}
               }
             }
           } = Builder.build(%{text: "secret", view_once: true})
  end

  test "built non-text messages roundtrip through message encode/decode" do
    messages = [
      Builder.build(%{location: %{latitude: 37.0, longitude: -122.0, name: "SF"}}),
      Builder.build(%{live_location: %{latitude: 37.0, longitude: -122.0, speed: 1.5}}),
      Builder.build(%{
        group_invite: %{group_jid: "120363001234567890@g.us", invite_code: "code"}
      }),
      Builder.build(%{product: %{title: "Product", product_id: "prod-1"}}),
      Builder.build(%{button_reply: %{display_text: "Tap", id: "btn-2"}}),
      Builder.build(%{button_reply: %{display_text: "Tap", id: "btn-1", type: :template}}),
      Builder.build(%{list_reply: %{title: "Choice", row_id: "row-1"}}),
      Builder.build(%{event: %{name: "Event", start_time: ~U[2026-03-11 12:00:00Z]}})
    ]

    for message <- messages do
      assert {:ok, %Message{}} = message |> Message.encode() |> Message.decode()
    end
  end
end
