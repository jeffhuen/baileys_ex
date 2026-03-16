defmodule BaileysEx.Signal.SessionCipherTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Crypto
  alias BaileysEx.Signal.Curve
  alias BaileysEx.Signal.PreKeyWhisperMessage
  alias BaileysEx.Signal.SessionBuilder
  alias BaileysEx.Signal.SessionCipher
  alias BaileysEx.Signal.SessionRecord
  alias BaileysEx.Signal.WhisperMessage

  # Deterministic key pairs
  defp key_pair(seed), do: Crypto.generate_key_pair(:x25519, private_key: <<seed::256>>)

  # Set up an Alice→Bob session pair
  defp setup_session do
    alice_identity = key_pair(1)
    bob_identity = key_pair(2)
    bob_signed_pre_key = key_pair(3)
    bob_pre_key = key_pair(4)
    alice_base_key = key_pair(5)
    alice_ratchet = key_pair(6)

    bundle = %{
      identity_key: bob_identity.public,
      signed_pre_key: bob_signed_pre_key.public,
      pre_key: bob_pre_key.public,
      registration_id: 42,
      signed_pre_key_id: 7,
      pre_key_id: 8
    }

    # Alice builds outgoing session
    {:ok, alice_record, _base_key} =
      SessionBuilder.init_outgoing(SessionRecord.new(), bundle,
        identity_key_pair: alice_identity,
        base_key_pair: alice_base_key,
        sending_ratchet_pair: alice_ratchet
      )

    %{
      alice_record: alice_record,
      alice_base_key: alice_base_key,
      alice_identity: alice_identity,
      bob_identity: bob_identity,
      bob_signed_pre_key: bob_signed_pre_key,
      bob_pre_key: bob_pre_key,
      bob_registration_id: 42
    }
  end

  test "Alice→Bob full roundtrip with PreKeyWhisperMessage" do
    ctx = setup_session()

    # Alice encrypts
    {:ok, _alice_record, encrypted} =
      SessionCipher.encrypt(ctx.alice_record, "hello bob")

    assert encrypted.type == :pkmsg

    {:ok, pkmsg} = PreKeyWhisperMessage.decode(encrypted.ciphertext)
    assert pkmsg.base_key == signal_public_key(ctx.alice_base_key.public)
    assert byte_size(pkmsg.base_key) == 33

    # Bob decrypts the PreKeyWhisperMessage
    bob_record = SessionRecord.new()

    {:ok, bob_record, plaintext, used_pre_key_id} =
      SessionCipher.decrypt_pre_key_whisper_message(bob_record, encrypted.ciphertext,
        identity_key_pair: ctx.bob_identity,
        signed_pre_key_pair: ctx.bob_signed_pre_key,
        pre_key_pair: ctx.bob_pre_key,
        registration_id: ctx.bob_registration_id
      )

    assert plaintext == "hello bob"
    assert used_pre_key_id == 8
    assert SessionRecord.have_open_session?(bob_record)
  end

  test "bidirectional messaging after session establishment" do
    ctx = setup_session()

    # Alice → Bob (first message, PreKeyWhisperMessage)
    {:ok, alice_record, encrypted1} =
      SessionCipher.encrypt(ctx.alice_record, "hello")

    bob_record = SessionRecord.new()

    {:ok, bob_record, "hello", _pre_key_id} =
      SessionCipher.decrypt_pre_key_whisper_message(bob_record, encrypted1.ciphertext,
        identity_key_pair: ctx.bob_identity,
        signed_pre_key_pair: ctx.bob_signed_pre_key,
        pre_key_pair: ctx.bob_pre_key,
        registration_id: ctx.bob_registration_id
      )

    # Alice → Bob (second message, should still be pkmsg because pending_pre_key exists)
    {:ok, alice_record, encrypted2} =
      SessionCipher.encrypt(alice_record, "how are you?")

    {:ok, bob_record, "how are you?", _} =
      SessionCipher.decrypt_pre_key_whisper_message(bob_record, encrypted2.ciphertext,
        identity_key_pair: ctx.bob_identity,
        signed_pre_key_pair: ctx.bob_signed_pre_key,
        pre_key_pair: ctx.bob_pre_key,
        registration_id: ctx.bob_registration_id
      )

    # Bob → Alice (Bob needs to encrypt, triggering ratchet)
    {:ok, _bob_record, encrypted3} =
      SessionCipher.encrypt(bob_record, "i'm fine")

    # Bob's message should be decryptable by Alice
    {:ok, alice_record, plaintext} =
      SessionCipher.decrypt_whisper_message(alice_record, encrypted3.ciphertext)

    assert plaintext == "i'm fine"

    {:ok, _alice_record, followup} =
      SessionCipher.encrypt(alice_record, "follow up")

    assert followup.type == :msg
  end

  test "encrypt fails with no session" do
    record = SessionRecord.new()
    assert {:error, :no_session} = SessionCipher.encrypt(record, "test")
  end

  test "decrypt_whisper_message fails with no matching session" do
    # Create a valid whisper message format (not pkmsg) that no session can decrypt
    empty_record = SessionRecord.new()

    # A properly formatted WhisperMessage that won't match any session
    # Build a minimal WhisperMessage wire format: version_byte + protobuf + 8-byte MAC
    ratchet_key = :binary.copy(<<0xFF>>, 32)

    alias BaileysEx.Protocol.Proto.Wire

    payload =
      Wire.encode_bytes(1, ratchet_key) <>
        Wire.encode_uint(2, 0) <>
        Wire.encode_uint(3, 0) <>
        Wire.encode_bytes(4, :binary.copy(<<0>>, 16))

    fake_whisper = <<0x33>> <> payload <> :binary.copy(<<0>>, 8)

    assert {:error, :no_session} =
             SessionCipher.decrypt_whisper_message(empty_record, fake_whisper)
  end

  test "multiple sequential messages from Alice to Bob" do
    ctx = setup_session()

    # Send 5 messages
    messages = ["one", "two", "three", "four", "five"]

    {_alice_record, ciphertexts} =
      Enum.reduce(messages, {ctx.alice_record, []}, fn msg, {record, cts} ->
        {:ok, record, encrypted} = SessionCipher.encrypt(record, msg)
        {record, cts ++ [encrypted]}
      end)

    # Decrypt all on Bob's side
    bob_record = SessionRecord.new()

    # First message (pkmsg)
    first = hd(ciphertexts)

    {:ok, bob_record, "one", _} =
      SessionCipher.decrypt_pre_key_whisper_message(bob_record, first.ciphertext,
        identity_key_pair: ctx.bob_identity,
        signed_pre_key_pair: ctx.bob_signed_pre_key,
        pre_key_pair: ctx.bob_pre_key,
        registration_id: ctx.bob_registration_id
      )

    # Remaining messages (also pkmsg because Alice hasn't cleared pending_pre_key)
    Enum.reduce(Enum.zip(tl(ciphertexts), tl(messages)), bob_record, fn {ct, expected}, record ->
      {:ok, record, ^expected, _} =
        SessionCipher.decrypt_pre_key_whisper_message(record, ct.ciphertext,
          identity_key_pair: ctx.bob_identity,
          signed_pre_key_pair: ctx.bob_signed_pre_key,
          pre_key_pair: ctx.bob_pre_key,
          registration_id: ctx.bob_registration_id
        )

      record
    end)
  end

  test "deterministic encryption produces same ciphertext" do
    ctx = setup_session()

    {:ok, _record1, encrypted1} =
      SessionCipher.encrypt(ctx.alice_record, "deterministic")

    {:ok, _record2, encrypted2} =
      SessionCipher.encrypt(ctx.alice_record, "deterministic")

    # Same input + same session state → same output
    assert encrypted1.ciphertext == encrypted2.ciphertext
    assert encrypted1.type == encrypted2.type
  end

  test "session without pre-key produces :msg type" do
    ctx = setup_session()

    # Alice sends first message (pkmsg)
    {:ok, _alice_record, encrypted1} =
      SessionCipher.encrypt(ctx.alice_record, "first")

    # Bob decrypts and establishes session
    bob_record = SessionRecord.new()

    {:ok, bob_record, "first", _} =
      SessionCipher.decrypt_pre_key_whisper_message(bob_record, encrypted1.ciphertext,
        identity_key_pair: ctx.bob_identity,
        signed_pre_key_pair: ctx.bob_signed_pre_key,
        pre_key_pair: ctx.bob_pre_key,
        registration_id: ctx.bob_registration_id
      )

    # Bob encrypts (no pending_pre_key on Bob's side)
    {:ok, _bob_record, bob_encrypted} =
      SessionCipher.encrypt(bob_record, "reply")

    # Bob's message type should be :msg (not :pkmsg) since Bob has no pending pre-key
    assert bob_encrypted.type == :msg
  end

  test "duplicate pre-key message replay is rejected after first successful decrypt" do
    ctx = setup_session()

    {:ok, _alice_record, encrypted} =
      SessionCipher.encrypt(ctx.alice_record, "hello bob")

    opts = [
      identity_key_pair: ctx.bob_identity,
      signed_pre_key_pair: ctx.bob_signed_pre_key,
      pre_key_pair: ctx.bob_pre_key,
      registration_id: ctx.bob_registration_id
    ]

    {:ok, bob_record, "hello bob", _} =
      SessionCipher.decrypt_pre_key_whisper_message(
        SessionRecord.new(),
        encrypted.ciphertext,
        opts
      )

    assert {:error, :no_session} =
             SessionCipher.decrypt_pre_key_whisper_message(
               bob_record,
               encrypted.ciphertext,
               opts
             )
  end

  test "out-of-order established messages decrypt using cached skipped keys" do
    ctx = setup_session()

    {:ok, alice_record, first_message} =
      SessionCipher.encrypt(ctx.alice_record, "hello")

    {:ok, bob_record, "hello", _} =
      SessionCipher.decrypt_pre_key_whisper_message(SessionRecord.new(), first_message.ciphertext,
        identity_key_pair: ctx.bob_identity,
        signed_pre_key_pair: ctx.bob_signed_pre_key,
        pre_key_pair: ctx.bob_pre_key,
        registration_id: ctx.bob_registration_id
      )

    {:ok, bob_record, bob_reply} =
      SessionCipher.encrypt(bob_record, "reply")

    {:ok, alice_record, "reply"} =
      SessionCipher.decrypt_whisper_message(alice_record, bob_reply.ciphertext,
        ratchet_key_pair: key_pair(7)
      )

    {:ok, alice_record, followup_one} =
      SessionCipher.encrypt(alice_record, "one")

    {:ok, _alice_record, followup_two} =
      SessionCipher.encrypt(alice_record, "two")

    assert followup_one.type == :msg
    assert followup_two.type == :msg

    {:ok, bob_record, "two"} =
      SessionCipher.decrypt_whisper_message(bob_record, followup_two.ciphertext)

    {:ok, _bob_record, "one"} =
      SessionCipher.decrypt_whisper_message(bob_record, followup_one.ciphertext)
  end

  test "ratchet step drops the prior sending chain after processing a reply" do
    ctx = setup_session()

    {_, initial_alice_session} = SessionRecord.get_open_session(ctx.alice_record)

    initial_chain_key =
      Base.encode64(initial_alice_session.current_ratchet.ephemeral_key_pair.public)

    {:ok, alice_record, first_message} =
      SessionCipher.encrypt(ctx.alice_record, "hello")

    {:ok, bob_record, "hello", _} =
      SessionCipher.decrypt_pre_key_whisper_message(SessionRecord.new(), first_message.ciphertext,
        identity_key_pair: ctx.bob_identity,
        signed_pre_key_pair: ctx.bob_signed_pre_key,
        pre_key_pair: ctx.bob_pre_key,
        registration_id: ctx.bob_registration_id
      )

    {:ok, _bob_record, bob_reply} =
      SessionCipher.encrypt(bob_record, "reply")

    {:ok, bob_reply_msg} = WhisperMessage.decode(bob_reply.ciphertext)
    next_alice_ratchet = key_pair(8)

    {:ok, alice_record, "reply"} =
      SessionCipher.decrypt_whisper_message(alice_record, bob_reply.ciphertext,
        ratchet_key_pair: next_alice_ratchet
      )

    {_, updated_alice_session} = SessionRecord.get_open_session(alice_record)

    refute Map.has_key?(updated_alice_session.chains, initial_chain_key)

    assert %{
             chain_type: :receiving
           } = updated_alice_session.chains[Base.encode64(bob_reply_msg.ratchet_key)]

    assert %{
             chain_type: :sending
           } = updated_alice_session.chains[Base.encode64(signal_public_key(next_alice_ratchet.public))]
  end

  defp signal_public_key(public_key) do
    {:ok, signal_public_key} = Curve.generate_signal_pub_key(public_key)
    signal_public_key
  end
end
