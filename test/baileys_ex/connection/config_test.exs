defmodule BaileysEx.Connection.ConfigTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Connection.Config

  test "new/1 returns the default transport configuration" do
    config = Config.new()

    assert config.ws_url == "wss://web.whatsapp.com/ws/chat"
    assert config.keep_alive_interval_ms == 25_000
    assert config.default_query_timeout_ms == 60_000
    assert config.retry_request_delay_ms == 250
    assert config.max_msg_retry_count == 5
    assert config.retry_delay_ms == 2_000
    assert config.reconnect_policy == :disabled
    assert config.max_retries == 5
    assert config.connect_timeout_ms == 20_000
    assert config.initial_sync_timeout_ms == 20_000
    assert config.pairing_qr_timeout_ms == nil
    assert config.pairing_qr_initial_timeout_ms == 60_000
    assert config.pairing_qr_refresh_timeout_ms == 20_000
    assert config.fire_init_queries == true
    assert config.mark_online_on_connect == true
    assert config.enable_auto_session_recreation == true
    assert config.enable_recent_message_cache == true
    assert config.browser == {"Mac OS", "Chrome", "14.4.1"}
    assert config.version == [2, 3000, 1_033_846_690]
    assert config.country_code == "US"
    assert config.sync_full_history == true
    assert config.validate_snapshot_macs == false
    assert config.validate_patch_macs == false
    assert config.print_qr_in_terminal == false
    assert config.should_sync_history_message.(%{sync_type: :RECENT}) == true
    assert config.should_sync_history_message.(%{sync_type: :FULL}) == false
  end

  test "new/1 applies overrides" do
    should_sync_history_message = fn %{sync_type: sync_type} -> sync_type == :ON_DEMAND end

    config =
      Config.new(
        ws_url: "wss://example.test/ws",
        keep_alive_interval_ms: 5_000,
        default_query_timeout_ms: 15_000,
        initial_sync_timeout_ms: 10_000,
        pairing_qr_timeout_ms: 30_000,
        pairing_qr_initial_timeout_ms: 45_000,
        pairing_qr_refresh_timeout_ms: 15_000,
        retry_request_delay_ms: 500,
        max_msg_retry_count: 7,
        reconnect_policy: :restart_required,
        max_retries: 2,
        fire_init_queries: false,
        mark_online_on_connect: false,
        enable_auto_session_recreation: false,
        enable_recent_message_cache: false,
        browser: {"Ubuntu", "Firefox", "24.04"},
        version: [2, 24, 7],
        country_code: "GB",
        sync_full_history: false,
        validate_snapshot_macs: true,
        validate_patch_macs: true,
        should_sync_history_message: should_sync_history_message
      )

    assert config.ws_url == "wss://example.test/ws"
    assert config.keep_alive_interval_ms == 5_000
    assert config.default_query_timeout_ms == 15_000
    assert config.initial_sync_timeout_ms == 10_000
    assert config.pairing_qr_timeout_ms == 30_000
    assert config.pairing_qr_initial_timeout_ms == 45_000
    assert config.pairing_qr_refresh_timeout_ms == 15_000
    assert config.retry_request_delay_ms == 500
    assert config.max_msg_retry_count == 7
    assert config.reconnect_policy == :restart_required
    assert config.max_retries == 2
    assert config.fire_init_queries == false
    assert config.mark_online_on_connect == false
    assert config.enable_auto_session_recreation == false
    assert config.enable_recent_message_cache == false
    assert config.browser == {"Ubuntu", "Firefox", "24.04"}
    assert config.version == [2, 24, 7]
    assert config.country_code == "GB"
    assert config.sync_full_history == false
    assert config.validate_snapshot_macs == true
    assert config.validate_patch_macs == true
    assert config.should_sync_history_message.(%{sync_type: :ON_DEMAND}) == true
    assert config.should_sync_history_message.(%{sync_type: :RECENT}) == false
  end

  test "platform_type/1 maps browsers and host platforms to the expected atoms" do
    assert Config.platform_type("Chrome") == :CHROME
    assert Config.platform_type("Firefox") == :FIREFOX
    assert Config.platform_type("Mac OS") == :DARWIN
    assert Config.platform_type("Linux") == :LINUX
    assert Config.platform_type("Something Else") == :UNKNOWN
  end

  test "single pairing_qr_timeout_ms override matches Baileys semantics for initial and refresh" do
    config = Config.new(pairing_qr_timeout_ms: 12_345)

    assert Config.pairing_qr_initial_timeout(config) == 12_345
    assert Config.pairing_qr_refresh_timeout(config) == 12_345
  end

  test "should_reconnect?/3 honors the configured reconnect policy and retry cap" do
    disabled = Config.new()
    restart_only = Config.new(reconnect_policy: :restart_required, max_retries: 1)
    all_non_logged_out = Config.new(reconnect_policy: :all_non_logged_out, max_retries: 2)

    refute Config.should_reconnect?(disabled, :restart_required, 1)

    assert Config.should_reconnect?(restart_only, :restart_required, 1)
    refute Config.should_reconnect?(restart_only, :tcp_closed, 1)
    refute Config.should_reconnect?(restart_only, :restart_required, 2)

    assert Config.should_reconnect?(all_non_logged_out, :connection_lost, 1)
    refute Config.should_reconnect?(all_non_logged_out, :logged_out, 1)
    refute Config.should_reconnect?(all_non_logged_out, :connection_lost, 3)
  end
end
