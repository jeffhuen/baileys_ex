defmodule BaileysEx.Signal.Adapter.SignalTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Crypto
  alias BaileysEx.Signal.Adapter.Signal, as: SignalAdapter
  alias BaileysEx.Signal.Curve
  alias BaileysEx.Signal.Repository
  alias BaileysEx.Signal.Store

  # Deterministic key pairs
  defp key_pair(seed), do: Crypto.generate_key_pair(:x25519, private_key: <<seed::256>>)

  defp setup_adapter do
    {:ok, store} = Store.start_link()

    alice_identity = key_pair(100)
    alice_signed_pre_key = key_pair(101)

    adapter_state =
      SignalAdapter.new(
        store: store,
        identity_key_pair: alice_identity,
        registration_id: 1000,
        signed_pre_key: %{key_id: 1, key_pair: alice_signed_pre_key}
      )

    %{
      store: store,
      adapter_state: adapter_state,
      alice_identity: alice_identity,
      alice_signed_pre_key: alice_signed_pre_key
    }
  end

  defp setup_repo do
    ctx = setup_adapter()

    repo =
      Repository.new(
        adapter: SignalAdapter,
        adapter_state: ctx.adapter_state,
        store: ctx.store
      )

    Map.put(ctx, :repo, repo)
  end

  defp bob_session_bundle do
    bob_identity = key_pair(200)
    bob_signed_pre_key = key_pair(201)
    bob_pre_key = key_pair(202)

    {:ok, bob_spk_signal} = Curve.generate_signal_pub_key(bob_signed_pre_key.public)
    {:ok, signature} = Curve.sign(bob_identity.private, bob_spk_signal)

    %{
      registration_id: 2000,
      identity_key: bob_identity.public,
      signed_pre_key: %{
        key_id: 5,
        public_key: bob_signed_pre_key.public,
        signature: signature
      },
      pre_key: %{
        key_id: 10,
        public_key: bob_pre_key.public
      },
      bob_identity: bob_identity,
      bob_signed_pre_key: bob_signed_pre_key,
      bob_pre_key: bob_pre_key
    }
  end

  test "inject_e2e_session + validate_session" do
    ctx = setup_repo()
    bundle = bob_session_bundle()
    jid = "5511999887766@s.whatsapp.net"

    session = Map.take(bundle, [:registration_id, :identity_key, :signed_pre_key, :pre_key])

    assert {:ok, repo} = Repository.inject_e2e_session(ctx.repo, %{jid: jid, session: session})
    assert {:ok, %{exists: true}} = Repository.validate_session(repo, jid)
  end

  test "validate_session returns no_session for unknown JID" do
    ctx = setup_repo()

    assert {:ok, %{exists: false, reason: :no_session}} =
             Repository.validate_session(ctx.repo, "unknown@s.whatsapp.net")
  end

  test "encrypt_message after session injection" do
    ctx = setup_repo()
    bundle = bob_session_bundle()
    jid = "5511999887766@s.whatsapp.net"

    session = Map.take(bundle, [:registration_id, :identity_key, :signed_pre_key, :pre_key])
    {:ok, repo} = Repository.inject_e2e_session(ctx.repo, %{jid: jid, session: session})

    assert {:ok, _repo, encrypted} =
             Repository.encrypt_message(repo, %{jid: jid, data: "hello world"})

    assert encrypted.type in [:pkmsg, :msg]
    assert is_binary(encrypted.ciphertext)
    assert byte_size(encrypted.ciphertext) > 0
  end

  test "full encrypt/decrypt roundtrip through two adapter instances" do
    # Alice setup
    {:ok, alice_store} = Store.start_link()
    alice_identity = key_pair(300)
    alice_signed_pre_key = key_pair(301)
    alice_pre_key = key_pair(302)

    # Store Alice's pre-key
    Store.set(alice_store, %{:"pre-key" => %{"10" => alice_pre_key}})

    alice_state =
      SignalAdapter.new(
        store: alice_store,
        identity_key_pair: alice_identity,
        registration_id: 3000,
        signed_pre_key: %{key_id: 1, key_pair: alice_signed_pre_key}
      )

    # Bob setup
    {:ok, bob_store} = Store.start_link()
    bob_identity = key_pair(400)
    bob_signed_pre_key = key_pair(401)
    bob_pre_key = key_pair(402)

    Store.set(bob_store, %{:"pre-key" => %{"20" => bob_pre_key}})

    bob_state =
      SignalAdapter.new(
        store: bob_store,
        identity_key_pair: bob_identity,
        registration_id: 4000,
        signed_pre_key: %{key_id: 2, key_pair: bob_signed_pre_key}
      )

    # Alice injects Bob's bundle
    {:ok, bob_spk_signal} = Curve.generate_signal_pub_key(bob_signed_pre_key.public)
    {:ok, bob_sig} = Curve.sign(bob_identity.private, bob_spk_signal)

    alice_jid = "alice@s.whatsapp.net"
    bob_jid = "bob@s.whatsapp.net"

    {:ok, alice_address} = BaileysEx.Signal.Address.from_jid(bob_jid)
    {:ok, bob_address} = BaileysEx.Signal.Address.from_jid(alice_jid)

    bob_bundle = %{
      registration_id: 4000,
      identity_key: <<5>> <> bob_identity.public,
      signed_pre_key: %{
        key_id: 2,
        public_key: <<5>> <> bob_signed_pre_key.public,
        signature: bob_sig
      },
      pre_key: %{
        key_id: 20,
        public_key: <<5>> <> bob_pre_key.public
      }
    }

    {:ok, alice_state} = SignalAdapter.inject_e2e_session(alice_state, alice_address, bob_bundle)

    # Alice encrypts
    {:ok, _alice_state, encrypted} =
      SignalAdapter.encrypt_message(alice_state, alice_address, "hello bob")

    assert encrypted.type == :pkmsg

    # Bob decrypts
    {:ok, _bob_state, plaintext} =
      SignalAdapter.decrypt_message(bob_state, bob_address, :pkmsg, encrypted.ciphertext)

    assert plaintext == "hello bob"
  end

  test "delete_sessions removes session" do
    ctx = setup_repo()
    bundle = bob_session_bundle()
    jid = "5511999887766@s.whatsapp.net"

    session = Map.take(bundle, [:registration_id, :identity_key, :signed_pre_key, :pre_key])
    {:ok, repo} = Repository.inject_e2e_session(ctx.repo, %{jid: jid, session: session})

    assert {:ok, %{exists: true}} = Repository.validate_session(repo, jid)

    {:ok, repo} = Repository.delete_session(repo, [jid])

    assert {:ok, %{exists: false, reason: :no_session}} =
             Repository.validate_session(repo, jid)
  end
end
