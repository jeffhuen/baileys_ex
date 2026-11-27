defmodule BaileysEx.Media.ReqDefaultsTest do
  use ExUnit.Case, async: false

  alias BaileysEx.BinaryNode
  alias BaileysEx.Connection.Version
  alias BaileysEx.Media.Crypto
  alias BaileysEx.Media.Download
  alias BaileysEx.Media.Upload
  alias BaileysEx.Protocol.Proto.Message
  alias BaileysEx.TestHelpers.LoopbackHTTPServer

  @tag :tmp_dir
  test "Version, Download, and Upload ignore global Req.default_options(into: :self, compressed: true)",
       %{tmp_dir: tmp_dir} do
    previous_defaults = Req.default_options()
    Req.default_options(into: :self, compressed: true, decode_body: true)
    on_exit(fn -> Req.default_options(previous_defaults) end)

    media_key = :binary.copy(<<15>>, 32)
    plaintext = "global-req-defaults-isolation-payload"

    assert {:ok, %{encrypted_path: encrypted_path}} =
             Crypto.encrypt(plaintext, :image, media_key: media_key, tmp_dir: tmp_dir)

    encrypted = File.read!(encrypted_path)

    parent = self()

    {:ok, server} =
      LoopbackHTTPServer.start(fn req ->
        send(parent, {:req_defaults_http, req.path, req.headers})

        case req.path do
          "/version" ->
            {200, [{"content-type", "text/plain"}], "const version = [2, 3000, 777666555]"}

          "/media" ->
            {200, [{"content-type", "application/octet-stream"}], encrypted}

          "/upload" ->
            {200, [{"content-type", "application/json"}],
             JSON.encode!(%{
               "url" => "https://mmg.whatsapp.net/mms/image/default-safe",
               "direct_path" => "/mms/image/default-safe"
             })}
        end
      end)

    on_exit(server.stop)

    assert %{version: [2, 3000, 777_666_555], is_latest: true} =
             Version.fetch_latest_baileys_version(
               url: "#{server.url}/version",
               req_options: [retry: false]
             )

    assert_receive {:req_defaults_http, "/version", version_headers}
    refute Map.has_key?(version_headers, "accept-encoding")
    refute_receive {_, {:data, _}}, 100

    assert {:ok, ^plaintext} =
             Download.download(
               %Message.ImageMessage{media_key: media_key, url: "#{server.url}/media"},
               req_options: [retry: false]
             )

    assert_receive {:req_defaults_http, "/media", media_headers}
    refute Map.has_key?(media_headers, "accept-encoding")
    refute_receive {_, {:data, _}}, 100

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

    assert {:ok, %{direct_path: "/mms/image/default-safe"}} =
             Upload.upload(host_query, encrypted_path, :image,
               file_enc_sha256: <<3::256>>,
               req_options: [retry: false],
               request_fun: fn req_opts ->
                 Req.post(Keyword.put(req_opts, :url, "#{server.url}/upload"))
               end
             )

    refute_receive {_, {:data, _}}, 100
  end
end
