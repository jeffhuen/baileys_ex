defmodule BaileysEx.Message.Parser do
  @moduledoc """
  Normalizes wrapped message content and detects the active message type.
  """

  alias BaileysEx.Protocol.Proto.Message

  @content_field_order [
    :conversation,
    :image_message,
    :contact_message,
    :location_message,
    :extended_text_message,
    :document_message,
    :audio_message,
    :video_message,
    :protocol_message,
    :contacts_array_message,
    :template_message,
    :sticker_message,
    :group_invite_message,
    :template_button_reply_message,
    :product_message,
    :device_sent_message,
    :list_response_message,
    :buttons_message,
    :buttons_response_message,
    :reaction_message,
    :poll_creation_message,
    :poll_update_message,
    :request_phone_number_message,
    :poll_creation_message_v2,
    :enc_reaction_message,
    :pin_in_chat_message,
    :poll_creation_message_v3,
    :ptv_message,
    :event_message,
    :enc_event_response_message,
    :live_location_message
  ]

  @future_proof_fields [
    :ephemeral_message,
    :view_once_message,
    :document_with_caption_message,
    :view_once_message_v2,
    :view_once_message_v2_extension,
    :edited_message,
    :associated_child_message,
    :group_status_message,
    :group_status_message_v2
  ]

  @doc """
  Recursively unwraps ephemeral, view-once, edited, and grouping message wrappers.
  """
  @spec normalize_content(struct()) :: struct()
  def normalize_content(%Message{} = content) do
    Enum.reduce_while(1..5, content, fn _, current ->
      case future_proof_message(current) do
        %Message.FutureProofMessage{message: %Message{} = inner} -> {:cont, inner}
        _ -> {:halt, current}
      end
    end)
  end

  @doc """
  Identifies the active content field type from a parsed Message struct.
  """
  @spec get_content_type(struct()) :: atom() | nil
  def get_content_type(%Message{} = message) do
    message = normalize_content(message)

    Enum.find(@content_field_order, fn field ->
      not is_nil(Map.get(message, field))
    end)
  end

  @doc """
  Extracts the inner text or media struct from template wrappers.
  """
  @spec extract_message_content(struct()) :: struct()
  def extract_message_content(%Message{} = content) do
    content = normalize_content(content)

    case content do
      %Message{buttons_message: %Message.ButtonsMessage{} = buttons_message} ->
        extract_from_template_message(buttons_message)

      %Message{
        template_message: %Message.TemplateMessage{
          hydrated_four_row_template: template
        }
      }
      when not is_nil(template) ->
        extract_from_template_message(template)

      %Message{
        template_message: %Message.TemplateMessage{
          hydrated_template: template
        }
      }
      when not is_nil(template) ->
        extract_from_template_message(template)

      %Message{
        template_message: %Message.TemplateMessage{
          four_row_template: template
        }
      }
      when not is_nil(template) ->
        extract_from_template_message(template)

      _ ->
        content
    end
  end

  defp extract_from_template_message(%{image_message: %Message.ImageMessage{} = image_message}) do
    %Message{image_message: image_message}
  end

  defp extract_from_template_message(%{
         document_message: %Message.DocumentMessage{} = document_message
       }) do
    %Message{document_message: document_message}
  end

  defp extract_from_template_message(%{video_message: %Message.VideoMessage{} = video_message}) do
    %Message{video_message: video_message}
  end

  defp extract_from_template_message(%{
         location_message: %Message.LocationMessage{} = location_message
       }) do
    %Message{location_message: location_message}
  end

  defp extract_from_template_message(template) do
    text =
      Map.get(template, :content_text) ||
        Map.get(template, :hydrated_content_text) ||
        ""

    %Message{conversation: text}
  end

  defp future_proof_message(%Message{} = message) do
    Enum.find_value(@future_proof_fields, fn field ->
      Map.get(message, field)
    end)
  end
end
