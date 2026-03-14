defmodule BaileysEx.Signal.IdentityTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Signal.Address
  alias BaileysEx.Signal.Curve
  alias BaileysEx.Signal.Identity
  alias BaileysEx.Signal.Store

  setup do
    {:ok, store} = Store.start_link()
    %{store: store}
  end

  test "trusts first use and loads saved identity keys by signal address", %{store: store} do
    assert {:ok, address} = Address.from_jid("5511999887766@s.whatsapp.net")
    raw_identity_key = Curve.generate_key_pair(private_key: <<11::256>>).public
    expected_identity_key = <<5, raw_identity_key::binary>>

    assert {:ok, :new} = Identity.save(store, address, raw_identity_key)

    assert {:ok, ^expected_identity_key} = Identity.load(store, address)
  end

  test "detects changed identities and leaves unchanged identities alone", %{store: store} do
    assert {:ok, address} = Address.from_jid("5511999887766@s.whatsapp.net")
    identity_one = Curve.generate_key_pair(private_key: <<12::256>>).public
    identity_two = Curve.generate_key_pair(private_key: <<13::256>>).public
    expected_identity_two = <<5, identity_two::binary>>

    assert {:ok, :new} = Identity.save(store, address, identity_one)

    assert {:ok, :unchanged} = Identity.save(store, address, identity_one)

    assert {:ok, :changed} = Identity.save(store, address, identity_two)

    assert {:ok, ^expected_identity_two} = Identity.load(store, address)
  end
end
