defmodule BaileysEx.Signal.GroupTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Signal.Address
  alias BaileysEx.Signal.Group.Cipher
  alias BaileysEx.Signal.Group.SenderChainKey
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
      sender_signing_key: %{public: <<11::256>>}
    }

    state = SenderKeyState.from_structure(legacy_structure)
    structure = SenderKeyState.to_structure(state)

    assert structure.sender_key_id == 42
    assert structure.sender_message_keys == []
  end

  test "group session builder initializes a record with deterministic key material" do
    record = SenderKeyRecord.new()
    signing_key = %{public: <<9::256>>, private: <<10::256>>}

    assert {:ok, record, distribution_message} =
             SessionBuilder.create(record,
               key_id: 7,
               sender_key: <<8::256>>,
               signing_key: signing_key
             )

    refute SenderKeyRecord.empty?(record)

    assert {:ok,
            %SenderKeyDistributionMessage{
              id: 7,
              iteration: 0,
              chain_key: <<8::256>>,
              signing_key: <<5, 9::256>>
            }} = SenderKeyDistributionMessage.decode(distribution_message)

    refute SenderKeyRecord.empty?(record)
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

  test "sender chain and message keys match pinned vectors" do
    seed = Base.decode16!("000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F")
    chain = SenderChainKey.new(0, seed)
    message_key = SenderChainKey.sender_message_key(chain)
    next_chain = SenderChainKey.next(chain)

    assert message_key.seed ==
             Base.decode16!("9B4C8120A4823A95F47CDE17A244F4507244EE6E3957D1FAB9FA29B44D3829B7")

    assert message_key.iv ==
             Base.decode16!("ED1F5E26325B1399F6A34C76E47FF047")

    assert message_key.cipher_key ==
             Base.decode16!("D89F10A08215E845CEB4DF3FC59C052AD09E01CD499650025FF83DF48ED656E6")

    assert next_chain.seed ==
             Base.decode16!("4304C22C84A53755AB08EAD8D97A8D429BE5EFA480682D7AD1DA27F73E1FBE1D")
  end
end
