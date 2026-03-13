defmodule BaileysEx.Media.DownloadTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Media.Crypto
  alias BaileysEx.Media.Download
  alias BaileysEx.Protocol.Proto.Message

  @tag :tmp_dir
  test "download/2 decrypts media via direct_path fallback even when a non-mmg url is present",
       %{tmp_dir: tmp_dir} do
    parent = self()
    media_key = :binary.copy(<<5>>, 32)
    plaintext = "downloaded media payload"

    assert {:ok, %{encrypted_path: encrypted_path}} =
             Crypto.encrypt(plaintext, :image, media_key: media_key, tmp_dir: tmp_dir)

    encrypted = File.read!(encrypted_path)

    request_fun = fn request ->
      uri = URI.parse(request[:url])
      send(parent, {:download_request, uri.host, uri.path, List.wrap(request[:headers])})
      {:ok, %Req.Response{status: 200, body: encrypted}}
    end

    message = %Message.ImageMessage{
      url: "https://example.com/not-whatsapp",
      media_key: media_key,
      direct_path: "/mms/image/file-1"
    }

    assert {:ok, ^plaintext} = Download.download(message, request_fun: request_fun)

    assert_receive {:download_request, "mmg.whatsapp.net", "/mms/image/file-1", headers}
    assert {"origin", "https://web.whatsapp.com"} in headers
  end

  @tag :tmp_dir
  test "download_to_file/3 persists plaintext for the media message structs", %{tmp_dir: tmp_dir} do
    media_key = :binary.copy(<<5>>, 32)
    plaintext = "downloaded media payload"

    for {message, media_type} <- [
          {%Message.ImageMessage{media_key: media_key, direct_path: "/mms/image/file-1"}, :image},
          {%Message.VideoMessage{media_key: media_key, direct_path: "/mms/video/file-1"}, :video},
          {%Message.AudioMessage{media_key: media_key, direct_path: "/mms/audio/file-1"}, :audio},
          {%Message.DocumentMessage{media_key: media_key, direct_path: "/mms/document/file-1"},
           :document},
          {%Message.StickerMessage{media_key: media_key, direct_path: "/mms/image/file-1"},
           :sticker}
        ] do
      assert {:ok, %{encrypted_path: encrypted_path}} =
               Crypto.encrypt(plaintext, media_type, media_key: media_key, tmp_dir: tmp_dir)

      encrypted = File.read!(encrypted_path)

      request_fun = fn _request ->
        {:ok, %Req.Response{status: 200, body: encrypted}}
      end

      output_path =
        Path.join(tmp_dir, "out-#{media_type}-#{System.unique_integer([:positive])}.bin")

      assert {:ok, ^output_path} =
               Download.download_to_file(message, output_path, request_fun: request_fun)

      assert File.read!(output_path) == plaintext
    end
  end

  test "download/2 returns explicit errors for missing media data and HTTP failures" do
    assert {:error, :missing_media_key} =
             Download.download(%Message.ImageMessage{direct_path: "/mms/image/file-1"},
               request_fun: fn _request ->
                 {:ok, %Req.Response{status: 200, body: "irrelevant"}}
               end
             )

    assert {:error, :missing_media_url} =
             Download.download(%Message.ImageMessage{media_key: :binary.copy(<<1>>, 32)},
               request_fun: fn _request ->
                 {:ok, %Req.Response{status: 200, body: "irrelevant"}}
               end
             )

    assert {:error, :unknown_media_type} =
             Download.download(%{
               media_key: :binary.copy(<<1>>, 32),
               direct_path: "/mms/image/file-1"
             })

    assert {:error, {:http_error, 404, "gone"}} =
             Download.download(
               %Message.ImageMessage{
                 media_key: :binary.copy(<<1>>, 32),
                 direct_path: "/mms/image/file-1"
               },
               request_fun: fn _request -> {:ok, %Req.Response{status: 404, body: "gone"}} end
             )

    assert {:error, :invalid_media_payload} =
             Download.download(
               %Message.ImageMessage{
                 media_key: :binary.copy(<<1>>, 32),
                 direct_path: "/mms/image/file-1"
               },
               request_fun: fn _request ->
                 {:ok, %Req.Response{status: 200, body: <<1, 2, 3>>}}
               end
             )
  end
end
