# Phase 3: Protocol Layer

**Goal:** Implement WABinary encoding/decoding, JID handling, and generate Elixir
modules from WhatsApp's protobuf definitions.

**Depends on:** Phase 1 (Foundation)
**Parallel with:** Phase 2 (Crypto NIF)
**Blocks:** Phase 6 (Connection)

---

## Design Decisions

**WABinary: Elixir or Rust NIF?**
Elixir. Binary pattern matching is one of Elixir's superpowers. The WABinary format
is straightforward enough that Elixir will be fast and much more maintainable than
a Rust NIF. If profiling later shows it's a bottleneck, we can move it to Rust.

**Protobuf: protox (Elixir) not prost (Rust).**
Keeps proto handling in Elixir where it's easier to debug and iterate. `protox`
generates Elixir structs with encode/decode — clean integration with the rest of
the codebase.

---

## Tasks

### 3.1 WABinary Node Types

File: `lib/baileys_ex/protocol/binary_node.ex`

The WABinary format encodes XMPP-style nodes as:
- Tag (string from dictionary or raw)
- Attributes (key-value pairs)
- Content (binary data, child nodes, or nil)

```elixir
defmodule BaileysEx.Protocol.BinaryNode do
  @type t :: %__MODULE__{
    tag: String.t(),
    attrs: %{String.t() => String.t()},
    content: binary() | [t()] | nil
  }

  defstruct [:tag, attrs: %{}, content: nil]

  def encode(%__MODULE__{} = node), do: ...
  def decode(binary), do: ...
end
```

Reference: `dev/reference/Baileys-master/src/WABinary/encode.ts` and `decode.ts`

### 3.2 WABinary Constants/Dictionaries

File: `lib/baileys_ex/protocol/constants.ex`

Port the string dictionaries from `src/WABinary/constants.ts`:
- Single-byte token dictionary (256 entries)
- Double-byte token dictionaries
- Tag constants (LIST_EMPTY, STREAM_END, etc.)

These are static — use module attributes or `:persistent_term` for zero-cost lookups.

### 3.3 WABinary Encoder

Encode BinaryNode to binary format. Node serialization:
1. **List header**: `2 * num_attributes + 1 + (has_content? 1 : 0)`.
   Sizes use `LIST_EMPTY` (tag 0), `LIST_8` (tag 248, 1-byte len), `LIST_16` (tag 249, 2-byte len).
2. **Tag string**: encoded via `write_string` (see below).
3. **Attributes**: key-value pairs, each string via `write_string`.
4. **Content**: string (via `write_string`), binary (length-prefixed with `BINARY_8/20/32` tags),
   or child nodes (list header + recursive encoding).

String encoding strategies (tried in order):
1. **Token lookup**: `SINGLE_BYTE_TOKENS` (1 byte) or `DOUBLE_BYTE_TOKENS` (prefixed with `DICTIONARY_0..3` tags 236-239)
2. **Nibble packing** (tag 255): strings of only digits, `-`, `.` → 4 bits per char
3. **Hex packing** (tag 251): strings of only `0-9A-F` → 4 bits per char
4. **JID encoding**: `user@server` split and encoded separately
5. **Raw string**: length-prefixed UTF-8 bytes

Reference: `dev/reference/Baileys-master/src/WABinary/encode.ts`

### 3.4 WABinary Decoder

Decode binary to BinaryNode (inverse of encoder):
- Read list header → determine attribute count and content presence
- Read tag string → dictionary lookup or raw decode
- Read attributes → pairs of decoded strings
- Read content → recursive node decode, raw binary, or string
- Handle all token types: dictionary (single/double byte), nibble, hex, JID, raw

Reference: `dev/reference/Baileys-master/src/WABinary/decode.ts`

### 3.5 JID Module

File: `lib/baileys_ex/protocol/jid.ex`

```elixir
defmodule BaileysEx.Protocol.JID do
  @type t :: %__MODULE__{
    user: String.t() | nil,
    server: String.t(),
    device: non_neg_integer() | nil,
    agent: non_neg_integer() | nil
  }

  @type addressing_mode :: :lid | :pn
  @type lid_pn_mapping :: %{lid: t(), pn: t()}

  defstruct [:user, :server, :device, :agent]

  @s_whatsapp_net "s.whatsapp.net"
  @g_us "g.us"
  @lid "lid"

  def parse(jid_string), do: ...
  def to_string(%__MODULE__{} = jid), do: ...
  def is_group?(%__MODULE__{server: @g_us}), do: true
  def is_group?(_), do: false
  def is_user?(%__MODULE__{server: @s_whatsapp_net}), do: true
  def is_user?(_), do: false
  def jid_encode(user, server), do: ...
  def jid_decode(jid_string), do: ...

  # --- LID/PN Dual Addressing ---
  #
  # WhatsApp uses two addressing modes:
  # - PN (Phone Number): Traditional `user@s.whatsapp.net` format
  # - LID (Logical Device ID): `lid_user@lid` format for multi-device
  #
  # The Connection Store (Phase 6) must maintain a LID↔PN mapping table in ETS.
  # This module provides functions to query and update those mappings via the
  # store, but the ETS table itself lives in the connection process.

  @doc "Detect addressing mode from JID"
  def addressing_mode(%__MODULE__{server: @lid}), do: :lid
  def addressing_mode(_), do: :pn

  @doc "Check if JID is a LID"
  def lid?(%__MODULE__{server: @lid}), do: true
  def lid?(_), do: false

  @doc "Normalize JID for signal address (strips device, handles LID)"
  def to_signal_address(%__MODULE__{} = jid), do: ...

  @doc """
  Extract sender alternative addressing from message stanza.

  Returns %{addressing_mode: :lid | :pn, sender_alt: jid | nil, recipient_alt: jid | nil}
  """
  def extract_addressing_context(%BinaryNode{} = stanza), do: ...
end
```

Reference: `dev/reference/Baileys-master/src/WABinary/jid-utils.ts`

### 3.6 USync Query Infrastructure

File: `lib/baileys_ex/protocol/usync.ex`

USync is WhatsApp's general-purpose user-sync query mechanism. It is used by device
discovery, phone validation, status fetch, disappearing mode fetch, and LID mapping.
Building the query builder here in Phase 3 (alongside the binary node types it depends
on) keeps the protocol layer self-contained. Higher-level modules in later phases
call into `USync.build_query/3` and `USync.parse_response/2`.

```elixir
defmodule BaileysEx.Protocol.USync do
  @moduledoc """
  General-purpose USync query builder. Used by device discovery, phone validation,
  status fetch, disappearing mode fetch, and LID mapping.
  """

  alias BaileysEx.Protocol.BinaryNode

  @type protocol :: :device | :contact | :status | :disappearing_mode | :lid
  @type mode :: :query | :delta
  @type context :: :message | :interactive | :notification

  @doc "Build a USync query binary node"
  def build_query(protocols, users, opts \\ []) do
    mode = opts[:mode] || :query
    context = opts[:context] || :interactive

    %BinaryNode{
      tag: "iq",
      attrs: %{"xmlns" => "usync", "to" => "s.whatsapp.net", "type" => "get"},
      content: [
        %BinaryNode{
          tag: "usync",
          attrs: %{
            "context" => to_string(context),
            "mode" => to_string(mode),
            "sid" => generate_tag(),
            "last" => "true",
            "index" => "0"
          },
          content: [
            build_query_node(protocols),
            build_list_node(users)
          ]
        }
      ]
    }
  end

  @doc """
  Parse USync response.

  Extracts user results from a usync response node.
  Returns list of %{jid: jid, data: protocol_specific_data}
  """
  def parse_response(response_node, protocol), do: ...

  # Protocol-specific query builders
  defp build_protocol_node(:device), do: %BinaryNode{tag: "device", attrs: %{}}
  defp build_protocol_node(:contact), do: %BinaryNode{tag: "contact", attrs: %{}}
  defp build_protocol_node(:status), do: %BinaryNode{tag: "status", attrs: %{}}
  defp build_protocol_node(:disappearing_mode), do: %BinaryNode{tag: "disappearing_mode", attrs: %{}}
  defp build_protocol_node(:lid), do: %BinaryNode{tag: "lid", attrs: %{}}

  defp build_query_node(protocols) do
    %BinaryNode{
      tag: "query",
      attrs: %{},
      content: Enum.map(protocols, &build_protocol_node/1)
    }
  end

  defp build_list_node(users), do: ...

  defp generate_tag, do: ...
end
```

Reference: `dev/reference/Baileys-master/src/Utils/chat-utils.ts` (search for `usync`)

### 3.6a Message Stub Type Constants

File: `lib/baileys_ex/protocol/constants.ex` (extend)

Group notification types map to `messageStubType` values. Define as an enum
module for pattern matching in the receiver (Phase 8).

```elixir
defmodule BaileysEx.Protocol.MessageStubType do
  @moduledoc "Group notification stub types for synthetic messages."

  @stub_types %{
    "create" => :GROUP_CREATE,
    "ephemeral" => :GROUP_CHANGE_EPHEMERAL_SETTING,
    "not_ephemeral" => :GROUP_CHANGE_NOT_EPHEMERAL,
    "modify" => :GROUP_CHANGE_SUBJECT,
    "promote" => :GROUP_PARTICIPANT_PROMOTE,
    "demote" => :GROUP_PARTICIPANT_DEMOTE,
    "remove" => :GROUP_PARTICIPANT_REMOVE,
    "add" => :GROUP_PARTICIPANT_ADD,
    "leave" => :GROUP_PARTICIPANT_LEAVE,
    "subject" => :GROUP_CHANGE_SUBJECT,
    "description" => :GROUP_CHANGE_DESCRIPTION,
    "announcement" => :GROUP_CHANGE_ANNOUNCE,
    "not_announcement" => :GROUP_CHANGE_NOT_ANNOUNCE,
    "locked" => :GROUP_CHANGE_RESTRICT,
    "unlocked" => :GROUP_CHANGE_NOT_RESTRICT,
    "invite" => :GROUP_PARTICIPANT_INVITE,
    "member_add_mode" => :GROUP_MEMBER_ADD_MODE,
    "membership_approval_mode" => :GROUP_MEMBERSHIP_JOIN_APPROVAL_MODE,
    "created_membership_requests" => :GROUP_MEMBERSHIP_JOIN_APPROVAL_REQUEST_NON_ADMIN_ADD,
    "revoked_membership_requests" => :GROUP_PARTICIPANT_LINKED_GROUP_JOIN
  }

  def from_string(type), do: Map.get(@stub_types, type)
  def all_types, do: Map.values(@stub_types)
end
```

### 3.6b WMex Query Engine

File: `lib/baileys_ex/protocol/wmex.ex`

Generic GraphQL-over-binary-node transport used by all newsletter operations.
Sends JSON-encoded variables in `xmlns: 'w:mex'` IQ nodes. Parses result
nodes, extracts data by XWAPath, handles GraphQL error responses.

```elixir
defmodule BaileysEx.Protocol.WMex do
  @moduledoc """
  WMex (WhatsApp MEX) query engine. Used by newsletter operations to send
  GraphQL-style queries over binary nodes.

  Reference: dev/reference/Baileys-master/src/Utils/mex.ts
  """

  alias BaileysEx.Protocol.BinaryNode

  @doc "Execute a WMex query with JSON-encoded variables"
  def execute(conn, query_id, variables, xwa_path) do
    node = %BinaryNode{
      tag: "iq",
      attrs: %{
        "to" => "s.whatsapp.net",
        "type" => "get",
        "xmlns" => "w:mex"
      },
      content: [
        %BinaryNode{
          tag: "query",
          attrs: %{"query_id" => query_id},
          content: JSON.encode!(%{variables: variables})
        }
      ]
    }

    with {:ok, response} <- Connection.Socket.send_node_and_wait(conn, node),
         {:ok, result} <- extract_result(response, xwa_path) do
      {:ok, result}
    end
  end

  defp extract_result(response_node, xwa_path) do
    # Parse "result" child node -> decode JSON -> navigate xwa_path
    # Handle GraphQL error responses
  end
end
```

### 3.7 Protobuf Code Generation

There is a **single massive proto file**: `dev/reference/Baileys-master/WAProto/WAProto.proto`
(5,479 lines, ~498 message types, ~174 enums, proto3 syntax, package `proto`).

Key message types:
- `Message` — main message content union (text, image, video, etc.)
- `WebMessageInfo` — wraps Message with metadata (key, status, timestamps)
- `ClientPayload` — sent during login/registration
- `HandshakeMessage` — Noise protocol handshake wrapper
- `SyncActionValue` — app state sync patches
- `SessionStructure`, `SenderKeyDistributionMessage` — Signal protocol structures

Copy to `priv/proto/WAProto.proto` and generate Elixir modules using `protox`:

```
lib/baileys_ex/protocol/proto/
└── wa_proto.ex              # Generated — all 498+ message structs
```

Add a mix task or script to regenerate when proto changes.
Consider splitting the single proto into logical sub-files if `protox` compilation
is slow, but start with the single file.

### 3.8 Tests

- **BinaryNode roundtrip**: encode → decode returns original node
- **Dictionary lookups**: all known tokens resolve correctly
- **JID parsing**: test all formats (user@server, with device, LID, group)
- **JID LID/PN addressing**: `addressing_mode/1`, `lid?/1`, `to_signal_address/1`,
  `extract_addressing_context/1` for both `@s.whatsapp.net` and `@lid` JIDs
- **USync query builder**: `build_query/3` produces correct binary nodes for each
  protocol type (`:device`, `:contact`, `:status`, `:disappearing_mode`, `:lid`)
- **USync response parser**: `parse_response/2` extracts user results from sample
  response nodes
- **Message stub types**: all stub type strings resolve to correct atoms
- **WMex query**: `execute/4` constructs correct IQ node with JSON body
- **WMex response**: `extract_result/2` parses result and navigates XWA path
- **Protobuf roundtrip**: encode → decode for key message types
- **Cross-validation**: capture binary data from Baileys, decode in BaileysEx

---

## Acceptance Criteria

- [ ] BinaryNode encode/decode roundtrip works for all node types
- [ ] JID parse/to_string covers all WhatsApp JID formats
- [ ] JID module handles LID (`@lid`) and PN (`@s.whatsapp.net`) addressing modes
- [ ] USync query builder constructs correct binary nodes for all 5 protocol types
- [ ] USync response parser extracts user results correctly
- [ ] Protobuf modules generated and compile
- [ ] Dictionary constants match Baileys reference exactly
- [ ] Cross-validation tests pass with captured Baileys data
- [ ] Message stub type constants defined for all 20+ group notification types
- [ ] WMex query engine constructs correct IQ nodes with JSON variables
- [ ] WMex response parser extracts data by XWA path

## Files Created/Modified

- `lib/baileys_ex/protocol/binary_node.ex`
- `lib/baileys_ex/protocol/constants.ex`
- `lib/baileys_ex/protocol/jid.ex`
- `lib/baileys_ex/protocol/usync.ex`
- `lib/baileys_ex/protocol/wmex.ex`
- `lib/baileys_ex/protocol/proto/*.ex` (generated)
- `priv/proto/*.proto` (copied from Baileys)
- `test/baileys_ex/protocol/binary_node_test.exs`
- `test/baileys_ex/protocol/jid_test.exs`
- `test/baileys_ex/protocol/usync_test.exs`
- `test/baileys_ex/protocol/proto_test.exs`
