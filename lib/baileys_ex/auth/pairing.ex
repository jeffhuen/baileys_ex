defmodule BaileysEx.Auth.Pairing do
  @moduledoc false

  alias BaileysEx.BinaryNode
  alias BaileysEx.Crypto
  alias BaileysEx.Protocol.BinaryNode, as: BinaryNodeUtil
  alias BaileysEx.Protocol.Proto.ADVDeviceIdentity
  alias BaileysEx.Protocol.Proto.ADVEncryptionType
  alias BaileysEx.Protocol.Proto.ADVSignedDeviceIdentity
  alias BaileysEx.Protocol.Proto.ADVSignedDeviceIdentityHMAC
  alias BaileysEx.Signal.Curve

  @account_sig_prefix <<6, 0>>
  @device_sig_prefix <<6, 1>>
  @hosted_account_sig_prefix <<6, 5>>
  @s_whatsapp_net "s.whatsapp.net"

  @spec configure_successful_pairing(BinaryNode.t(), map()) ::
          {:ok, %{reply: BinaryNode.t(), creds_update: map()}} | {:error, term()}
  def configure_successful_pairing(%BinaryNode{} = stanza, auth_state) when is_map(auth_state) do
    with {:ok, pair_success_node} <- fetch_child(stanza, "pair-success"),
         {:ok, device_identity_node} <- fetch_child(pair_success_node, "device-identity"),
         {:ok, device_identity_hmac} <- fetch_binary_content(device_identity_node),
         {:ok, device_identity_hmac} <- ADVSignedDeviceIdentityHMAC.decode(device_identity_hmac),
         {:ok, adv_secret_key} <- fetch_adv_secret_key(auth_state),
         :ok <- verify_pairing_hmac(device_identity_hmac, adv_secret_key),
         {:ok, account} <- ADVSignedDeviceIdentity.decode(device_identity_hmac.details),
         {:ok, device_identity} <- ADVDeviceIdentity.decode(account.details),
         {:ok, signed_identity_key} <- fetch_signed_identity_key(auth_state),
         :ok <- verify_account_signature(account, device_identity, signed_identity_key.public),
         {:ok, device_signature} <-
           Curve.sign(
             signed_identity_key.private,
             @device_sig_prefix <>
               account.details <> signed_identity_key.public <> account.account_signature_key
           ),
         {:ok, signal_identity} <-
           create_signal_identity(
             fetch_attr!(pair_success_node, "device", "lid"),
             account.account_signature_key
           ) do
      account = %{account | device_signature: device_signature}
      reply = reply_node(stanza.attrs["id"], device_identity.key_index, encode_account(account))

      creds_update = %{
        account: account,
        me: %{
          id: fetch_attr!(pair_success_node, "device", "jid"),
          lid: fetch_attr!(pair_success_node, "device", "lid"),
          name: fetch_optional_attr(pair_success_node, "biz", "name")
        },
        signal_identities: (auth_state[:signal_identities] || []) ++ [signal_identity],
        platform: fetch_optional_attr(pair_success_node, "platform", "name")
      }

      {:ok, %{reply: reply, creds_update: creds_update}}
    end
  end

  defp verify_pairing_hmac(
         %ADVSignedDeviceIdentityHMAC{details: details, hmac: hmac, account_type: account_type},
         adv_secret_key
       )
       when is_binary(details) and is_binary(hmac) do
    prefix =
      if account_type == ADVEncryptionType.hosted(), do: @hosted_account_sig_prefix, else: <<>>

    expected_hmac = Crypto.hmac_sha256(adv_secret_key, prefix <> details)

    if expected_hmac == hmac do
      :ok
    else
      {:error, :invalid_pairing_hmac}
    end
  end

  defp verify_pairing_hmac(_device_identity_hmac, _adv_secret_key),
    do: {:error, :invalid_pairing_hmac}

  defp verify_account_signature(
         %ADVSignedDeviceIdentity{
           details: details,
           account_signature_key: account_signature_key,
           account_signature: account_signature
         },
         %ADVDeviceIdentity{device_type: device_type},
         signed_identity_public
       )
       when is_binary(details) and is_binary(account_signature_key) and
              is_binary(account_signature) do
    prefix =
      if device_type == ADVEncryptionType.hosted(),
        do: @hosted_account_sig_prefix,
        else: @account_sig_prefix

    message = prefix <> details <> signed_identity_public

    if Curve.verify(account_signature_key, message, account_signature) do
      :ok
    else
      {:error, :invalid_account_signature}
    end
  end

  defp verify_account_signature(_account, _device_identity, _signed_identity_public),
    do: {:error, :invalid_account_signature}

  defp create_signal_identity(lid, account_signature_key) when is_binary(lid) do
    case Curve.generate_signal_pub_key(account_signature_key) do
      {:ok, identifier_key} ->
        {:ok, %{identifier: %{name: lid, device_id: 0}, identifier_key: identifier_key}}

      {:error, _reason} = error ->
        error
    end
  end

  defp encode_account(%ADVSignedDeviceIdentity{} = account) do
    %{account | account_signature_key: nil}
    |> ADVSignedDeviceIdentity.encode()
  end

  defp reply_node(message_id, key_index, encoded_identity) do
    %BinaryNode{
      tag: "iq",
      attrs: %{"to" => @s_whatsapp_net, "type" => "result", "id" => message_id},
      content: [
        %BinaryNode{
          tag: "pair-device-sign",
          attrs: %{},
          content: [
            %BinaryNode{
              tag: "device-identity",
              attrs: %{"key-index" => Integer.to_string(key_index || 0)},
              content: {:binary, encoded_identity}
            }
          ]
        }
      ]
    }
  end

  defp fetch_signed_identity_key(%{
         signed_identity_key: %{public: public, private: private} = key_pair
       })
       when is_binary(public) and is_binary(private),
       do: {:ok, key_pair}

  defp fetch_signed_identity_key(_auth_state), do: {:error, :missing_signed_identity_key}

  defp fetch_adv_secret_key(%{adv_secret_key: <<_::binary-size(32)>> = adv_secret_key}),
    do: {:ok, adv_secret_key}

  defp fetch_adv_secret_key(%{adv_secret_key: adv_secret_key}) when is_binary(adv_secret_key) do
    case Base.decode64(adv_secret_key) do
      {:ok, <<_::binary-size(32)>> = decoded} -> {:ok, decoded}
      _ -> {:error, :invalid_adv_secret_key}
    end
  end

  defp fetch_adv_secret_key(_auth_state), do: {:error, :missing_adv_secret_key}

  defp fetch_child(node, child_tag) when is_binary(child_tag) do
    case BinaryNodeUtil.child(node, child_tag) do
      %BinaryNode{} = child -> {:ok, child}
      nil -> {:error, {:missing_child, child_tag}}
    end
  end

  defp fetch_binary_content(%BinaryNode{content: {:binary, binary}}) when is_binary(binary),
    do: {:ok, binary}

  defp fetch_binary_content(%BinaryNode{content: binary}) when is_binary(binary),
    do: {:ok, binary}

  defp fetch_binary_content(_node), do: {:error, :invalid_device_identity}

  defp fetch_attr!(node, child_tag, attr_name) do
    node
    |> BinaryNodeUtil.child(child_tag)
    |> case do
      %BinaryNode{attrs: attrs} ->
        case attrs[attr_name] do
          value when is_binary(value) -> value
          _ -> raise ArgumentError, "missing #{child_tag}.#{attr_name}"
        end

      nil ->
        raise ArgumentError, "missing #{child_tag}"
    end
  end

  defp fetch_optional_attr(node, child_tag, attr_name) do
    case BinaryNodeUtil.child(node, child_tag) do
      %BinaryNode{attrs: attrs} -> attrs[attr_name]
      nil -> nil
    end
  end
end
