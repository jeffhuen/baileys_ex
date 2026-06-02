defmodule BaileysEx.Auth.QRTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Auth.QR
  alias BaileysEx.Connection.Config
  alias BaileysEx.Auth.State

  test "generate/2 emits the rc13 linked-devices URL payload" do
    state = auth_state(1)

    assert [
             "ref-rc13",
             Base.encode64(state.noise_key.public),
             Base.encode64(state.signed_identity_key.public),
             Base.encode64(state.adv_secret_key),
             "1"
           ] == qr_parts(QR.generate("ref-rc13", state))
  end

  test "generate/3 maps the configured browser to the companion platform id" do
    state = auth_state(2)

    assert List.last(
             qr_parts(
               QR.generate("chrome", state, Config.new(browser: {"Mac OS", "Chrome", "14.4.1"}))
             )
           ) ==
             "1"

    assert List.last(
             qr_parts(
               QR.generate("edge", state, Config.new(browser: {"Windows", "Edge", "10.0.22631"}))
             )
           ) ==
             "2"

    assert List.last(qr_parts(QR.generate("firefox", state, {"Linux", "Firefox", "24.04"}))) ==
             "3"

    assert List.last(
             qr_parts(QR.generate("desktop-windows", state, {"Windows", "Desktop", "10.0.22631"}))
           ) ==
             "8"

    assert List.last(qr_parts(QR.generate("desktop-mac", state, {"Mac OS", "Desktop", "14.4.1"}))) ==
             "7"

    assert List.last(qr_parts(QR.generate("other", state, {"Linux", "Brave", "1.0"}))) ==
             "9"
  end

  test "generate/2 reuses a base64 adv secret without double encoding it" do
    state = %State{
      noise_key: %{public: <<1::256>>, private: <<2::256>>},
      signed_identity_key: %{public: <<3::256>>, private: <<4::256>>},
      adv_secret_key: Base.encode64(<<5::256>>)
    }

    assert [ref, noise_key, identity_key, adv_secret_key, platform_id] =
             qr_parts(QR.generate("ref-1", state))

    assert ref == "ref-1"
    assert noise_key == Base.encode64(state.noise_key.public)
    assert identity_key == Base.encode64(state.signed_identity_key.public)
    assert adv_secret_key == state.adv_secret_key
    assert platform_id == "1"
  end

  test "generate/2 encodes raw adv secrets like Baileys pair-device flow" do
    raw_adv_secret_key = <<6::256>>

    auth_state = %{
      noise_key: %{public: <<7::256>>, private: <<8::256>>},
      signed_identity_key: %{
        public: <<9::256>>,
        private: <<10::256>>
      },
      adv_secret_key: raw_adv_secret_key
    }

    assert [_ref, _noise_key, _identity_key, adv_secret_key, _platform_id] =
             qr_parts(QR.generate("ref-2", auth_state))

    assert adv_secret_key == Base.encode64(raw_adv_secret_key)
  end

  defp auth_state(seed) do
    %State{
      noise_key: %{public: <<seed::256>>, private: <<seed + 1::256>>},
      signed_identity_key: %{public: <<seed + 2::256>>, private: <<seed + 3::256>>},
      adv_secret_key: <<seed + 4::256>>
    }
  end

  defp qr_parts(payload) do
    assert "https://wa.me/settings/linked_devices#" <> data = payload
    String.split(data, ",")
  end
end
