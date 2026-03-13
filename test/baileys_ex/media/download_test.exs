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

  @tag :tmp_dir
  test "download_to_file/3 streams the response body instead of buffering it all first",
       %{tmp_dir: tmp_dir} do
    parent = self()
    media_key = :binary.copy(<<6>>, 32)
    plaintext = String.duplicate("stream-to-file-", 64)

    assert {:ok, %{encrypted_path: encrypted_path}} =
             Crypto.encrypt(plaintext, :image, media_key: media_key, tmp_dir: tmp_dir)

    encrypted = File.read!(encrypted_path)
    chunks = chunk_binary(encrypted, 23)

    request_fun = fn request ->
      send(parent, {:stream_request, request[:into], List.wrap(request[:headers])})

      {:ok,
       %Req.Response{
         status: 200,
         body: chunks
       }}
    end

    message = %Message.ImageMessage{
      media_key: media_key,
      direct_path: "/mms/image/file-1"
    }

    output_path = Path.join(tmp_dir, "streamed-output.bin")

    assert {:ok, ^output_path} =
             Download.download_to_file(message, output_path, request_fun: request_fun)

    assert_receive {:stream_request, :self, headers}
    assert {"origin", "https://web.whatsapp.com"} in headers
    assert File.read!(output_path) == plaintext
  end

  @tag :tmp_dir
  test "download/2 supports Baileys-style ranged downloads with aligned encrypted fetches",
       %{tmp_dir: tmp_dir} do
    parent = self()
    media_key = :binary.copy(<<7>>, 32)
    plaintext = Enum.map_join(0..95, fn idx -> <<rem(idx, 26) + ?a>> end)
    start_byte = 20
    end_byte = 32

    assert {:ok, %{encrypted_path: encrypted_path}} =
             Crypto.encrypt(plaintext, :image, media_key: media_key, tmp_dir: tmp_dir)

    encrypted = File.read!(encrypted_path)
    # Baileys fetches the previous block to use as the IV and extends the end by one block.
    ranged_body = binary_part(encrypted, 0, 49)
    chunks = chunk_binary(ranged_body, 11)

    request_fun = fn request ->
      send(parent, {:range_request, List.wrap(request[:headers]), request[:into]})

      {:ok,
       %Req.Response{
         status: 200,
         body: chunks
       }}
    end

    message = %Message.ImageMessage{
      media_key: media_key,
      direct_path: "/mms/image/file-1"
    }

    assert {:ok, expected} = {:ok, binary_part(plaintext, start_byte, end_byte - start_byte)}

    assert {:ok, ^expected} =
             Download.download(message,
               start_byte: start_byte,
               end_byte: end_byte,
               request_fun: request_fun
             )

    assert_receive {:range_request, headers, :self}
    assert {"range", "bytes=0-48"} in headers
    assert {"origin", "https://web.whatsapp.com"} in headers
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

  defp chunk_binary(binary, chunk_size) do
    Stream.unfold(binary, fn
      <<>> -> nil
      data when byte_size(data) <= chunk_size -> {data, <<>>}
      <<chunk::binary-size(chunk_size), rest::binary>> -> {chunk, rest}
    end)
    |> Enum.to_list()
  end
end
