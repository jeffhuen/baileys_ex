defmodule BaileysEx.Signal.GroupTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Signal.Address
  alias BaileysEx.Signal.Group.Cipher
  alias BaileysEx.Signal.Group.SessionBuilder
  alias BaileysEx.Signal.Group.SenderKeyDistributionMessage
  alias BaileysEx.Signal.Group.SenderKeyName
  alias BaileysEx.Signal.Group.SenderKeyRecord
  alias BaileysEx.Signal.Group.SenderKeyState

  test "sender key name serializes like Baileys" do
    assert {:ok, address} = Address.from_jid("5511999887766:3@s.whatsapp.net")

    assert "120363001234567890@g.us::5511999887766::3" ==
             SenderKeyName.new("120363001234567890@g.us", address)
             |> SenderKeyName.serialize()
  end

  test "sender key state initializes missing sender message keys from legacy structure" do
    legacy_structure = %{
      sender_key_id: 42,
      sender_chain_key: %{iteration: 0, seed: <<1, 2, 3>>},
      sender_signing_key: %{public: :crypto.strong_rand_bytes(32)}
    }

    state = SenderKeyState.from_structure(legacy_structure)
    structure = SenderKeyState.to_structure(state)

    assert structure.sender_key_id == 42
    assert structure.sender_message_keys == []
  end

  test "group session builder initializes a record and returns a distribution message" do
    record = SenderKeyRecord.new()

    assert {:ok, record, distribution_message} = SessionBuilder.create(record)

    refute SenderKeyRecord.empty?(record)

    assert {:ok, %SenderKeyDistributionMessage{id: id, iteration: 0, chain_key: chain_key}} =
             SenderKeyDistributionMessage.decode(distribution_message)

    assert is_integer(id) and id >= 0
    assert byte_size(chain_key) == 32
  end

  test "group cipher roundtrips between distributed sender key records" do
    sender_record = SenderKeyRecord.new()
    recipient_record = SenderKeyRecord.new()

    assert {:ok, sender_record, distribution_message} = SessionBuilder.create(sender_record)
    assert {:ok, distribution_message} = SenderKeyDistributionMessage.decode(distribution_message)

    assert {:ok, recipient_record} =
             SessionBuilder.process(recipient_record, distribution_message)

    assert {:ok, sender_record, ciphertext} = Cipher.encrypt(sender_record, "hello group")
    assert {:ok, recipient_record, "hello group"} = Cipher.decrypt(recipient_record, ciphertext)

    refute SenderKeyRecord.empty?(sender_record)
    refute SenderKeyRecord.empty?(recipient_record)
  end

  test "group cipher decrypts out-of-order messages using cached sender message keys" do
    sender_record = SenderKeyRecord.new()
    recipient_record = SenderKeyRecord.new()

    assert {:ok, sender_record, distribution_message} = SessionBuilder.create(sender_record)

    assert {:ok, recipient_record} =
             SessionBuilder.process(recipient_record, distribution_message)

    assert {:ok, sender_record, first} = Cipher.encrypt(sender_record, "first")
    assert {:ok, next_sender_record, second} = Cipher.encrypt(sender_record, "second")

    assert {:ok, recipient_record, "second"} = Cipher.decrypt(recipient_record, second)
    assert {:ok, _recipient_record, "first"} = Cipher.decrypt(recipient_record, first)
    refute SenderKeyRecord.empty?(next_sender_record)
  end
end
