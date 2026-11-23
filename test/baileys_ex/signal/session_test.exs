defmodule BaileysEx.Signal.SessionTest do
  use ExUnit.Case, async: true

  alias BaileysEx.BinaryNode
  alias BaileysEx.Crypto
  alias BaileysEx.Signal.Adapter.Signal, as: SignalAdapter
  alias BaileysEx.Signal.Address
  alias BaileysEx.Signal.Curve
  alias BaileysEx.Signal.Repository
  alias BaileysEx.Signal.Session
  alias BaileysEx.Signal.Store

  @alice_jid "5511900000001@s.whatsapp.net"
  @bob_jid "5511900000002@s.whatsapp.net"

  defp key_pair(seed), do: Crypto.generate_key_pair(:x25519, private_key: <<seed::256>>)

  defp adapter(seed, registration_id) do
    {:ok, store} = Store.new()
    identity = key_pair(seed)
    signed_pre_key = key_pair(seed + 1)

    state =
      SignalAdapter.new(
        store: store,
        identity_key_pair: identity,
        registration_id: registration_id,
        signed_pre_key: %{key_id: 7, key_pair: signed_pre_key}
      )

    %{store: store, state: state, identity: identity, signed_pre_key: signed_pre_key}
  end

  defp bytes_node(tag, bytes), do: %BinaryNode{tag: tag, attrs: %{}, content: {:binary, bytes}}

  defp user_node_without_one_time_pre_key(bob) do
    {:ok, signed_public} = Curve.generate_signal_pub_key(bob.signed_pre_key.public)
    {:ok, signature} = Curve.sign(bob.identity.private, signed_public)

    %BinaryNode{
      tag: "user",
      attrs: %{"jid" => @bob_jid},
      content: [
        bytes_node("registration", <<4000::unsigned-big-32>>),
        bytes_node("identity", bob.identity.public),
        %BinaryNode{
          tag: "skey",
          attrs: %{},
          content: [
            bytes_node("id", <<7::unsigned-big-24>>),
            bytes_node("value", bob.signed_pre_key.public),
            bytes_node("signature", signature)
          ]
        }
      ]
    }
  end

  test "parse_and_inject_e2e_sessions/2 builds a session when the device has no one-time pre-key" do
    alice = adapter(500, 3000)
    bob = adapter(600, 4000)

    repo = Repository.new(adapter: SignalAdapter, adapter_state: alice.state, store: alice.store)

    response = %BinaryNode{
      tag: "iq",
      attrs: %{},
      content: [
        %BinaryNode{tag: "list", attrs: %{}, content: [user_node_without_one_time_pre_key(bob)]}
      ]
    }

    assert {:ok, repo} = Session.parse_and_inject_e2e_sessions(response, repo)
    assert {:ok, %{exists: true}} = Repository.validate_session(repo, @bob_jid)

    assert {:ok, _repo, %{type: :pkmsg, ciphertext: ciphertext}} =
             Repository.encrypt_message(repo, %{jid: @bob_jid, data: "hello bob"})

    {:ok, alice_address} = Address.from_jid(@alice_jid)

    assert {:ok, _bob_state, "hello bob"} =
             SignalAdapter.decrypt_message(bob.state, alice_address, :pkmsg, ciphertext)
  end
end
