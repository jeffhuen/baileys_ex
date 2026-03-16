defmodule BaileysEx.Signal.SessionBuilderTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Crypto
  alias BaileysEx.Signal.Curve
  alias BaileysEx.Signal.SessionBuilder
  alias BaileysEx.Signal.SessionRecord

  # Deterministic key pairs from fixed seeds
  defp key_pair(seed), do: Crypto.generate_key_pair(:x25519, private_key: <<seed::256>>)

  test "init_outgoing creates session with sending chain" do
    alice_identity = key_pair(1)
    bob_identity = key_pair(2)
    bob_signed_pre_key = key_pair(3)
    bob_pre_key = key_pair(4)
    alice_base_key = key_pair(5)
    alice_sending_ratchet = key_pair(6)

    {:ok, bob_signed_pre_key_signal} = Curve.generate_signal_pub_key(bob_signed_pre_key.public)

    {:ok, _signature} = Curve.sign(bob_identity.private, bob_signed_pre_key_signal)

    bundle = %{
      identity_key: bob_identity.public,
      signed_pre_key: bob_signed_pre_key.public,
      pre_key: bob_pre_key.public,
      registration_id: 42,
      signed_pre_key_id: 7,
      pre_key_id: 8
    }

    record = SessionRecord.new()

    assert {:ok, record, _base_key} =
             SessionBuilder.init_outgoing(record, bundle,
               identity_key_pair: alice_identity,
               base_key_pair: alice_base_key,
               sending_ratchet_pair: alice_sending_ratchet
             )

    assert SessionRecord.have_open_session?(record)
    {_key, session} = SessionRecord.get_open_session(record)

    # Session should have a sending chain (Alice's ratchet key)
    assert Map.has_key?(session.chains, Base.encode64(alice_sending_ratchet.public))

    # Session should have pending pre-key info
    assert session.pending_pre_key != nil
    assert session.pending_pre_key.pre_key_id == 8
    assert session.pending_pre_key.signed_pre_key_id == 7
    assert session.registration_id == 42

    # Verify the identity keys are stored in Signal format (33 bytes)
    assert byte_size(session.index_info.remote_identity_key) == 33
    assert byte_size(session.index_info.local_identity_key) == 33
  end

  test "init_outgoing without one-time pre-key" do
    alice_identity = key_pair(10)
    bob_identity = key_pair(11)
    bob_signed_pre_key = key_pair(12)
    alice_base_key = key_pair(13)

    bundle = %{
      identity_key: bob_identity.public,
      signed_pre_key: bob_signed_pre_key.public,
      pre_key: nil,
      registration_id: 100,
      signed_pre_key_id: 1,
      pre_key_id: nil
    }

    record = SessionRecord.new()

    assert {:ok, record, _base_key} =
             SessionBuilder.init_outgoing(record, bundle,
               identity_key_pair: alice_identity,
               base_key_pair: alice_base_key
             )

    assert SessionRecord.have_open_session?(record)
    {_key, session} = SessionRecord.get_open_session(record)
    assert session.pending_pre_key.pre_key_id == nil
  end

  test "init_incoming creates session with receiving chain" do
    alice_identity = key_pair(20)
    bob_identity = key_pair(21)
    bob_signed_pre_key = key_pair(22)
    alice_base_key = key_pair(23)

    their_message = %{
      identity_key: alice_identity.public,
      base_key: alice_base_key.public
    }

    our_keys = %{
      signed_pre_key: bob_signed_pre_key
    }

    record = SessionRecord.new()

    assert {:ok, record} =
             SessionBuilder.init_incoming(record, their_message, our_keys,
               identity_key_pair: bob_identity,
               registration_id: 55
             )

    assert SessionRecord.have_open_session?(record)
    {_key, session} = SessionRecord.get_open_session(record)

    # Session should have a receiving chain (Alice's base key)
    assert Map.has_key?(session.chains, Base.encode64(alice_base_key.public))
    assert session.index_info.base_key_type == :receiving
    assert session.pending_pre_key == nil
    assert session.registration_id == 55
  end

  test "init_outgoing closes previous open session" do
    alice_identity = key_pair(30)
    bob_identity = key_pair(31)
    bob_signed_pre_key = key_pair(32)
    alice_base_key_1 = key_pair(33)
    alice_base_key_2 = key_pair(34)

    bundle = %{
      identity_key: bob_identity.public,
      signed_pre_key: bob_signed_pre_key.public,
      pre_key: nil,
      registration_id: 1,
      signed_pre_key_id: 1,
      pre_key_id: nil
    }

    record = SessionRecord.new()

    {:ok, record, _} =
      SessionBuilder.init_outgoing(record, bundle,
        identity_key_pair: alice_identity,
        base_key_pair: alice_base_key_1
      )

    # First session is open
    assert SessionRecord.have_open_session?(record)

    {:ok, record, _} =
      SessionBuilder.init_outgoing(record, bundle,
        identity_key_pair: alice_identity,
        base_key_pair: alice_base_key_2
      )

    # Should have exactly one open session (the second one)
    open_sessions =
      Enum.count(record.sessions, fn {_k, s} -> s.index_info.closed == nil end)

    assert open_sessions == 1
    assert map_size(record.sessions) == 2
  end

  test "X3DH shared secret is deterministic" do
    alice_identity = key_pair(40)
    bob_identity = key_pair(41)
    bob_signed_pre_key = key_pair(42)
    bob_pre_key = key_pair(43)
    alice_base_key = key_pair(44)
    alice_ratchet = key_pair(45)

    bundle = %{
      identity_key: bob_identity.public,
      signed_pre_key: bob_signed_pre_key.public,
      pre_key: bob_pre_key.public,
      registration_id: 1,
      signed_pre_key_id: 1,
      pre_key_id: 1
    }

    record1 = SessionRecord.new()
    record2 = SessionRecord.new()

    {:ok, record1, _} =
      SessionBuilder.init_outgoing(record1, bundle,
        identity_key_pair: alice_identity,
        base_key_pair: alice_base_key,
        sending_ratchet_pair: alice_ratchet
      )

    {:ok, record2, _} =
      SessionBuilder.init_outgoing(record2, bundle,
        identity_key_pair: alice_identity,
        base_key_pair: alice_base_key,
        sending_ratchet_pair: alice_ratchet
      )

    {_, session1} = SessionRecord.get_open_session(record1)
    {_, session2} = SessionRecord.get_open_session(record2)

    assert session1.current_ratchet.root_key == session2.current_ratchet.root_key
  end
end
