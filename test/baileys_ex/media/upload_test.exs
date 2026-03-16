defmodule BaileysEx.Media.UploadTest do
  use ExUnit.Case, async: true

  alias BaileysEx.BinaryNode
  alias BaileysEx.Connection.Store
  alias BaileysEx.Media.Upload
  alias BaileysEx.TestHelpers.TelemetryHelpers

  test "refresh_media_conn/2 issues the w:m media_conn iq and parses the response" do
    parent = self()

    query_fun = fn %BinaryNode{} = node, timeout ->
      send(parent, {:query, node, timeout})

      {:ok,
       %BinaryNode{
         tag: "iq",
         attrs: %{"type" => "result"},
         content: [
           %BinaryNode{
             tag: "media_conn",
             attrs: %{"auth" => "auth-token", "ttl" => "3600"},
             content: [
               %BinaryNode{
                 tag: "host",
                 attrs: %{
                   "hostname" => "upload.example.com",
                   "maxContentLengthBytes" => "1048576"
                 }
               }
             ]
           }
         ]
       }}
    end

    assert {:ok, media_conn} =
             Upload.refresh_media_conn(query_fun, now_fun: fn -> ~U[2026-03-13 00:00:00Z] end)

    assert_receive {:query,
                    %BinaryNode{
                      tag: "iq",
                      attrs: %{
                        "type" => "set",
                        "xmlns" => "w:m",
                        "to" => "s.whatsapp.net"
                      },
                      content: [%BinaryNode{tag: "media_conn", attrs: %{}}]
                    }, 60_000}

    assert %{
             auth: "auth-token",
             ttl: 3600,
             fetch_date: ~U[2026-03-13 00:00:00Z],
             hosts: [%{hostname: "upload.example.com", max_content_length_bytes: 1_048_576}]
           } = media_conn
  end

  test "refresh_media_conn/2 reuses a cached media_conn when it is still valid" do
    {:ok, store} = Store.start_link()
    store_ref = Store.wrap(store)

    cached = %{
      auth: "cached-auth",
      ttl: 3600,
      fetch_date: ~U[2026-03-13 00:00:00Z],
      hosts: [%{hostname: "cached.example.com", max_content_length_bytes: 1024}]
    }

    assert :ok = Store.put(store_ref, :media_conn, cached)

    query_fun = fn _node, _timeout ->
      flunk("refresh_media_conn/2 should not query when the cache entry is still valid")
    end

    assert {:ok, ^cached} =
             Upload.refresh_media_conn(query_fun,
               store_ref: store_ref,
               now_fun: fn -> ~U[2026-03-13 00:10:00Z] end
             )
  end

  @tag :tmp_dir
  test "upload/4 posts the encrypted file to the resolved CDN path", %{tmp_dir: tmp_dir} do
    parent = self()
    enc_path = Path.join(tmp_dir, "enc.bin")
    File.write!(enc_path, "ciphertext-with-mac")
    file_enc_sha256 = :crypto.hash(:sha256, "ciphertext-with-mac")

    query_fun = fn _node, _timeout ->
      {:ok,
       %BinaryNode{
         tag: "iq",
         attrs: %{"type" => "result"},
         content: [
           %BinaryNode{
             tag: "media_conn",
             attrs: %{"auth" => "auth-token", "ttl" => "3600"},
             content: [%BinaryNode{tag: "host", attrs: %{"hostname" => "upload.example.com"}}]
           }
         ]
       }}
    end

    request_fun = fn request ->
      uri = URI.parse(request[:url])
      body = request[:body] |> Enum.to_list() |> IO.iodata_to_binary()

      send(parent, {
        :upload_request,
        uri.host,
        uri.path,
        uri.query,
        body,
        List.wrap(request[:headers])
      })

      {:ok,
       %Req.Response{
         status: 200,
         body: %{
           "url" => "https://mmg.whatsapp.net/mms/image/abc123",
           "direct_path" => "/mms/image/abc123",
           "meta_hmac" => "meta-hmac",
           "ts" => "1710000000",
           "fbid" => "42"
         }
       }}
    end

    assert {:ok,
            %{
              media_url: "https://mmg.whatsapp.net/mms/image/abc123",
              direct_path: "/mms/image/abc123",
              meta_hmac: "meta-hmac",
              ts: 1_710_000_000,
              fbid: 42
            }} =
             Upload.upload(query_fun, enc_path, :image,
               file_enc_sha256: file_enc_sha256,
               request_fun: request_fun
             )

    token = "-7Gr5yBsToK49ZMobsMBDIB3BgQ1zyp5NsKfEEJ0LdY"

    assert_receive {:upload_request, "upload.example.com", request_path, query_string,
                    "ciphertext-with-mac", headers}

    assert request_path == "/mms/image/#{token}"
    assert query_string == "auth=auth-token&token=#{token}"

    assert {"content-type", "application/octet-stream"} in headers
    assert {"origin", "https://web.whatsapp.com"} in headers
  end

  @tag :tmp_dir
  test "upload/4 emits telemetry for successful uploads", %{tmp_dir: tmp_dir} do
    enc_path = Path.join(tmp_dir, "enc.bin")
    File.write!(enc_path, "ciphertext-with-mac")
    file_enc_sha256 = :crypto.hash(:sha256, "ciphertext-with-mac")

    telemetry_id =
      TelemetryHelpers.attach_events(self(), [
        [:baileys_ex, :media, :upload, :start],
        [:baileys_ex, :media, :upload, :stop]
      ])

    on_exit(fn -> TelemetryHelpers.detach(telemetry_id) end)

    query_fun = fn _node, _timeout ->
      {:ok,
       %BinaryNode{
         tag: "iq",
         attrs: %{"type" => "result"},
         content: [
           %BinaryNode{
             tag: "media_conn",
             attrs: %{"auth" => "auth-token", "ttl" => "3600"},
             content: [%BinaryNode{tag: "host", attrs: %{"hostname" => "upload.example.com"}}]
           }
         ]
       }}
    end

    request_fun = fn _request ->
      {:ok,
       %Req.Response{
         status: 200,
         body: %{
           "url" => "https://mmg.whatsapp.net/mms/image/abc123",
           "direct_path" => "/mms/image/abc123"
         }
       }}
    end

    assert {:ok, %{direct_path: "/mms/image/abc123"}} =
             Upload.upload(query_fun, enc_path, :image,
               file_enc_sha256: file_enc_sha256,
               request_fun: request_fun
             )

    assert_receive {:telemetry, [:baileys_ex, :media, :upload, :start],
                    %{system_time: system_time}, %{media_type: :image, path: ^enc_path}}

    assert is_integer(system_time)

    assert_receive {:telemetry, [:baileys_ex, :media, :upload, :stop], %{duration: duration},
                    %{media_type: :image, path: ^enc_path, status: :ok}}

    assert is_integer(duration)
  end

  @tag :tmp_dir
  test "upload/4 retries subsequent media hosts when the first upload attempt fails",
       %{tmp_dir: tmp_dir} do
    parent = self()
    enc_path = Path.join(tmp_dir, "enc.bin")
    File.write!(enc_path, "ciphertext-with-mac")
    file_enc_sha256 = :crypto.hash(:sha256, "ciphertext-with-mac")

    query_fun = fn _node, _timeout ->
      {:ok,
       %BinaryNode{
         tag: "iq",
         attrs: %{"type" => "result"},
         content: [
           %BinaryNode{
             tag: "media_conn",
             attrs: %{"auth" => "auth-token", "ttl" => "3600"},
             content: [
               %BinaryNode{tag: "host", attrs: %{"hostname" => "upload-1.example.com"}},
               %BinaryNode{tag: "host", attrs: %{"hostname" => "upload-2.example.com"}}
             ]
           }
         ]
       }}
    end

    request_fun = fn request ->
      uri = URI.parse(request[:url])
      send(parent, {:upload_host_attempt, uri.host})

      case uri.host do
        "upload-1.example.com" ->
          {:error, :econnrefused}

        "upload-2.example.com" ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{
               "url" => "https://mmg.whatsapp.net/mms/image/retried",
               "direct_path" => "/mms/image/retried"
             }
           }}
      end
    end

    assert {:ok, %{direct_path: "/mms/image/retried"}} =
             Upload.upload(query_fun, enc_path, :image,
               file_enc_sha256: file_enc_sha256,
               request_fun: request_fun
             )

    assert_receive {:upload_host_attempt, "upload-1.example.com"}
    assert_receive {:upload_host_attempt, "upload-2.example.com"}
  end

  @tag :tmp_dir
  test "upload/4 returns explicit errors for missing host, file hash, unsupported path, and HTTP failures",
       %{tmp_dir: tmp_dir} do
    enc_path = Path.join(tmp_dir, "enc.bin")
    File.write!(enc_path, "ciphertext-with-mac")

    no_host_query = fn _node, _timeout ->
      {:ok,
       %BinaryNode{
         tag: "iq",
         attrs: %{"type" => "result"},
         content: [
           %BinaryNode{tag: "media_conn", attrs: %{"auth" => "auth-token", "ttl" => "3600"}}
         ]
       }}
    end

    assert {:error, :missing_upload_host} =
             Upload.upload(no_host_query, enc_path, :image, file_enc_sha256: <<1::256>>)

    host_query = fn _node, _timeout ->
      {:ok,
       %BinaryNode{
         tag: "iq",
         attrs: %{"type" => "result"},
         content: [
           %BinaryNode{
             tag: "media_conn",
             attrs: %{"auth" => "auth-token", "ttl" => "3600"},
             content: [%BinaryNode{tag: "host", attrs: %{"hostname" => "upload.example.com"}}]
           }
         ]
       }}
    end

    assert {:error, :missing_file_enc_sha256} = Upload.upload(host_query, enc_path, :image)

    assert {:error, :unsupported_media_type} =
             Upload.upload(host_query, enc_path, :md_app_state, file_enc_sha256: <<1::256>>)

    assert {:error, {:http_error, 500, "nope"}} =
             Upload.upload(host_query, enc_path, :image,
               file_enc_sha256: <<1::256>>,
               request_fun: fn _request -> {:ok, %Req.Response{status: 500, body: "nope"}} end
             )
  end
end
