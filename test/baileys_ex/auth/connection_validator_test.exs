defmodule BaileysEx.Auth.ConnectionValidatorTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Auth.ConnectionValidator
  alias BaileysEx.Auth.State
  alias BaileysEx.Connection.Config
  alias BaileysEx.Protocol.Proto.ClientPayload
  alias BaileysEx.Protocol.Proto.DeviceProps

  test "generate_login_node/2 builds the rc9 passive login payload" do
    config =
      Config.new(
        version: [2, 3000, 1_033_846_690],
        country_code: "GB",
        browser: {"Mac OS", "Chrome", "14.4.1"}
      )

    assert {:ok, payload} =
             ConnectionValidator.generate_login_node("15551234567:7@s.whatsapp.net", config)

    encoded = ClientPayload.encode(payload)
    assert {:ok, decoded} = ClientPayload.decode(encoded)

    assert decoded.username == 15_551_234_567
    assert decoded.device == 7
    assert decoded.passive == true
    assert decoded.pull == true
    assert decoded.lid_db_migrated == false
    assert decoded.connect_type == 1
    assert decoded.connect_reason == 1
    assert decoded.user_agent.platform == 14
    assert decoded.user_agent.release_channel == 0
    assert decoded.user_agent.app_version.primary == 2
    assert decoded.user_agent.app_version.secondary == 3000
    assert decoded.user_agent.app_version.tertiary == 1_033_846_690
    assert decoded.user_agent.locale_country_iso31661_alpha2 == "GB"
    assert decoded.web_info.web_sub_platform == 0
  end

  test "generate_login_node/2 uses desktop web sub platform only for full-history desktop builds" do
    config =
      Config.new(
        sync_full_history: true,
        browser: {"Windows", "Desktop", "10.0.22631"}
      )

    assert {:ok, payload} =
             ConnectionValidator.generate_login_node("15551234567@s.whatsapp.net", config)

    encoded = ClientPayload.encode(payload)
    assert {:ok, decoded} = ClientPayload.decode(encoded)
    assert decoded.web_info.web_sub_platform == 4
  end

  test "generate_registration_node/2 includes device props and pairing registration data" do
    state = State.new()

    config =
      Config.new(
        version: [2, 24, 7],
        sync_full_history: true,
        browser: {"Windows", "Edge", "10.0.22631"}
      )

    assert {:ok, payload} = ConnectionValidator.generate_registration_node(state, config)

    encoded = ClientPayload.encode(payload)
    assert {:ok, decoded} = ClientPayload.decode(encoded)

    assert decoded.passive == false
    assert decoded.pull == false
    assert decoded.connect_type == 1
    assert decoded.connect_reason == 1

    assert reg = decoded.device_pairing_data
    assert reg.build_hash == :crypto.hash(:md5, "2.24.7")
    assert reg.e_regid == <<state.registration_id::unsigned-big-integer-size(32)>>
    assert reg.e_keytype == <<5>>
    assert reg.e_ident == state.signed_identity_key.public
    assert reg.e_skey_id == <<state.signed_pre_key.key_id::unsigned-big-integer-size(24)>>
    assert reg.e_skey_val == state.signed_pre_key.key_pair.public
    assert reg.e_skey_sig == state.signed_pre_key.signature

    assert {:ok, companion} = DeviceProps.decode(reg.device_props)
    assert companion.os == "Windows"
    assert companion.platform_type == 6
    assert companion.require_full_sync == true
    assert companion.version.primary == 10
    assert companion.version.secondary == 15
    assert companion.version.tertiary == 7
    assert companion.history_sync_config.storage_quota_mb == 10_240
    assert companion.history_sync_config.inline_initial_payload_in_e2_ee_msg == true
    assert companion.history_sync_config.support_message_association == true
    assert companion.history_sync_config.support_group_history == false
  end
end
