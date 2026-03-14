defmodule BaileysEx.Auth.QRTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Auth.QR
  alias BaileysEx.Auth.State

  test "generate/2 reuses a base64 adv secret without double encoding it" do
    state = %State{
      noise_key: %{public: <<1::256>>, private: <<2::256>>},
      signed_identity_key: %{public: <<3::256>>, private: <<4::256>>},
      adv_secret_key: Base.encode64(<<5::256>>)
    }

    assert [ref, noise_key, identity_key, adv_secret_key] =
             String.split(QR.generate("ref-1", state), ",")

    assert ref == "ref-1"
    assert noise_key == Base.encode64(state.noise_key.public)
    assert identity_key == Base.encode64(state.signed_identity_key.public)
    assert adv_secret_key == state.adv_secret_key
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

    assert [_ref, _noise_key, _identity_key, adv_secret_key] =
             String.split(QR.generate("ref-2", auth_state), ",")

    assert adv_secret_key == Base.encode64(raw_adv_secret_key)
  end
end
