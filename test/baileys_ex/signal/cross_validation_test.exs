defmodule BaileysEx.Signal.CrossValidationTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Signal.LIDMappingStore
  alias BaileysEx.Signal.Repository
  alias BaileysEx.Signal.Store
  alias BaileysEx.Signal.Address
  alias BaileysEx.Signal.SessionBuilder, as: DirectSessionBuilder
  alias BaileysEx.Signal.SessionCipher, as: DirectSessionCipher
  alias BaileysEx.Signal.SessionRecord
  alias BaileysEx.Signal.Group.Cipher
  alias BaileysEx.Signal.Group.SessionBuilder
  alias BaileysEx.Signal.Group.SenderKeyDistributionMessage
  alias BaileysEx.Signal.Group.SenderKeyName
  alias BaileysEx.Signal.Group.SenderKeyRecord
  alias BaileysEx.Signal.Group.SenderKeyState
  alias BaileysEx.Signal.Group.SenderKeyMessage

  @fixture_path Path.expand("../../fixtures/signal/baileys_v7.json", __DIR__)

  test "matches Baileys address fixtures" do
    fixtures = fixtures!()

    Enum.each(fixtures["addresses"], fn fixture ->
      jid = fixture["jid"]

      case fixture do
        %{"signal_address" => expected} ->
          assert {:ok, ^expected} = Repository.jid_to_signal_protocol_address(jid)

        %{"error" => true} ->
          assert {:error, :invalid_signal_address} =
                   Repository.jid_to_signal_protocol_address(jid)
      end
    end)
  end

  test "matches Baileys LID mapping fixtures" do
    fixtures = fixtures!()
    {:ok, store} = Store.start_link()

    assert :ok =
             fixtures["lid_mapping"]["stored_pairs"]
             |> Enum.map(&atomize_mapping/1)
             |> then(&LIDMappingStore.store_lid_pn_mappings(store, &1))

    Enum.each(fixtures["lid_mapping"]["forward_lookups"], fn %{"pn" => pn, "lid" => expected_lid} ->
      assert {:ok, ^expected_lid} = LIDMappingStore.get_lid_for_pn(store, pn)
    end)

    Enum.each(fixtures["lid_mapping"]["reverse_lookups"], fn %{"lid" => lid, "pn" => expected_pn} ->
      assert {:ok, ^expected_pn} = LIDMappingStore.get_pn_for_lid(store, lid)
    end)
  end

  test "matches Baileys sender-key fixtures" do
    fixture = fixtures!()["sender_key"]

    assert {:ok, author} = Address.from_jid(fixture["author_jid"])

    assert fixture["sender_key_name"] ==
             SenderKeyName.new(fixture["group"], author)
             |> SenderKeyName.serialize()

    distribution_message = decode64!(fixture["distribution_message"])
    messages = fixture["messages"]

    assert {:ok, decoded_distribution} =
             SenderKeyDistributionMessage.decode(distribution_message)

    assert decoded_distribution.id == fixture["state"]["key_id"]
    assert decoded_distribution.iteration == fixture["state"]["iteration"]
    assert decoded_distribution.chain_key == decode64!(fixture["state"]["chain_key"])
    assert decoded_distribution.signing_key == decode64!(fixture["state"]["signing_public_key"])

    sender_record = sender_record_from_fixture(fixture)

    assert distribution_message ==
             sender_record
             |> SenderKeyRecord.current_state()
             |> encode_distribution_message()

    Enum.reduce(messages, sender_record, fn %{
                                              "plaintext" => plaintext,
                                              "ciphertext" => ciphertext
                                            },
                                            record ->
      plaintext = decode64!(plaintext)
      expected_message = decode_sender_key_message_fixture!(ciphertext)

      assert {:ok, record, actual_ciphertext} = Cipher.encrypt(record, plaintext)

      actual_message = parse_sender_key_message!(actual_ciphertext)

      assert actual_message.id == expected_message.id
      assert actual_message.iteration == expected_message.iteration
      assert actual_message.ciphertext == expected_message.ciphertext

      assert SenderKeyMessage.verify_signature(
               actual_message,
               decode64!(fixture["state"]["signing_public_key"])
             )

      record
    end)

    assert {:ok, recipient_record} =
             SessionBuilder.process(SenderKeyRecord.new(), distribution_message)

    Enum.reduce(fixture["decrypt_order"], recipient_record, fn index, record ->
      message = Enum.at(messages, index)
      plaintext = decode64!(message["plaintext"])
      ciphertext = decode64!(message["ciphertext"])

      assert {:ok, record, ^plaintext} = Cipher.decrypt(record, ciphertext)
      record
    end)
  end

  test "matches Baileys direct-message fixtures" do
    fixture = fixtures!()["direct_message"]

    alice_identity = key_pair_from_fixture(fixture["alice"]["identity_key"])
    alice_base_key = key_pair_from_fixture(fixture["alice"]["base_key"])
    alice_sending_ratchet = key_pair_from_fixture(fixture["alice"]["sending_ratchet"])
    alice_next_ratchet = key_pair_from_fixture(fixture["alice"]["next_ratchet"])

    bob_identity = key_pair_from_fixture(fixture["bob"]["identity_key"])
    bob_signed_pre_key = key_pair_from_fixture(fixture["bob"]["signed_pre_key"])
    bob_pre_key = key_pair_from_fixture(fixture["bob"]["pre_key"])
    bob_reply_ratchet = key_pair_from_fixture(fixture["bob"]["reply_ratchet"])
    pre_key_id = fixture["bob"]["pre_key_id"]

    bundle = %{
      identity_key: bob_identity.public,
      signed_pre_key: bob_signed_pre_key.public,
      pre_key: bob_pre_key.public,
      registration_id: fixture["bob"]["registration_id"],
      signed_pre_key_id: fixture["bob"]["signed_pre_key_id"],
      pre_key_id: fixture["bob"]["pre_key_id"]
    }

    alice_plaintext = decode64!(fixture["messages"]["alice_to_bob"]["plaintext"])
    alice_ciphertext = decode64!(fixture["messages"]["alice_to_bob"]["ciphertext"])

    assert {:ok, alice_record, _base_key} =
             DirectSessionBuilder.init_outgoing(SessionRecord.new(), bundle,
               identity_key_pair: alice_identity,
               base_key_pair: alice_base_key,
               sending_ratchet_pair: alice_sending_ratchet
             )

    assert {:ok, alice_record_after_send, %{type: :pkmsg, ciphertext: ^alice_ciphertext}} =
             DirectSessionCipher.encrypt(alice_record, alice_plaintext,
               registration_id: fixture["alice"]["registration_id"]
             )

    assert {:ok, bob_record, ^alice_plaintext, ^pre_key_id} =
             DirectSessionCipher.decrypt_pre_key_whisper_message(
               SessionRecord.new(),
               alice_ciphertext,
               identity_key_pair: bob_identity,
               signed_pre_key_pair: bob_signed_pre_key,
               pre_key_pair: bob_pre_key,
               registration_id: fixture["bob"]["registration_id"],
               ratchet_key_pair: bob_reply_ratchet
             )

    bob_plaintext = decode64!(fixture["messages"]["bob_to_alice"]["plaintext"])
    bob_ciphertext = decode64!(fixture["messages"]["bob_to_alice"]["ciphertext"])

    assert {:ok, _bob_record, %{type: :msg, ciphertext: ^bob_ciphertext}} =
             DirectSessionCipher.encrypt(bob_record, bob_plaintext)

    assert {:ok, _alice_record, ^bob_plaintext} =
             DirectSessionCipher.decrypt_whisper_message(alice_record_after_send, bob_ciphertext,
               ratchet_key_pair: alice_next_ratchet
             )
  end

  defp encode_distribution_message(%SenderKeyState{} = state) do
    SenderKeyDistributionMessage.new(
      state.sender_key_id,
      state.sender_chain_key.iteration,
      state.sender_chain_key.seed,
      SenderKeyState.signing_key_public(state)
    )
    |> SenderKeyDistributionMessage.encode()
  end

  defp sender_record_from_fixture(fixture) do
    key_pair = %{
      public: decode64!(fixture["state"]["signing_public_key"]),
      private: decode64!(fixture["state"]["signing_private_key"])
    }

    SenderKeyRecord.new()
    |> SenderKeyRecord.set_state(
      fixture["state"]["key_id"],
      fixture["state"]["iteration"],
      decode64!(fixture["state"]["chain_key"]),
      key_pair
    )
  end

  defp fixtures! do
    @fixture_path
    |> File.read!()
    |> JSON.decode!()
  end

  defp decode64!(value) when is_binary(value), do: Base.decode64!(value)

  defp key_pair_from_fixture(%{"public" => public_key, "private" => private_key}) do
    %{public: decode64!(public_key), private: decode64!(private_key)}
  end

  defp decode_sender_key_message_fixture!(value),
    do: value |> decode64!() |> parse_sender_key_message!()

  defp parse_sender_key_message!(value) when is_binary(value) do
    case SenderKeyMessage.decode(value) do
      {:ok, message} -> message
      {:error, reason} -> raise "failed to decode sender-key message fixture: #{inspect(reason)}"
    end
  end

  defp atomize_mapping(%{"lid" => lid, "pn" => pn}), do: %{lid: lid, pn: pn}
end
