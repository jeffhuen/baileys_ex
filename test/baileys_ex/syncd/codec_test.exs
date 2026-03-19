defmodule BaileysEx.Syncd.CodecTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Protocol.Proto.Syncd
  alias BaileysEx.Syncd.Codec
  alias BaileysEx.Syncd.Keys

  # Deterministic test fixtures
  @key_data :binary.copy(<<0xAB>>, 32)
  @key_id_b64 Base.encode64(<<1, 2, 3, 4>>)
  @key_id_bin <<1, 2, 3, 4>>

  # Cross-language pinned MAC vectors from Node.js (dev/scripts/generate_syncd_vectors.mjs)
  @pinned_value_mac_set Base.decode16!(
                          "97CBE88C1699F9F1234D1DBD7EF8B093C7B2FBC8FF3D6EFCDE41849AD1828569"
                        )
  @pinned_value_mac_remove Base.decode16!(
                             "D313E752B853225C8FCB93765D5FDB03CD16A509F7EB806CA8C705E9EDEDB3B4"
                           )
  @pinned_snapshot_mac Base.decode16!(
                         "6875D29D0DB3CCA9CCAFF28976EE3158941E5A6EA1AA306EB67B4A48B10CBCE9"
                       )
  @pinned_patch_mac Base.decode16!(
                      "B95F06307D7EE8D6CB5496CF3224C62F1A753FBF367FC0FC82B3BD0A203595E3"
                    )

  # Cross-language pinned protobuf vectors from Baileys WAProto
  @pinned_syncd_mutation_bytes Base.decode16!(
                                 "080012700A220A20111111111111111111111111111111111111111111111111111111111111111112420A40222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222222221A060A0401020304"
                               )
  @pinned_sync_action_data_bytes Base.decode16!(
                                   "0A1E5B226D757465222C227573657240732E77686174736170702E6E6574225D121008808FB2AF06220808011080B2B7AF061A002002"
                                 )

  defp test_keys, do: Keys.expand_app_state_keys(@key_data)

  defp mock_get_key(b64) do
    if b64 == @key_id_b64 do
      {:ok, %{key_data: @key_data}}
    else
      {:error, {:key_not_found, b64}}
    end
  end

  defp valid_mute_mutation do
    keys = test_keys()
    index = ~s(["mute","user@s.whatsapp.net"])

    sync_action_data = %Syncd.SyncActionData{
      index: index,
      value: %Syncd.SyncActionValue{
        timestamp: 1_710_000_000,
        mute_action: %Syncd.MuteAction{muted: true}
      },
      padding: <<>>,
      version: 2
    }

    encoded = Syncd.SyncActionData.encode(sync_action_data)
    iv = :binary.copy(<<0x33>>, 16)
    {:ok, ciphertext} = BaileysEx.Crypto.aes_cbc_encrypt(keys.value_encryption_key, iv, encoded)
    enc_value = <<iv::binary-16, ciphertext::binary>>
    value_mac = Codec.generate_mac(:set, enc_value, @key_id_bin, keys.value_mac_key)
    index_mac = :crypto.mac(:hmac, :sha256, keys.index_key, index)

    %Syncd.SyncdMutation{
      operation: :set,
      record: %Syncd.SyncdRecord{
        index: %Syncd.SyncdIndex{blob: index_mac},
        value: %Syncd.SyncdValue{blob: <<enc_value::binary, value_mac::binary>>},
        key_id: %Syncd.KeyId{id: @key_id_bin}
      }
    }
  end

  # ============================================================================
  # MAC generation tests
  # ============================================================================

  describe "generate_mac/4" do
    test "returns 32-byte binary" do
      keys = test_keys()
      mac = Codec.generate_mac(:set, <<"test data">>, @key_id_bin, keys.value_mac_key)
      assert byte_size(mac) == 32
    end

    test "SET and REMOVE produce different MACs for same data" do
      keys = test_keys()
      mac_set = Codec.generate_mac(:set, <<"data">>, @key_id_bin, keys.value_mac_key)
      mac_remove = Codec.generate_mac(:remove, <<"data">>, @key_id_bin, keys.value_mac_key)
      assert mac_set != mac_remove
    end

    test "deterministic for same inputs" do
      keys = test_keys()
      mac1 = Codec.generate_mac(:set, <<"data">>, @key_id_bin, keys.value_mac_key)
      mac2 = Codec.generate_mac(:set, <<"data">>, @key_id_bin, keys.value_mac_key)
      assert mac1 == mac2
    end

    test "different data produces different MACs" do
      keys = test_keys()
      mac1 = Codec.generate_mac(:set, <<"data1">>, @key_id_bin, keys.value_mac_key)
      mac2 = Codec.generate_mac(:set, <<"data2">>, @key_id_bin, keys.value_mac_key)
      assert mac1 != mac2
    end

    test "pinned vector — SET MAC matches Node.js output" do
      keys = test_keys()
      data = <<"test payload">>
      mac = Codec.generate_mac(:set, data, @key_id_bin, keys.value_mac_key)
      assert mac == @pinned_value_mac_set
    end

    test "pinned vector — REMOVE MAC matches Node.js output" do
      keys = test_keys()
      data = <<"test payload">>
      mac = Codec.generate_mac(:remove, data, @key_id_bin, keys.value_mac_key)
      assert mac == @pinned_value_mac_remove
    end
  end

  describe "generate_snapshot_mac/4" do
    test "pinned vector — matches Node.js output" do
      keys = test_keys()
      mac = Codec.generate_snapshot_mac(<<0::1024>>, 1, :regular_high, keys.snapshot_mac_key)
      assert mac == @pinned_snapshot_mac
    end

    test "different versions produce different MACs" do
      keys = test_keys()
      hash = <<0::1024>>
      mac1 = Codec.generate_snapshot_mac(hash, 1, :regular_high, keys.snapshot_mac_key)
      mac2 = Codec.generate_snapshot_mac(hash, 2, :regular_high, keys.snapshot_mac_key)
      assert mac1 != mac2
    end

    test "different collection names produce different MACs" do
      keys = test_keys()
      hash = <<0::1024>>
      mac1 = Codec.generate_snapshot_mac(hash, 1, :regular_high, keys.snapshot_mac_key)
      mac2 = Codec.generate_snapshot_mac(hash, 1, :regular_low, keys.snapshot_mac_key)
      assert mac1 != mac2
    end
  end

  describe "generate_patch_mac/5" do
    test "pinned vector — matches Node.js output" do
      keys = test_keys()
      # Uses the pinned snapshot_mac and value_mac_set from the same vector set
      mac =
        Codec.generate_patch_mac(
          @pinned_snapshot_mac,
          [@pinned_value_mac_set],
          1,
          :regular_high,
          keys.patch_mac_key
        )

      assert mac == @pinned_patch_mac
    end
  end

  # ============================================================================
  # LTHash generator tests
  # ============================================================================

  describe "LTHash generator (init/mix/finish)" do
    test "SET adds to hash" do
      state = Codec.new_lt_hash_state()
      gen = Codec.init_lt_hash_generator(state)

      gen =
        Codec.mix_mutation(gen, %{
          index_mac: <<1::256>>,
          value_mac: <<2::256>>,
          operation: :set
        })

      result = Codec.finish_lt_hash_generator(gen)
      assert result.hash != state.hash
      assert Map.has_key?(result.index_value_map, Base.encode64(<<1::256>>))
    end

    test "SET then REMOVE returns to original hash" do
      state = Codec.new_lt_hash_state()
      gen = Codec.init_lt_hash_generator(state)

      gen =
        Codec.mix_mutation(gen, %{
          index_mac: <<1::256>>,
          value_mac: <<2::256>>,
          operation: :set
        })

      gen =
        Codec.mix_mutation(gen, %{
          index_mac: <<1::256>>,
          value_mac: <<2::256>>,
          operation: :remove
        })

      result = Codec.finish_lt_hash_generator(gen)
      assert result.hash == state.hash
      refute Map.has_key?(result.index_value_map, Base.encode64(<<1::256>>))
    end

    test "REMOVE without previous SET raises" do
      state = Codec.new_lt_hash_state()
      gen = Codec.init_lt_hash_generator(state)

      assert_raise RuntimeError, ~r/tried remove/, fn ->
        Codec.mix_mutation(gen, %{
          index_mac: <<1::256>>,
          value_mac: <<2::256>>,
          operation: :remove
        })
      end
    end

    test "replacing a value (SET overwrites previous SET)" do
      state = Codec.new_lt_hash_state()
      gen = Codec.init_lt_hash_generator(state)
      index = <<1::256>>

      gen = Codec.mix_mutation(gen, %{index_mac: index, value_mac: <<2::256>>, operation: :set})
      gen = Codec.mix_mutation(gen, %{index_mac: index, value_mac: <<3::256>>, operation: :set})

      result = Codec.finish_lt_hash_generator(gen)
      # Should have the new value_mac
      assert result.index_value_map[Base.encode64(index)].value_mac == <<3::256>>
    end
  end

  # ============================================================================
  # Encode/Decode roundtrip tests
  # ============================================================================

  describe "encode_syncd_patch/5" do
    test "produces valid patch with correct structure" do
      state = Codec.new_lt_hash_state()
      iv = :binary.copy(<<0x42>>, 16)

      patch_create = %{
        type: :regular_high,
        index: ["mute", "user@s.whatsapp.net"],
        sync_action: %Syncd.SyncActionValue{
          timestamp: 1_710_000_000,
          mute_action: %Syncd.MuteAction{muted: true, mute_end_timestamp: 1_710_086_400}
        },
        api_version: 2,
        operation: :set
      }

      assert {:ok, %{patch: patch, state: new_state}} =
               Codec.encode_syncd_patch(
                 patch_create,
                 @key_id_b64,
                 state,
                 &mock_get_key/1,
                 iv: iv
               )

      # Patch structure
      assert byte_size(patch.patch_mac) == 32
      assert byte_size(patch.snapshot_mac) == 32
      assert patch.key_id.id == @key_id_bin
      assert length(patch.mutations) == 1

      mutation = hd(patch.mutations)
      assert mutation.operation == :set
      assert byte_size(mutation.record.index.blob) == 32
      assert byte_size(mutation.record.value.blob) > 32

      # State updated
      assert new_state.version == 1
      assert new_state.hash != state.hash
    end

    test "encode then decode roundtrip recovers original action" do
      state = Codec.new_lt_hash_state()
      iv = :binary.copy(<<0x42>>, 16)

      patch_create = %{
        type: :regular_high,
        index: ["mute", "user@s.whatsapp.net"],
        sync_action: %Syncd.SyncActionValue{
          timestamp: 1_710_000_000,
          mute_action: %Syncd.MuteAction{muted: true, mute_end_timestamp: 1_710_086_400}
        },
        api_version: 2,
        operation: :set
      }

      {:ok, %{patch: patch, state: encode_state}} =
        Codec.encode_syncd_patch(patch_create, @key_id_b64, state, &mock_get_key/1, iv: iv)

      # Add version to patch (Baileys does this in appPatch before decoding)
      patch = %{patch | version: %Syncd.SyncdVersion{version: encode_state.version}}

      # Decode the patch
      mutations_received = []

      on_mutation = fn mutation ->
        send(self(), {:test_mutation, mutation})
      end

      assert {:ok, _state} =
               Codec.decode_syncd_patch(
                 patch,
                 :regular_high,
                 state,
                 &mock_get_key/1,
                 on_mutation,
                 true
               )

      assert_received {:test_mutation, mutation}
      assert mutation.index == ["mute", "user@s.whatsapp.net"]
      assert mutation.sync_action.value.mute_action.muted == true
      assert mutation.sync_action.value.mute_action.mute_end_timestamp == 1_710_086_400
      assert mutation.sync_action.value.timestamp == 1_710_000_000
      _ = mutations_received
    end

    test "MAC verification detects tampered data" do
      state = Codec.new_lt_hash_state()
      iv = :binary.copy(<<0x42>>, 16)

      patch_create = %{
        type: :regular_high,
        index: ["pin_v1", "user@s.whatsapp.net"],
        sync_action: %Syncd.SyncActionValue{
          timestamp: 1_710_000_000,
          pin_action: %Syncd.PinAction{pinned: true}
        },
        api_version: 5,
        operation: :set
      }

      {:ok, %{patch: patch, state: encode_state}} =
        Codec.encode_syncd_patch(patch_create, @key_id_b64, state, &mock_get_key/1, iv: iv)

      # Add version (Baileys does this in appPatch before decoding)
      patch = %{patch | version: %Syncd.SyncdVersion{version: encode_state.version}}

      # Tamper with the patch MAC
      tampered = %{patch | patch_mac: :binary.copy(<<0xAA>>, 32)}

      assert {:error, :invalid_patch_mac} =
               Codec.decode_syncd_patch(
                 tampered,
                 :regular_high,
                 state,
                 &mock_get_key/1,
                 fn _ -> :ok end,
                 true
               )
    end
  end

  # ============================================================================
  # Decode mutations tests
  # ============================================================================

  describe "decode_syncd_mutations/5" do
    test "decodes encrypted mutation and calls on_mutation callback" do
      keys = test_keys()

      # Build a valid encrypted mutation manually
      index = ~s(["mute","user@s.whatsapp.net"])

      sync_action_data = %Syncd.SyncActionData{
        index: index,
        value: %Syncd.SyncActionValue{
          timestamp: 1_710_000_000,
          mute_action: %Syncd.MuteAction{muted: true}
        },
        padding: <<>>,
        version: 2
      }

      encoded = Syncd.SyncActionData.encode(sync_action_data)

      # Encrypt with AES-256-CBC, IV prepended
      iv = :binary.copy(<<0x33>>, 16)
      {:ok, ciphertext} = BaileysEx.Crypto.aes_cbc_encrypt(keys.value_encryption_key, iv, encoded)
      enc_value = <<iv::binary-16, ciphertext::binary>>

      # Generate MACs
      value_mac = Codec.generate_mac(:set, enc_value, @key_id_bin, keys.value_mac_key)
      index_mac = :crypto.mac(:hmac, :sha256, keys.index_key, index)

      # Build mutation record
      mutation = %Syncd.SyncdMutation{
        operation: :set,
        record: %Syncd.SyncdRecord{
          index: %Syncd.SyncdIndex{blob: index_mac},
          value: %Syncd.SyncdValue{blob: <<enc_value::binary, value_mac::binary>>},
          key_id: %Syncd.KeyId{id: @key_id_bin}
        }
      }

      state = Codec.new_lt_hash_state()

      on_mutation = fn m -> send(self(), {:decoded_mutation, m}) end

      assert {:ok, result} =
               Codec.decode_syncd_mutations(
                 [mutation],
                 state,
                 &mock_get_key/1,
                 on_mutation,
                 true
               )

      # Check callback was called
      assert_received {:decoded_mutation, decoded}
      assert decoded.index == ["mute", "user@s.whatsapp.net"]
      assert decoded.sync_action.value.mute_action.muted == true

      # Check LTHash was updated
      assert result.hash != state.hash
    end

    test "key not found returns error" do
      mutation = %Syncd.SyncdMutation{
        operation: :set,
        record: %Syncd.SyncdRecord{
          index: %Syncd.SyncdIndex{blob: <<0::256>>},
          value: %Syncd.SyncdValue{blob: :binary.copy(<<1>>, 64)},
          key_id: %Syncd.KeyId{id: <<99, 99, 99>>}
        }
      }

      state = Codec.new_lt_hash_state()

      assert {:error, _} =
               Codec.decode_syncd_mutations(
                 [mutation],
                 state,
                 fn _b64 -> {:error, :not_found} end,
                 fn _ -> :ok end,
                 false
               )
    end
  end

  describe "mailbox isolation" do
    test "decode_syncd_snapshot/5 does not leave mutation messages behind on verification failure" do
      mutation = valid_mute_mutation()

      snapshot = %Syncd.SyncdSnapshot{
        version: %Syncd.SyncdVersion{version: 1},
        records: [mutation.record],
        mac: :binary.copy(<<0xFF>>, 32),
        key_id: %Syncd.KeyId{id: @key_id_bin}
      }

      assert {:error, :invalid_snapshot_mac} =
               Codec.decode_syncd_snapshot(:regular_high, snapshot, &mock_get_key/1, nil, true)

      refute_receive {:syncd_mutation, _, _}
    end

    test "decode_patches/7 does not leave patch mutation messages behind on verification failure" do
      patch_create = %{
        type: :regular_high,
        index: ["mute", "user@s.whatsapp.net"],
        sync_action: %Syncd.SyncActionValue{
          timestamp: 1_710_000_000,
          mute_action: %Syncd.MuteAction{muted: true, mute_end_timestamp: 1_710_086_400}
        },
        api_version: 2,
        operation: :set
      }

      {:ok, %{patch: patch, state: encoded_state}} =
        Codec.encode_syncd_patch(
          patch_create,
          @key_id_b64,
          Codec.new_lt_hash_state(),
          &mock_get_key/1,
          iv: :binary.copy(<<0x42>>, 16)
        )

      patch = %{patch | version: %Syncd.SyncdVersion{version: encoded_state.version}}
      wrong_initial_state = %{Codec.new_lt_hash_state() | hash: :binary.copy(<<0x11>>, 128)}

      assert {:error, :invalid_snapshot_mac} =
               Codec.decode_patches(
                 :regular_high,
                 [patch],
                 wrong_initial_state,
                 &mock_get_key/1,
                 nil,
                 true
               )

      refute_receive {:syncd_patch_mutation, _, _}
    end
  end

  # ============================================================================
  # new_lt_hash_state tests
  # ============================================================================

  describe "new_lt_hash_state/0" do
    test "returns expected initial state" do
      state = Codec.new_lt_hash_state()
      assert state.version == 0
      assert byte_size(state.hash) == 128
      assert state.hash == <<0::1024>>
      assert state.index_value_map == %{}
    end
  end

  describe "patch_names/0" do
    test "returns all five collection names" do
      names = Codec.patch_names()
      assert :critical_block in names
      assert :critical_unblock_low in names
      assert :regular_high in names
      assert :regular_low in names
      assert :regular in names
      assert length(names) == 5
    end
  end

  # ============================================================================
  # Protobuf wire-format parity tests
  # ============================================================================

  describe "protobuf wire-format parity" do
    test "SyncdMutation encoding matches Baileys WAProto output" do
      mutation = %Syncd.SyncdMutation{
        operation: :set,
        record: %Syncd.SyncdRecord{
          index: %Syncd.SyncdIndex{blob: :binary.copy(<<0x11>>, 32)},
          value: %Syncd.SyncdValue{blob: :binary.copy(<<0x22>>, 64)},
          key_id: %Syncd.KeyId{id: <<1, 2, 3, 4>>}
        }
      }

      encoded = Syncd.SyncdMutation.encode(mutation)
      assert encoded == @pinned_syncd_mutation_bytes
    end

    test "SyncdMutation decoding from Baileys WAProto bytes produces correct struct" do
      assert {:ok, decoded} = Syncd.SyncdMutation.decode(@pinned_syncd_mutation_bytes)
      assert decoded.operation == :set
      assert decoded.record.index.blob == :binary.copy(<<0x11>>, 32)
      assert decoded.record.value.blob == :binary.copy(<<0x22>>, 64)
      assert decoded.record.key_id.id == <<1, 2, 3, 4>>
    end

    test "SyncActionData encoding matches Baileys WAProto output" do
      data = %Syncd.SyncActionData{
        index: ~s(["mute","user@s.whatsapp.net"]),
        value: %Syncd.SyncActionValue{
          timestamp: 1_710_000_000,
          mute_action: %Syncd.MuteAction{muted: true, mute_end_timestamp: 1_710_086_400}
        },
        padding: <<>>,
        version: 2
      }

      encoded = Syncd.SyncActionData.encode(data)
      assert encoded == @pinned_sync_action_data_bytes
    end

    test "SyncActionData decoding from Baileys WAProto bytes produces correct struct" do
      assert {:ok, decoded} = Syncd.SyncActionData.decode(@pinned_sync_action_data_bytes)
      assert decoded.index == ~s(["mute","user@s.whatsapp.net"])
      assert decoded.value.timestamp == 1_710_000_000
      assert decoded.value.mute_action.muted == true
      assert decoded.value.mute_action.mute_end_timestamp == 1_710_086_400
      assert decoded.version == 2
    end
  end

  describe "external blob handling" do
    test "extract_syncd_patches/2 decodes tuple-wrapped patch payloads" do
      state = Codec.new_lt_hash_state()
      iv = :binary.copy(<<0x42>>, 16)

      patch_create = %{
        type: :regular_high,
        index: ["mute", "user@s.whatsapp.net"],
        sync_action: %Syncd.SyncActionValue{
          timestamp: 1_710_000_000,
          mute_action: %Syncd.MuteAction{muted: true, mute_end_timestamp: 1_710_086_400}
        },
        api_version: 2,
        operation: :set
      }

      {:ok, %{patch: patch, state: enc_state}} =
        Codec.encode_syncd_patch(patch_create, @key_id_b64, state, &mock_get_key/1, iv: iv)

      patch = %{patch | version: %Syncd.SyncdVersion{version: enc_state.version}}
      patch_binary = Syncd.SyncdPatch.encode(patch)

      response = %{
        tag: "iq",
        attrs: %{},
        content: [
          %{
            tag: "sync",
            attrs: %{},
            content: [
              %{
                tag: "collection",
                attrs: %{"name" => "regular_high", "version" => "1"},
                content: [
                  %{tag: "patch", attrs: %{}, content: {:binary, patch_binary}}
                ]
              }
            ]
          }
        ]
      }

      assert {:ok, %{regular_high: %{patches: [%Syncd.SyncdPatch{}]}}} =
               Codec.extract_syncd_patches(response)
    end

    test "extract_syncd_patches/2 downloads external snapshots" do
      snapshot = %Syncd.SyncdSnapshot{
        version: %Syncd.SyncdVersion{version: 1},
        records: [],
        mac: <<0::256>>,
        key_id: %Syncd.KeyId{id: @key_id_bin}
      }

      snapshot_ref = %Syncd.ExternalBlobReference{
        media_key: :binary.copy(<<0x44>>, 32),
        direct_path: "/mms/md-app-state/snapshot-1"
      }

      response = %{
        tag: "iq",
        attrs: %{},
        content: [
          %{
            tag: "sync",
            attrs: %{},
            content: [
              %{
                tag: "collection",
                attrs: %{"name" => "regular_high", "version" => "1"},
                content: [
                  %{
                    tag: "snapshot",
                    attrs: %{},
                    content: Syncd.ExternalBlobReference.encode(snapshot_ref)
                  }
                ]
              }
            ]
          }
        ]
      }

      fetcher = fn blob ->
        send(self(), {:external_blob, blob})
        {:ok, Syncd.SyncdSnapshot.encode(snapshot)}
      end

      assert {:ok, %{regular_high: %{snapshot: ^snapshot}}} =
               Codec.extract_syncd_patches(response, external_blob_fetcher: fetcher)

      assert_received {:external_blob, ^snapshot_ref}
    end

    test "extract_syncd_patches/2 downloads tuple-wrapped external snapshots" do
      snapshot = %Syncd.SyncdSnapshot{
        version: %Syncd.SyncdVersion{version: 1},
        records: [],
        mac: <<0::256>>,
        key_id: %Syncd.KeyId{id: @key_id_bin}
      }

      snapshot_ref = %Syncd.ExternalBlobReference{
        media_key: :binary.copy(<<0x44>>, 32),
        direct_path: "/mms/md-app-state/snapshot-1"
      }

      response = %{
        tag: "iq",
        attrs: %{},
        content: [
          %{
            tag: "sync",
            attrs: %{},
            content: [
              %{
                tag: "collection",
                attrs: %{"name" => "regular_high", "version" => "1"},
                content: [
                  %{
                    tag: "snapshot",
                    attrs: %{},
                    content: {:binary, Syncd.ExternalBlobReference.encode(snapshot_ref)}
                  }
                ]
              }
            ]
          }
        ]
      }

      fetcher = fn blob ->
        send(self(), {:external_blob, blob})
        {:ok, Syncd.SyncdSnapshot.encode(snapshot)}
      end

      assert {:ok, %{regular_high: %{snapshot: ^snapshot}}} =
               Codec.extract_syncd_patches(response, external_blob_fetcher: fetcher)

      assert_received {:external_blob, ^snapshot_ref}
    end

    test "extract_syncd_patches/2 rejects inline snapshot payloads that are not external refs" do
      snapshot = %Syncd.SyncdSnapshot{
        version: %Syncd.SyncdVersion{version: 1},
        records: [],
        mac: <<0::256>>,
        key_id: %Syncd.KeyId{id: @key_id_bin}
      }

      response = %{
        tag: "iq",
        attrs: %{},
        content: [
          %{
            tag: "sync",
            attrs: %{},
            content: [
              %{
                tag: "collection",
                attrs: %{"name" => "regular_high", "version" => "1"},
                content: [
                  %{
                    tag: "snapshot",
                    attrs: %{},
                    content: Syncd.SyncdSnapshot.encode(snapshot)
                  }
                ]
              }
            ]
          }
        ]
      }

      assert match?({:error, _reason}, Codec.extract_syncd_patches(response))
    end

    test "decode_patches/7 expands external mutations and skips only outer MAC checks when validate_macs=false" do
      keys = test_keys()
      index = ~s(["mute","user@s.whatsapp.net"])

      sync_action_data = %Syncd.SyncActionData{
        index: index,
        value: %Syncd.SyncActionValue{
          timestamp: 1_710_000_000,
          mute_action: %Syncd.MuteAction{muted: true}
        },
        padding: <<>>,
        version: 2
      }

      encoded = Syncd.SyncActionData.encode(sync_action_data)
      iv = :binary.copy(<<0x33>>, 16)
      {:ok, ciphertext} = BaileysEx.Crypto.aes_cbc_encrypt(keys.value_encryption_key, iv, encoded)
      enc_value = <<iv::binary-16, ciphertext::binary>>
      value_mac = Codec.generate_mac(:set, enc_value, @key_id_bin, keys.value_mac_key)
      index_mac = :crypto.mac(:hmac, :sha256, keys.index_key, index)

      mutation = %Syncd.SyncdMutation{
        operation: :set,
        record: %Syncd.SyncdRecord{
          index: %Syncd.SyncdIndex{blob: index_mac},
          value: %Syncd.SyncdValue{blob: <<enc_value::binary, value_mac::binary>>},
          key_id: %Syncd.KeyId{id: @key_id_bin}
        }
      }

      external_ref = %Syncd.ExternalBlobReference{
        media_key: :binary.copy(<<0x55>>, 32),
        direct_path: "/mms/md-app-state/patch-1"
      }

      patch = %Syncd.SyncdPatch{
        version: %Syncd.SyncdVersion{version: 1},
        mutations: [],
        external_mutations: external_ref,
        snapshot_mac: <<0::256>>,
        patch_mac: <<0::256>>,
        key_id: %Syncd.KeyId{id: @key_id_bin}
      }

      fetcher = fn blob ->
        send(self(), {:external_patch_blob, blob})
        {:ok, Syncd.SyncdMutations.encode(%Syncd.SyncdMutations{mutations: [mutation]})}
      end

      assert {:ok, %{mutation_map: mutation_map}} =
               Codec.decode_patches(
                 :regular_high,
                 [patch],
                 Codec.new_lt_hash_state(),
                 &mock_get_key/1,
                 nil,
                 false,
                 external_blob_fetcher: fetcher
               )

      assert_received {:external_patch_blob, ^external_ref}
      assert %{"[\"mute\",\"user@s.whatsapp.net\"]" => decoded_mutation} = mutation_map
      assert decoded_mutation.index == ["mute", "user@s.whatsapp.net"]
      assert decoded_mutation.sync_action.value.mute_action.muted == true
    end

    test "decode_patches/7 still validates inner mutation MACs when validate_macs=false" do
      keys = test_keys()
      index = ~s(["mute","user@s.whatsapp.net"])

      sync_action_data = %Syncd.SyncActionData{
        index: index,
        value: %Syncd.SyncActionValue{
          timestamp: 1_710_000_000,
          mute_action: %Syncd.MuteAction{muted: true}
        },
        padding: <<>>,
        version: 2
      }

      encoded = Syncd.SyncActionData.encode(sync_action_data)
      iv = :binary.copy(<<0x33>>, 16)
      {:ok, ciphertext} = BaileysEx.Crypto.aes_cbc_encrypt(keys.value_encryption_key, iv, encoded)
      enc_value = <<iv::binary-16, ciphertext::binary>>
      value_mac = Codec.generate_mac(:set, enc_value, @key_id_bin, keys.value_mac_key)

      tampered_value_mac =
        binary_part(value_mac, 0, 31) <> <<Bitwise.bxor(:binary.last(value_mac), 0x01)>>

      index_mac = :crypto.mac(:hmac, :sha256, keys.index_key, index)

      patch = %Syncd.SyncdPatch{
        version: %Syncd.SyncdVersion{version: 1},
        mutations: [
          %Syncd.SyncdMutation{
            operation: :set,
            record: %Syncd.SyncdRecord{
              index: %Syncd.SyncdIndex{blob: index_mac},
              value: %Syncd.SyncdValue{blob: <<enc_value::binary, tampered_value_mac::binary>>},
              key_id: %Syncd.KeyId{id: @key_id_bin}
            }
          }
        ],
        snapshot_mac: <<0::256>>,
        patch_mac: <<0::256>>,
        key_id: %Syncd.KeyId{id: @key_id_bin}
      }

      assert {:error, :hmac_content_verification_failed} =
               Codec.decode_patches(
                 :regular_high,
                 [patch],
                 Codec.new_lt_hash_state(),
                 &mock_get_key/1,
                 nil,
                 false
               )
    end
  end
end
