defmodule BaileysEx.Connection.VersionTest do
  use ExUnit.Case, async: true

  alias BaileysEx
  alias BaileysEx.Connection.Version

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
end
