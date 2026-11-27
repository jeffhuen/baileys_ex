defmodule BaileysEx.Media.DownloadTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Media.Crypto
  alias BaileysEx.Media.Download
  alias BaileysEx.Protocol.Proto.Message
  alias BaileysEx.TestHelpers.LoopbackHTTPServer
  alias BaileysEx.TestHelpers.TelemetryHelpers

  @tag :tmp_dir
  test "download/2 uses direct_path with host parsed from a non-default media url",
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
      url: "https://media-custom.whatsapp.net/not-whatsapp",
      media_key: media_key,
      direct_path: "/mms/image/file-1"
    }

    assert {:ok, ^plaintext} = Download.download(message, request_fun: request_fun)

    assert_receive {:download_request, "media-custom.whatsapp.net", "/mms/image/file-1", headers}

    assert {"origin", "https://web.whatsapp.com"} in headers
  end

  @tag :tmp_dir
  test "download/2 falls back to mmg.whatsapp.net when url uses the a.whatsapp.net placeholder host",
       %{tmp_dir: tmp_dir} do
    parent = self()
    media_key = :binary.copy(<<7>>, 32)
    plaintext = "downloaded sticker payload"

    assert {:ok, %{encrypted_path: encrypted_path}} =
             Crypto.encrypt(plaintext, :sticker, media_key: media_key, tmp_dir: tmp_dir)

    encrypted = File.read!(encrypted_path)

    request_fun = fn request ->
      uri = URI.parse(request[:url])
      send(parent, {:download_request, uri.host, uri.path})
      {:ok, %Req.Response{status: 200, body: encrypted}}
    end

    message = %Message.StickerMessage{
      url: "https://a.whatsapp.net/v/t62.15575-24/123_456_n.enc?mms3=true",
      media_key: media_key,
      direct_path: "/v/t62.15575-24/123_456_n.enc"
    }

    assert {:ok, ^plaintext} = Download.download(message, request_fun: request_fun)

    assert_receive {:download_request, "mmg.whatsapp.net", "/v/t62.15575-24/123_456_n.enc"}
  end

  @tag :tmp_dir
  test "download/2 allows an explicit media host override for direct_path downloads",
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
      url: "https://media-custom.whatsapp.net/not-whatsapp",
      media_key: media_key,
      direct_path: "/mms/image/file-1"
    }

    assert {:ok, ^plaintext} =
             Download.download(message, request_fun: request_fun, host: "override.whatsapp.net")

    assert_receive {:download_request, "override.whatsapp.net", "/mms/image/file-1", headers}
    assert {"origin", "https://web.whatsapp.com"} in headers
  end

  @tag :tmp_dir
  test "download/2 emits telemetry for in-memory downloads", %{tmp_dir: tmp_dir} do
    media_key = :binary.copy(<<12>>, 32)
    plaintext = "download telemetry payload"

    telemetry_id =
      TelemetryHelpers.attach_events(self(), [
        [:baileys_ex, :media, :download, :start],
        [:baileys_ex, :media, :download, :stop]
      ])

    on_exit(fn -> TelemetryHelpers.detach(telemetry_id) end)

    assert {:ok, %{encrypted_path: encrypted_path}} =
             Crypto.encrypt(plaintext, :image, media_key: media_key, tmp_dir: tmp_dir)

    encrypted = File.read!(encrypted_path)

    request_fun = fn _request ->
      {:ok, %Req.Response{status: 200, body: encrypted}}
    end

    message = %Message.ImageMessage{
      media_key: media_key,
      direct_path: "/mms/image/file-telemetry"
    }

    assert {:ok, ^plaintext} = Download.download(message, request_fun: request_fun)

    assert_receive {:telemetry, [:baileys_ex, :media, :download, :start],
                    %{system_time: system_time}, %{media_type: :image, target: :memory}}

    assert is_integer(system_time)

    assert_receive {:telemetry, [:baileys_ex, :media, :download, :stop], %{duration: duration},
                    %{media_type: :image, status: :ok, target: :memory}}

    assert is_integer(duration)
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
  test "download_to_file/3 removes partial plaintext files when streaming raises",
       %{tmp_dir: tmp_dir} do
    media_key = :binary.copy(<<8>>, 32)
    plaintext = String.duplicate("partial-cleanup-", 32)

    assert {:ok, %{encrypted_path: encrypted_path}} =
             Crypto.encrypt(plaintext, :image, media_key: media_key, tmp_dir: tmp_dir)

    encrypted = File.read!(encrypted_path)
    [first_chunk | _rest] = chunk_binary(encrypted, 19)

    request_fun = fn _request ->
      {:ok,
       %Req.Response{
         status: 200,
         body:
           Stream.concat(
             [first_chunk],
             Stream.map([:boom], fn _ -> raise "stream failed" end)
           )
       }}
    end

    message = %Message.ImageMessage{
      media_key: media_key,
      direct_path: "/mms/image/file-1"
    }

    output_path = Path.join(tmp_dir, "partial-output.bin")

    assert_raise RuntimeError, "stream failed", fn ->
      Download.download_to_file(message, output_path, request_fun: request_fun)
    end

    refute File.exists?(output_path)
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

  @tag :tmp_dir
  test "download/2 uses the original IV when start_byte is smaller than one AES block",
       %{tmp_dir: tmp_dir} do
    parent = self()
    media_key = :binary.copy(<<9>>, 32)
    plaintext = Enum.map_join(0..63, fn idx -> <<rem(idx, 26) + ?a>> end)
    start_byte = 5
    end_byte = 20

    assert {:ok, %{encrypted_path: encrypted_path}} =
             Crypto.encrypt(plaintext, :image, media_key: media_key, tmp_dir: tmp_dir)

    encrypted = File.read!(encrypted_path)
    ranged_body = binary_part(encrypted, 0, 33)

    request_fun = fn request ->
      send(parent, {:small_range_request, List.wrap(request[:headers]), request[:into]})

      {:ok,
       %Req.Response{
         status: 200,
         body: chunk_binary(ranged_body, 9)
       }}
    end

    message = %Message.ImageMessage{
      media_key: media_key,
      direct_path: "/mms/image/file-1"
    }

    expected = binary_part(plaintext, start_byte, end_byte - start_byte)

    assert {:ok, ^expected} =
             Download.download(message,
               start_byte: start_byte,
               end_byte: end_byte,
               request_fun: request_fun
             )

    assert_receive {:small_range_request, headers, :self}
    assert {"range", "bytes=0-32"} in headers
  end

  @tag :tmp_dir
  test "download/2 supports open-ended ranged downloads", %{tmp_dir: tmp_dir} do
    parent = self()
    media_key = :binary.copy(<<10>>, 32)
    plaintext = Enum.map_join(0..95, fn idx -> <<rem(idx, 26) + ?a>> end)
    start_byte = 20

    assert {:ok, %{encrypted_path: encrypted_path}} =
             Crypto.encrypt(plaintext, :image, media_key: media_key, tmp_dir: tmp_dir)

    encrypted = File.read!(encrypted_path)

    request_fun = fn request ->
      send(parent, {:open_range_request, List.wrap(request[:headers]), request[:into]})

      {:ok,
       %Req.Response{
         status: 200,
         body: chunk_binary(encrypted, 15)
       }}
    end

    message = %Message.ImageMessage{
      media_key: media_key,
      direct_path: "/mms/image/file-1"
    }

    expected = binary_part(plaintext, start_byte, byte_size(plaintext) - start_byte)

    assert {:ok, ^expected} =
             Download.download(message, start_byte: start_byte, request_fun: request_fun)

    assert_receive {:open_range_request, headers, :self}
    refute Enum.any?(headers, fn {key, _value} -> key == "range" end)
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

  @tag :tmp_dir
  test "real Req transport streams 200, ranged 206, and 410 responses cleanly with raw: true",
       %{tmp_dir: tmp_dir} do
    parent = self()
    media_key = :binary.copy(<<11>>, 32)
    plaintext = String.duplicate("req-stream-media-payload-", 40)

    assert {:ok, %{encrypted_path: encrypted_path}} =
             Crypto.encrypt(plaintext, :image, media_key: media_key, tmp_dir: tmp_dir)

    encrypted = File.read!(encrypted_path)
    full_chunks = chunk_binary(encrypted, 37)
    ranged_chunks = chunk_binary(binary_part(encrypted, 0, 49), 13)

    {:ok, server} =
      LoopbackHTTPServer.start(fn req ->
        send(parent, {:download_http_request, req.path, req.headers})

        case req.path do
          "/full" ->
            {200, [{"content-type", "application/json"}], full_chunks}

          "/ranged" ->
            {206, [{"content-type", "application/octet-stream"}], ranged_chunks}

          "/gone" ->
            {410, [{"content-type", "text/plain"}], "media expired"}
        end
      end)

    on_exit(server.stop)

    # 1. Full streaming download to file over real Req
    output_path = Path.join(tmp_dir, "real-req-full.bin")

    assert {:ok, ^output_path} =
             Download.download_to_file(
               %Message.ImageMessage{media_key: media_key, url: "#{server.url}/full"},
               output_path,
               req_options: [retry: false]
             )

    assert_receive {:download_http_request, "/full", %{"origin" => "https://web.whatsapp.com"}}
    assert File.read!(output_path) == plaintext

    # 2. Ranged 206 streaming download over real Req
    expected_range = binary_part(plaintext, 20, 12)

    assert {:ok, ^expected_range} =
             Download.download(
               %Message.ImageMessage{media_key: media_key, url: "#{server.url}/ranged"},
               start_byte: 20,
               end_byte: 32,
               req_options: [retry: false]
             )

    assert_receive {:download_http_request, "/ranged",
                    %{"origin" => "https://web.whatsapp.com", "range" => "bytes=0-48"}}

    # 3. Non-2xx response returns error body cleanly and leaves no partial file
    missing_path = Path.join(tmp_dir, "real-req-missing.bin")

    assert {:error, {:http_error, 410, "media expired"}} =
             Download.download_to_file(
               %Message.ImageMessage{media_key: media_key, url: "#{server.url}/gone"},
               missing_path,
               req_options: [retry: false]
             )

    refute File.exists?(missing_path)
  end

  @tag :tmp_dir
  test "download_to_file/3 truncates partial file before Req retry after mid-stream TCP close",
       %{tmp_dir: tmp_dir} do
    media_key = :binary.copy(<<12>>, 32)
    long_plaintext = String.duplicate("attempt-one-much-longer-payload-", 40)
    short_plaintext = "attempt-two-short-clean-payload!"

    assert {:ok, %{encrypted_path: long_encrypted_path}} =
             Crypto.encrypt(long_plaintext, :image, media_key: media_key, tmp_dir: tmp_dir)

    assert {:ok, %{encrypted_path: short_encrypted_path}} =
             Crypto.encrypt(short_plaintext, :image, media_key: media_key, tmp_dir: tmp_dir)

    long_encrypted = File.read!(long_encrypted_path)
    short_encrypted = File.read!(short_encrypted_path)
    first_partial = binary_part(long_encrypted, 0, 256)
    short_chunks = chunk_binary(short_encrypted, 17)
    ranged_partial = binary_part(long_encrypted, 0, 80)
    ranged_chunks = chunk_binary(binary_part(long_encrypted, 0, 49), 13)
    retry_path = Path.join(tmp_dir, "retried-output.bin")
    ranged_retry_path = Path.join(tmp_dir, "retried-ranged-output.bin")
    {:ok, attempts} = Agent.start_link(fn -> 0 end)
    {:ok, ranged_attempts} = Agent.start_link(fn -> 0 end)
    {:ok, sizes_before_retry} = Agent.start_link(fn -> %{} end)

    {:ok, server} =
      LoopbackHTTPServer.start(fn req ->
        case req.path do
          "/flaky" ->
            case Agent.get_and_update(attempts, fn n -> {n + 1, n + 1} end) do
              1 ->
                {200, [{"content-type", "application/octet-stream"}],
                 {:truncate_after, first_partial}}

              _ ->
                size = File.stat!(retry_path).size
                Agent.update(sizes_before_retry, &Map.put(&1, :full, size))
                {200, [{"content-type", "application/octet-stream"}], short_chunks}
            end

          "/flaky-ranged" ->
            case Agent.get_and_update(ranged_attempts, fn n -> {n + 1, n + 1} end) do
              1 ->
                {206, [{"content-type", "application/octet-stream"}],
                 {:truncate_after, ranged_partial}}

              _ ->
                size = File.stat!(ranged_retry_path).size
                Agent.update(sizes_before_retry, &Map.put(&1, :ranged, size))
                {206, [{"content-type", "application/octet-stream"}], ranged_chunks}
            end

          "/redirect" ->
            {302, [{"location", "/final"}], "moved"}

          "/redirect-empty-gone" ->
            {302, [{"location", "/empty-gone"}], "moved"}

          "/empty-gone" ->
            {410, [{"content-type", "text/plain"}], ""}

          "/final" ->
            {200, [{"content-type", "application/octet-stream"}], short_chunks}
        end
      end)

    on_exit(server.stop)

    # 1. Attempt 1 writes > byte_size(short_plaintext) before closing; attempt 2 writes the
    # shorter payload, proving truncate (not just rewind) cleared the leftover bytes.
    assert {:ok, ^retry_path} =
             Download.download_to_file(
               %Message.ImageMessage{media_key: media_key, url: "#{server.url}/flaky"},
               retry_path,
               req_options: [
                 headers: %{"X-Test-Header" => "retry-map"},
                 retry: :safe_transient,
                 retry_delay: fn _ -> 5 end,
                 retry_log_level: false
               ]
             )

    assert Agent.get(attempts, & &1) == 2
    assert Agent.get(sizes_before_retry, & &1[:full]) > byte_size(short_plaintext)
    assert File.read!(retry_path) == short_plaintext

    # 2. Mid-stream TCP close on ranged 206 retry also truncates partial file cleanly
    assert {:ok, ^ranged_retry_path} =
             Download.download_to_file(
               %Message.ImageMessage{media_key: media_key, url: "#{server.url}/flaky-ranged"},
               ranged_retry_path,
               start_byte: 20,
               end_byte: 32,
               req_options: [
                 retry: :safe_transient,
                 retry_delay: fn _ -> 5 end,
                 retry_log_level: false
               ]
             )

    assert Agent.get(ranged_attempts, & &1) == 2
    assert Agent.get(sizes_before_retry, & &1[:ranged]) > 0
    assert File.read!(ranged_retry_path) == binary_part(long_plaintext, 20, 12)

    # 3. 302 redirect -> 200 streams cleanly without corrupting decrypt state
    redirect_path = Path.join(tmp_dir, "redirect-output.bin")

    assert {:ok, ^redirect_path} =
             Download.download_to_file(
               %Message.ImageMessage{media_key: media_key, url: "#{server.url}/redirect"},
               redirect_path,
               req_options: [retry: false]
             )

    assert File.read!(redirect_path) == short_plaintext

    # 4. 302 redirect with body -> 410 empty body does not leak the 302 body
    assert {:error, {:http_error, 410, ""}} =
             Download.download(
               %Message.ImageMessage{
                 media_key: media_key,
                 url: "#{server.url}/redirect-empty-gone"
               },
               req_options: [retry: false]
             )
  end

  defmodule BufferedAdapter do
    @moduledoc false

    def run(req) do
      fun = Process.get(:baileys_ex_buffered_adapter_fun)
      fun.(req)
    end

    def stream(req, acc, _fun, state) do
      {req, resp} = run(req)
      {:ok, Map.put(resp, :request, req), acc, state}
    end
  end

  @tag :tmp_dir
  test "buffered Req adapter decrypts 200 ciphertext and caps 410 error body to 64 KiB",
       %{tmp_dir: tmp_dir} do
    media_key = :binary.copy(<<13>>, 32)
    plaintext = "buffered-adapter-decryption-payload-across-blocks"

    assert {:ok, %{encrypted_path: encrypted_path}} =
             Crypto.encrypt(plaintext, :image, media_key: media_key, tmp_dir: tmp_dir)

    encrypted = File.read!(encrypted_path)

    Process.put(:baileys_ex_buffered_adapter_fun, fn req ->
      {req, Req.Response.new(status: 200, body: encrypted)}
    end)

    assert {:ok, ^plaintext} =
             Download.download(
               %Message.ImageMessage{
                 media_key: media_key,
                 url: "https://mmg.whatsapp.net/buffered"
               },
               req_options: [adapter: BufferedAdapter, retry: false]
             )

    oversized_error = String.duplicate("e", 70_000)

    Process.put(:baileys_ex_buffered_adapter_fun, fn req ->
      {req, Req.Response.new(status: 410, body: oversized_error)}
    end)

    assert {:error, {:http_error, 410, capped_body}} =
             Download.download(
               %Message.ImageMessage{
                 media_key: media_key,
                 url: "https://mmg.whatsapp.net/buffered-gone"
               },
               req_options: [adapter: BufferedAdapter, retry: false]
             )

    assert byte_size(capped_body) == 65_536
  end

  test "custom request_fun returns error tuple on mid-stream 410 close and cancels bounded async once" do
    media_key = :binary.copy(<<14>>, 32)

    {:ok, server} =
      LoopbackHTTPServer.start(fn _req ->
        {410, [{"content-type", "text/plain"}], {:truncate_after, "partial-410"}}
      end)

    on_exit(server.stop)

    assert {:error, _transport_reason} =
             Download.download(
               %Message.ImageMessage{media_key: media_key, url: "#{server.url}/broken-410"},
               req_options: [retry: false],
               request_fun: &Req.get/1
             )

    # Bounded async error response must call cancel_fun exactly once when hitting 64 KiB cap
    {:ok, cancel_counter} = Agent.start_link(fn -> 0 end)
    ref = make_ref()

    stream_fun = fn
      ^ref, {^ref, {:data, chunk}} -> {:ok, [data: chunk]}
      ^ref, {^ref, :done} -> {:ok, [:done]}
    end

    cancel_fun = fn ^ref ->
      count = Agent.get_and_update(cancel_counter, fn n -> {n + 1, n + 1} end)
      if count > 1, do: raise("cancel_fun called #{count} times")
      :ok
    end

    request_fun = fn _opts ->
      send(self(), {ref, {:data, String.duplicate("a", 40_000)}})
      send(self(), {ref, {:data, String.duplicate("b", 40_000)}})
      send(self(), {ref, {:data, String.duplicate("c", 10_000)}})
      send(self(), {ref, :done})

      {:ok,
       %Req.Response{
         status: 410,
         body: %Req.Response.Async{
           pid: self(),
           ref: ref,
           stream_fun: stream_fun,
           cancel_fun: cancel_fun
         }
       }}
    end

    assert {:error, {:http_error, 410, capped_body}} =
             Download.download(
               %Message.ImageMessage{
                 media_key: media_key,
                 url: "https://mmg.whatsapp.net/async-capped"
               },
               request_fun: request_fun
             )

    assert byte_size(capped_body) == 65_536
    assert Agent.get(cancel_counter, & &1) == 1
  end

  defp chunk_binary(binary, chunk_size) do
    Stream.unfold(binary, fn
      <<>> -> nil
      data when byte_size(data) <= chunk_size -> {data, <<>>}
      <<chunk::binary-size(^chunk_size), rest::binary>> -> {chunk, rest}
    end)
    |> Enum.to_list()
  end
end
