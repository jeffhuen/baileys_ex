defmodule BaileysEx.Message.DecodeTest do
  use ExUnit.Case, async: true

  alias BaileysEx.BinaryNode
  alias BaileysEx.Connection.EventEmitter
  alias BaileysEx.Message.Builder
  alias BaileysEx.Message.Decode
  alias BaileysEx.Message.Receiver
  alias BaileysEx.Protocol.Proto.Message
  alias BaileysEx.Signal.Repository
  alias BaileysEx.Signal.Store
  alias BaileysEx.TestHelpers.MessageSignalHelpers

  test "process_node/3 stores PN/LID mappings from the envelope and migrates decryption to the canonical LID session" do
    {:ok, emitter} = EventEmitter.start_link()
    {repo, store} = MessageSignalHelpers.new_repo()

    :ok = Store.set(store, %{:"device-list" => %{"15551234567" => ["1"]}})

    session = MessageSignalHelpers.session_fixture()

    assert {:ok, repo} =
             Repository.inject_e2e_session(repo, %{
               jid: "15551234567:1@s.whatsapp.net",
               session: session
             })

    plaintext = Builder.build(%{text: "migrated sender"}) |> Message.encode()

    assert {:ok, repo, %{ciphertext: ciphertext}} =
             Repository.encrypt_message(repo, %{
               jid: "15551234567:1@s.whatsapp.net",
               data: plaintext
             })

    node = %BinaryNode{
      tag: "message",
      attrs: %{
        "id" => "lid-migrate-1",
        "from" => "15551234567@s.whatsapp.net",
        "participant" => "15551234567:1@s.whatsapp.net",
        "participant_lid" => "12345:1@lid",
        "t" => "1710000200"
      },
      content: [
        %BinaryNode{tag: "enc", attrs: %{"type" => "pkmsg"}, content: {:binary, ciphertext}}
      ]
    }

    context = %{
      signal_repository: repo,
      signal_store: store,
      event_emitter: emitter,
      me_id: "15550001111@s.whatsapp.net",
      me_lid: "15550001111@lid"
    }

    assert {:ok,
            %{
              key: %{
                remote_jid: "15551234567@s.whatsapp.net",
                remote_jid_alt: "12345@lid",
                addressing_mode: :pn
              }
            }, %{signal_repository: repo}} = Receiver.process_node(node, context)

    assert {:ok, %{exists: true}} = Repository.validate_session(repo, "12345:1@lid")

    assert {:ok, _repo, "12345:1@lid"} =
             Repository.get_lid_for_pn(repo, "15551234567:1@s.whatsapp.net")
  end

  test "decode_envelope/2 infers lid addressing when the attribute is absent and preserves alternate PN addressing" do
    {repo, _store} = MessageSignalHelpers.new_repo()

    node = %BinaryNode{
      tag: "message",
      attrs: %{
        "id" => "lid-1",
        "from" => "12345@lid",
        "sender_pn" => "15551234567@s.whatsapp.net",
        "t" => "1710000201"
      },
      content: []
    }

    context = %{
      signal_repository: repo,
      me_id: "15550001111@s.whatsapp.net",
      me_lid: "15550001111@lid"
    }

    assert {:ok, envelope, %{signal_repository: ^repo}} = Decode.decode_envelope(node, context)
    assert envelope.addressing_mode == :lid
    assert envelope.remote_jid == "12345@lid"
    assert envelope.remote_jid_alt == "15551234567@s.whatsapp.net"
    assert envelope.decryption_jid == "12345@lid"
  end
end
