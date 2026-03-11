defmodule BaileysEx.Protocol.Proto.DeviceProps.AppVersion do
  @moduledoc false

  alias BaileysEx.Protocol.Proto.Wire

  defstruct primary: nil, secondary: nil, tertiary: nil, quaternary: nil, quinary: nil

  @type t :: %__MODULE__{
          primary: non_neg_integer() | nil,
          secondary: non_neg_integer() | nil,
          tertiary: non_neg_integer() | nil,
          quaternary: non_neg_integer() | nil,
          quinary: non_neg_integer() | nil
        }

  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = version) do
    Wire.encode_uint(1, version.primary) <>
      Wire.encode_uint(2, version.secondary) <>
      Wire.encode_uint(3, version.tertiary) <>
      Wire.encode_uint(4, version.quaternary) <>
      Wire.encode_uint(5, version.quinary)
  end

  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(binary), do: decode_fields(binary, %__MODULE__{})

  defp decode_fields(<<>>, version), do: {:ok, version}

  defp decode_fields(binary, version) do
    case Wire.decode_key(binary) do
      {:ok, field, wire_type, rest} -> decode_field(field, wire_type, rest, version)
      {:error, _} = error -> error
    end
  end

  defp decode_field(1, 0, rest, version),
    do: Wire.continue_varint(rest, version, &Map.put(&1, :primary, &2), &decode_fields/2)

  defp decode_field(2, 0, rest, version),
    do: Wire.continue_varint(rest, version, &Map.put(&1, :secondary, &2), &decode_fields/2)

  defp decode_field(3, 0, rest, version),
    do: Wire.continue_varint(rest, version, &Map.put(&1, :tertiary, &2), &decode_fields/2)

  defp decode_field(4, 0, rest, version),
    do: Wire.continue_varint(rest, version, &Map.put(&1, :quaternary, &2), &decode_fields/2)

  defp decode_field(5, 0, rest, version),
    do: Wire.continue_varint(rest, version, &Map.put(&1, :quinary, &2), &decode_fields/2)

  defp decode_field(_field, wire_type, rest, version),
    do: Wire.skip_and_continue(wire_type, rest, version, &decode_fields/2)
end

defmodule BaileysEx.Protocol.Proto.DeviceProps.HistorySyncConfig do
  @moduledoc false

  alias BaileysEx.Protocol.Proto.Wire

  defstruct full_sync_days_limit: nil,
            full_sync_size_mb_limit: nil,
            storage_quota_mb: nil,
            inline_initial_payload_in_e2_ee_msg: nil,
            recent_sync_days_limit: nil,
            support_call_log_history: nil,
            support_bot_user_agent_chat_history: nil,
            support_cag_reactions_and_polls: nil,
            support_biz_hosted_msg: nil,
            support_recent_sync_chunk_message_count_tuning: nil,
            support_hosted_group_msg: nil,
            support_fbid_bot_chat_history: nil,
            support_add_on_history_sync_migration: nil,
            support_message_association: nil,
            support_group_history: nil,
            on_demand_ready: nil,
            support_guest_chat: nil,
            complete_on_demand_ready: nil,
            thumbnail_sync_days_limit: nil

  @type t :: %__MODULE__{
          full_sync_days_limit: non_neg_integer() | nil,
          full_sync_size_mb_limit: non_neg_integer() | nil,
          storage_quota_mb: non_neg_integer() | nil,
          inline_initial_payload_in_e2_ee_msg: boolean() | nil,
          recent_sync_days_limit: non_neg_integer() | nil,
          support_call_log_history: boolean() | nil,
          support_bot_user_agent_chat_history: boolean() | nil,
          support_cag_reactions_and_polls: boolean() | nil,
          support_biz_hosted_msg: boolean() | nil,
          support_recent_sync_chunk_message_count_tuning: boolean() | nil,
          support_hosted_group_msg: boolean() | nil,
          support_fbid_bot_chat_history: boolean() | nil,
          support_add_on_history_sync_migration: boolean() | nil,
          support_message_association: boolean() | nil,
          support_group_history: boolean() | nil,
          on_demand_ready: boolean() | nil,
          support_guest_chat: boolean() | nil,
          complete_on_demand_ready: boolean() | nil,
          thumbnail_sync_days_limit: non_neg_integer() | nil
        }

  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = config) do
    Wire.encode_uint(1, config.full_sync_days_limit) <>
      Wire.encode_uint(2, config.full_sync_size_mb_limit) <>
      Wire.encode_uint(3, config.storage_quota_mb) <>
      Wire.encode_bool(4, config.inline_initial_payload_in_e2_ee_msg) <>
      Wire.encode_uint(5, config.recent_sync_days_limit) <>
      Wire.encode_bool(6, config.support_call_log_history) <>
      Wire.encode_bool(7, config.support_bot_user_agent_chat_history) <>
      Wire.encode_bool(8, config.support_cag_reactions_and_polls) <>
      Wire.encode_bool(9, config.support_biz_hosted_msg) <>
      Wire.encode_bool(10, config.support_recent_sync_chunk_message_count_tuning) <>
      Wire.encode_bool(11, config.support_hosted_group_msg) <>
      Wire.encode_bool(12, config.support_fbid_bot_chat_history) <>
      Wire.encode_bool(13, config.support_add_on_history_sync_migration) <>
      Wire.encode_bool(14, config.support_message_association) <>
      Wire.encode_bool(15, config.support_group_history) <>
      Wire.encode_bool(16, config.on_demand_ready) <>
      Wire.encode_bool(17, config.support_guest_chat) <>
      Wire.encode_bool(18, config.complete_on_demand_ready) <>
      Wire.encode_uint(19, config.thumbnail_sync_days_limit)
  end

  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(binary), do: decode_fields(binary, %__MODULE__{})

  defp decode_fields(<<>>, config), do: {:ok, config}

  defp decode_fields(binary, config) do
    case Wire.decode_key(binary) do
      {:ok, field, wire_type, rest} -> decode_field(field, wire_type, rest, config)
      {:error, _} = error -> error
    end
  end

  defp decode_field(1, 0, rest, config),
    do:
      Wire.continue_varint(
        rest,
        config,
        &Map.put(&1, :full_sync_days_limit, &2),
        &decode_fields/2
      )

  defp decode_field(2, 0, rest, config),
    do:
      Wire.continue_varint(
        rest,
        config,
        &Map.put(&1, :full_sync_size_mb_limit, &2),
        &decode_fields/2
      )

  defp decode_field(3, 0, rest, config),
    do: Wire.continue_varint(rest, config, &Map.put(&1, :storage_quota_mb, &2), &decode_fields/2)

  defp decode_field(4, 0, rest, config),
    do: decode_bool(rest, config, :inline_initial_payload_in_e2_ee_msg, &decode_fields/2)

  defp decode_field(5, 0, rest, config),
    do:
      Wire.continue_varint(
        rest,
        config,
        &Map.put(&1, :recent_sync_days_limit, &2),
        &decode_fields/2
      )

  defp decode_field(6, 0, rest, config),
    do: decode_bool(rest, config, :support_call_log_history, &decode_fields/2)

  defp decode_field(7, 0, rest, config),
    do: decode_bool(rest, config, :support_bot_user_agent_chat_history, &decode_fields/2)

  defp decode_field(8, 0, rest, config),
    do: decode_bool(rest, config, :support_cag_reactions_and_polls, &decode_fields/2)

  defp decode_field(9, 0, rest, config),
    do: decode_bool(rest, config, :support_biz_hosted_msg, &decode_fields/2)

  defp decode_field(10, 0, rest, config),
    do:
      decode_bool(rest, config, :support_recent_sync_chunk_message_count_tuning, &decode_fields/2)

  defp decode_field(11, 0, rest, config),
    do: decode_bool(rest, config, :support_hosted_group_msg, &decode_fields/2)

  defp decode_field(12, 0, rest, config),
    do: decode_bool(rest, config, :support_fbid_bot_chat_history, &decode_fields/2)

  defp decode_field(13, 0, rest, config),
    do: decode_bool(rest, config, :support_add_on_history_sync_migration, &decode_fields/2)

  defp decode_field(14, 0, rest, config),
    do: decode_bool(rest, config, :support_message_association, &decode_fields/2)

  defp decode_field(15, 0, rest, config),
    do: decode_bool(rest, config, :support_group_history, &decode_fields/2)

  defp decode_field(16, 0, rest, config),
    do: decode_bool(rest, config, :on_demand_ready, &decode_fields/2)

  defp decode_field(17, 0, rest, config),
    do: decode_bool(rest, config, :support_guest_chat, &decode_fields/2)

  defp decode_field(18, 0, rest, config),
    do: decode_bool(rest, config, :complete_on_demand_ready, &decode_fields/2)

  defp decode_field(19, 0, rest, config),
    do:
      Wire.continue_varint(
        rest,
        config,
        &Map.put(&1, :thumbnail_sync_days_limit, &2),
        &decode_fields/2
      )

  defp decode_field(_field, wire_type, rest, config),
    do: Wire.skip_and_continue(wire_type, rest, config, &decode_fields/2)

  defp decode_bool(rest, config, field, cont) do
    Wire.continue_varint(rest, config, &Map.put(&1, field, &2 == 1), cont)
  end
end

defmodule BaileysEx.Protocol.Proto.DeviceProps do
  @moduledoc false

  alias BaileysEx.Protocol.Proto.DeviceProps.AppVersion
  alias BaileysEx.Protocol.Proto.DeviceProps.HistorySyncConfig
  alias BaileysEx.Protocol.Proto.Wire

  defstruct os: nil,
            version: nil,
            platform_type: nil,
            require_full_sync: nil,
            history_sync_config: nil

  @type t :: %__MODULE__{
          os: binary() | nil,
          version: AppVersion.t() | nil,
          platform_type: non_neg_integer() | nil,
          require_full_sync: boolean() | nil,
          history_sync_config: HistorySyncConfig.t() | nil
        }

  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = props) do
    version = if props.version, do: AppVersion.encode(props.version)

    history_sync_config =
      if props.history_sync_config, do: HistorySyncConfig.encode(props.history_sync_config)

    Wire.encode_bytes(1, props.os) <>
      Wire.encode_bytes(2, version) <>
      Wire.encode_uint(3, props.platform_type) <>
      Wire.encode_bool(4, props.require_full_sync) <>
      Wire.encode_bytes(5, history_sync_config)
  end

  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(binary), do: decode_fields(binary, %__MODULE__{})

  defp decode_fields(<<>>, props), do: {:ok, props}

  defp decode_fields(binary, props) do
    case Wire.decode_key(binary) do
      {:ok, field, wire_type, rest} -> decode_field(field, wire_type, rest, props)
      {:error, _} = error -> error
    end
  end

  defp decode_field(1, 2, rest, props),
    do: Wire.continue_bytes(rest, props, &Map.put(&1, :os, &2), &decode_fields/2)

  defp decode_field(2, 2, rest, props),
    do:
      Wire.continue_nested_bytes(
        rest,
        props,
        &AppVersion.decode/1,
        &Map.put(&1, :version, &2),
        &decode_fields/2
      )

  defp decode_field(3, 0, rest, props),
    do: Wire.continue_varint(rest, props, &Map.put(&1, :platform_type, &2), &decode_fields/2)

  defp decode_field(4, 0, rest, props),
    do:
      Wire.continue_varint(
        rest,
        props,
        &Map.put(&1, :require_full_sync, &2 == 1),
        &decode_fields/2
      )

  defp decode_field(5, 2, rest, props),
    do:
      Wire.continue_nested_bytes(
        rest,
        props,
        &HistorySyncConfig.decode/1,
        &Map.put(&1, :history_sync_config, &2),
        &decode_fields/2
      )

  defp decode_field(_field, wire_type, rest, props),
    do: Wire.skip_and_continue(wire_type, rest, props, &decode_fields/2)
end

defmodule BaileysEx.Protocol.Proto.ClientPayload.DevicePairingRegistrationData do
  @moduledoc false

  alias BaileysEx.Protocol.Proto.Wire

  defstruct e_regid: nil,
            e_keytype: nil,
            e_ident: nil,
            e_skey_id: nil,
            e_skey_val: nil,
            e_skey_sig: nil,
            build_hash: nil,
            device_props: nil

  @type t :: %__MODULE__{
          e_regid: binary() | nil,
          e_keytype: binary() | nil,
          e_ident: binary() | nil,
          e_skey_id: binary() | nil,
          e_skey_val: binary() | nil,
          e_skey_sig: binary() | nil,
          build_hash: binary() | nil,
          device_props: binary() | nil
        }

  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = data) do
    Wire.encode_bytes(1, data.e_regid) <>
      Wire.encode_bytes(2, data.e_keytype) <>
      Wire.encode_bytes(3, data.e_ident) <>
      Wire.encode_bytes(4, data.e_skey_id) <>
      Wire.encode_bytes(5, data.e_skey_val) <>
      Wire.encode_bytes(6, data.e_skey_sig) <>
      Wire.encode_bytes(7, data.build_hash) <>
      Wire.encode_bytes(8, data.device_props)
  end

  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(binary), do: decode_fields(binary, %__MODULE__{})

  defp decode_fields(<<>>, data), do: {:ok, data}

  defp decode_fields(binary, data) do
    case Wire.decode_key(binary) do
      {:ok, field, wire_type, rest} -> decode_field(field, wire_type, rest, data)
      {:error, _} = error -> error
    end
  end

  defp decode_field(field, 2, rest, data) when field in 1..8 do
    field_name =
      case field do
        1 -> :e_regid
        2 -> :e_keytype
        3 -> :e_ident
        4 -> :e_skey_id
        5 -> :e_skey_val
        6 -> :e_skey_sig
        7 -> :build_hash
        8 -> :device_props
      end

    Wire.continue_bytes(rest, data, &Map.put(&1, field_name, &2), &decode_fields/2)
  end

  defp decode_field(_field, wire_type, rest, data),
    do: Wire.skip_and_continue(wire_type, rest, data, &decode_fields/2)
end

defmodule BaileysEx.Protocol.Proto.ClientPayload.UserAgent.AppVersion do
  @moduledoc false

  alias BaileysEx.Protocol.Proto.Wire

  defstruct primary: nil, secondary: nil, tertiary: nil, quaternary: nil, quinary: nil

  @type t :: %__MODULE__{
          primary: non_neg_integer() | nil,
          secondary: non_neg_integer() | nil,
          tertiary: non_neg_integer() | nil,
          quaternary: non_neg_integer() | nil,
          quinary: non_neg_integer() | nil
        }

  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = version) do
    Wire.encode_uint(1, version.primary) <>
      Wire.encode_uint(2, version.secondary) <>
      Wire.encode_uint(3, version.tertiary) <>
      Wire.encode_uint(4, version.quaternary) <>
      Wire.encode_uint(5, version.quinary)
  end

  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(binary), do: decode_fields(binary, %__MODULE__{})

  defp decode_fields(<<>>, version), do: {:ok, version}

  defp decode_fields(binary, version) do
    case Wire.decode_key(binary) do
      {:ok, field, wire_type, rest} -> decode_field(field, wire_type, rest, version)
      {:error, _} = error -> error
    end
  end

  defp decode_field(1, 0, rest, version),
    do: Wire.continue_varint(rest, version, &Map.put(&1, :primary, &2), &decode_fields/2)

  defp decode_field(2, 0, rest, version),
    do: Wire.continue_varint(rest, version, &Map.put(&1, :secondary, &2), &decode_fields/2)

  defp decode_field(3, 0, rest, version),
    do: Wire.continue_varint(rest, version, &Map.put(&1, :tertiary, &2), &decode_fields/2)

  defp decode_field(4, 0, rest, version),
    do: Wire.continue_varint(rest, version, &Map.put(&1, :quaternary, &2), &decode_fields/2)

  defp decode_field(5, 0, rest, version),
    do: Wire.continue_varint(rest, version, &Map.put(&1, :quinary, &2), &decode_fields/2)

  defp decode_field(_field, wire_type, rest, version),
    do: Wire.skip_and_continue(wire_type, rest, version, &decode_fields/2)
end

defmodule BaileysEx.Protocol.Proto.ClientPayload.UserAgent do
  @moduledoc false

  alias BaileysEx.Protocol.Proto.ClientPayload.UserAgent.AppVersion
  alias BaileysEx.Protocol.Proto.Wire

  defstruct platform: nil,
            app_version: nil,
            mcc: nil,
            mnc: nil,
            os_version: nil,
            manufacturer: nil,
            device: nil,
            os_build_number: nil,
            phone_id: nil,
            release_channel: nil,
            locale_language_iso6391: nil,
            locale_country_iso31661_alpha2: nil,
            device_board: nil,
            device_exp_id: nil,
            device_type: nil,
            device_model_type: nil

  @type t :: %__MODULE__{
          platform: non_neg_integer() | nil,
          app_version: AppVersion.t() | nil,
          mcc: binary() | nil,
          mnc: binary() | nil,
          os_version: binary() | nil,
          manufacturer: binary() | nil,
          device: binary() | nil,
          os_build_number: binary() | nil,
          phone_id: binary() | nil,
          release_channel: non_neg_integer() | nil,
          locale_language_iso6391: binary() | nil,
          locale_country_iso31661_alpha2: binary() | nil,
          device_board: binary() | nil,
          device_exp_id: binary() | nil,
          device_type: non_neg_integer() | nil,
          device_model_type: binary() | nil
        }

  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = agent) do
    app_version = if agent.app_version, do: AppVersion.encode(agent.app_version)

    Wire.encode_uint(1, agent.platform) <>
      Wire.encode_bytes(2, app_version) <>
      Wire.encode_bytes(3, agent.mcc) <>
      Wire.encode_bytes(4, agent.mnc) <>
      Wire.encode_bytes(5, agent.os_version) <>
      Wire.encode_bytes(6, agent.manufacturer) <>
      Wire.encode_bytes(7, agent.device) <>
      Wire.encode_bytes(8, agent.os_build_number) <>
      Wire.encode_bytes(9, agent.phone_id) <>
      Wire.encode_uint(10, agent.release_channel) <>
      Wire.encode_bytes(11, agent.locale_language_iso6391) <>
      Wire.encode_bytes(12, agent.locale_country_iso31661_alpha2) <>
      Wire.encode_bytes(13, agent.device_board) <>
      Wire.encode_bytes(14, agent.device_exp_id) <>
      Wire.encode_uint(15, agent.device_type) <>
      Wire.encode_bytes(16, agent.device_model_type)
  end

  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(binary), do: decode_fields(binary, %__MODULE__{})

  defp decode_fields(<<>>, agent), do: {:ok, agent}

  defp decode_fields(binary, agent) do
    case Wire.decode_key(binary) do
      {:ok, field, wire_type, rest} -> decode_field(field, wire_type, rest, agent)
      {:error, _} = error -> error
    end
  end

  defp decode_field(1, 0, rest, agent),
    do: Wire.continue_varint(rest, agent, &Map.put(&1, :platform, &2), &decode_fields/2)

  defp decode_field(2, 2, rest, agent),
    do:
      Wire.continue_nested_bytes(
        rest,
        agent,
        &AppVersion.decode/1,
        &Map.put(&1, :app_version, &2),
        &decode_fields/2
      )

  defp decode_field(field, 2, rest, agent),
    do: decode_string_field(field, rest, agent)

  defp decode_field(10, 0, rest, agent),
    do: Wire.continue_varint(rest, agent, &Map.put(&1, :release_channel, &2), &decode_fields/2)

  defp decode_field(15, 0, rest, agent),
    do: Wire.continue_varint(rest, agent, &Map.put(&1, :device_type, &2), &decode_fields/2)

  defp decode_field(_field, wire_type, rest, agent),
    do: Wire.skip_and_continue(wire_type, rest, agent, &decode_fields/2)

  defp decode_string_field(field, rest, agent) do
    case user_agent_string_field(field) do
      nil ->
        Wire.skip_and_continue(2, rest, agent, &decode_fields/2)

      field_name ->
        Wire.continue_bytes(rest, agent, &Map.put(&1, field_name, &2), &decode_fields/2)
    end
  end

  defp user_agent_string_field(3), do: :mcc
  defp user_agent_string_field(4), do: :mnc
  defp user_agent_string_field(5), do: :os_version
  defp user_agent_string_field(6), do: :manufacturer
  defp user_agent_string_field(7), do: :device
  defp user_agent_string_field(8), do: :os_build_number
  defp user_agent_string_field(9), do: :phone_id
  defp user_agent_string_field(11), do: :locale_language_iso6391
  defp user_agent_string_field(12), do: :locale_country_iso31661_alpha2
  defp user_agent_string_field(13), do: :device_board
  defp user_agent_string_field(14), do: :device_exp_id
  defp user_agent_string_field(16), do: :device_model_type
  defp user_agent_string_field(_field), do: nil
end

defmodule BaileysEx.Protocol.Proto.ClientPayload.WebInfo do
  @moduledoc false

  alias BaileysEx.Protocol.Proto.Wire

  defstruct ref_token: nil, version: nil, webd_payload: nil, web_sub_platform: nil

  @type t :: %__MODULE__{
          ref_token: binary() | nil,
          version: binary() | nil,
          webd_payload: binary() | nil,
          web_sub_platform: non_neg_integer() | nil
        }

  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = web_info) do
    Wire.encode_bytes(1, web_info.ref_token) <>
      Wire.encode_bytes(2, web_info.version) <>
      Wire.encode_bytes(3, web_info.webd_payload) <>
      Wire.encode_uint(4, web_info.web_sub_platform)
  end

  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(binary), do: decode_fields(binary, %__MODULE__{})

  defp decode_fields(<<>>, web_info), do: {:ok, web_info}

  defp decode_fields(binary, web_info) do
    case Wire.decode_key(binary) do
      {:ok, field, wire_type, rest} -> decode_field(field, wire_type, rest, web_info)
      {:error, _} = error -> error
    end
  end

  defp decode_field(field, 2, rest, web_info) when field in [1, 2, 3] do
    field_name =
      case field do
        1 -> :ref_token
        2 -> :version
        3 -> :webd_payload
      end

    Wire.continue_bytes(rest, web_info, &Map.put(&1, field_name, &2), &decode_fields/2)
  end

  defp decode_field(4, 0, rest, web_info),
    do:
      Wire.continue_varint(rest, web_info, &Map.put(&1, :web_sub_platform, &2), &decode_fields/2)

  defp decode_field(_field, wire_type, rest, web_info),
    do: Wire.skip_and_continue(wire_type, rest, web_info, &decode_fields/2)
end

defmodule BaileysEx.Protocol.Proto.ClientPayload do
  @moduledoc false

  alias BaileysEx.Protocol.Proto.ClientPayload.DevicePairingRegistrationData
  alias BaileysEx.Protocol.Proto.ClientPayload.UserAgent
  alias BaileysEx.Protocol.Proto.ClientPayload.WebInfo
  alias BaileysEx.Protocol.Proto.Wire

  defstruct username: nil,
            passive: nil,
            user_agent: nil,
            web_info: nil,
            connect_type: nil,
            connect_reason: nil,
            device: nil,
            device_pairing_data: nil,
            pull: nil,
            lid_db_migrated: nil

  @type t :: %__MODULE__{
          username: non_neg_integer() | nil,
          passive: boolean() | nil,
          user_agent: UserAgent.t() | nil,
          web_info: WebInfo.t() | nil,
          connect_type: non_neg_integer() | nil,
          connect_reason: non_neg_integer() | nil,
          device: non_neg_integer() | nil,
          device_pairing_data: DevicePairingRegistrationData.t() | nil,
          pull: boolean() | nil,
          lid_db_migrated: boolean() | nil
        }

  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = payload) do
    user_agent = if payload.user_agent, do: UserAgent.encode(payload.user_agent)
    web_info = if payload.web_info, do: WebInfo.encode(payload.web_info)

    device_pairing_data =
      if payload.device_pairing_data,
        do: DevicePairingRegistrationData.encode(payload.device_pairing_data)

    Wire.encode_uint(1, payload.username) <>
      Wire.encode_bool(3, payload.passive) <>
      Wire.encode_bytes(5, user_agent) <>
      Wire.encode_bytes(6, web_info) <>
      Wire.encode_uint(12, payload.connect_type) <>
      Wire.encode_uint(13, payload.connect_reason) <>
      Wire.encode_uint(18, payload.device) <>
      Wire.encode_bytes(19, device_pairing_data) <>
      Wire.encode_bool(33, payload.pull) <>
      Wire.encode_bool(41, payload.lid_db_migrated)
  end

  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(binary), do: decode_fields(binary, %__MODULE__{})

  defp decode_fields(<<>>, payload), do: {:ok, payload}

  defp decode_fields(binary, payload) do
    case Wire.decode_key(binary) do
      {:ok, field, wire_type, rest} -> decode_field(field, wire_type, rest, payload)
      {:error, _} = error -> error
    end
  end

  defp decode_field(1, 0, rest, payload),
    do: Wire.continue_varint(rest, payload, &Map.put(&1, :username, &2), &decode_fields/2)

  defp decode_field(3, 0, rest, payload),
    do: Wire.continue_varint(rest, payload, &Map.put(&1, :passive, &2 == 1), &decode_fields/2)

  defp decode_field(5, 2, rest, payload),
    do:
      Wire.continue_nested_bytes(
        rest,
        payload,
        &UserAgent.decode/1,
        &Map.put(&1, :user_agent, &2),
        &decode_fields/2
      )

  defp decode_field(6, 2, rest, payload),
    do:
      Wire.continue_nested_bytes(
        rest,
        payload,
        &WebInfo.decode/1,
        &Map.put(&1, :web_info, &2),
        &decode_fields/2
      )

  defp decode_field(12, 0, rest, payload),
    do: Wire.continue_varint(rest, payload, &Map.put(&1, :connect_type, &2), &decode_fields/2)

  defp decode_field(13, 0, rest, payload),
    do: Wire.continue_varint(rest, payload, &Map.put(&1, :connect_reason, &2), &decode_fields/2)

  defp decode_field(18, 0, rest, payload),
    do: Wire.continue_varint(rest, payload, &Map.put(&1, :device, &2), &decode_fields/2)

  defp decode_field(19, 2, rest, payload),
    do:
      Wire.continue_nested_bytes(
        rest,
        payload,
        &DevicePairingRegistrationData.decode/1,
        &Map.put(&1, :device_pairing_data, &2),
        &decode_fields/2
      )

  defp decode_field(33, 0, rest, payload),
    do: Wire.continue_varint(rest, payload, &Map.put(&1, :pull, &2 == 1), &decode_fields/2)

  defp decode_field(41, 0, rest, payload),
    do:
      Wire.continue_varint(
        rest,
        payload,
        &Map.put(&1, :lid_db_migrated, &2 == 1),
        &decode_fields/2
      )

  defp decode_field(_field, wire_type, rest, payload),
    do: Wire.skip_and_continue(wire_type, rest, payload, &decode_fields/2)
end
