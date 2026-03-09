defmodule BaileysEx.Signal.IdentityTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Signal.Address
  alias BaileysEx.Signal.Curve
  alias BaileysEx.Signal.Identity

  test "trusts first use and loads saved identity keys by signal address" do
    identity_store = Identity.new()
    assert {:ok, address} = Address.from_jid("5511999887766@s.whatsapp.net")
    raw_identity_key = Curve.generate_key_pair().public
    assert {:ok, expected_identity_key} = Curve.generate_signal_pub_key(raw_identity_key)

    assert {:ok, identity_store, :new} =
             Identity.save(identity_store, address, raw_identity_key)

    assert {:ok, ^expected_identity_key} = Identity.load(identity_store, address)
  end

  test "detects changed identities and leaves unchanged identities alone" do
    assert {:ok, address} = Address.from_jid("5511999887766@s.whatsapp.net")
    identity_one = Curve.generate_key_pair().public
    identity_two = Curve.generate_key_pair().public
    assert {:ok, expected_identity_two} = Curve.generate_signal_pub_key(identity_two)

    assert {:ok, identity_store, :new} = Identity.new() |> Identity.save(address, identity_one)

    assert {:ok, ^identity_store, :unchanged} =
             Identity.save(identity_store, address, identity_one)

    assert {:ok, updated_identity_store, :changed} =
             Identity.save(identity_store, address, identity_two)

    assert {:ok, ^expected_identity_two} = Identity.load(updated_identity_store, address)
  end
end
