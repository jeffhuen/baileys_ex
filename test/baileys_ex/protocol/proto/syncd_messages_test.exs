defmodule BaileysEx.Protocol.Proto.SyncdTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Protocol.Proto.Syncd

  describe "KeyId" do
    test "encode/decode roundtrip" do
      key_id = %Syncd.KeyId{id: <<1, 2, 3, 4>>}
      encoded = Syncd.KeyId.encode(key_id)
      assert {:ok, decoded} = Syncd.KeyId.decode(encoded)
      assert decoded.id == <<1, 2, 3, 4>>
    end
  end

  describe "SyncdIndex" do
    test "encode/decode roundtrip" do
      index = %Syncd.SyncdIndex{blob: :binary.copy(<<0x11>>, 32)}
      encoded = Syncd.SyncdIndex.encode(index)
      assert {:ok, decoded} = Syncd.SyncdIndex.decode(encoded)
      assert decoded.blob == index.blob
    end
  end

  describe "SyncdValue" do
    test "encode/decode roundtrip" do
      value = %Syncd.SyncdValue{blob: :binary.copy(<<0x22>>, 64)}
      encoded = Syncd.SyncdValue.encode(value)
      assert {:ok, decoded} = Syncd.SyncdValue.decode(encoded)
      assert decoded.blob == value.blob
    end
  end

  describe "SyncdVersion" do
    test "encode/decode roundtrip" do
      version = %Syncd.SyncdVersion{version: 42}
      encoded = Syncd.SyncdVersion.encode(version)
      assert {:ok, decoded} = Syncd.SyncdVersion.decode(encoded)
      assert decoded.version == 42
    end
  end

  describe "SyncdRecord" do
    test "encode/decode roundtrip" do
      record = %Syncd.SyncdRecord{
        index: %Syncd.SyncdIndex{blob: <<1::256>>},
        value: %Syncd.SyncdValue{blob: <<2::512>>},
        key_id: %Syncd.KeyId{id: <<3, 4, 5>>}
      }

      encoded = Syncd.SyncdRecord.encode(record)
      assert {:ok, decoded} = Syncd.SyncdRecord.decode(encoded)
      assert decoded.index.blob == <<1::256>>
      assert decoded.value.blob == <<2::512>>
      assert decoded.key_id.id == <<3, 4, 5>>
    end
  end

  describe "SyncdMutation" do
    test "encode/decode roundtrip with SET operation" do
      mutation = %Syncd.SyncdMutation{
        operation: :set,
        record: %Syncd.SyncdRecord{
          index: %Syncd.SyncdIndex{blob: <<0::256>>},
          value: %Syncd.SyncdValue{blob: <<1::256>>},
          key_id: %Syncd.KeyId{id: <<2>>}
        }
      }

      encoded = Syncd.SyncdMutation.encode(mutation)
      assert {:ok, decoded} = Syncd.SyncdMutation.decode(encoded)
      assert decoded.operation == :set
      assert decoded.record.index.blob == <<0::256>>
    end

    test "encode/decode roundtrip with REMOVE operation" do
      mutation = %Syncd.SyncdMutation{
        operation: :remove,
        record: %Syncd.SyncdRecord{
          index: %Syncd.SyncdIndex{blob: <<0::256>>},
          value: %Syncd.SyncdValue{blob: <<1::256>>},
          key_id: %Syncd.KeyId{id: <<2>>}
        }
      }

      encoded = Syncd.SyncdMutation.encode(mutation)
      assert {:ok, decoded} = Syncd.SyncdMutation.decode(encoded)
      assert decoded.operation == :remove
    end

    test "operation_byte converts correctly" do
      assert Syncd.SyncdMutation.operation_byte(:set) == 0x01
      assert Syncd.SyncdMutation.operation_byte(:remove) == 0x02
    end

    test "operation_atom converts correctly" do
      assert Syncd.SyncdMutation.operation_atom(:set) == :set
      assert Syncd.SyncdMutation.operation_atom(:remove) == :remove
      assert Syncd.SyncdMutation.operation_atom(0) == :set
      assert Syncd.SyncdMutation.operation_atom(1) == :remove
      assert Syncd.SyncdMutation.operation_atom(nil) == :set
    end
  end

  describe "SyncdPatch" do
    test "encode/decode roundtrip" do
      patch = %Syncd.SyncdPatch{
        version: %Syncd.SyncdVersion{version: 10},
        mutations: [
          %Syncd.SyncdMutation{
            operation: :set,
            record: %Syncd.SyncdRecord{
              index: %Syncd.SyncdIndex{blob: <<0::256>>},
              value: %Syncd.SyncdValue{blob: <<1::256>>},
              key_id: %Syncd.KeyId{id: <<2>>}
            }
          }
        ],
        snapshot_mac: :binary.copy(<<0x33>>, 32),
        patch_mac: :binary.copy(<<0x44>>, 32),
        key_id: %Syncd.KeyId{id: <<3, 4, 5>>}
      }

      encoded = Syncd.SyncdPatch.encode(patch)
      assert {:ok, decoded} = Syncd.SyncdPatch.decode(encoded)
      assert decoded.version.version == 10
      assert length(decoded.mutations) == 1
      assert decoded.snapshot_mac == patch.snapshot_mac
      assert decoded.patch_mac == patch.patch_mac
      assert decoded.key_id.id == <<3, 4, 5>>
    end
  end

  describe "SyncdSnapshot" do
    test "encode/decode roundtrip" do
      snapshot = %Syncd.SyncdSnapshot{
        version: %Syncd.SyncdVersion{version: 5},
        records: [
          %Syncd.SyncdRecord{
            index: %Syncd.SyncdIndex{blob: <<0::256>>},
            value: %Syncd.SyncdValue{blob: <<1::256>>},
            key_id: %Syncd.KeyId{id: <<2>>}
          }
        ],
        mac: :binary.copy(<<0x55>>, 32),
        key_id: %Syncd.KeyId{id: <<3>>}
      }

      encoded = Syncd.SyncdSnapshot.encode(snapshot)
      assert {:ok, decoded} = Syncd.SyncdSnapshot.decode(encoded)
      assert decoded.version.version == 5
      assert length(decoded.records) == 1
      assert decoded.mac == snapshot.mac
    end
  end

  describe "SyncActionData" do
    test "encode/decode roundtrip with mute action" do
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
      assert {:ok, decoded} = Syncd.SyncActionData.decode(encoded)
      assert decoded.index == data.index
      assert decoded.value.timestamp == 1_710_000_000
      assert decoded.value.mute_action.muted == true
      assert decoded.value.mute_action.mute_end_timestamp == 1_710_086_400
      assert decoded.version == 2
    end

    test "encode/decode roundtrip with pin action" do
      data = %Syncd.SyncActionData{
        index: ~s(["pin_v1","user@s.whatsapp.net"]),
        value: %Syncd.SyncActionValue{
          timestamp: 1_710_000_000,
          pin_action: %Syncd.PinAction{pinned: true}
        },
        version: 5
      }

      encoded = Syncd.SyncActionData.encode(data)
      assert {:ok, decoded} = Syncd.SyncActionData.decode(encoded)
      assert decoded.value.pin_action.pinned == true
    end

    test "encode/decode roundtrip with contact action" do
      data = %Syncd.SyncActionData{
        index: ~s(["contact","user@s.whatsapp.net"]),
        value: %Syncd.SyncActionValue{
          timestamp: 1_710_000_000,
          contact_action: %Syncd.ContactAction{
            full_name: "John Doe",
            lid_jid: "lid@lid.whatsapp.net"
          }
        },
        version: 2
      }

      encoded = Syncd.SyncActionData.encode(data)
      assert {:ok, decoded} = Syncd.SyncActionData.decode(encoded)
      assert decoded.value.contact_action.full_name == "John Doe"
      assert decoded.value.contact_action.lid_jid == "lid@lid.whatsapp.net"
    end

    test "encode/decode roundtrip with label edit action" do
      data = %Syncd.SyncActionData{
        index: ~s(["label_edit","5"]),
        value: %Syncd.SyncActionValue{
          timestamp: 1_710_000_000,
          label_edit_action: %Syncd.LabelEditAction{
            name: "Important",
            color: 3,
            deleted: false
          }
        },
        version: 3
      }

      encoded = Syncd.SyncActionData.encode(data)
      assert {:ok, decoded} = Syncd.SyncActionData.decode(encoded)
      assert decoded.value.label_edit_action.name == "Important"
      assert decoded.value.label_edit_action.color == 3
    end

    test "encode/decode roundtrip with archive action and message range" do
      data = %Syncd.SyncActionData{
        index: ~s(["archive","user@s.whatsapp.net"]),
        value: %Syncd.SyncActionValue{
          timestamp: 1_710_000_000,
          archive_chat_action: %Syncd.ArchiveChatAction{
            archived: true,
            message_range: %Syncd.SyncActionMessageRange{
              last_message_timestamp: 1_710_000_000,
              messages: []
            }
          }
        },
        version: 3
      }

      encoded = Syncd.SyncActionData.encode(data)
      assert {:ok, decoded} = Syncd.SyncActionData.decode(encoded)
      assert decoded.value.archive_chat_action.archived == true

      assert decoded.value.archive_chat_action.message_range.last_message_timestamp ==
               1_710_000_000
    end
  end

  describe "SyncdMutations" do
    test "encode/decode roundtrip with multiple mutations" do
      mutations = %Syncd.SyncdMutations{
        mutations: [
          %Syncd.SyncdMutation{
            operation: :set,
            record: %Syncd.SyncdRecord{
              index: %Syncd.SyncdIndex{blob: <<0::256>>},
              value: %Syncd.SyncdValue{blob: <<1::256>>},
              key_id: %Syncd.KeyId{id: <<2>>}
            }
          },
          %Syncd.SyncdMutation{
            operation: :remove,
            record: %Syncd.SyncdRecord{
              index: %Syncd.SyncdIndex{blob: <<3::256>>},
              value: %Syncd.SyncdValue{blob: <<4::256>>},
              key_id: %Syncd.KeyId{id: <<5>>}
            }
          }
        ]
      }

      encoded = Syncd.SyncdMutations.encode(mutations)
      assert {:ok, decoded} = Syncd.SyncdMutations.decode(encoded)
      assert length(decoded.mutations) == 2
      assert Enum.at(decoded.mutations, 0).operation == :set
      assert Enum.at(decoded.mutations, 1).operation == :remove
    end
  end

  describe "ExternalBlobReference" do
    test "encode/decode roundtrip" do
      ref = %Syncd.ExternalBlobReference{
        media_key: <<1::256>>,
        direct_path: "/path/to/blob",
        file_size_bytes: 1024,
        file_sha256: <<2::256>>,
        file_enc_sha256: <<3::256>>
      }

      encoded = Syncd.ExternalBlobReference.encode(ref)
      assert {:ok, decoded} = Syncd.ExternalBlobReference.decode(encoded)
      assert decoded.media_key == <<1::256>>
      assert decoded.direct_path == "/path/to/blob"
      assert decoded.file_size_bytes == 1024
    end
  end
end
