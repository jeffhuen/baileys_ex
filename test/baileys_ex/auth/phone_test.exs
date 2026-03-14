defmodule BaileysEx.Auth.PhoneTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Auth.Phone
  alias BaileysEx.BinaryNode
  alias BaileysEx.Connection.Config
  alias BaileysEx.Crypto
  alias BaileysEx.Protocol.BinaryNode, as: BinaryNodeUtil
  alias BaileysEx.Signal.Curve
  alias BaileysEx.TestSupport.DeterministicAuth

  test "derive_pairing_code_key/2 matches the rc9 PBKDF2 output" do
    salt =
      Base.decode16!("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
        case: :mixed
      )

    expected_key =
      Base.decode16!("920ceedbc74a9319a309daf1493c79d001e31d9a6b3ed51cf7374849878d84e4",
        case: :mixed
      )

    assert {:ok, ^expected_key} = Phone.derive_pairing_code_key("ABCDEFGH", salt)
  end

  test "build_pairing_request/4 creates the companion hello node and wraps the ephemeral key" do
    auth_state = DeterministicAuth.state(10)
    config = Config.new(browser: {"Mac OS", "Chrome", "14.4.1"})
    pairing_ephemeral_public = auth_state.pairing_ephemeral_key.public
    noise_public = auth_state.noise_key.public

    assert {:ok, %{pairing_code: "ABCDEFGH", creds_update: creds_update, node: node}} =
             Phone.build_pairing_request("15551234567", auth_state, config,
               custom_pairing_code: "ABCDEFGH"
             )

    assert creds_update == %{
             pairing_code: "ABCDEFGH",
             me: %{id: "15551234567@s.whatsapp.net", name: "~"}
           }

    assert %BinaryNode{
             tag: "iq",
             attrs: %{"to" => "s.whatsapp.net", "type" => "set", "xmlns" => "md"},
             content: [%BinaryNode{tag: "link_code_companion_reg", attrs: attrs} = reg_node]
           } = node

    assert attrs == %{
             "jid" => "15551234567@s.whatsapp.net",
             "stage" => "companion_hello",
             "should_show_push_notification" => "true"
           }

    assert wrapped_ephemeral_public =
             binary_child_content(reg_node, "link_code_pairing_wrapped_companion_ephemeral_pub")

    assert byte_size(wrapped_ephemeral_public) == 80

    <<salt::binary-size(32), iv::binary-size(16), ciphertext::binary-size(32)>> =
      wrapped_ephemeral_public

    assert {:ok, derived_key} = Phone.derive_pairing_code_key("ABCDEFGH", salt)
    assert {:ok, ^pairing_ephemeral_public} = Crypto.aes_ctr_decrypt(derived_key, iv, ciphertext)

    assert binary_child_content(reg_node, "companion_server_auth_key_pub") == noise_public

    assert %BinaryNode{content: "1"} = BinaryNodeUtil.child(reg_node, "companion_platform_id")

    assert %BinaryNode{content: "Chrome (Mac OS)"} =
             BinaryNodeUtil.child(reg_node, "companion_platform_display")

    assert %BinaryNode{content: "0"} = BinaryNodeUtil.child(reg_node, "link_code_pairing_nonce")
  end

  test "build_pairing_request/4 rejects custom pairing codes that are not exactly eight characters" do
    assert {:error, :invalid_custom_pairing_code} =
             Phone.build_pairing_request("15551234567", DeterministicAuth.state(20), Config.new(),
               custom_pairing_code: "SHORT"
             )
  end

  test "build_pairing_request/4 uses injected salt and iv for deterministic wrapping" do
    auth_state = DeterministicAuth.state(30)
    config = Config.new(browser: {"Mac OS", "Chrome", "14.4.1"})
    salt = :binary.copy(<<17>>, 32)
    iv = :binary.copy(<<29>>, 16)

    assert {:ok, %{node: node}} =
             Phone.build_pairing_request("15551234567", auth_state, config,
               custom_pairing_code: "ABCDEFGH",
               pairing_key_salt: salt,
               pairing_key_iv: iv
             )

    wrapped_ephemeral_public =
      node
      |> BinaryNodeUtil.child("link_code_companion_reg")
      |> binary_child_content("link_code_pairing_wrapped_companion_ephemeral_pub")

    assert <<^salt::binary-size(32), ^iv::binary-size(16), _ciphertext::binary-size(32)>> =
             wrapped_ephemeral_public
  end

  test "complete_pairing/3 builds the companion finish node and updates creds deterministically" do
    auth_state =
      DeterministicAuth.state(40, %{
        pairing_code: "ABCDEFGH",
        me: %{id: "15551234567@s.whatsapp.net", name: "~"}
      })

    signed_identity_public = auth_state.signed_identity_key.public

    primary_identity_key = Curve.generate_key_pair(private_key: <<27::256>>)
    code_pairing_key = Curve.generate_key_pair(private_key: <<28::256>>)

    salt =
      <<17::8, 18::8, 19::8, 20::8, 21::8, 22::8, 23::8, 24::8, 25::8, 26::8, 27::8, 28::8, 29::8,
        30::8, 31::8, 32::8, 33::8, 34::8, 35::8, 36::8, 37::8, 38::8, 39::8, 40::8, 41::8, 42::8,
        43::8, 44::8, 45::8, 46::8, 47::8, 48::8>>

    iv = <<48, 47, 46, 45, 44, 43, 42, 41, 40, 39, 38, 37, 36, 35, 34, 33>>
    assert {:ok, pairing_key} = Phone.derive_pairing_code_key("ABCDEFGH", salt)

    assert {:ok, wrapped_public_key} =
             Crypto.aes_ctr_encrypt(pairing_key, iv, code_pairing_key.public)

    finish_random = :binary.copy(<<51>>, 32)
    link_code_salt = :binary.copy(<<68>>, 32)
    encrypt_iv = :binary.copy(<<85>>, 12)

    node =
      %BinaryNode{
        tag: "notification",
        attrs: %{"type" => "set"},
        content: [
          %BinaryNode{
            tag: "link_code_companion_reg",
            attrs: %{},
            content: [
              %BinaryNode{tag: "link_code_pairing_ref", attrs: %{}, content: "ref-123"},
              %BinaryNode{
                tag: "primary_identity_pub",
                attrs: %{},
                content: primary_identity_key.public
              },
              %BinaryNode{
                tag: "link_code_pairing_wrapped_primary_ephemeral_pub",
                attrs: %{},
                content: salt <> iv <> wrapped_public_key
              }
            ]
          }
        ]
      }

    assert {:ok, %{creds_update: creds_update, node: finish_node}} =
             Phone.complete_pairing(node, auth_state,
               finish_random: finish_random,
               link_code_salt: link_code_salt,
               encrypt_iv: encrypt_iv
             )

    assert %{registered: true, adv_secret_key: adv_secret_key} = creds_update
    assert {:ok, decoded_adv_secret_key} = Base.decode64(adv_secret_key)
    assert byte_size(decoded_adv_secret_key) == 32
    refute adv_secret_key == auth_state.adv_secret_key

    assert %BinaryNode{
             tag: "iq",
             attrs: %{"to" => "s.whatsapp.net", "type" => "set", "xmlns" => "md"},
             content: [
               %BinaryNode{
                 tag: "link_code_companion_reg",
                 attrs: %{"stage" => "companion_finish"}
               } = reg_node
             ]
           } = finish_node

    assert binary_child_content(reg_node, "link_code_pairing_ref") == "ref-123"

    assert binary_child_content(reg_node, "companion_identity_public") == signed_identity_public

    assert wrapped_key_bundle =
             binary_child_content(reg_node, "link_code_pairing_wrapped_key_bundle")

    assert byte_size(wrapped_key_bundle) == 156

    assert <<^link_code_salt::binary-size(32), ^encrypt_iv::binary-size(12), ciphertext::binary>> =
             wrapped_key_bundle

    assert {:ok, companion_shared_key} =
             Curve.shared_key(auth_state.pairing_ephemeral_key.private, code_pairing_key.public)

    assert {:ok, link_code_pairing_key} =
             Crypto.hkdf(
               companion_shared_key,
               "link_code_pairing_key_bundle_encryption_key",
               32,
               link_code_salt
             )

    assert {:ok, decrypted_payload} =
             Crypto.aes_gcm_decrypt(link_code_pairing_key, encrypt_iv, ciphertext, <<>>)

    assert decrypted_payload ==
             auth_state.signed_identity_key.public <> primary_identity_key.public <> finish_random
  end

  defp binary_child_content(node, tag) do
    case BinaryNodeUtil.child(node, tag) do
      %BinaryNode{content: {:binary, content}} -> content
      %BinaryNode{content: content} -> content
      nil -> flunk("missing child #{inspect(tag)}")
    end
  end
end
