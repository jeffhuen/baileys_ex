defmodule BaileysEx.Auth.Phone do
  @moduledoc false

  import Bitwise

  alias BaileysEx.Auth.State
  alias BaileysEx.BinaryNode
  alias BaileysEx.Connection.Config
  alias BaileysEx.Crypto
  alias BaileysEx.Protocol.BinaryNode, as: BinaryNodeUtil
  alias BaileysEx.Protocol.JID
  alias BaileysEx.Signal.Curve

  @crockford_characters "123456789ABCDEFGHJKLMNPQRSTVWXYZ"
  @pairing_iterations 131_072
  @s_whatsapp_net "s.whatsapp.net"
  @pairing_bundle_info "link_code_pairing_key_bundle_encryption_key"
  @adv_secret_info "adv_secret"

  @spec derive_pairing_code_key(binary(), binary()) :: {:ok, binary()} | {:error, term()}
  def derive_pairing_code_key(pairing_code, salt)
      when is_binary(pairing_code) and is_binary(salt) and byte_size(salt) == 32 do
    Crypto.pbkdf2_sha256(pairing_code, salt, @pairing_iterations, 32)
  end

  def derive_pairing_code_key(_pairing_code, _salt), do: {:error, :invalid_pairing_key_material}

  @spec build_pairing_request(binary(), map(), Config.t(), keyword()) ::
          {:ok, %{pairing_code: binary(), creds_update: map(), node: BinaryNode.t()}}
          | {:error, term()}
  def build_pairing_request(phone_number, auth_state, %Config{} = config, opts \\ [])
      when is_binary(phone_number) and is_map(auth_state) and is_list(opts) do
    with {:ok, pairing_code} <- pairing_code(opts),
         {:ok, pairing_ephemeral_key} <- fetch_key_pair(auth_state, :pairing_ephemeral_key),
         {:ok, noise_key} <- fetch_key_pair(auth_state, :noise_key),
         {:ok, wrapped_public_key} <-
           generate_pairing_key(pairing_code, pairing_ephemeral_key.public) do
      me = %{id: JID.jid_encode(phone_number, @s_whatsapp_net), name: "~"}

      {:ok,
       %{
         pairing_code: pairing_code,
         creds_update: %{pairing_code: pairing_code, me: me},
         node: companion_hello_node(me.id, wrapped_public_key, noise_key.public, config)
       }}
    end
  end

  @spec complete_pairing(BinaryNode.t(), map()) ::
          {:ok, %{creds_update: map(), node: BinaryNode.t()}} | {:error, term()}
  def complete_pairing(%BinaryNode{} = node, auth_state) when is_map(auth_state) do
    with {:ok, reg_node} <- fetch_reg_node(node),
         {:ok, ref} <- fetch_child_content(reg_node, "link_code_pairing_ref"),
         {:ok, primary_identity_public_key} <-
           fetch_child_content(reg_node, "primary_identity_pub"),
         {:ok, wrapped_primary_ephemeral_public_key} <-
           fetch_child_content(reg_node, "link_code_pairing_wrapped_primary_ephemeral_pub"),
         {:ok, pairing_code} <- fetch_pairing_code(auth_state),
         {:ok, pairing_ephemeral_key} <- fetch_key_pair(auth_state, :pairing_ephemeral_key),
         {:ok, signed_identity_key} <- fetch_key_pair(auth_state, :signed_identity_key),
         {:ok, me} <- fetch_me(auth_state),
         {:ok, code_pairing_public_key} <-
           decipher_link_public_key(wrapped_primary_ephemeral_public_key, pairing_code),
         {:ok, companion_shared_key} <-
           Curve.shared_key(pairing_ephemeral_key.private, code_pairing_public_key),
         {:ok, finish_payload, adv_secret_key} <-
           build_finish_payload(
             companion_shared_key,
             signed_identity_key,
             primary_identity_public_key
           ) do
      {:ok,
       %{
         creds_update: %{registered: true, adv_secret_key: adv_secret_key},
         node: companion_finish_node(me.id, ref, finish_payload, signed_identity_key.public)
       }}
    end
  end

  defp pairing_code(opts) do
    case Keyword.get(opts, :custom_pairing_code) do
      nil ->
        {:ok, Crypto.random_bytes(5) |> bytes_to_crockford()}

      custom_pairing_code
      when is_binary(custom_pairing_code) and byte_size(custom_pairing_code) == 8 ->
        {:ok, custom_pairing_code}

      _ ->
        {:error, :invalid_custom_pairing_code}
    end
  end

  defp generate_pairing_key(pairing_code, companion_ephemeral_public_key) do
    salt = Crypto.random_bytes(32)
    iv = Crypto.random_bytes(16)

    with {:ok, key} <- derive_pairing_code_key(pairing_code, salt),
         {:ok, encrypted_public_key} <-
           Crypto.aes_ctr_encrypt(key, iv, companion_ephemeral_public_key) do
      {:ok, salt <> iv <> encrypted_public_key}
    end
  end

  defp companion_hello_node(jid, wrapped_public_key, noise_public_key, %Config{
         browser: {platform_name, browser, _version}
       }) do
    %BinaryNode{
      tag: "iq",
      attrs: %{"to" => @s_whatsapp_net, "type" => "set", "xmlns" => "md"},
      content: [
        %BinaryNode{
          tag: "link_code_companion_reg",
          attrs: %{
            "jid" => jid,
            "stage" => "companion_hello",
            "should_show_push_notification" => "true"
          },
          content: [
            %BinaryNode{
              tag: "link_code_pairing_wrapped_companion_ephemeral_pub",
              attrs: %{},
              content: {:binary, wrapped_public_key}
            },
            %BinaryNode{
              tag: "companion_server_auth_key_pub",
              attrs: %{},
              content: {:binary, noise_public_key}
            },
            %BinaryNode{
              tag: "companion_platform_id",
              attrs: %{},
              content: Config.platform_id(browser)
            },
            %BinaryNode{
              tag: "companion_platform_display",
              attrs: %{},
              content: "#{browser} (#{platform_name})"
            },
            %BinaryNode{tag: "link_code_pairing_nonce", attrs: %{}, content: "0"}
          ]
        }
      ]
    }
  end

  defp build_finish_payload(
         companion_shared_key,
         signed_identity_key,
         primary_identity_public_key
       ) do
    random = Crypto.random_bytes(32)
    link_code_salt = Crypto.random_bytes(32)
    encrypt_iv = Crypto.random_bytes(12)

    with {:ok, link_code_pairing_key} <-
           Crypto.hkdf(companion_shared_key, @pairing_bundle_info, 32, link_code_salt),
         {:ok, encrypted_bundle} <-
           Crypto.aes_gcm_encrypt(
             link_code_pairing_key,
             encrypt_iv,
             signed_identity_key.public <> primary_identity_public_key <> random,
             <<>>
           ),
         {:ok, identity_shared_key} <-
           Curve.shared_key(signed_identity_key.private, primary_identity_public_key),
         {:ok, adv_secret_key} <-
           Crypto.hkdf(
             companion_shared_key <> identity_shared_key <> random,
             @adv_secret_info,
             32
           ) do
      {:ok, link_code_salt <> encrypt_iv <> encrypted_bundle, Base.encode64(adv_secret_key)}
    end
  end

  defp companion_finish_node(jid, ref, wrapped_key_bundle, signed_identity_public_key) do
    %BinaryNode{
      tag: "iq",
      attrs: %{"to" => @s_whatsapp_net, "type" => "set", "xmlns" => "md"},
      content: [
        %BinaryNode{
          tag: "link_code_companion_reg",
          attrs: %{"jid" => jid, "stage" => "companion_finish"},
          content: [
            %BinaryNode{
              tag: "link_code_pairing_wrapped_key_bundle",
              attrs: %{},
              content: {:binary, wrapped_key_bundle}
            },
            %BinaryNode{
              tag: "companion_identity_public",
              attrs: %{},
              content: {:binary, signed_identity_public_key}
            },
            %BinaryNode{tag: "link_code_pairing_ref", attrs: %{}, content: ref}
          ]
        }
      ]
    }
  end

  defp decipher_link_public_key(
         <<salt::binary-size(32), iv::binary-size(16), payload::binary-size(32)>>,
         pairing_code
       ) do
    with {:ok, secret_key} <- derive_pairing_code_key(pairing_code, salt) do
      Crypto.aes_ctr_decrypt(secret_key, iv, payload)
    end
  end

  defp decipher_link_public_key(_wrapped_public_key, _pairing_code),
    do: {:error, :invalid_wrapped_primary_ephemeral_public_key}

  defp fetch_reg_node(%BinaryNode{tag: "link_code_companion_reg"} = node), do: {:ok, node}

  defp fetch_reg_node(%BinaryNode{} = node) do
    case BinaryNodeUtil.child(node, "link_code_companion_reg") do
      %BinaryNode{} = reg_node -> {:ok, reg_node}
      nil -> {:error, :missing_link_code_companion_reg}
    end
  end

  defp fetch_child_content(node, tag) do
    case BinaryNodeUtil.child(node, tag) do
      %BinaryNode{content: {:binary, content}} when is_binary(content) -> {:ok, content}
      %BinaryNode{content: content} when is_binary(content) -> {:ok, content}
      _ -> {:error, {:missing_child_content, tag}}
    end
  end

  defp fetch_pairing_code(auth_state) do
    case State.get(auth_state, :pairing_code) do
      pairing_code when is_binary(pairing_code) and pairing_code != "" -> {:ok, pairing_code}
      _ -> {:error, :missing_pairing_code}
    end
  end

  defp fetch_me(auth_state) do
    case State.get(auth_state, :me) do
      %{id: jid} = me when is_binary(jid) -> {:ok, me}
      %{"id" => jid} = me when is_binary(jid) -> {:ok, me}
      _ -> {:error, :missing_me}
    end
  end

  defp fetch_key_pair(auth_state, key_name) do
    case State.get(auth_state, key_name) do
      %{public: public_key, private: private_key} = key_pair
      when is_binary(public_key) and is_binary(private_key) ->
        {:ok, key_pair}

      _ ->
        {:error, {:missing_key_pair, key_name}}
    end
  end

  defp bytes_to_crockford(buffer) when is_binary(buffer) do
    {value, bit_count, crockford} =
      buffer
      |> :binary.bin_to_list()
      |> Enum.reduce({0, 0, []}, fn element, {value, bit_count, crockford} ->
        value = Bitwise.bsl(value, 8) ||| Bitwise.band(element, 0xFF)
        bit_count = bit_count + 8
        {value, bit_count, crockford} = emit_crockford_chars(value, bit_count, crockford)
        {value, bit_count, crockford}
      end)

    crockford =
      if bit_count > 0 do
        [crockford_char(Bitwise.band(Bitwise.bsl(value, 5 - bit_count), 31)) | crockford]
      else
        crockford
      end

    crockford |> Enum.reverse() |> IO.iodata_to_binary()
  end

  defp emit_crockford_chars(value, bit_count, crockford) when bit_count >= 5 do
    char = crockford_char(Bitwise.band(Bitwise.bsr(value, bit_count - 5), 31))
    emit_crockford_chars(value, bit_count - 5, [char | crockford])
  end

  defp emit_crockford_chars(value, bit_count, crockford), do: {value, bit_count, crockford}

  defp crockford_char(index), do: binary_part(@crockford_characters, index, 1)
end
