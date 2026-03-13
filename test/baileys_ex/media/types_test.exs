defmodule BaileysEx.Media.TypesTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Media.Types

  test "get/1 returns the rc9 descriptor for image media" do
    assert %{
             path: "/mms/image",
             hkdf_info: "WhatsApp Image Keys",
             proto_field: :image_message
           } = Types.get(:image)
  end

  test "from_mime/1 maps common whatsapp media mime types" do
    assert Types.from_mime("image/jpeg") == :image
    assert Types.from_mime("video/mp4") == :video
    assert Types.from_mime("audio/ogg; codecs=opus") == :audio
    assert Types.from_mime("application/pdf") == :document
    assert Types.from_mime("image/webp") == :sticker
  end

  test "path/1 returns upload paths only for media types that use the normal CDN upload flow" do
    assert Types.path(:image) == "/mms/image"
    assert Types.path(:product_catalog_image) == "/product/image"
    assert Types.path(:md_app_state) == nil
  end
end
