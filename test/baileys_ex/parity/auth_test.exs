defmodule BaileysEx.Parity.AuthTest do
  use BaileysEx.Parity.Case, async: true

  alias BaileysEx.Auth.Phone
  alias BaileysEx.Connection.Config
  alias BaileysEx.TestSupport.DeterministicAuth

  @pairing_code "ABCDEFGH"
  @pairing_salt :binary.copy(<<0x11>>, 32)
  @pairing_iv :binary.copy(<<0x22>>, 16)

  test "Baileys derivePairingCodeKey matches Elixir PBKDF2 output" do
    expected_hex =
      run_baileys_reference!("auth.derive_pairing_code_key", %{
        "pairing_code" => @pairing_code,
        "salt_base64" => Base.encode64(@pairing_salt)
      })["key_hex"]

    assert {:ok, derived_key} = Phone.derive_pairing_code_key(@pairing_code, @pairing_salt)

    assert Base.encode16(derived_key, case: :lower) == expected_hex
  end

  test "Baileys requestPairingCode companion hello payload matches Elixir build_pairing_request" do
    auth_state = DeterministicAuth.state(40)
    config = Config.new(browser: {"Mac OS", "Chrome", "14.4.1"})

    assert {:ok, %{pairing_code: pairing_code, node: node}} =
             Phone.build_pairing_request("15551234567", auth_state, config,
               custom_pairing_code: @pairing_code,
               pairing_key_salt: @pairing_salt,
               pairing_key_iv: @pairing_iv
             )

    expected =
      run_baileys_reference!("auth.build_pairing_request", %{
        "phone_number" => "15551234567",
        "pairing_code" => @pairing_code,
        "pairing_ephemeral_public_base64" =>
          Base.encode64(auth_state.pairing_ephemeral_key.public),
        "noise_public_base64" => Base.encode64(auth_state.noise_key.public),
        "browser" => %{"platform_name" => "Mac OS", "browser" => "Chrome"},
        "salt_base64" => Base.encode64(@pairing_salt),
        "iv_base64" => Base.encode64(@pairing_iv)
      })

    assert pairing_code == expected["pairing_code"]
    assert normalize_binary_node(node) == expected["node"]
  end
end
