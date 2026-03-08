defmodule BaileysEx.JID do
  @moduledoc """
  WhatsApp Jabber ID — the address format for users, groups, and broadcasts.

  Examples:
  - User: `5511999887766@s.whatsapp.net`
  - Group: `120363001234567890@g.us`
  - Broadcast: `status@broadcast`
  - LID: `abc123@lid`
  """

  @type t :: %__MODULE__{
          user: String.t() | nil,
          server: String.t(),
          device: non_neg_integer() | nil,
          agent: non_neg_integer() | nil
        }

  defstruct [:user, :server, :device, :agent]
end

defmodule BaileysEx.BinaryNode do
  @moduledoc """
  WhatsApp's wire format node — a compact binary encoding of XML-like structures.

  Each node has a tag (string), attributes (map), and content (child nodes or binary data).
  """

  @type t :: %__MODULE__{
          tag: String.t(),
          attrs: %{String.t() => String.t()},
          content: [t()] | binary() | nil
        }

  defstruct [:tag, attrs: %{}, content: nil]
end
