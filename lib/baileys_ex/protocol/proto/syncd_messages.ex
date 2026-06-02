# credo:disable-for-this-file Credo.Check.Warning.StructFieldAmount

defmodule BaileysEx.Protocol.Proto.Syncd do
  @moduledoc false

  # Protobuf encode/decode for Syncd (app state sync) wire types.
  # Ports WAProto.proto lines 4453-5001 + SyncActionValue sub-messages.
  #
  # Uses the existing MessageSupport hand-written protobuf pattern.

  alias BaileysEx.Protocol.Proto.MessageSupport

  # ============================================================================
  # Core wire types
  # ============================================================================

  defmodule KeyId do
    @moduledoc false

    defstruct id: nil
    @type t :: %__MODULE__{id: binary() | nil}

    @spec encode(t()) :: binary()
    def encode(%__MODULE__{} = s), do: MessageSupport.encode_fields(s, id: {:bytes, 1})

    @spec decode(binary()) :: {:ok, t()} | {:error, term()}
    def decode(bin), do: MessageSupport.decode_fields(bin, %__MODULE__{}, id: {:bytes, 1})
  end

  defmodule SyncdIndex do
    @moduledoc false

    defstruct blob: nil
    @type t :: %__MODULE__{blob: binary() | nil}

    @spec encode(t()) :: binary()
    def encode(%__MODULE__{} = s), do: MessageSupport.encode_fields(s, blob: {:bytes, 1})

    @spec decode(binary()) :: {:ok, t()} | {:error, term()}
    def decode(bin), do: MessageSupport.decode_fields(bin, %__MODULE__{}, blob: {:bytes, 1})
  end

  defmodule SyncdValue do
    @moduledoc false

    defstruct blob: nil
    @type t :: %__MODULE__{blob: binary() | nil}

    @spec encode(t()) :: binary()
    def encode(%__MODULE__{} = s), do: MessageSupport.encode_fields(s, blob: {:bytes, 1})

    @spec decode(binary()) :: {:ok, t()} | {:error, term()}
    def decode(bin), do: MessageSupport.decode_fields(bin, %__MODULE__{}, blob: {:bytes, 1})
  end

  defmodule SyncdVersion do
    @moduledoc false

    defstruct version: nil
    @type t :: %__MODULE__{version: non_neg_integer() | nil}

    @spec encode(t()) :: binary()
    def encode(%__MODULE__{} = s), do: MessageSupport.encode_fields(s, version: {:uint, 1})

    @spec decode(binary()) :: {:ok, t()} | {:error, term()}
    def decode(bin), do: MessageSupport.decode_fields(bin, %__MODULE__{}, version: {:uint, 1})
  end

  defmodule SyncdRecord do
    @moduledoc false

    defstruct index: nil, value: nil, key_id: nil

    @type t :: %__MODULE__{
            index: SyncdIndex.t() | nil,
            value: SyncdValue.t() | nil,
            key_id: KeyId.t() | nil
          }

    @specs [
      index: {:message, 1, SyncdIndex},
      value: {:message, 2, SyncdValue},
      key_id: {:message, 3, KeyId}
    ]

    @spec encode(t()) :: binary()
    def encode(%__MODULE__{} = s), do: MessageSupport.encode_fields(s, @specs)

    @spec decode(binary()) :: {:ok, t()} | {:error, term()}
    def decode(bin), do: MessageSupport.decode_fields(bin, %__MODULE__{}, @specs)
  end

  defmodule SyncdMutation do
    @moduledoc false

    # Proto enum: SET = 0, REMOVE = 1
    @operation_values %{set: 0, remove: 1}

    defstruct operation: nil, record: nil

    @type operation :: :set | :remove
    @type t :: %__MODULE__{
            operation: operation() | nil,
            record: SyncdRecord.t() | nil
          }

    @specs [
      operation: {:enum, 1, @operation_values},
      record: {:message, 2, SyncdRecord}
    ]

    @spec encode(t()) :: binary()
    def encode(%__MODULE__{} = s), do: MessageSupport.encode_fields(s, @specs)

    @spec decode(binary()) :: {:ok, t()} | {:error, term()}
    def decode(bin), do: MessageSupport.decode_fields(bin, %__MODULE__{}, @specs)

    @doc "Convert proto enum value (0/1) to atom, defaulting to :set for records."
    @spec operation_atom(non_neg_integer() | atom() | nil) :: operation()
    def operation_atom(:set), do: :set
    def operation_atom(:remove), do: :remove
    def operation_atom(0), do: :set
    def operation_atom(1), do: :remove
    def operation_atom(nil), do: :set

    @doc "Convert operation atom to the MAC input byte (SET=0x01, REMOVE=0x02)."
    @spec operation_byte(operation()) :: 1 | 2
    def operation_byte(:set), do: 0x01
    def operation_byte(:remove), do: 0x02
  end

  defmodule SyncdMutations do
    @moduledoc false

    defstruct mutations: []
    @type t :: %__MODULE__{mutations: [SyncdMutation.t()]}

    @spec encode(t()) :: binary()
    def encode(%__MODULE__{} = s) do
      MessageSupport.encode_fields(s, mutations: {:repeated_message, 1, SyncdMutation})
    end

    @spec decode(binary()) :: {:ok, t()} | {:error, term()}
    def decode(bin) do
      MessageSupport.decode_fields(bin, %__MODULE__{},
        mutations: {:repeated_message, 1, SyncdMutation}
      )
    end
  end

  defmodule SyncdPatch do
    @moduledoc false

    defstruct version: nil,
              mutations: [],
              external_mutations: nil,
              snapshot_mac: nil,
              patch_mac: nil,
              key_id: nil,
              exit_code: nil,
              device_index: nil,
              client_debug_data: nil

    @type t :: %__MODULE__{
            version: SyncdVersion.t() | nil,
            mutations: [SyncdMutation.t()],
            external_mutations: BaileysEx.Protocol.Proto.Syncd.ExternalBlobReference.t() | nil,
            snapshot_mac: binary() | nil,
            patch_mac: binary() | nil,
            key_id: KeyId.t() | nil,
            exit_code: non_neg_integer() | nil,
            device_index: non_neg_integer() | nil,
            client_debug_data: binary() | nil
          }

    @encode_specs [
      version: {:message, 1, SyncdVersion},
      mutations: {:repeated_message, 2, SyncdMutation},
      external_mutations: {:message, 3, BaileysEx.Protocol.Proto.Syncd.ExternalBlobReference},
      snapshot_mac: {:bytes, 4},
      patch_mac: {:bytes, 5},
      key_id: {:message, 6, KeyId},
      exit_code: {:uint, 7},
      device_index: {:uint, 8},
      client_debug_data: {:bytes, 9}
    ]

    @decode_specs [
      version: {:message, 1, SyncdVersion},
      mutations: {:repeated_message, 2, SyncdMutation},
      external_mutations: {:message, 3, BaileysEx.Protocol.Proto.Syncd.ExternalBlobReference},
      snapshot_mac: {:bytes, 4},
      patch_mac: {:bytes, 5},
      key_id: {:message, 6, KeyId},
      exit_code: {:uint, 7},
      device_index: {:uint, 8},
      client_debug_data: {:bytes, 9}
    ]

    @spec encode(t()) :: binary()
    def encode(%__MODULE__{} = s), do: MessageSupport.encode_fields(s, @encode_specs)

    @spec decode(binary()) :: {:ok, t()} | {:error, term()}
    def decode(bin), do: MessageSupport.decode_fields(bin, %__MODULE__{}, @decode_specs)
  end

  defmodule SyncdSnapshot do
    @moduledoc false

    defstruct version: nil, records: [], mac: nil, key_id: nil

    @type t :: %__MODULE__{
            version: SyncdVersion.t() | nil,
            records: [SyncdRecord.t()],
            mac: binary() | nil,
            key_id: KeyId.t() | nil
          }

    @specs [
      version: {:message, 1, SyncdVersion},
      records: {:repeated_message, 2, SyncdRecord},
      mac: {:bytes, 3},
      key_id: {:message, 4, KeyId}
    ]

    @spec encode(t()) :: binary()
    def encode(%__MODULE__{} = s), do: MessageSupport.encode_fields(s, @specs)

    @spec decode(binary()) :: {:ok, t()} | {:error, term()}
    def decode(bin), do: MessageSupport.decode_fields(bin, %__MODULE__{}, @specs)
  end

  defmodule ExternalBlobReference do
    @moduledoc false

    defstruct media_key: nil,
              direct_path: nil,
              handle: nil,
              file_size_bytes: nil,
              file_sha256: nil,
              file_enc_sha256: nil

    @type t :: %__MODULE__{
            media_key: binary() | nil,
            direct_path: String.t() | nil,
            handle: String.t() | nil,
            file_size_bytes: non_neg_integer() | nil,
            file_sha256: binary() | nil,
            file_enc_sha256: binary() | nil
          }

    @specs [
      media_key: {:bytes, 1},
      direct_path: {:string, 2},
      handle: {:string, 3},
      file_size_bytes: {:uint, 4},
      file_sha256: {:bytes, 5},
      file_enc_sha256: {:bytes, 6}
    ]

    @spec encode(t()) :: binary()
    def encode(%__MODULE__{} = s), do: MessageSupport.encode_fields(s, @specs)

    @spec decode(binary()) :: {:ok, t()} | {:error, term()}
    def decode(bin), do: MessageSupport.decode_fields(bin, %__MODULE__{}, @specs)
  end

  # ============================================================================
  # SyncAction types
  # ============================================================================

  defmodule SyncActionMessage do
    @moduledoc false

    alias BaileysEx.Protocol.Proto.MessageKey

    defstruct key: nil, timestamp: nil
    @type t :: %__MODULE__{key: MessageKey.t() | nil, timestamp: non_neg_integer() | nil}

    @specs [key: {:message, 1, MessageKey}, timestamp: {:int64, 2}]

    @spec encode(t()) :: binary()
    def encode(%__MODULE__{} = s), do: MessageSupport.encode_fields(s, @specs)

    @spec decode(binary()) :: {:ok, t()} | {:error, term()}
    def decode(bin), do: MessageSupport.decode_fields(bin, %__MODULE__{}, @specs)
  end

  defmodule SyncActionMessageRange do
    @moduledoc false

    defstruct last_message_timestamp: nil, last_system_message_timestamp: nil, messages: []

    @type t :: %__MODULE__{
            last_message_timestamp: non_neg_integer() | nil,
            last_system_message_timestamp: non_neg_integer() | nil,
            messages: [SyncActionMessage.t()]
          }

    @specs [
      last_message_timestamp: {:int64, 1},
      last_system_message_timestamp: {:int64, 2},
      messages: {:repeated_message, 3, SyncActionMessage}
    ]

    @spec encode(t()) :: binary()
    def encode(%__MODULE__{} = s), do: MessageSupport.encode_fields(s, @specs)

    @spec decode(binary()) :: {:ok, t()} | {:error, term()}
    def decode(bin), do: MessageSupport.decode_fields(bin, %__MODULE__{}, @specs)
  end

  # -- Action sub-messages (alphabetical, matching WAProto.proto) --

  defmodule ArchiveChatAction do
    @moduledoc false
    defstruct archived: nil, message_range: nil

    @type t :: %__MODULE__{
            archived: boolean() | nil,
            message_range: SyncActionMessageRange.t() | nil
          }
    @specs [archived: {:bool, 1}, message_range: {:message, 2, SyncActionMessageRange}]
    def encode(%__MODULE__{} = s), do: MessageSupport.encode_fields(s, @specs)
    def decode(bin), do: MessageSupport.decode_fields(bin, %__MODULE__{}, @specs)
  end

  defmodule ClearChatAction do
    @moduledoc false
    defstruct message_range: nil
    @type t :: %__MODULE__{message_range: SyncActionMessageRange.t() | nil}
    @specs [message_range: {:message, 1, SyncActionMessageRange}]
    def encode(%__MODULE__{} = s), do: MessageSupport.encode_fields(s, @specs)
    def decode(bin), do: MessageSupport.decode_fields(bin, %__MODULE__{}, @specs)
  end

  defmodule ContactAction do
    @moduledoc false
    defstruct full_name: nil,
              first_name: nil,
              lid_jid: nil,
              save_on_primary_addressbook: nil,
              pn_jid: nil,
              username: nil

    @type t :: %__MODULE__{
            full_name: String.t() | nil,
            first_name: String.t() | nil,
            lid_jid: String.t() | nil,
            save_on_primary_addressbook: boolean() | nil,
            pn_jid: String.t() | nil,
            username: String.t() | nil
          }
    @specs [
      full_name: {:string, 1},
      first_name: {:string, 2},
      lid_jid: {:string, 3},
      save_on_primary_addressbook: {:bool, 4},
      pn_jid: {:string, 5},
      username: {:string, 6}
    ]
    def encode(%__MODULE__{} = s), do: MessageSupport.encode_fields(s, @specs)
    def decode(bin), do: MessageSupport.decode_fields(bin, %__MODULE__{}, @specs)
  end

  defmodule DeleteChatAction do
    @moduledoc false
    defstruct message_range: nil
    @type t :: %__MODULE__{message_range: SyncActionMessageRange.t() | nil}
    @specs [message_range: {:message, 1, SyncActionMessageRange}]
    def encode(%__MODULE__{} = s), do: MessageSupport.encode_fields(s, @specs)
    def decode(bin), do: MessageSupport.decode_fields(bin, %__MODULE__{}, @specs)
  end

  defmodule DeleteMessageForMeAction do
    @moduledoc false
    defstruct delete_media: nil, message_timestamp: nil

    @type t :: %__MODULE__{
            delete_media: boolean() | nil,
            message_timestamp: non_neg_integer() | nil
          }
    @specs [delete_media: {:bool, 1}, message_timestamp: {:int64, 2}]
    def encode(%__MODULE__{} = s), do: MessageSupport.encode_fields(s, @specs)
    def decode(bin), do: MessageSupport.decode_fields(bin, %__MODULE__{}, @specs)
  end

  defmodule LabelAssociationAction do
    @moduledoc false
    defstruct labeled: nil
    @type t :: %__MODULE__{labeled: boolean() | nil}
    @specs [labeled: {:bool, 1}]
    def encode(%__MODULE__{} = s), do: MessageSupport.encode_fields(s, @specs)
    def decode(bin), do: MessageSupport.decode_fields(bin, %__MODULE__{}, @specs)
  end

  defmodule LabelEditAction do
    @moduledoc false
    defstruct name: nil,
              color: nil,
              predefined_id: nil,
              deleted: nil,
              order_index: nil,
              is_active: nil

    @type t :: %__MODULE__{
            name: String.t() | nil,
            color: integer() | nil,
            predefined_id: integer() | nil,
            deleted: boolean() | nil,
            order_index: integer() | nil,
            is_active: boolean() | nil
          }
    @specs [
      name: {:string, 1},
      color: {:int, 2},
      predefined_id: {:int, 3},
      deleted: {:bool, 4},
      order_index: {:int, 5},
      is_active: {:bool, 6}
    ]
    def encode(%__MODULE__{} = s), do: MessageSupport.encode_fields(s, @specs)
    def decode(bin), do: MessageSupport.decode_fields(bin, %__MODULE__{}, @specs)
  end

  defmodule LidContactAction do
    @moduledoc false
    defstruct full_name: nil, first_name: nil, username: nil

    @type t :: %__MODULE__{
            full_name: String.t() | nil,
            first_name: String.t() | nil,
            username: String.t() | nil
          }
    @specs [full_name: {:string, 1}, first_name: {:string, 2}, username: {:string, 3}]
    def encode(%__MODULE__{} = s), do: MessageSupport.encode_fields(s, @specs)
    def decode(bin), do: MessageSupport.decode_fields(bin, %__MODULE__{}, @specs)
  end

  defmodule LocaleSetting do
    @moduledoc false
    defstruct locale: nil
    @type t :: %__MODULE__{locale: String.t() | nil}
    @specs [locale: {:string, 1}]
    def encode(%__MODULE__{} = s), do: MessageSupport.encode_fields(s, @specs)
    def decode(bin), do: MessageSupport.decode_fields(bin, %__MODULE__{}, @specs)
  end

  defmodule LockChatAction do
    @moduledoc false
    defstruct locked: nil
    @type t :: %__MODULE__{locked: boolean() | nil}
    @specs [locked: {:bool, 1}]
    def encode(%__MODULE__{} = s), do: MessageSupport.encode_fields(s, @specs)
    def decode(bin), do: MessageSupport.decode_fields(bin, %__MODULE__{}, @specs)
  end

  defmodule MarkChatAsReadAction do
    @moduledoc false
    defstruct read: nil, message_range: nil
    @type t :: %__MODULE__{read: boolean() | nil, message_range: SyncActionMessageRange.t() | nil}
    @specs [read: {:bool, 1}, message_range: {:message, 2, SyncActionMessageRange}]
    def encode(%__MODULE__{} = s), do: MessageSupport.encode_fields(s, @specs)
    def decode(bin), do: MessageSupport.decode_fields(bin, %__MODULE__{}, @specs)
  end

  defmodule MuteAction do
    @moduledoc false
    defstruct muted: nil, mute_end_timestamp: nil, auto_muted: nil

    @type t :: %__MODULE__{
            muted: boolean() | nil,
            mute_end_timestamp: non_neg_integer() | nil,
            auto_muted: boolean() | nil
          }
    @specs [muted: {:bool, 1}, mute_end_timestamp: {:int64, 2}, auto_muted: {:bool, 3}]
    def encode(%__MODULE__{} = s), do: MessageSupport.encode_fields(s, @specs)
    def decode(bin), do: MessageSupport.decode_fields(bin, %__MODULE__{}, @specs)
  end

  defmodule NotificationActivitySettingAction do
    @moduledoc false
    @setting_values %{
      0 => :default_all_messages,
      1 => :all_messages,
      2 => :highlights,
      3 => :default_highlights
    }
    defstruct notification_activity_setting: nil
    @type t :: %__MODULE__{notification_activity_setting: atom() | nil}
    @specs [notification_activity_setting: {:enum, 1, @setting_values}]
    def encode(%__MODULE__{} = s) do
      reverse = Map.new(@setting_values, fn {k, v} -> {v, k} end)
      MessageSupport.encode_fields(s, notification_activity_setting: {:enum, 1, reverse})
    end

    def decode(bin), do: MessageSupport.decode_fields(bin, %__MODULE__{}, @specs)
  end

  defmodule PinAction do
    @moduledoc false
    defstruct pinned: nil
    @type t :: %__MODULE__{pinned: boolean() | nil}
    @specs [pinned: {:bool, 1}]
    def encode(%__MODULE__{} = s), do: MessageSupport.encode_fields(s, @specs)
    def decode(bin), do: MessageSupport.decode_fields(bin, %__MODULE__{}, @specs)
  end

  defmodule PnForLidChatAction do
    @moduledoc false
    defstruct pn_jid: nil
    @type t :: %__MODULE__{pn_jid: String.t() | nil}
    @specs [pn_jid: {:string, 1}]
    def encode(%__MODULE__{} = s), do: MessageSupport.encode_fields(s, @specs)
    def decode(bin), do: MessageSupport.decode_fields(bin, %__MODULE__{}, @specs)
  end

  defmodule PrivacySettingChannelsPersonalisedRecommendationAction do
    @moduledoc false
    defstruct is_user_opted_out: nil
    @type t :: %__MODULE__{is_user_opted_out: boolean() | nil}
    @specs [is_user_opted_out: {:bool, 1}]
    def encode(%__MODULE__{} = s), do: MessageSupport.encode_fields(s, @specs)
    def decode(bin), do: MessageSupport.decode_fields(bin, %__MODULE__{}, @specs)
  end

  defmodule PrivacySettingDisableLinkPreviewsAction do
    @moduledoc false
    defstruct is_previews_disabled: nil
    @type t :: %__MODULE__{is_previews_disabled: boolean() | nil}
    @specs [is_previews_disabled: {:bool, 1}]
    def encode(%__MODULE__{} = s), do: MessageSupport.encode_fields(s, @specs)
    def decode(bin), do: MessageSupport.decode_fields(bin, %__MODULE__{}, @specs)
  end

  defmodule PrivacySettingRelayAllCalls do
    @moduledoc false
    defstruct is_enabled: nil
    @type t :: %__MODULE__{is_enabled: boolean() | nil}
    @specs [is_enabled: {:bool, 1}]
    def encode(%__MODULE__{} = s), do: MessageSupport.encode_fields(s, @specs)
    def decode(bin), do: MessageSupport.decode_fields(bin, %__MODULE__{}, @specs)
  end

  defmodule PushNameSetting do
    @moduledoc false
    defstruct name: nil
    @type t :: %__MODULE__{name: String.t() | nil}
    @specs [name: {:string, 1}]
    def encode(%__MODULE__{} = s), do: MessageSupport.encode_fields(s, @specs)
    def decode(bin), do: MessageSupport.decode_fields(bin, %__MODULE__{}, @specs)
  end

  defmodule QuickReplyAction do
    @moduledoc false
    defstruct shortcut: nil, message: nil, keywords: [], count: nil, deleted: nil

    @type t :: %__MODULE__{
            shortcut: String.t() | nil,
            message: String.t() | nil,
            keywords: [String.t()],
            count: integer() | nil,
            deleted: boolean() | nil
          }
    @specs [
      shortcut: {:string, 1},
      message: {:string, 2},
      keywords: {:repeated_string, 3},
      count: {:int, 4},
      deleted: {:bool, 5}
    ]
    def encode(%__MODULE__{} = s), do: MessageSupport.encode_fields(s, @specs)
    def decode(bin), do: MessageSupport.decode_fields(bin, %__MODULE__{}, @specs)
  end

  defmodule StarAction do
    @moduledoc false
    defstruct starred: nil
    @type t :: %__MODULE__{starred: boolean() | nil}
    @specs [starred: {:bool, 1}]
    def encode(%__MODULE__{} = s), do: MessageSupport.encode_fields(s, @specs)
    def decode(bin), do: MessageSupport.decode_fields(bin, %__MODULE__{}, @specs)
  end

  defmodule StatusPrivacyAction do
    @moduledoc false
    @mode_values %{0 => :allow_list, 1 => :deny_list, 2 => :contacts, 3 => :close_friends}
    defstruct mode: nil, user_jid: []
    @type t :: %__MODULE__{mode: atom() | nil, user_jid: [String.t()]}

    def encode(%__MODULE__{} = s) do
      reverse = Map.new(@mode_values, fn {k, v} -> {v, k} end)
      MessageSupport.encode_fields(s, mode: {:enum, 1, reverse}, user_jid: {:repeated_string, 2})
    end

    def decode(bin) do
      MessageSupport.decode_fields(bin, %__MODULE__{},
        mode: {:enum, 1, @mode_values},
        user_jid: {:repeated_string, 2}
      )
    end
  end

  defmodule TimeFormatAction do
    @moduledoc false
    defstruct is_twenty_four_hour_format_enabled: nil
    @type t :: %__MODULE__{is_twenty_four_hour_format_enabled: boolean() | nil}
    @specs [is_twenty_four_hour_format_enabled: {:bool, 1}]
    def encode(%__MODULE__{} = s), do: MessageSupport.encode_fields(s, @specs)
    def decode(bin), do: MessageSupport.decode_fields(bin, %__MODULE__{}, @specs)
  end

  defmodule UnarchiveChatsSetting do
    @moduledoc false
    defstruct unarchive_chats: nil
    @type t :: %__MODULE__{unarchive_chats: boolean() | nil}
    @specs [unarchive_chats: {:bool, 1}]
    def encode(%__MODULE__{} = s), do: MessageSupport.encode_fields(s, @specs)
    def decode(bin), do: MessageSupport.decode_fields(bin, %__MODULE__{}, @specs)
  end

  # ============================================================================
  # SyncActionValue — container for all action types
  # ============================================================================

  defmodule SyncActionValue do
    @moduledoc false

    # Only the fields referenced by processSyncAction in chat-utils.ts:758-974.
    # Additional fields are silently skipped during decode (MessageSupport behavior).

    defstruct timestamp: nil,
              star_action: nil,
              contact_action: nil,
              mute_action: nil,
              pin_action: nil,
              push_name_setting: nil,
              quick_reply_action: nil,
              label_edit_action: nil,
              label_association_action: nil,
              locale_setting: nil,
              archive_chat_action: nil,
              delete_message_for_me_action: nil,
              mark_chat_as_read_action: nil,
              clear_chat_action: nil,
              delete_chat_action: nil,
              unarchive_chats_setting: nil,
              time_format_action: nil,
              pn_for_lid_chat_action: nil,
              privacy_setting_relay_all_calls: nil,
              status_privacy: nil,
              lock_chat_action: nil,
              privacy_setting_disable_link_previews_action: nil,
              notification_activity_setting_action: nil,
              lid_contact_action: nil,
              privacy_setting_channels_personalised_recommendation_action: nil

    @type t :: %__MODULE__{
            timestamp: integer() | nil,
            star_action: StarAction.t() | nil,
            contact_action: ContactAction.t() | nil,
            mute_action: MuteAction.t() | nil,
            pin_action: PinAction.t() | nil,
            push_name_setting: PushNameSetting.t() | nil,
            quick_reply_action: QuickReplyAction.t() | nil,
            label_edit_action: LabelEditAction.t() | nil,
            label_association_action: LabelAssociationAction.t() | nil,
            locale_setting: LocaleSetting.t() | nil,
            archive_chat_action: ArchiveChatAction.t() | nil,
            delete_message_for_me_action: DeleteMessageForMeAction.t() | nil,
            mark_chat_as_read_action: MarkChatAsReadAction.t() | nil,
            clear_chat_action: ClearChatAction.t() | nil,
            delete_chat_action: DeleteChatAction.t() | nil,
            unarchive_chats_setting: UnarchiveChatsSetting.t() | nil,
            time_format_action: TimeFormatAction.t() | nil,
            pn_for_lid_chat_action: PnForLidChatAction.t() | nil,
            privacy_setting_relay_all_calls: PrivacySettingRelayAllCalls.t() | nil,
            status_privacy: StatusPrivacyAction.t() | nil,
            lock_chat_action: LockChatAction.t() | nil,
            privacy_setting_disable_link_previews_action:
              PrivacySettingDisableLinkPreviewsAction.t() | nil,
            notification_activity_setting_action: NotificationActivitySettingAction.t() | nil,
            lid_contact_action: LidContactAction.t() | nil,
            privacy_setting_channels_personalised_recommendation_action:
              PrivacySettingChannelsPersonalisedRecommendationAction.t() | nil
          }

    # Field numbers match WAProto.proto SyncActionValue definition
    @specs [
      timestamp: {:int64, 1},
      star_action: {:message, 2, StarAction},
      contact_action: {:message, 3, ContactAction},
      mute_action: {:message, 4, MuteAction},
      pin_action: {:message, 5, PinAction},
      push_name_setting: {:message, 7, PushNameSetting},
      quick_reply_action: {:message, 8, QuickReplyAction},
      label_edit_action: {:message, 14, LabelEditAction},
      label_association_action: {:message, 15, LabelAssociationAction},
      locale_setting: {:message, 16, LocaleSetting},
      archive_chat_action: {:message, 17, ArchiveChatAction},
      delete_message_for_me_action: {:message, 18, DeleteMessageForMeAction},
      mark_chat_as_read_action: {:message, 20, MarkChatAsReadAction},
      clear_chat_action: {:message, 21, ClearChatAction},
      delete_chat_action: {:message, 22, DeleteChatAction},
      unarchive_chats_setting: {:message, 23, UnarchiveChatsSetting},
      time_format_action: {:message, 30, TimeFormatAction},
      pn_for_lid_chat_action: {:message, 37, PnForLidChatAction},
      privacy_setting_relay_all_calls: {:message, 41, PrivacySettingRelayAllCalls},
      status_privacy: {:message, 44, StatusPrivacyAction},
      lock_chat_action: {:message, 50, LockChatAction},
      privacy_setting_disable_link_previews_action:
        {:message, 53, PrivacySettingDisableLinkPreviewsAction},
      notification_activity_setting_action: {:message, 60, NotificationActivitySettingAction},
      lid_contact_action: {:message, 61, LidContactAction},
      privacy_setting_channels_personalised_recommendation_action:
        {:message, 64, PrivacySettingChannelsPersonalisedRecommendationAction}
    ]

    @spec encode(t()) :: binary()
    def encode(%__MODULE__{} = s), do: MessageSupport.encode_fields(s, @specs)

    @spec decode(binary()) :: {:ok, t()} | {:error, term()}
    def decode(bin), do: MessageSupport.decode_fields(bin, %__MODULE__{}, @specs)
  end

  # ============================================================================
  # SyncActionData — top-level container decoded from encrypted patch value
  # ============================================================================

  defmodule SyncActionData do
    @moduledoc false

    defstruct index: nil, value: nil, padding: nil, version: nil

    @type t :: %__MODULE__{
            index: binary() | nil,
            value: SyncActionValue.t() | nil,
            padding: binary() | nil,
            version: integer() | nil
          }

    @specs [
      index: {:bytes, 1},
      value: {:message, 2, SyncActionValue},
      padding: {:bytes, 3},
      version: {:int, 4}
    ]

    @spec encode(t()) :: binary()
    def encode(%__MODULE__{} = s), do: MessageSupport.encode_fields(s, @specs)

    @spec decode(binary()) :: {:ok, t()} | {:error, term()}
    def decode(bin), do: MessageSupport.decode_fields(bin, %__MODULE__{}, @specs)
  end
end
