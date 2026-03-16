defmodule BaileysEx.Auth.ConnectionValidator do
  @moduledoc """
  Builds the rc.9 login and registration client payloads sent after Noise handshake.
  """

  alias BaileysEx.Auth.State
  alias BaileysEx.Connection.Config
  alias BaileysEx.Protocol.JID
  alias BaileysEx.Protocol.Proto.ClientPayload
  alias BaileysEx.Protocol.Proto.ClientPayload.DevicePairingRegistrationData
  alias BaileysEx.Protocol.Proto.ClientPayload.UserAgent
  alias BaileysEx.Protocol.Proto.ClientPayload.UserAgent.AppVersion, as: UserAgentAppVersion
  alias BaileysEx.Protocol.Proto.ClientPayload.WebInfo
  alias BaileysEx.Protocol.Proto.DeviceProps
  alias BaileysEx.Protocol.Proto.DeviceProps.AppVersion, as: DevicePropsAppVersion
  alias BaileysEx.Protocol.Proto.DeviceProps.HistorySyncConfig

  @key_bundle_type <<5>>
  @user_agent_platform_web 14
  @user_agent_release_channel_release 0
  @connect_type_wifi_unknown 1
  @connect_reason_user_activated 1

  @doc """
  Constructs a connection node payload for an existing login session.
  """
  @spec generate_login_node(binary(), Config.t()) ::
          {:ok, struct()} | {:error, term()}
  def generate_login_node(me_jid, %Config{} = config) when is_binary(me_jid) do
    with %BaileysEx.JID{user: user, device: device} <- JID.parse(me_jid),
         true <- is_binary(user),
         {username, ""} <- Integer.parse(user) do
      {:ok,
       %ClientPayload{
         username: username,
         device: device,
         passive: true,
         pull: true,
         lid_db_migrated: false,
         user_agent: user_agent(config),
         web_info: web_info(config),
         connect_type: @connect_type_wifi_unknown,
         connect_reason: @connect_reason_user_activated
       }}
    else
      _ -> {:error, :invalid_me_jid}
    end
  end

  @doc """
  Constructs a registration pair-device node payload.
  """
  @spec generate_registration_node(State.t() | map(), Config.t()) ::
          {:ok, struct()} | {:error, term()}
  def generate_registration_node(auth_state, %Config{} = config) when is_map(auth_state) do
    with {:ok, registration_id} <- fetch_integer(auth_state, :registration_id),
         {:ok, signed_identity_key} <- fetch_key_pair(auth_state, :signed_identity_key),
         {:ok, signed_pre_key} <- fetch_signed_pre_key(auth_state) do
      companion = companion_device_props(config)

      {:ok,
       %ClientPayload{
         passive: false,
         pull: false,
         user_agent: user_agent(config),
         web_info: web_info(config),
         connect_type: @connect_type_wifi_unknown,
         connect_reason: @connect_reason_user_activated,
         device_pairing_data: %DevicePairingRegistrationData{
           build_hash: :crypto.hash(:md5, Enum.join(config.version, ".")),
           device_props: DeviceProps.encode(companion),
           e_regid: encode_big_endian(registration_id, 4),
           e_keytype: @key_bundle_type,
           e_ident: signed_identity_key.public,
           e_skey_id: encode_big_endian(signed_pre_key.key_id, 3),
           e_skey_val: signed_pre_key.key_pair.public,
           e_skey_sig: signed_pre_key.signature
         }
       }}
    end
  end

  @doc """
  Builds the fully encoded binary protobuf payload containing the initial client setup.
  """
  @spec generate_client_payload(State.t() | map(), Config.t()) ::
          {:ok, binary()} | {:error, term()}
  def generate_client_payload(auth_state, %Config{} = config) when is_map(auth_state) do
    with {:ok, node} <- generate_client_node(auth_state, config) do
      {:ok, ClientPayload.encode(node)}
    end
  end

  defp generate_client_node(auth_state, config) do
    case me_id(auth_state) do
      jid when is_binary(jid) -> generate_login_node(jid, config)
      _ -> generate_registration_node(auth_state, config)
    end
  end

  defp user_agent(%Config{} = config) do
    [primary, secondary, tertiary | _rest] = config.version

    %UserAgent{
      app_version: %UserAgentAppVersion{
        primary: primary,
        secondary: secondary,
        tertiary: tertiary
      },
      platform: @user_agent_platform_web,
      release_channel: @user_agent_release_channel_release,
      os_version: "0.1",
      device: "Desktop",
      os_build_number: "0.1",
      locale_language_iso6391: "en",
      mnc: "000",
      mcc: "000",
      locale_country_iso31661_alpha2: config.country_code
    }
  end

  defp web_info(%Config{} = config) do
    %WebInfo{web_sub_platform: Config.web_sub_platform(config)}
  end

  defp companion_device_props(%Config{} = config) do
    {platform_name, browser_name, _platform_version} = config.browser

    %DeviceProps{
      os: platform_name,
      platform_type: Config.device_props_platform_type(browser_name),
      require_full_sync: config.sync_full_history,
      history_sync_config: %HistorySyncConfig{
        storage_quota_mb: 10_240,
        inline_initial_payload_in_e2_ee_msg: true,
        support_call_log_history: false,
        support_bot_user_agent_chat_history: true,
        support_cag_reactions_and_polls: true,
        support_biz_hosted_msg: true,
        support_recent_sync_chunk_message_count_tuning: true,
        support_hosted_group_msg: true,
        support_fbid_bot_chat_history: true,
        support_message_association: true,
        support_group_history: false
      },
      version: %DevicePropsAppVersion{primary: 10, secondary: 15, tertiary: 7}
    }
  end

  defp fetch_integer(auth_state, key) do
    case State.get(auth_state, key) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _ -> {:error, {:missing_integer, key}}
    end
  end

  defp fetch_key_pair(auth_state, key) do
    case State.get(auth_state, key) do
      %{public: public_key, private: private_key} = key_pair
      when is_binary(public_key) and is_binary(private_key) ->
        {:ok, key_pair}

      _ ->
        {:error, {:missing_key_pair, key}}
    end
  end

  defp fetch_signed_pre_key(auth_state) do
    case State.get(auth_state, :signed_pre_key) do
      %{
        key_pair: %{public: public, private: private} = key_pair,
        key_id: key_id,
        signature: signature
      } =
          signed_pre_key
      when is_binary(public) and is_binary(private) and is_integer(key_id) and key_id >= 0 and
             is_binary(signature) ->
        {:ok, %{signed_pre_key | key_pair: key_pair}}

      _ ->
        {:error, :missing_signed_pre_key}
    end
  end

  defp me_id(auth_state) do
    case State.get(auth_state, :me) do
      %{id: jid} when is_binary(jid) -> jid
      %{"id" => jid} when is_binary(jid) -> jid
      _ -> nil
    end
  end

  defp encode_big_endian(integer, bytes) when is_integer(integer) and integer >= 0 do
    <<integer::unsigned-big-integer-size(bytes * 8)>>
  end
end
