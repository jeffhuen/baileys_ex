defmodule BaileysEx.Connection.VersionTest do
  use ExUnit.Case, async: true

  alias BaileysEx
  alias BaileysEx.Connection.Version
  alias BaileysEx.TestHelpers.LoopbackHTTPServer

  test "fetch_latest_baileys_version/1 parses the published Defaults version" do
    body = """
    import something from 'elsewhere'
    const ignored = true
    const version = [2, 3000, 123456789]
    export default {}
    """

    assert %{version: [2, 3000, 123_456_789], is_latest: true} =
             Version.fetch_latest_baileys_version(
               fetch_fun: fn _url, _opts -> {:ok, %{status: 200, body: body}} end
             )
  end

  test "fetch_latest_baileys_version/1 falls back to the configured default on fetch failure" do
    assert %{version: [9, 9, 9], is_latest: false, error: :timeout} =
             Version.fetch_latest_baileys_version(
               default_version: [9, 9, 9],
               fetch_fun: fn _url, _opts -> {:error, :timeout} end
             )
  end

  test "fetch_latest_baileys_version/1 uses the rc14 default when no override is supplied" do
    assert %{
             version: [2, 3000, 1_043_857_760],
             is_latest: false,
             error: :timeout
           } =
             Version.fetch_latest_baileys_version(
               fetch_fun: fn _url, _opts -> {:error, :timeout} end
             )
  end

  test "fetch_latest_wa_web_version/1 parses the service worker client revision" do
    body = ~s(self.__WB_MANIFEST=[]; var data = {"client_revision": 987654321};)

    assert %{version: [2, 3000, 987_654_321], is_latest: true} =
             Version.fetch_latest_wa_web_version(
               fetch_fun: fn _url, _opts -> {:ok, %{status: 200, body: body}} end
             )
  end

  test "Baileys helpers are exposed through the public facade" do
    assert %{version: [2, 3000, 444], is_latest: true} =
             BaileysEx.fetch_latest_baileys_version(
               fetch_fun: fn _url, _opts ->
                 {:ok, %{status: 200, body: "const version = [2, 3000, 444]"}}
               end
             )

    assert %{version: [2, 3000, 555], is_latest: true} =
             BaileysEx.fetch_latest_wa_web_version(
               fetch_fun: fn _url, _opts ->
                 {:ok, %{status: 200, body: ~s({"client_revision": 555})}}
               end
             )
  end

  test "default_fetch uses Req over real HTTP with raw: true, atom header overrides, and retry: false" do
    parent = self()
    {:ok, unavailable_attempts} = Agent.start_link(fn -> 0 end)

    {:ok, server} =
      LoopbackHTTPServer.start(fn req ->
        send(parent, {:version_http_request, req.path, req.headers})

        case req.path do
          "/baileys" ->
            {200, [{"content-type", "text/plain"}], "const version = [2, 3000, 999888777]"}

          "/sw.js" ->
            {200, [{"content-type", "application/json"}], ~s({"client_revision": 444555666})}

          "/unavailable" ->
            Agent.update(unavailable_attempts, &(&1 + 1))
            {503, [{"content-type", "text/plain"}], "try later"}
        end
      end)

    on_exit(server.stop)

    assert %{version: [2, 3000, 999_888_777], is_latest: true} =
             Version.fetch_latest_baileys_version(
               url: "#{server.url}/baileys",
               req_options: [retry: false]
             )

    assert_receive {:version_http_request, "/baileys", _headers}

    # Even when server claims application/json, raw: true preserves the binary body for regex parsing,
    # and atom :user_agent overrides the default "user-agent" without sending a duplicate "user_agent".
    assert %{version: [2, 3000, 444_555_666], is_latest: true} =
             Version.fetch_latest_wa_web_version(
               url: "#{server.url}/sw.js",
               req_options: [
                 headers: %{"X_Literal" => "kept", user_agent: "CustomAgent/1.0"},
                 retry: false
               ]
             )

    assert_receive {:version_http_request, "/sw.js", sw_headers}
    assert sw_headers["sec-fetch-site"] == "none"
    assert sw_headers["user-agent"] == "CustomAgent/1.0"
    assert sw_headers["x_literal"] == "kept"
    refute Map.has_key?(sw_headers, "user_agent")

    # 503 retries by default in Req, so observing 1 attempt proves retry: false was forwarded.
    assert %{version: [1, 2, 3], is_latest: false, error: {:http_error, 503, "try later"}} =
             Version.fetch_latest_baileys_version(
               url: "#{server.url}/unavailable",
               default_version: [1, 2, 3],
               req_options: [retry: false]
             )

    assert Agent.get(unavailable_attempts, & &1) == 1

    # Charlist top-level headers remain supported, absolute URLs ignore bad base_url,
    # and relative URLs resolve against %URI{} base_url just like Req.
    assert %{version: [2, 3000, 999_888_777], is_latest: true} =
             Version.fetch_latest_baileys_version(
               url: "#{server.url}/baileys",
               headers: [{~c"user-agent", ~c"charlist-agent"}],
               req_options: [base_url: "bad-base", retry: false]
             )

    assert_receive {:version_http_request, "/baileys", %{"user-agent" => "charlist-agent"}}

    assert %{version: [2, 3000, 999_888_777], is_latest: true} =
             Version.fetch_latest_baileys_version(
               url: "/baileys",
               req_options: [base_url: URI.parse(server.url), retry: false]
             )

    assert_receive {:version_http_request, "/baileys", _headers}

    # Charlist absolute URLs and callable (0-arity fun and MFA) base_url values work too
    assert %{version: [2, 3000, 999_888_777], is_latest: true} =
             Version.fetch_latest_baileys_version(
               url: String.to_charlist("#{server.url}/baileys"),
               req_options: [retry: false]
             )

    assert_receive {:version_http_request, "/baileys", _headers}

    {:ok, base_url_calls} = Agent.start_link(fn -> 0 end)

    assert %{version: [2, 3000, 999_888_777], is_latest: true} =
             Version.fetch_latest_baileys_version(
               url: "/baileys",
               req_options: [
                 base_url: fn ->
                   Agent.update(base_url_calls, &(&1 + 1))
                   server.url
                 end,
                 retry: false
               ]
             )

    assert Agent.get(base_url_calls, & &1) == 1
    assert_receive {:version_http_request, "/baileys", _headers}

    assert %{version: [2, 3000, 999_888_777], is_latest: true} =
             Version.fetch_latest_baileys_version(
               url: "/baileys",
               req_options: [base_url: {Function, :identity, [server.url]}, retry: false]
             )

    assert_receive {:version_http_request, "/baileys", _headers}
  end

  test "default_fetch returns the fallback version map on malformed or relative URLs" do
    assert %{version: [9, 9, 9], is_latest: false, error: :invalid_url} =
             Version.fetch_latest_baileys_version(
               url: "not-a-url",
               default_version: [9, 9, 9]
             )

    assert %{version: [9, 9, 9], is_latest: false, error: :invalid_url} =
             Version.fetch_latest_wa_web_version(
               url: "/relative-only",
               default_version: [9, 9, 9]
             )
  end
end
