defmodule BaileysEx.Auth.PairingTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Auth.Pairing
  alias BaileysEx.BinaryNode
  alias BaileysEx.Crypto
  alias BaileysEx.Protocol.Proto.ADVDeviceIdentity
  alias BaileysEx.Protocol.Proto.ADVSignedDeviceIdentity
  alias BaileysEx.Protocol.Proto.ADVSignedDeviceIdentityHMAC
  alias BaileysEx.Signal.Curve
  alias BaileysEx.TestSupport.DeterministicAuth

  test "configure_successful_pairing rejects missing device key index" do
    auth_state = %{
      signed_identity_key: DeterministicAuth.x25519_key_pair(300),
      adv_secret_key: DeterministicAuth.fixed_bytes(32, 301),
      signal_identities: []
    }

    account_signature_key = DeterministicAuth.x25519_key_pair(302)

    device_identity =
      %ADVDeviceIdentity{
        raw_id: 1,
        timestamp: 1_710_000_000,
        key_index: nil,
        device_type: 0
      }

    device_details = ADVDeviceIdentity.encode(device_identity)

    {:ok, account_signature} =
      Curve.sign(
        account_signature_key.private,
        <<6, 0, device_details::binary, auth_state.signed_identity_key.public::binary>>
      )

    account =
      %ADVSignedDeviceIdentity{
        details: device_details,
        account_signature_key: account_signature_key.public,
        account_signature: account_signature,
        device_signature: nil
      }

    account_details = ADVSignedDeviceIdentity.encode(account)

    device_identity_hmac =
      %ADVSignedDeviceIdentityHMAC{
        details: account_details,
        hmac: Crypto.hmac_sha256(auth_state.adv_secret_key, account_details),
        account_type: nil
      }
      |> ADVSignedDeviceIdentityHMAC.encode()

    stanza = %BinaryNode{
      tag: "iq",
      attrs: %{"id" => "pair-success-1", "to" => "s.whatsapp.net", "type" => "result"},
      content: [
        %BinaryNode{
          tag: "pair-success",
          attrs: %{},
          content: [
            %BinaryNode{
              tag: "device-identity",
              attrs: %{},
              content: {:binary, device_identity_hmac}
            },
            %BinaryNode{tag: "platform", attrs: %{"name" => "Chrome"}, content: nil},
            %BinaryNode{
              tag: "device",
              attrs: %{"jid" => "15551234567@s.whatsapp.net", "lid" => "12345678901234@lid"},
              content: nil
            }
          ]
        }
      ]
    }

    assert {:error, :missing_device_identity_key_index} =
             Pairing.configure_successful_pairing(stanza, auth_state)
  end
end
