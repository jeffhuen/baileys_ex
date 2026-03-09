# Phase 3: Protocol Layer

> **Status note:** This phase is complete for the corrected scope. The repo now has
> `BinaryNode`, `Constants`, `JID`, Baileys-style `BinaryNode` helpers, `USync`,
> `WMex`, `MessageStubType`, and the minimal manual protobuf modules needed by the
> transport/auth boundary. Broad `WAProto` code generation is intentionally deferred
> to the later phases that consume `ClientPayload`, `Message`, and the rest of the
> message/auth schema surface.

**Goal:** Implement the protocol-layer building blocks that Phase 4 and Phase 6 need
immediately: WABinary encoding/decoding, JID handling, generic node helpers, USync,
WMex, message stub mapping, and the minimal protobuf boundary required by the
transport/auth handshake.

**Depends on:** Phase 1 (Foundation)
**Parallel with:** Phase 2 (Crypto)
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
the codebase. But the Baileys reference only needs a narrow subset of WAProto at
this stage (`HandshakeMessage`, `CertChain`, and closely-related transport/auth
types), so Phase 3 should not block on generating the entire WhatsApp schema tree.

---

## Tasks

### 3.1 WABinary Node Types

File: `lib/baileys_ex/protocol/binary_node.ex`

The WABinary format encodes XMPP-style nodes as:
- Tag (string from dictionary or raw)
- Attributes (key-value pairs)
- Content (text, raw bytes, child nodes, or nil)

```elixir
defmodule BaileysEx.Protocol.BinaryNode do
  @type content :: String.t() | {:binary, binary()} | [t()] | nil

  @type t :: %__MODULE__{
    tag: String.t(),
    attrs: %{String.t() => String.t()},
    content: content()
  }

  defstruct [:tag, attrs: %{}, content: nil]

  def encode(%__MODULE__{} = node), do: ...
  def decode(binary), do: ...
end
```

Do not infer text-versus-bytes from `String.valid?/1` or similar heuristics. Baileys keeps
these two wire representations distinct (`string` vs `Buffer`/`Uint8Array`), so the plan
must preserve that distinction explicitly in Elixir too.

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
4. **Content**: plain string content (via `write_string`), `{:binary, bytes}` (length-prefixed with
   `BINARY_8/20/32` tags), or child nodes (list header + recursive encoding).

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
- Read content → recursive node decode, `{:binary, bytes}`, or plain string content
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
  @hosted "hosted"
  @hosted_lid "hosted.lid"

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
  # - LID (Local Identifier): `lid_user@lid` format for multi-device
  # - Hosted PN / Hosted LID: `user@hosted` and `user@hosted.lid` variants used
  #   in history sync, routing, and decryption helpers
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

  @doc "Check if JID is a hosted PN"
  def hosted_pn?(%__MODULE__{server: @hosted}), do: true
  def hosted_pn?(_), do: false

  @doc "Check if JID is a hosted LID"
  def hosted_lid?(%__MODULE__{server: @hosted_lid}), do: true
  def hosted_lid?(_), do: false

  @doc "Normalize JID for signal address (strips device, handles LID)"
  def to_signal_address(%__MODULE__{} = jid), do: ...

end
```

Reference: `dev/reference/Baileys-master/src/WABinary/jid-utils.ts`

### 3.6 USync Query Infrastructure

File: `lib/baileys_ex/protocol/usync.ex`

USync is WhatsApp's general-purpose user-sync query mechanism. It is used by device
discovery, phone validation, status fetch, disappearing mode fetch, and LID mapping.
Building the query builder here in Phase 3 (alongside the binary node types it depends
on) keeps the protocol layer self-contained. Higher-level modules in later phases
call into `USync.build_query/3` or the more explicit `new/0` / `with_protocol/2` /
`with_user/2` / `to_node/2` builder flow, then parse responses with
`USync.parse_result/2`.

```elixir
defmodule BaileysEx.Protocol.USync do
  @moduledoc """
  General-purpose USync query builder. Used by device discovery, phone validation,
  status fetch, disappearing mode fetch, and LID mapping.
  """

  alias BaileysEx.Protocol.BinaryNode

  @type protocol :: :devices | :contact | :status | :disappearing_mode | :lid
  @type mode :: :query | :delta
  @type context :: :message | :interactive | :notification | :background

  def new(opts \\ []), do: ...
  def with_protocol(query, protocol), do: ...
  def with_user(query, user), do: ...
  def with_context(query, context), do: ...
  def with_mode(query, mode), do: ...

  @doc "Build the `iq/usync` binary node sent to WhatsApp."
  def to_node(query, sid), do: ...

  @doc "Convenience wrapper around `new/1` + `with_*` + `to_node/2`."
  def build_query(protocols, users, opts \\ []), do: ...

  @doc """
  Parse a `type=\"result\"` USync IQ into `%{list: [...], side_list: [...]}`.

  Protocol keys are returned as Elixir atoms (`:devices`, `:contact`, `:status`,
  `:disappearing_mode`, `:lid`) with nested maps using snake_case keys.
  """
  def parse_result(query, response_node), do: ...
end
```

Reference:
- `dev/reference/Baileys-master/src/Socket/socket.ts`
- `dev/reference/Baileys-master/src/WAUSync/USyncQuery.ts`
- `dev/reference/Baileys-master/src/WAUSync/USyncUser.ts`
- `dev/reference/Baileys-master/src/WAUSync/Protocols/*.ts`

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
    "revoked_membership_requests" => :GROUP_MEMBERSHIP_JOIN_APPROVAL_REQUEST_NON_ADMIN_ADD
  }

  def from_string(type), do: Map.get(@stub_types, type)
  def all_types, do: Map.values(@stub_types)
end
```

### 3.6b WMex Query Engine

File: `lib/baileys_ex/protocol/wmex.ex`

Generic GraphQL-over-binary-node transport used by newsletter operations.
Sends JSON-encoded variables in `xmlns: 'w:mex'` IQ nodes as raw bytes, then
parses `result` payload JSON and extracts the requested XWA field.

```elixir
defmodule BaileysEx.Protocol.WMex do
  @moduledoc """
  WMex (WhatsApp MEX) query helpers. Used by newsletter operations to build
  GraphQL-style query IQ nodes and parse the returned JSON payload.

  Reference: `dev/reference/Baileys-master/src/Socket/mex.ts`
  """

  alias BaileysEx.Protocol.BinaryNode

  @doc "Build the `iq/query` node that Phase 11 newsletter calls will send."
  def build_query(query_id, variables, message_id), do: ...

  @doc "Parse the `result` child payload and extract a single XWA data field."
  def extract_result(response_node, xwa_path), do: ...
end
```

### 3.7 Minimal Protobuf Boundary

Baileys uses `WAProto` broadly, but the reference code does not need the entire
schema surface to finish the protocol layer. At this point in the stack, the
immediate dependency is the transport/auth handshake path:

- `HandshakeMessage` — Noise protocol handshake wrapper
- `CertChain` / `NoiseCertificate` — WhatsApp Noise certificate chain
- closely-related nested types used by the transport/auth boundary

Those modules live in `lib/baileys_ex/protocol/proto/noise_messages.ex` today as a
small manual boundary that keeps Phases 3 and 4 unblocked. The full `WAProto.proto`
copy in `priv/proto/WAProto.proto` is retained as a source artifact for the later
auth/messaging work, where broad `protox` generation belongs.

This matches the Baileys reference more closely than forcing the whole WhatsApp
schema tree into Phase 3, because the real schema consumers (`ClientPayload`,
`Message`, `WebMessageInfo`, app-state, etc.) live in later phases.

### 3.8 Tests

- **BinaryNode roundtrip**: encode → decode returns original node
- **Dictionary lookups**: all known tokens resolve correctly
- **JID parsing**: test all formats (user@server, with device, LID, group)
- **BinaryNode generic helpers**: `children/1`, `children/2`, `child/2`,
  `child_string/2`, `child_bytes/2`, `assert_error_free/1`
- **JID LID/PN addressing**: `addressing_mode/1`, `lid?/1`, `to_signal_address/1`,
  hosted domain predicates, and domain-type conversion helpers
- **USync query builder**: `build_query/3` produces correct binary nodes for each
  protocol type (`:devices`, `:contact`, `:status`, `:disappearing_mode`, `:lid`)
- **USync response parser**: `parse_result/2` extracts user results from sample
  `list` and `side_list` response nodes
- **Message stub types**: all stub type strings resolve to correct atoms
- **WMex query**: `build_query/3` constructs correct IQ node with JSON body
- **WMex response**: `extract_result/2` parses result and navigates XWA path
- **Minimal protobuf roundtrip**: encode → decode for the transport/auth proto
  modules needed by Noise

---

## Acceptance Criteria

- [x] BinaryNode encode/decode roundtrip works for covered node types
- [x] BinaryNode helper APIs mirror the Baileys `generic-utils.ts` traversal/error surface
- [x] JID parse/to_string covers core WhatsApp JID formats
- [x] JID module handles LID (`@lid`) and PN (`@s.whatsapp.net`) addressing modes
- [x] USync query builder constructs correct binary nodes for all 5 supported protocol types
- [x] USync response parser extracts `list` and `side_list` user results correctly
- [x] Minimal transport/auth protobuf modules compile and roundtrip in focused tests
- [x] Message stub type constants are defined for the current 20 group notification mappings
- [x] WMex query helpers construct correct IQ nodes with JSON variables as raw bytes
- [x] WMex response parser extracts data by XWA path and surfaces GraphQL errors

## Files Created/Modified

- `lib/baileys_ex/protocol/binary_node.ex`
- `lib/baileys_ex/protocol/constants.ex`
- `lib/baileys_ex/protocol/jid.ex`
- `lib/baileys_ex/protocol/usync.ex`
- `lib/baileys_ex/protocol/wmex.ex`
- `lib/baileys_ex/protocol/proto/noise_messages.ex`
- `priv/proto/WAProto.proto`
- `test/baileys_ex/protocol/binary_node_test.exs`
- `test/baileys_ex/protocol/jid_test.exs`
- `test/baileys_ex/protocol/usync_test.exs`
- `test/baileys_ex/protocol/wmex_test.exs`
- `test/baileys_ex/protocol/proto_test.exs`
