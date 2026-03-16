defmodule BaileysEx.Syncd.Keys do
  @moduledoc """
  App state sync key expansion.

  Expands raw 32-byte key material into five derived keys used by the Syncd
  protocol for index signing, value encryption, value MAC, snapshot MAC,
  and patch MAC operations.

  Ports `expandAppStateKeys` + `mutationKeys` from `chat-utils.ts:34-43`.
  """

  alias BaileysEx.Crypto

  @hkdf_info "WhatsApp Mutation Keys"
  @expanded_length 160

  @type t :: %{
          index_key: <<_::256>>,
          value_encryption_key: <<_::256>>,
          value_mac_key: <<_::256>>,
          snapshot_mac_key: <<_::256>>,
          patch_mac_key: <<_::256>>
        }

  @doc """
  Expand raw key material into five Syncd subkeys via HKDF-SHA256.

  Equivalent to Baileys `expandAppStateKeys(keydata)` from `whatsapp-rust-bridge`.

  ## Parameters

    * `key_data` — 32-byte raw app state sync key material

  ## Returns

  Map with five 32-byte keys: `:index_key`, `:value_encryption_key`,
  `:value_mac_key`, `:snapshot_mac_key`, `:patch_mac_key`.
  """
  @spec expand_app_state_keys(binary()) :: t()
  def expand_app_state_keys(key_data) when byte_size(key_data) == 32 do
    {:ok, expanded} = Crypto.hkdf(key_data, @hkdf_info, @expanded_length)

    <<index_key::binary-32, value_encryption_key::binary-32, value_mac_key::binary-32,
      snapshot_mac_key::binary-32, patch_mac_key::binary-32>> = expanded

    %{
      index_key: index_key,
      value_encryption_key: value_encryption_key,
      value_mac_key: value_mac_key,
      snapshot_mac_key: snapshot_mac_key,
      patch_mac_key: patch_mac_key
    }
  end

  @doc """
  Alias for `expand_app_state_keys/1`.

  Ports `mutationKeys(keydata)` from `chat-utils.ts:34`.
  """
  @spec mutation_keys(binary()) :: t()
  def mutation_keys(key_data), do: expand_app_state_keys(key_data)
end
