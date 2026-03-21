defmodule BaileysEx.Signal.CurveTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Signal.Curve

  test "generate_signal_pub_key prefixes raw public keys and preserves prefixed keys" do
    raw_public_key =
      <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25,
        26, 27, 28, 29, 30, 31, 32>>

    prefixed_public_key = <<5, raw_public_key::binary>>

    assert {:ok, ^prefixed_public_key} = Curve.generate_signal_pub_key(raw_public_key)
    assert {:ok, ^prefixed_public_key} = Curve.generate_signal_pub_key(prefixed_public_key)
    assert {:error, :invalid_public_key} = Curve.generate_signal_pub_key(<<1, 2, 3>>)
  end

  test "ensure_signal helpers normalize raw and prefixed public keys" do
    raw_public_key =
      <<27, 26, 25, 24, 23, 22, 21, 20, 19, 18, 17, 16, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4,
        3, 2, 1, 0, 31, 30, 29, 28>>

    prefixed_public_key = <<5, raw_public_key::binary>>
    key_pair = %{public: raw_public_key, private: <<28::256>>}

    assert %{public: ^prefixed_public_key, private: <<28::256>>} =
             Curve.ensure_signal_key_pair!(key_pair)

    assert prefixed_public_key == Curve.ensure_signal_public_key!(raw_public_key)
    assert prefixed_public_key == Curve.ensure_signal_public_key!(prefixed_public_key)
  end

  test "ensure_signal helpers raise on invalid public keys" do
    assert_raise MatchError, fn ->
      Curve.ensure_signal_public_key!(<<1, 2, 3>>)
    end

    assert_raise MatchError, fn ->
      Curve.ensure_signal_key_pair!(%{public: <<1, 2, 3>>, private: <<29::256>>})
    end
  end

  test "sign and verify accept raw and prefixed public keys" do
    key_pair = Curve.generate_key_pair(private_key: <<14::256>>)
    message = "adv account signature payload"

    assert {:ok, signature} = Curve.sign(key_pair.private, message)
    assert byte_size(signature) == 64
    assert Curve.verify(key_pair.public, message, signature)
    assert Curve.verify(<<5, key_pair.public::binary>>, message, signature)

    refute Curve.verify(key_pair.public, "different", signature)
  end

  test "shared_key matches x25519 agreement semantics" do
    alice = Curve.generate_key_pair(private_key: <<15::256>>)
    bob = Curve.generate_key_pair(private_key: <<16::256>>)

    assert {:ok, shared_ab} = Curve.shared_key(alice.private, bob.public)
    assert {:ok, shared_ba} = Curve.shared_key(bob.private, alice.public)
    assert shared_ab == shared_ba
    assert byte_size(shared_ab) == 32
  end

  test "signed_key_pair signs the prefixed pre-key exactly like Baileys" do
    identity_key_pair = Curve.generate_key_pair(private_key: <<17::256>>)

    assert {:ok, signed_pre_key} =
             Curve.signed_key_pair(identity_key_pair, 7,
               key_pair: Curve.generate_key_pair(private_key: <<18::256>>)
             )

    assert %{key_pair: key_pair, signature: signature, key_id: 7} = signed_pre_key
    assert byte_size(key_pair.public) == 32
    assert byte_size(key_pair.private) == 32
    assert byte_size(signature) == 64

    assert {:ok, signal_public_key} = Curve.generate_signal_pub_key(key_pair.public)
    assert Curve.verify(identity_key_pair.public, signal_public_key, signature)
  end

  test "matches the reference curve25519-js signature bytes for sender-key signing" do
    private_key = Base.decode64!("AAIcmaF2D5rTsgGZo9h4oqGa393qFKjilfMfUDqr8G8=")
    public_key = Base.decode64!("BYBnBY4toVNm9NPplrAdbCEr09r7ZvolG0erkS7zMnBY")
    message = <<1, 2, 3>>

    expected_signature =
      Base.decode16!(
        "510628a855f33a9cf4d6b3d353d20042d5228c409fed17c5f0121dcc9695c280" <>
          "da292e0fa34a6af9f4dc0aadb3c1637d8c9c313fa6e0bc188d36472e036ea88c",
        case: :mixed
      )

    assert {:ok, ^expected_signature} = Curve.sign(private_key, message)
    assert Curve.verify(public_key, message, expected_signature)
  end

  describe "error paths" do
    test "shared_key rejects invalid private key sizes" do
      valid_public = <<19::256>>
      assert {:error, :invalid_private_key} = Curve.shared_key(<<1, 2, 3>>, valid_public)
      assert {:error, :invalid_private_key} = Curve.shared_key(<<>>, valid_public)

      too_long = :binary.copy(<<20>>, 33)
      assert {:error, :invalid_private_key} = Curve.shared_key(too_long, valid_public)
    end

    test "shared_key rejects invalid public key sizes" do
      valid_private = <<21::256>>
      assert {:error, :invalid_public_key} = Curve.shared_key(valid_private, <<1, 2, 3>>)
      assert {:error, :invalid_public_key} = Curve.shared_key(valid_private, <<>>)

      too_long = :binary.copy(<<22>>, 34)
      assert {:error, :invalid_public_key} = Curve.shared_key(valid_private, too_long)
    end

    test "shared_key accepts Signal-prefixed (33-byte) public keys" do
      alice = Curve.generate_key_pair(private_key: <<23::256>>)
      bob = Curve.generate_key_pair(private_key: <<24::256>>)
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
      refute Curve.verify(<<1, 2, 3>>, "message", :binary.copy(<<25>>, 64))
    end

    test "signed_key_pair rejects non-map identity key" do
      assert {:error, :invalid_identity_key} = Curve.signed_key_pair("not a map", 1)
    end

    test "signed_key_pair rejects negative key_id" do
      key_pair = Curve.generate_key_pair(private_key: <<26::256>>)
      assert {:error, :invalid_identity_key} = Curve.signed_key_pair(key_pair, -1)
    end
  end
end
