defmodule BaileysEx.Auth.ConnectionValidatorRuntimeTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Auth.ConnectionValidator
  alias BaileysEx.Auth.State
  alias BaileysEx.Connection.Config

  test "generate_client_payload/2 selects registration when creds.me is absent" do
    state = State.new()

    assert {:ok, payload} = ConnectionValidator.generate_client_payload(state, Config.new())
    assert is_binary(payload)
    assert byte_size(payload) > 0
  end

  test "generate_client_payload/2 selects login when creds.me is present" do
    state = State.new() |> Map.put(:me, %{id: "15551234567:3@s.whatsapp.net", name: "~"})

    assert {:ok, payload} = ConnectionValidator.generate_client_payload(state, Config.new())
    assert is_binary(payload)
    assert byte_size(payload) > 0
  end
end
