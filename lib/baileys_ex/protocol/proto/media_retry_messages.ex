defmodule BaileysEx.Protocol.Proto.MediaRetryNotification do
  @moduledoc false

  alias BaileysEx.Protocol.Proto.MessageSupport

  @result_type %{
    GENERAL_ERROR: 0,
    SUCCESS: 1,
    NOT_FOUND: 2,
    DECRYPTION_ERROR: 3
  }

  defstruct stanza_id: nil,
            direct_path: nil,
            result: nil,
            message_secret: nil

  @type result_type :: :GENERAL_ERROR | :SUCCESS | :NOT_FOUND | :DECRYPTION_ERROR

  @type t :: %__MODULE__{
          stanza_id: String.t() | nil,
          direct_path: String.t() | nil,
          result: result_type() | non_neg_integer() | nil,
          message_secret: binary() | nil
        }

  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = notification) do
    MessageSupport.encode_fields(notification,
      stanza_id: {:string, 1},
      direct_path: {:string, 2},
      result: {:enum, 3, @result_type},
      message_secret: {:bytes, 4}
    )
  end

  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(binary) do
    MessageSupport.decode_fields(binary, %__MODULE__{},
      stanza_id: {:string, 1},
      direct_path: {:string, 2},
      result: {:enum, 3, @result_type},
      message_secret: {:bytes, 4}
    )
  end
end

defmodule BaileysEx.Protocol.Proto.ServerErrorReceipt do
  @moduledoc false

  alias BaileysEx.Protocol.Proto.MessageSupport

  defstruct stanza_id: nil

  @type t :: %__MODULE__{stanza_id: String.t() | nil}

  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = receipt) do
    MessageSupport.encode_fields(receipt, stanza_id: {:string, 1})
  end

  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(binary) do
    MessageSupport.decode_fields(binary, %__MODULE__{}, stanza_id: {:string, 1})
  end
end
