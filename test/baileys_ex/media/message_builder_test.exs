defmodule BaileysEx.Media.MessageBuilderTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Media.MessageBuilder
  alias BaileysEx.TestHelpers.FakeThumbnail

  @tag :tmp_dir
  test "prepare/2 enriches image content with uploaded media metadata and thumbnail fields",
       %{tmp_dir: tmp_dir} do
    parent = self()
    image_path = Path.join(tmp_dir, "photo.jpg")
    File.write!(image_path, "fake-image-binary")

    assert {:ok, prepared} =
             MessageBuilder.prepare(
               %{image: {:file, image_path}, caption: "hello"},
               media_upload_fun: fn encrypted_path, media_type, upload_opts ->
                 send(
                   parent,
                   {:media_upload, encrypted_path, File.exists?(encrypted_path), media_type,
                    upload_opts}
                 )

                 {:ok,
                  %{
                    media_url: "https://mmg.whatsapp.net/mms/image/abc",
                    direct_path: "/mms/image/abc"
                  }}
               end,
               thumbnail_module: FakeThumbnail,
               tmp_dir: tmp_dir,
               now_unix_fun: fn -> 1_710_000_000 end
             )

    assert prepared.caption == "hello"
    assert prepared.mimetype == "image/jpeg"

    assert %{
             media_url: "https://mmg.whatsapp.net/mms/image/abc",
             direct_path: "/mms/image/abc",
             jpeg_thumbnail: "thumb-jpeg",
             width: 13,
             height: 7,
             media_key_timestamp: 1_710_000_000,
             media_key: <<_::binary-size(32)>>,
             file_sha256: <<_::binary-size(32)>>,
             file_enc_sha256: <<_::binary-size(32)>>,
             file_length: 17
           } = prepared.media_upload

    assert_receive {:media_upload, _encrypted_path, true, :image, upload_opts}
    assert upload_opts[:file_enc_sha256] == prepared.media_upload.file_enc_sha256
  end

  @tag :tmp_dir
  test "prepare/2 enriches push-to-talk audio with a waveform when available", %{tmp_dir: tmp_dir} do
    audio_path = Path.join(tmp_dir, "voice.ogg")
    File.write!(audio_path, "fake-audio-binary")

    assert {:ok, prepared} =
             MessageBuilder.prepare(
               %{audio: {:file, audio_path}, ptt: true},
               media_upload_fun: fn _encrypted_path, :audio, _upload_opts ->
                 {:ok,
                  %{
                    media_url: "https://mmg.whatsapp.net/mms/audio/voice",
                    direct_path: "/mms/audio/voice"
                  }}
               end,
               thumbnail_module: FakeThumbnail,
               tmp_dir: tmp_dir
             )

    assert prepared.mimetype == "audio/ogg"
    assert prepared.media_upload.waveform == :binary.copy(<<42>>, 64)
  end
end
