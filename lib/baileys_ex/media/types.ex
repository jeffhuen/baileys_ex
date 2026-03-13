defmodule BaileysEx.Media.Types do
  @moduledoc """
  Media type descriptors used by media crypto, upload, and download flows.
  """

  @type media_type ::
          :image
          | :video
          | :audio
          | :document
          | :sticker
          | :gif
          | :ptt
          | :ptv
          | :thumbnail_link
          | :product_catalog_image
          | :md_app_state
          | :md_msg_hist
          | :product
          | :thumbnail_document
          | :thumbnail_image
          | :thumbnail_video
          | :payment_bg_image
          | :ppic
          | :biz_cover_photo

  @type descriptor :: %{
          path: String.t() | nil,
          hkdf_info: String.t(),
          proto_field: atom()
        }

  @media_types %{
    image: %{path: "/mms/image", hkdf_info: "WhatsApp Image Keys", proto_field: :image_message},
    video: %{path: "/mms/video", hkdf_info: "WhatsApp Video Keys", proto_field: :video_message},
    audio: %{path: "/mms/audio", hkdf_info: "WhatsApp Audio Keys", proto_field: :audio_message},
    document: %{
      path: "/mms/document",
      hkdf_info: "WhatsApp Document Keys",
      proto_field: :document_message
    },
    sticker: %{
      path: "/mms/image",
      hkdf_info: "WhatsApp Image Keys",
      proto_field: :sticker_message
    },
    gif: %{path: "/mms/video", hkdf_info: "WhatsApp Video Keys", proto_field: :video_message},
    ptt: %{path: "/mms/audio", hkdf_info: "WhatsApp Audio Keys", proto_field: :audio_message},
    ptv: %{path: "/mms/video", hkdf_info: "WhatsApp Video Keys", proto_field: :ptv_message},
    thumbnail_link: %{
      path: "/mms/image",
      hkdf_info: "WhatsApp Link Thumbnail Keys",
      proto_field: :extended_text_message
    },
    thumbnail_document: %{
      path: nil,
      hkdf_info: "WhatsApp Document Thumbnail Keys",
      proto_field: :document_message
    },
    thumbnail_image: %{
      path: nil,
      hkdf_info: "WhatsApp Image Thumbnail Keys",
      proto_field: :image_message
    },
    thumbnail_video: %{
      path: nil,
      hkdf_info: "WhatsApp Video Thumbnail Keys",
      proto_field: :video_message
    },
    product: %{path: nil, hkdf_info: "WhatsApp Image Keys", proto_field: :product_message},
    product_catalog_image: %{
      path: "/product/image",
      hkdf_info: "WhatsApp  Keys",
      proto_field: :product_message
    },
    md_app_state: %{
      path: nil,
      hkdf_info: "WhatsApp App State Keys",
      proto_field: :app_state_sync_key
    },
    md_msg_hist: %{
      path: "/mms/md-app-state",
      hkdf_info: "WhatsApp History Keys",
      proto_field: :history_sync_notification
    },
    payment_bg_image: %{
      path: nil,
      hkdf_info: "WhatsApp Payment Background Keys",
      proto_field: :payment_background
    },
    ppic: %{path: nil, hkdf_info: "WhatsApp  Keys", proto_field: :profile_picture},
    biz_cover_photo: %{
      path: "/pps/biz-cover-photo",
      hkdf_info: "WhatsApp Image Keys",
      proto_field: :business_profile
    }
  }

  @doc """
  Return the descriptor for a media type.
  """
  @spec get(media_type()) :: descriptor()
  def get(type), do: Map.fetch!(@media_types, type)

  @doc """
  Return the CDN upload path for a media type, or `nil` when that type does not
  use the normal media CDN upload flow.
  """
  @spec path(media_type()) :: String.t() | nil
  def path(type), do: get(type).path

  @doc """
  Return the HKDF info string used for a media type.
  """
  @spec hkdf_info(media_type()) :: String.t()
  def hkdf_info(type), do: get(type).hkdf_info

  @doc """
  Infer a media type from a MIME type.
  """
  @spec from_mime(String.t()) :: media_type() | nil
  def from_mime(mime) when is_binary(mime) do
    mime
    |> String.downcase()
    |> String.split(";", parts: 2)
    |> hd()
    |> case do
      "image/webp" -> :sticker
      <<"image/", _::binary>> -> :image
      <<"video/", _::binary>> -> :video
      <<"audio/", _::binary>> -> :audio
      <<"application/", _::binary>> -> :document
      _ -> nil
    end
  end
end
