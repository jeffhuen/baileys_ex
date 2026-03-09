defmodule BaileysEx.Signal.CrossValidationTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Signal.LIDMappingStore
  alias BaileysEx.Signal.Repository
  alias BaileysEx.Signal.Store
  alias BaileysEx.Signal.Address
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
