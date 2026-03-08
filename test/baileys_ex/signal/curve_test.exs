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

  describe "error paths" do
    test "shared_key rejects invalid private key sizes" do
      valid_public = :crypto.strong_rand_bytes(32)
      assert {:error, :invalid_private_key} = Curve.shared_key(<<1, 2, 3>>, valid_public)
      assert {:error, :invalid_private_key} = Curve.shared_key(<<>>, valid_public)

      too_long = :crypto.strong_rand_bytes(33)
      assert {:error, :invalid_private_key} = Curve.shared_key(too_long, valid_public)
    end

    test "shared_key rejects invalid public key sizes" do
      valid_private = :crypto.strong_rand_bytes(32)
      assert {:error, :invalid_public_key} = Curve.shared_key(valid_private, <<1, 2, 3>>)
      assert {:error, :invalid_public_key} = Curve.shared_key(valid_private, <<>>)

      too_long = :crypto.strong_rand_bytes(34)
      assert {:error, :invalid_public_key} = Curve.shared_key(valid_private, too_long)
    end

    test "shared_key accepts Signal-prefixed (33-byte) public keys" do
      alice = Curve.generate_key_pair()
      bob = Curve.generate_key_pair()
      prefixed_bob = <<5, bob.public::binary>>

      assert {:ok, shared_raw} = Curve.shared_key(alice.private, bob.public)
      assert {:ok, shared_prefixed} = Curve.shared_key(alice.private, prefixed_bob)
      assert shared_raw == shared_prefixed
    end

    test "sign rejects invalid private key sizes" do
      assert {:error, :invalid_private_key} = Curve.sign(<<1, 2, 3>>, "message")
      assert {:error, :invalid_private_key} = Curve.sign(<<>>, "message")
    end

    test "verify returns false for invalid public key sizes" do
      refute Curve.verify(<<1, 2, 3>>, "message", :crypto.strong_rand_bytes(64))
    end

    test "signed_key_pair rejects non-map identity key" do
      assert {:error, :invalid_identity_key} = Curve.signed_key_pair("not a map", 1)
    end

    test "signed_key_pair rejects negative key_id" do
      key_pair = Curve.generate_key_pair()
      assert {:error, :invalid_identity_key} = Curve.signed_key_pair(key_pair, -1)
    end
  end
end
