defmodule BaileysEx.Protocol.Proto.PhoneNumberToLIDMapping do
  @moduledoc false

  alias BaileysEx.Protocol.Proto.MessageSupport

  defstruct pn_jid: nil, lid_jid: nil

  @type t :: %__MODULE__{pn_jid: String.t() | nil, lid_jid: String.t() | nil}

  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = mapping) do
    MessageSupport.encode_fields(mapping,
      pn_jid: {:string, 1},
      lid_jid: {:string, 2}
    )
  end

  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(binary) do
    MessageSupport.decode_fields(binary, %__MODULE__{},
      pn_jid: {:string, 1},
      lid_jid: {:string, 2}
    )
  end
end

defmodule BaileysEx.Protocol.Proto.Pushname do
  @moduledoc false

  alias BaileysEx.Protocol.Proto.MessageSupport

  defstruct id: nil, pushname: nil

  @type t :: %__MODULE__{id: String.t() | nil, pushname: String.t() | nil}

  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = pushname) do
    MessageSupport.encode_fields(pushname,
      id: {:string, 1},
      pushname: {:string, 2}
    )
  end

  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(binary) do
    MessageSupport.decode_fields(binary, %__MODULE__{},
      id: {:string, 1},
      pushname: {:string, 2}
    )
  end
end

defmodule BaileysEx.Protocol.Proto.HistorySyncMsg do
  @moduledoc false

  alias BaileysEx.Protocol.Proto.MessageSupport
  alias BaileysEx.Protocol.Proto.WebMessageInfo

  defstruct message: nil, msg_order_id: nil

  @type t :: %__MODULE__{
          message: WebMessageInfo.t() | nil,
          msg_order_id: non_neg_integer() | nil
        }

  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = history_sync_msg) do
    MessageSupport.encode_fields(history_sync_msg,
      message: {:message, 1, WebMessageInfo},
      msg_order_id: {:uint, 2}
    )
  end

  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(binary) do
    MessageSupport.decode_fields(binary, %__MODULE__{},
      message: {:message, 1, WebMessageInfo},
      msg_order_id: {:uint, 2}
    )
  end
end

defmodule BaileysEx.Protocol.Proto.Conversation do
  @moduledoc false

  alias BaileysEx.Protocol.Proto.HistorySyncMsg
  alias BaileysEx.Protocol.Proto.MessageSupport

  defstruct id: nil,
            messages: [],
            last_msg_timestamp: nil,
            unread_count: nil,
            conversation_timestamp: nil,
            name: nil,
            display_name: nil,
            pn_jid: nil,
            lid_jid: nil,
            username: nil

  @type t :: %__MODULE__{
          id: String.t() | nil,
          messages: [HistorySyncMsg.t()],
          last_msg_timestamp: non_neg_integer() | nil,
          unread_count: non_neg_integer() | nil,
          conversation_timestamp: non_neg_integer() | nil,
          name: String.t() | nil,
          display_name: String.t() | nil,
          pn_jid: String.t() | nil,
          lid_jid: String.t() | nil,
          username: String.t() | nil
        }

  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = conversation) do
    MessageSupport.encode_fields(conversation,
      id: {:string, 1},
      messages: {:repeated_message, 2, HistorySyncMsg},
      last_msg_timestamp: {:uint, 5},
      unread_count: {:uint, 6},
      conversation_timestamp: {:uint, 12},
      name: {:string, 13},
      display_name: {:string, 38},
      pn_jid: {:string, 39},
      lid_jid: {:string, 42},
      username: {:string, 43}
    )
  end

  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(binary) do
    MessageSupport.decode_fields(binary, %__MODULE__{},
      id: {:string, 1},
      messages: {:repeated_message, 2, HistorySyncMsg},
      last_msg_timestamp: {:uint, 5},
      unread_count: {:uint, 6},
      conversation_timestamp: {:uint, 12},
      name: {:string, 13},
      display_name: {:string, 38},
      pn_jid: {:string, 39},
      lid_jid: {:string, 42},
      username: {:string, 43}
    )
  end
end

defmodule BaileysEx.Protocol.Proto.HistorySync do
  @moduledoc false

  alias BaileysEx.Protocol.Proto.Conversation
  alias BaileysEx.Protocol.Proto.MessageSupport
  alias BaileysEx.Protocol.Proto.PhoneNumberToLIDMapping
  alias BaileysEx.Protocol.Proto.Pushname

  @sync_type_values %{
    INITIAL_BOOTSTRAP: 0,
    INITIAL_STATUS_V3: 1,
    FULL: 2,
    RECENT: 3,
    PUSH_NAME: 4,
    NON_BLOCKING_DATA: 5,
    ON_DEMAND: 6
  }

  defstruct sync_type: nil,
            conversations: [],
            progress: nil,
            pushnames: [],
            phone_number_to_lid_mappings: []

  @type t :: %__MODULE__{
          sync_type: atom() | integer() | nil,
          conversations: [Conversation.t()],
          progress: non_neg_integer() | nil,
          pushnames: [Pushname.t()],
          phone_number_to_lid_mappings: [PhoneNumberToLIDMapping.t()]
        }

  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = history_sync) do
    MessageSupport.encode_fields(history_sync,
      sync_type: {:enum, 1, @sync_type_values},
      conversations: {:repeated_message, 2, Conversation},
      progress: {:uint, 6},
      pushnames: {:repeated_message, 7, Pushname},
      phone_number_to_lid_mappings: {:repeated_message, 15, PhoneNumberToLIDMapping}
    )
  end

  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(binary) do
    MessageSupport.decode_fields(binary, %__MODULE__{},
      sync_type: {:enum, 1, @sync_type_values},
      conversations: {:repeated_message, 2, Conversation},
      progress: {:uint, 6},
      pushnames: {:repeated_message, 7, Pushname},
      phone_number_to_lid_mappings: {:repeated_message, 15, PhoneNumberToLIDMapping}
    )
  end
end
