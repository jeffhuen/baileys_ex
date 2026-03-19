defmodule BaileysEx.Parity.SyncdTest do
  use BaileysEx.Parity.Case, async: true

  alias BaileysEx.Protocol.Proto.Syncd
  alias BaileysEx.Syncd.Codec
  alias BaileysEx.Syncd.Keys

  @fixture_path Path.expand("../../fixtures/parity/syncd/baileys_rc9.json", __DIR__)

  test "parity syncd fixtures pin Baileys key expansion and MAC outputs" do
    fixture = parity_fixture!()
    key_data = Base.decode64!(fixture["hkdf"]["input_base64"])
    keys = Keys.expand_app_state_keys(key_data)

    assert Base.encode16(keys.index_key, case: :lower) == fixture["hkdf"]["index_key_hex"]

    assert Base.encode16(keys.value_encryption_key, case: :lower) ==
             fixture["hkdf"]["value_encryption_key_hex"]

    assert Base.encode16(keys.value_mac_key, case: :lower) == fixture["hkdf"]["value_mac_key_hex"]

    assert Base.encode16(keys.snapshot_mac_key, case: :lower) ==
             fixture["hkdf"]["snapshot_mac_key_hex"]

    assert Base.encode16(keys.patch_mac_key, case: :lower) == fixture["hkdf"]["patch_mac_key_hex"]

    data = Base.decode64!(fixture["mac"]["data_base64"])
    key_id = Base.decode64!(fixture["mac"]["key_id_base64"])

    assert Base.encode16(Codec.generate_mac(:set, data, key_id, keys.value_mac_key), case: :lower) ==
             fixture["mac"]["value_mac_set_hex"]

    assert Base.encode16(Codec.generate_mac(:remove, data, key_id, keys.value_mac_key),
             case: :lower
           ) == fixture["mac"]["value_mac_remove_hex"]
  end

  test "parity syncd fixtures pin Baileys WAProto serialization outputs" do
    fixture = parity_fixture!()

    mutation = %Syncd.SyncdMutation{
      operation: :set,
      record: %Syncd.SyncdRecord{
        index: %Syncd.SyncdIndex{blob: :binary.copy(<<0x11>>, 32)},
        value: %Syncd.SyncdValue{blob: :binary.copy(<<0x22>>, 64)},
        key_id: %Syncd.KeyId{id: <<1, 2, 3, 4>>}
      }
    }

    sync_action_data = %Syncd.SyncActionData{
      index: ~s(["mute","user@s.whatsapp.net"]),
      value: %Syncd.SyncActionValue{
        timestamp: 1_710_000_000,
        mute_action: %Syncd.MuteAction{muted: true, mute_end_timestamp: 1_710_086_400}
      },
      padding: <<>>,
      version: 2
    }

    assert Base.encode16(Syncd.SyncdMutation.encode(mutation), case: :lower) ==
             fixture["proto"]["mutation_hex"]

    assert Base.encode16(Syncd.SyncActionData.encode(sync_action_data), case: :lower) ==
             fixture["proto"]["sync_action_data_hex"]
  end

  defp parity_fixture! do
    @fixture_path
    |> File.read!()
    |> JSON.decode!()
  end
end
