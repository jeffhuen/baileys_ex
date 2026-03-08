defmodule BaileysEx.Signal.CurveTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Signal.Curve

  test "generate_signal_pub_key prefixes raw public keys and preserves prefixed keys" do
    raw_public_key = :crypto.strong_rand_bytes(32)
    prefixed_public_key = <<5, raw_public_key::binary>>

    assert {:ok, ^prefixed_public_key} = Curve.generate_signal_pub_key(raw_public_key)
    assert {:ok, ^prefixed_public_key} = Curve.generate_signal_pub_key(prefixed_public_key)
    assert {:error, :invalid_public_key} = Curve.generate_signal_pub_key(<<1, 2, 3>>)
  end

  test "sign and verify accept raw and prefixed public keys" do
    key_pair = Curve.generate_key_pair()
    message = "adv account signature payload"

    assert {:ok, signature} = Curve.sign(key_pair.private, message)
    assert byte_size(signature) == 64
    assert Curve.verify(key_pair.public, message, signature)
    assert Curve.verify(<<5, key_pair.public::binary>>, message, signature)

    refute Curve.verify(key_pair.public, "different", signature)
  end

  test "shared_key matches x25519 agreement semantics" do
    alice = Curve.generate_key_pair()
    bob = Curve.generate_key_pair()

    assert {:ok, shared_ab} = Curve.shared_key(alice.private, bob.public)
    assert {:ok, shared_ba} = Curve.shared_key(bob.private, alice.public)
    assert shared_ab == shared_ba
    assert byte_size(shared_ab) == 32
  end

  test "signed_key_pair signs the prefixed pre-key exactly like Baileys" do
    identity_key_pair = Curve.generate_key_pair()

    assert {:ok, signed_pre_key} = Curve.signed_key_pair(identity_key_pair, 7)
    assert %{key_pair: key_pair, signature: signature, key_id: 7} = signed_pre_key
    assert byte_size(key_pair.public) == 32
    assert byte_size(key_pair.private) == 32
    assert byte_size(signature) == 64

    assert {:ok, signal_public_key} = Curve.generate_signal_pub_key(key_pair.public)
    assert Curve.verify(identity_key_pair.public, signal_public_key, signature)
  end
end
