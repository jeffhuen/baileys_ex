defmodule BaileysEx.Message.ParserTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Message.Parser
  alias BaileysEx.Protocol.Proto.Message

  test "normalizes nested wrappers until the inner message is reached" do
    inner = %Message{extended_text_message: %Message.ExtendedTextMessage{text: "hello"}}

    wrapped = %Message{
      ephemeral_message: %Message.FutureProofMessage{
        message: %Message{
          view_once_message: %Message.FutureProofMessage{
            message: %Message{
              edited_message: %Message.FutureProofMessage{message: inner}
            }
          }
        }
      }
    }

    assert ^inner = Parser.normalize_content(wrapped)
  end

  test "returns the active content type for a message" do
    known_types = [
      {:conversation, %Message{conversation: "hello"}},
      {:image_message, %Message{image_message: %Message.ImageMessage{caption: "image"}}},
      {:contact_message, %Message{contact_message: %Message.ContactMessage{display_name: "Ada"}}},
      {:location_message,
       %Message{location_message: %Message.LocationMessage{degrees_latitude: 1.0}}},
      {:extended_text_message,
       %Message{extended_text_message: %Message.ExtendedTextMessage{text: "hello"}}},
      {:document_message,
       %Message{document_message: %Message.DocumentMessage{file_name: "f.txt"}}},
      {:audio_message, %Message{audio_message: %Message.AudioMessage{seconds: 1}}},
      {:video_message, %Message{video_message: %Message.VideoMessage{caption: "video"}}},
      {:protocol_message, %Message{protocol_message: %Message.ProtocolMessage{type: :REVOKE}}},
      {:contacts_array_message,
       %Message{contacts_array_message: %Message.ContactsArrayMessage{display_name: "Group"}}},
      {:template_message,
       %Message{
         template_message: %Message.TemplateMessage{
           hydrated_template: %Message.TemplateMessage.HydratedFourRowTemplate{
             hydrated_content_text: "template"
           }
         }
       }},
      {:sticker_message, %Message{sticker_message: %Message.StickerMessage{is_animated: false}}},
      {:group_invite_message,
       %Message{group_invite_message: %Message.GroupInviteMessage{invite_code: "123"}}},
      {:template_button_reply_message,
       %Message{
         template_button_reply_message: %Message.TemplateButtonReplyMessage{
           selected_id: "btn-1"
         }
       }},
      {:product_message,
       %Message{
         product_message: %Message.ProductMessage{
           product: %Message.ProductMessage.ProductSnapshot{product_id: "sku-1"}
         }
       }},
      {:device_sent_message,
       %Message{
         device_sent_message: %Message.DeviceSentMessage{
           destination_jid: "15551234567@s.whatsapp.net"
         }
       }},
      {:list_response_message,
       %Message{
         list_response_message: %Message.ListResponseMessage{
           title: "list",
           single_select_reply: %Message.ListResponseMessage.SingleSelectReply{
             selected_row_id: "row-1"
           }
         }
       }},
      {:buttons_message,
       %Message{buttons_message: %Message.ButtonsMessage{content_text: "buttons"}}},
      {:buttons_response_message,
       %Message{
         buttons_response_message: %Message.ButtonsResponseMessage{selected_button_id: "btn-1"}
       }},
      {:reaction_message, %Message{reaction_message: %Message.ReactionMessage{text: "🔥"}}},
      {:poll_creation_message,
       %Message{poll_creation_message: %Message.PollCreationMessage{name: "poll"}}},
      {:request_phone_number_message,
       %Message{request_phone_number_message: %Message.RequestPhoneNumberMessage{}}},
      {:poll_creation_message_v2,
       %Message{poll_creation_message_v2: %Message.PollCreationMessage{name: "poll-v2"}}},
      {:pin_in_chat_message,
       %Message{pin_in_chat_message: %Message.PinInChatMessage{type: :PIN_FOR_ALL}}},
      {:poll_creation_message_v3,
       %Message{poll_creation_message_v3: %Message.PollCreationMessage{name: "poll-v3"}}},
      {:ptv_message, %Message{ptv_message: %Message.VideoMessage{caption: "ptv"}}},
      {:event_message, %Message{event_message: %Message.EventMessage{name: "event"}}},
      {:poll_update_message,
       %Message{
         poll_update_message: %Message.PollUpdateMessage{
           poll_creation_message_key: %BaileysEx.Protocol.Proto.MessageKey{id: "poll-1"}
         }
       }},
      {:live_location_message,
       %Message{live_location_message: %Message.LiveLocationMessage{degrees_latitude: 1.0}}},
      {:enc_reaction_message,
       %Message{
         enc_reaction_message: %Message.EncReactionMessage{
           target_message_key: %BaileysEx.Protocol.Proto.MessageKey{id: "msg-1"}
         }
       }},
      {:enc_event_response_message,
       %Message{
         enc_event_response_message: %Message.EncEventResponseMessage{
           event_creation_message_key: %BaileysEx.Protocol.Proto.MessageKey{id: "event-1"}
         }
       }}
    ]

    Enum.each(known_types, fn {expected, message} ->
      assert expected == Parser.get_content_type(message)
    end)
  end

  test "extracts inner content from buttons and template wrappers" do
    image = %Message.ImageMessage{caption: "caption"}

    assert %Message{image_message: ^image} =
             Parser.extract_message_content(%Message{
               buttons_message: %Message.ButtonsMessage{image_message: image}
             })

    assert %Message{conversation: "hello"} =
             Parser.extract_message_content(%Message{
               template_message: %Message.TemplateMessage{
                 hydrated_template: %Message.TemplateMessage.HydratedFourRowTemplate{
                   hydrated_content_text: "hello"
                 }
               }
             })
  end
end
