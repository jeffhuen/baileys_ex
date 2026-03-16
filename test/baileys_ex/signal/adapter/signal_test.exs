defmodule BaileysEx.Signal.Adapter.SignalTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Crypto
  alias BaileysEx.Signal.Address
  alias BaileysEx.Signal.Adapter.Signal, as: SignalAdapter
  alias BaileysEx.Signal.Curve
  alias BaileysEx.Signal.Identity
  alias BaileysEx.Signal.Repository
  alias BaileysEx.Signal.SessionRecord
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

  test "migrate_sessions only copies open sessions and reports skipped work" do
    ctx = setup_adapter()

    {:ok, open_from} = Address.from_jid("5511999887766@s.whatsapp.net")
    {:ok, open_to} = Address.from_jid("12345@lid")
    {:ok, closed_from} = Address.from_jid("5511999887766:2@s.whatsapp.net")
    {:ok, closed_to} = Address.from_jid("12345:2@lid")
    {:ok, missing_from} = Address.from_jid("5511999887766:3@s.whatsapp.net")
    {:ok, missing_to} = Address.from_jid("12345:3@lid")

    open_key = Address.to_string(open_from)
    closed_key = Address.to_string(closed_from)

    :ok =
      Store.set(ctx.store, %{
        session: %{
          open_key => session_record(:open, 900),
          closed_key => session_record(:closed, 901)
        }
      })

    operations = [
      %{
        from: open_from,
        to: open_to,
        pn_user: "5511999887766",
        lid_user: "12345",
        device_id: 0
      },
      %{
        from: closed_from,
        to: closed_to,
        pn_user: "5511999887766",
        lid_user: "12345",
        device_id: 2
      },
      %{
        from: missing_from,
        to: missing_to,
        pn_user: "5511999887766",
        lid_user: "12345",
        device_id: 3
      }
    ]

    assert {:ok, _state, %{migrated: 1, skipped: 2, total: 3}} =
             SignalAdapter.migrate_sessions(ctx.adapter_state, operations)

    refute Store.get(ctx.store, :session, [open_key]) |> Map.has_key?(open_key)

    migrated_key = Address.to_string(open_to)

    assert %{^migrated_key => %SessionRecord{} = migrated_record} =
             Store.get(ctx.store, :session, [migrated_key])

    assert SessionRecord.have_open_session?(migrated_record)

    assert %{^closed_key => %SessionRecord{} = closed_record} =
             Store.get(ctx.store, :session, [closed_key])

    refute SessionRecord.have_open_session?(closed_record)

    closed_target_key = Address.to_string(closed_to)
    refute Store.get(ctx.store, :session, [closed_target_key]) |> Map.has_key?(closed_target_key)
  end

  test "decrypting a pkmsg with a changed identity replaces the stored session record" do
    # Bob setup
    {:ok, bob_store} = Store.start_link()
    bob_identity = key_pair(500)
    bob_signed_pre_key = key_pair(501)
    bob_pre_key_one = key_pair(502)
    bob_pre_key_two = key_pair(503)

    Store.set(bob_store, %{
      :"pre-key" => %{
        "20" => bob_pre_key_one,
        "21" => bob_pre_key_two
      }
    })

    bob_state =
      SignalAdapter.new(
        store: bob_store,
        identity_key_pair: bob_identity,
        registration_id: 5000,
        signed_pre_key: %{key_id: 9, key_pair: bob_signed_pre_key}
      )

    alice_jid = "alice@s.whatsapp.net"
    bob_jid = "bob@s.whatsapp.net"

    {:ok, alice_address} = Address.from_jid(bob_jid)
    {:ok, bob_address} = Address.from_jid(alice_jid)

    first_alice = build_sender_state(600)
    second_alice = build_sender_state(700)

    first_bundle =
      recipient_bundle(
        bob_identity,
        bob_signed_pre_key,
        %{key_id: 20, public_key: bob_pre_key_one.public},
        5000,
        9
      )

    second_bundle =
      recipient_bundle(
        bob_identity,
        bob_signed_pre_key,
        %{key_id: 21, public_key: bob_pre_key_two.public},
        5000,
        9
      )

    {:ok, first_alice} = SignalAdapter.inject_e2e_session(first_alice, alice_address, first_bundle)

    {:ok, _first_alice, first_message} =
      SignalAdapter.encrypt_message(first_alice, alice_address, "hello from alice one")

    assert {:ok, bob_state, "hello from alice one"} =
             SignalAdapter.decrypt_message(
               bob_state,
               bob_address,
               :pkmsg,
               first_message.ciphertext
             )

    first_identity = prefixed_public_key(first_alice.identity_key_pair.public)

    assert {:ok, ^first_identity} = Identity.load(bob_store, bob_address)

    first_record = load_session_record(bob_store, bob_address)
    assert map_size(first_record.sessions) == 1

    {:ok, second_alice} =
      SignalAdapter.inject_e2e_session(second_alice, alice_address, second_bundle)

    {:ok, _second_alice, second_message} =
      SignalAdapter.encrypt_message(second_alice, alice_address, "hello from alice two")

    assert {:ok, _bob_state, "hello from alice two"} =
             SignalAdapter.decrypt_message(
               bob_state,
               bob_address,
               :pkmsg,
               second_message.ciphertext
             )

    second_identity = prefixed_public_key(second_alice.identity_key_pair.public)

    assert {:ok, ^second_identity} = Identity.load(bob_store, bob_address)

    replaced_record = load_session_record(bob_store, bob_address)
    assert map_size(replaced_record.sessions) == 1
    assert SessionRecord.have_open_session?(replaced_record)
  end

  defp build_sender_state(seed) do
    {:ok, store} = Store.start_link()
    identity_key_pair = key_pair(seed)
    signed_pre_key = key_pair(seed + 1)

    SignalAdapter.new(
      store: store,
      identity_key_pair: identity_key_pair,
      registration_id: seed * 10,
      signed_pre_key: %{key_id: seed, key_pair: signed_pre_key}
    )
  end

  defp recipient_bundle(identity_key_pair, signed_pre_key_pair, pre_key, registration_id, key_id) do
    {:ok, signed_pre_key_signal} = Curve.generate_signal_pub_key(signed_pre_key_pair.public)
    {:ok, signature} = Curve.sign(identity_key_pair.private, signed_pre_key_signal)

    %{
      registration_id: registration_id,
      identity_key: prefixed_public_key(identity_key_pair.public),
      signed_pre_key: %{
        key_id: key_id,
        public_key: prefixed_public_key(signed_pre_key_pair.public),
        signature: signature
      },
      pre_key: %{
        key_id: pre_key.key_id,
        public_key: prefixed_public_key(pre_key.public_key)
      }
    }
  end

  defp prefixed_public_key(public_key) do
    {:ok, prefixed_public_key} = Curve.generate_signal_pub_key(public_key)
    prefixed_public_key
  end

  defp load_session_record(store, address) do
    session_key = Address.to_string(address)

    case Store.get(store, :session, [session_key]) do
      %{^session_key => %SessionRecord{} = record} -> record
      _ -> SessionRecord.new()
    end
  end

  defp session_record(status, seed) do
    base_key = <<seed::unsigned-big-256>>

    session = %{
      current_ratchet: %{
        root_key: <<(seed + 1)::unsigned-big-256>>,
        ephemeral_key_pair: %{
          public: <<(seed + 2)::unsigned-big-256>>,
          private: <<(seed + 3)::unsigned-big-256>>
        },
        last_remote_ephemeral: <<(seed + 4)::unsigned-big-256>>,
        previous_counter: 0
      },
      index_info: %{
        remote_identity_key: <<5, (seed + 5)::unsigned-big-256>>,
        local_identity_key: <<5, (seed + 6)::unsigned-big-256>>,
        base_key: base_key,
        base_key_type: :sending,
        closed: if(status == :open, do: nil, else: seed)
      },
      chains: %{},
      pending_pre_key: nil,
      registration_id: seed
    }

    SessionRecord.new()
    |> SessionRecord.put_session(base_key, session)
  end
end
