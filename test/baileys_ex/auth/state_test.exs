defmodule BaileysEx.Auth.StateTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Auth.State

  test "new/0 builds rc9-shaped default credentials" do
    state = State.new()

    assert %State{
             noise_key: %{public: noise_public, private: noise_private},
             pairing_ephemeral_key: %{public: pairing_public, private: pairing_private},
             signed_identity_key: %{public: identity_public, private: identity_private},
             signed_pre_key: %{
               key_pair: %{public: signed_pre_public, private: signed_pre_private},
               key_id: 1,
               signature: signed_pre_signature
             },
             registration_id: registration_id,
             adv_secret_key: adv_secret_key,
             processed_history_messages: [],
             next_pre_key_id: 1,
             first_unuploaded_pre_key_id: 1,
             account_sync_counter: 0,
             account_settings: %{unarchive_chats: false, default_disappearing_mode: nil},
             registered: false,
             pairing_code: nil,
             last_prop_hash: nil,
             routing_info: nil,
             additional_data: nil
           } = state

    assert byte_size(noise_public) == 32
    assert byte_size(noise_private) == 32
    assert byte_size(pairing_public) == 32
    assert byte_size(pairing_private) == 32
    assert byte_size(identity_public) == 32
    assert byte_size(identity_private) == 32
    assert byte_size(signed_pre_public) == 32
    assert byte_size(signed_pre_private) == 32
    assert is_binary(signed_pre_signature)

    assert registration_id >= 0
    assert registration_id <= 16_383

    assert {:ok, decoded_adv_secret_key} = Base.decode64(adv_secret_key)
    assert byte_size(decoded_adv_secret_key) == 32
  end

  test "merge_updates/2 preserves the Auth.State struct shape for flat creds updates" do
    state = State.new()

    assert %State{
             me: %{id: "15551234567@s.whatsapp.net", lid: "12345678901234@lid"},
             pairing_code: "ABCDEFGH",
             registered: true
           } =
             State.merge_updates(state, %{
               me: %{id: "15551234567@s.whatsapp.net", lid: "12345678901234@lid"},
               pairing_code: "ABCDEFGH",
               registered: true
             })
  end

  test "merge_updates/2 keeps legacy nested creds maps compatible" do
    auth_state = %{
      noise_key: %{public: <<1::256>>, private: <<2::256>>},
      creds: %{me: %{id: "15551234567@s.whatsapp.net"}}
    }

    assert %{
             creds: %{
               me: %{id: "15551234567@s.whatsapp.net", lid: "12345678901234@lid"},
               pairing_code: "ABCDEFGH"
             }
           } =
             State.merge_updates(auth_state, %{
               me: %{lid: "12345678901234@lid"},
               pairing_code: "ABCDEFGH"
             })
  end
end
