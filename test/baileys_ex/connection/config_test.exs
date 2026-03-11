defmodule BaileysEx.Connection.ConfigTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Connection.Config

  test "new/1 returns the default transport configuration" do
    config = Config.new()

    assert config.ws_url == "wss://web.whatsapp.com/ws/chat"
    assert config.keep_alive_interval_ms == 25_000
    assert config.default_query_timeout_ms == 60_000
    assert config.retry_delay_ms == 2_000
    assert config.max_retries == 5
    assert config.connect_timeout_ms == 20_000
    assert config.initial_sync_timeout_ms == 20_000
    assert config.fire_init_queries == true
    assert config.mark_online_on_connect == true
    assert config.browser == {"BaileysEx", "Chrome", "0.1.0"}
    assert config.print_qr_in_terminal == false
  end

  test "new/1 applies overrides" do
    config =
      Config.new(
        ws_url: "wss://example.test/ws",
        keep_alive_interval_ms: 5_000,
        default_query_timeout_ms: 15_000,
        initial_sync_timeout_ms: 10_000,
        fire_init_queries: false,
        mark_online_on_connect: false,
        browser: {"BaileysEx", "Firefox", "1.2.3"}
      )

    assert config.ws_url == "wss://example.test/ws"
    assert config.keep_alive_interval_ms == 5_000
    assert config.default_query_timeout_ms == 15_000
    assert config.initial_sync_timeout_ms == 10_000
    assert config.fire_init_queries == false
    assert config.mark_online_on_connect == false
    assert config.browser == {"BaileysEx", "Firefox", "1.2.3"}
  end

  test "platform_type/1 maps browsers and host platforms to the expected atoms" do
    assert Config.platform_type("Chrome") == :CHROME
    assert Config.platform_type("Firefox") == :FIREFOX
    assert Config.platform_type("Mac OS") == :DARWIN
    assert Config.platform_type("Linux") == :LINUX
    assert Config.platform_type("Something Else") == :UNKNOWN
  end
end
