# Phase 6: Connection

**Goal:** WebSocket transport with Noise encryption, `:gen_statem` connection state
machine, keep-alive, reconnection, per-connection supervision tree.

**Depends on:** Phase 3 (Protocol Layer), Phase 4 (Noise NIF)
**Blocks:** Phase 7 (Auth), Phase 8 (Messaging)

---

> **Current snapshot:** Phase 6 now has two accepted slices in-tree. The repo has
> `Connection.Config`, a pure `Connection.Frame` codec, an evented `Connection.Transport`
> boundary, a real `Connection.Transport.MintWebSocket` implementation, and a
> `Connection.Socket` `:gen_statem` that performs the real Baileys-style Noise handshake
> up to `:authenticating`. Keep-alive, reconnect policy, per-connection supervision,
> event buffering, and the connection store remain open Phase 6 work.

## Design Decisions

**`:gen_statem` directly, not GenServer.**
Connection has explicit states with different valid operations per state. `:gen_statem`
expresses this naturally. Using it directly (not `gen_state_machine` hex) avoids a
dependency and is well-supported in OTP 27+.

**Mint.WebSocket for transport.**
Low-level, process-less HTTP/WebSocket client. Fits perfectly: we need raw frame
access to layer Noise encryption on top. Mint returns data to the owning process
via `Mint.WebSocket.stream/2`.

**WebSocket frames are Noise-encrypted after handshake.**
Pre-handshake: raw binary WebSocket frames carry Noise handshake messages.
Post-handshake: every frame is Noise-encrypted before sending, Noise-decrypted
after receiving, then decoded as WABinary nodes.

**Do not cargo-cult ACK behavior.**
Baileys v7 explicitly warns that sending successful delivery ACKs the way older
community snippets did can get clients banned. The Elixir port must mirror the
current Baileys/WhatsApp Web ack/nack behavior exactly, not apply a blanket
"ack every inbound node" rule.

**Versioning must stay current.**
Baileys v7 added `fetchWAWebVersion` and Meta coexistence support. The
connection layer should not hardcode a stale WA Web version string forever; the
config/runtime story must allow current version selection and coexistence-aware
behavior.

**Frame format:**
WhatsApp frames have a 3-byte length prefix (big-endian) followed by the payload.
Pre-noise: payload is raw. Post-noise: payload is Noise-encrypted.

**Build the connection layer in slices, not one jump.**
The first accepted slice established config defaults, frame encoding/decoding, and
the socket's state contract with an injected transport seam. The second slice adds
the real Mint transport and the real Noise handshake up to `:authenticating`
without prematurely pulling in Phase 7 auth validation or the later supervisor/store work.

---

## Tasks

### 6.1 Connection config

File: `lib/baileys_ex/connection/config.ex`

```elixir
defmodule BaileysEx.Connection.Config do
  @type t :: %__MODULE__{
    ws_url: String.t(),
    keep_alive_interval_ms: pos_integer(),
    retry_delay_ms: pos_integer(),
    max_retries: non_neg_integer(),
    connect_timeout_ms: pos_integer(),
    browser: {String.t(), String.t(), String.t()},
    print_qr_in_terminal: boolean()
  }

  defstruct [
    ws_url: "wss://web.whatsapp.com/ws/chat",
    keep_alive_interval_ms: 25_000,
    retry_delay_ms: 2_000,
    max_retries: 5,
    connect_timeout_ms: 20_000,
    browser: {"BaileysEx", "Chrome", "0.1.0"},
    print_qr_in_terminal: false
  ]

  def new(opts \\ []), do: struct(__MODULE__, opts)

  # Web version selection should remain configurable so later phases can track
  # Baileys' fetchWAWebVersion/coexistence behavior instead of freezing a stale
  # browser tuple in code.

  # --- Browser/Platform Identification (GAP-27) ---

  @doc "Platform type mapping for device registration"
  @platforms %{
    "Chrome" => :CHROME,
    "Firefox" => :FIREFOX,
    "Safari" => :SAFARI,
    "Edge" => :EDGE,
    "Opera" => :OPERA,
    "Desktop" => :DESKTOP,
    "Mac OS" => :DARWIN,
    "Windows" => :WIN32,
    "Linux" => :LINUX
  }

  def platform_type(browser_name) do
    Map.get(@platforms, browser_name, :UNKNOWN)
  end
end
```

### 6.2 Connection socket (:gen_statem)

Files:
- `lib/baileys_ex/connection/socket.ex`
- `lib/baileys_ex/connection/transport.ex`
- `lib/baileys_ex/connection/transport/mint_web_socket.ex`
- `lib/baileys_ex/connection/transport/mint_adapter.ex`

States:
```
:disconnected → :connecting → :noise_handshake → :authenticating → :connected
                                                                      ↓
                                                               :reconnecting
                                                                      ↓
                                                               :connecting (loop)
```

```elixir
defmodule BaileysEx.Connection.Socket do
  @behaviour :gen_statem

  defstruct [
    :config,
    :auth_state,     # Auth credentials
    :transport_module,
    :transport_options,
    :transport_state,
    :buffer,         # Incomplete frame buffer
    :last_error,
    retry_count: 0,
    epoch: 0
  ]

  # --- Lifecycle ---

  def start_link(opts) do
    :gen_statem.start_link(__MODULE__, opts, [])
  end

  @impl true
  def init(opts) do
    {transport_module, transport_options} = Keyword.get(opts, :transport, {Transport.Noop, %{}})

    data = %__MODULE__{
      config: Keyword.get(opts, :config, Config.new()),
      auth_state: Keyword.get(opts, :auth_state),
      transport_module: transport_module,
      transport_options: transport_options
    }

    {:ok, :disconnected, data}
  end

  def callback_mode, do: [:state_functions, :state_enter]

  # --- State: disconnected ---

  def disconnected(:enter, _old_state, data) do
    # Notify event emitter
    {:keep_state, data}
  end

  def disconnected(:internal, :connect, data) do
    case data.transport_module.connect(data.config, data.transport_options) do
      {:ok, transport_state} ->
        {:next_state, :noise_handshake, %{data | transport_state: transport_state, last_error: nil}}
      {:error, reason} ->
        {:next_state, :disconnected,
         %{data | transport_state: nil, retry_count: data.retry_count + 1, last_error: reason}}
    end
  end

  # --- State: noise_handshake ---

  def noise_handshake(:enter, _, data) do
    {:keep_state, data}
  end

  def noise_handshake(:internal, :start_handshake, data) do
    {:ok, noise_state} =
      BaileysEx.Protocol.Noise.new(
        routing_info: data.auth_state.creds.routing_info
      )

    {:ok, {noise_state, message}} = BaileysEx.Protocol.Noise.client_hello(noise_state)
    :ok = send_raw_frame(data, message)
    {:keep_state, %{data | noise_state: noise_state}}
  end

  def noise_handshake(:info, {tag, _ref, responses}, data) when tag in [:tcp, :ssl] do
    # Process Mint responses, extract WebSocket frames
    # Feed to Noise handshake steps
    # On completion: transition to :authenticating
  end

  # --- State: connected ---

  def connected(:enter, _, data) do
    # Start keep-alive timer
    actions = [{{:timeout, :keep_alive}, data.config.keep_alive_interval, :ping}]
    {:keep_state, data, actions}
  end

  def connected({:timeout, :keep_alive}, :ping, data) do
    send_keep_alive(data)
    actions = [{{:timeout, :keep_alive}, data.config.keep_alive_interval, :ping}]
    {:keep_state, data, actions}
  end

  # --- Sending ---

  def send_node(pid, %BinaryNode{} = node) do
    :gen_statem.call(pid, {:send_node, node})
  end

  def connected({:call, from}, {:send_node, node}, data) do
    binary = BinaryNode.encode(node)
    {:ok, {noise_state, encrypted}} = Protocol.Noise.encode_frame(data.noise_state, binary)
    :ok = send_frame(data, encrypted)
    {:keep_state, %{data | noise_state: noise_state}, [{:reply, from, :ok}]}
  end

  # --- ACK policy (GAP-03 / v7 parity) ---
  # Do not implement blanket automatic success ACKs here.
  # ACK/NACK behavior must be decided by the receive pipeline using the same
  # per-node rules Baileys v7 applies. Incorrect positive ACKing is a ban risk.

  defp send_ack(data, %BinaryNode{tag: tag, attrs: attrs} = node) do
    ack_attrs = %{
      "id" => attrs["id"],
      "to" => attrs["from"],
      "class" => tag
    }
    |> maybe_put("participant", attrs["participant"])
    |> maybe_put("recipient", attrs["recipient"])

    ack_node = %BinaryNode{tag: "ack", attrs: ack_attrs}
    send_node_internal(data, ack_node)
  end

  # --- Logout (GAP-18) ---

  @doc "Logout: removes device registration from server, then disconnects"
  def logout(pid) do
    :gen_statem.call(pid, :logout)
  end

  def connected({:call, from}, :logout, data) do
    node = %BinaryNode{
      tag: "iq",
      attrs: %{
        "to" => "s.whatsapp.net",
        "type" => "set",
        "xmlns" => "md"
      },
      content: [
        %BinaryNode{
          tag: "remove-companion-device",
          attrs: %{"jid" => JID.to_string(data.auth_state.me), "reason" => "user_initiated"}
        }
      ]
    }
    send_node_internal(data, node)
    {:next_state, :disconnected, data, [{:reply, from, :ok}]}
  end

  # --- Dirty Bit Handling (GAP-24) ---
  # Server sends CB:ib,,dirty notifications to trigger state refresh.
  # Types: "account_sync", "groups", "communities"

  defp handle_dirty_notification(%BinaryNode{} = node, conn) do
    dirty = BinaryNode.child(node, "dirty")
    dirty_type = dirty.attrs["type"]
    timestamp = dirty.attrs["timestamp"]

    case dirty_type do
      "account_sync" ->
        if last_sync = Store.get_cred(conn, :last_account_sync_timestamp) do
          clean_dirty_bits(conn, "account_sync", last_sync)
        end

        if timestamp do
          Store.update_creds(conn, %{last_account_sync_timestamp: String.to_integer(timestamp)})
        end

      "groups" ->
        dispatch_dirty_refresh(conn, :groups)
        clean_dirty_bits(conn, "groups")

      "communities" ->
        dispatch_dirty_refresh(conn, :communities)
        # WhatsApp reuses the "groups" dirty bucket when acknowledging community refresh.
        clean_dirty_bits(conn, "groups")

      _ -> :ok
    end
  end

  defp clean_dirty_bits(conn, type, from_timestamp \\ nil) do
    clean_attrs =
      %{"type" => type}
      |> maybe_put("timestamp", from_timestamp && to_string(from_timestamp))

    node = %BinaryNode{
      tag: "iq",
      attrs: %{"to" => "s.whatsapp.net", "type" => "set", "xmlns" => "urn:xmpp:whatsapp:dirty"},
      content: [%BinaryNode{tag: "clean", attrs: clean_attrs}]
    }
    send_node_internal(conn, node)
  end

  defp dispatch_dirty_refresh(conn, type) do
    # Hand off to the higher-level feature layer that owns the relevant refetch:
    # :groups -> Phase 10 group metadata refresh
    # :communities -> Phase 11 community participating refresh
  end

  # --- Unified Session (GAP-33) ---
  # Session deduplication across reconnects within a 7-day window.
  # Called on connection open and when presence changes to :available.

  defp send_unified_session(data) do
    # Session ID = (now_ms + 3_days_ms) rem 7_days_ms using server time offset
    server_offset = data.server_time_offset || 0
    now = System.os_time(:millisecond) + server_offset
    three_days = 3 * 24 * 60 * 60 * 1000
    seven_days = 7 * 24 * 60 * 60 * 1000
    session_id = rem(now + three_days, seven_days)

    node = %BinaryNode{
      tag: "ib",
      attrs: %{},
      content: [
        %BinaryNode{tag: "unified_session", attrs: %{"id" => to_string(session_id)}}
      ]
    }
    send_node_internal(data, node)
  end

  # --- Init Queries (GAP-34) ---
  # On connection open, fetch server props, blocklist, and privacy settings
  # in parallel. Props include server-side feature flags cached via lastPropHash.

  defp execute_init_queries(conn) do
    Task.Supervisor.async_nolink(task_supervisor(conn), fn ->
      tasks = [
        Task.async(fn -> Feature.Privacy.fetch_settings(conn, true) end),
        Task.async(fn -> Feature.Privacy.fetch_blocklist(conn) end),
        Task.async(fn -> fetch_server_props(conn) end)
      ]
      Task.await_many(tasks, 15_000)
    end)
  end

  defp fetch_server_props(conn) do
    # IQ: xmlns='w', type='get', content: <props protocol='2' hash='lastPropHash'/>
    # Response contains server feature flags under <prop/> children.
    # When the server returns a new hash, persist it to creds and emit :creds_update.
  end

  # --- WAM Analytics (GAP-31) ---
  # WhatsApp Analytics/Metrics. Server may expect periodic analytics pings.
  # Baileys sends via xmlns='w:stats' with 'add' tag and Unix timestamp.

  defp send_wam_buffer(data, wam_buffer) do
    node = %BinaryNode{
      tag: "iq",
      attrs: %{
        "to" => "s.whatsapp.net",
        "type" => "set",
        "xmlns" => "w:stats"
      },
      content: [
        %BinaryNode{
          tag: "add",
          attrs: %{"t" => to_string(System.os_time(:second))},
          content: wam_buffer
        }
      ]
    }
    send_node_internal(data, node)
  end
end
```

### 6.2a Initial sync choreography (GAP-05, GAP-34, GAP-48)

Connection-open behavior must follow the Baileys `chats.ts` sync choreography,
not just "connect then flush events":

- On `connection.update(received_pending_notifications: true)`, transition
  `:connecting -> :awaiting_initial_sync` and enable event buffering.
- If history sync is disabled by config, transition directly to `:online` and
  flush on the next turn of the mailbox.
- If history sync is enabled, start a 20-second timeout. The first processable
  history-sync message transitions the connection to `:syncing`.
- While `:syncing`, run app-state resync before flushing buffered events. If an
  `app_state_sync_key_share` arrives during this phase, resume the pending app
  state sync immediately.
- When app-state sync completes, transition to `:online`, flush buffered events,
  and increment `account_sync_counter` in stored creds.

On the BEAM, keep this as part of the socket state machine plus the event buffer;
do not spawn detached ad-hoc tasks for the transition logic itself.

### 6.2a Current accepted runtime boundary

The current accepted connection runtime stops at the boundary where the socket has:

- opened the real Mint-backed WebSocket transport
- initialized `Protocol.Noise`
- sent client hello
- processed server hello
- sent client finish
- transitioned to `:authenticating`

This is intentionally short of a full "open" connection, because Phase 7 still owns
registration/login payload generation and the post-handshake auth response flow.
The temporary seam is an injected already-encoded client payload binary used only to
exercise the real transport + Noise choreography before auth is implemented.

### 6.3 Frame handling

File: `lib/baileys_ex/connection/frame.ex`

The pure frame codec is accepted separately from the socket runtime so length-prefix
handling can be tested without a transport process:

```elixir
defmodule BaileysEx.Connection.Frame do
  @max_payload_size 16_777_215

  def encode(payload) when is_binary(payload) do
    payload_size = byte_size(payload)

    if payload_size <= @max_payload_size do
      {:ok, <<payload_size::unsigned-big-integer-size(24), payload::binary>>}
    else
      {:error, :frame_too_large}
    end
  end

  def decode_stream(buffer) when is_binary(buffer), do: decode_stream(buffer, [])

  defp decode_stream(<<payload_size::unsigned-big-integer-size(24), rest::binary>>, frames)
       when byte_size(rest) >= payload_size do
    <<payload::binary-size(payload_size), tail::binary>> = rest
    decode_stream(tail, [payload | frames])
  end

  defp decode_stream(buffer, frames), do: {Enum.reverse(frames), buffer}
end
```

### 6.4 Per-connection supervisor

File: `lib/baileys_ex/connection/supervisor.ex`

```elixir
defmodule BaileysEx.Connection.Supervisor do
  use Supervisor

  def start_link(opts) do
    name = {:via, Registry, {BaileysEx.Registry, opts[:name] || make_ref()}}
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    children = [
      {BaileysEx.Connection.Socket, opts},
      {BaileysEx.Connection.Store, opts},
      {BaileysEx.Connection.EventEmitter, opts},
      {Task.Supervisor, name: task_sup_name(opts)}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
```

### 6.5 Event emitter (GAP-07, GAP-22)

File: `lib/baileys_ex/connection/event_emitter.ex`

```elixir
defmodule BaileysEx.Connection.EventEmitter do
  use GenServer

  @moduledoc """
  Event dispatch with buffering support. Buffers events during offline
  message processing to ensure consistent ordering.
  """

  # --- Full Event Type Catalog ---
  # All event types that can be emitted:

  @event_types [
    # Connection
    :connection_update,          # %{connection: :open | :close | :connecting, qr: str, is_online: bool, ...}
    :creds_update,               # Auth credential changes (MUST persist immediately)

    # Messages
    :messaging_history_set,      # %{chats, contacts, messages, sync_type, progress, is_latest, peer_data_request_session_id}
    :messages_upsert,            # %{messages: [msg], type: :notify | :append}
    :messages_update,            # [%{key: key, update: changes}]
    :messages_delete,            # %{keys: [key]} or %{jid: jid, all: true}
    :messages_reaction,          # [%{key: target_key, reaction: reaction_msg}]
    :messages_media_update,      # [%{key: key, media: media_data}]
    :message_receipt_update,     # [%{key: key, receipt: %{user_jid: jid, read_timestamp: ts}}]

    # Contacts
    :contacts_upsert,            # [%{id: jid, ...}]
    :contacts_update,            # [%{id: jid, img_url: :changed | :removed, ...}]
    :lid_mapping_update,         # %{lid: jid, pn: jid}

    # Chats
    :chats_upsert,               # [%{id: jid, ...}]
    :chats_update,               # [%{id: jid, ...changes}]
    :chats_delete,               # [jid]
    :chats_lock,                 # %{id: jid, locked: boolean}

    # Groups
    :groups_upsert,              # [GroupMetadata]
    :groups_update,              # [%{id: jid, ...changes}]
    :group_participants_update,  # %{id: jid, author: jid, participants: [...], action: atom}
    :group_join_request,         # %{id: jid, author: jid, participant: jid, participant_pn: jid, action: atom, method: atom}
    :group_member_tag_update,    # %{group_id: jid, participant: jid, label: binary, message_timestamp: integer}

    # Presence
    :presence_update,            # %{id: jid, presences: %{participant_jid => presence_data}}

    # Privacy
    :blocklist_update,           # %{blocklist: [jid], type: :add | :remove}
    :settings_update,            # %{setting: atom, value: term}

    # Labels
    :labels_edit,                # label changes
    :labels_association,         # label ↔ chat/message associations

    # Calls
    :call,                       # [WACallEvent]

    # Newsletter
    :newsletter_settings_update, # %{id: jid, update: changes}
    :newsletter_participants_update, # %{id: jid, author: jid, ...}
    :newsletter_reaction,        # %{id: jid, server_id: id, reaction: %{code: emoji, count: n}}
    :newsletter_view             # %{id: jid, server_id: id, count: n}
  ]

  # --- Buffering ---
  # 12 bufferable event types (same intent as Baileys BUFFERABLE_EVENT)
  @bufferable_events [
    :messaging_history_set,
    :chats_upsert, :chats_update, :chats_delete,
    :contacts_upsert, :contacts_update,
    :messages_upsert, :messages_update, :messages_delete, :messages_reaction,
    :message_receipt_update,
    :groups_update
  ]

  @buffer_timeout_ms 30_000  # Auto-flush after 30 seconds

  # Subscribers are stored as MapSet of {pid, event_filter}
  # Events dispatched via send/2 to subscriber pids
  #
  # Buffer mode: during offline sync, events are accumulated and flushed
  # together for consistent ordering. Auto-flush timer prevents stuck buffers.

  def buffer(pid), do: GenServer.call(pid, :start_buffer)
  def flush(pid), do: GenServer.call(pid, :flush_buffer)
  def buffering?(pid), do: GenServer.call(pid, :is_buffering)

  # --- Conditional Chat Updates (GAP-48) ---
  # Chat updates from sync patches (mute/archive) include a condition that
  # checks whether relevant message ranges have been populated by history sync.
  # During AwaitingInitialSync, these updates are held as "conditional" and
  # only applied when the condition evaluates to true after history populates.

  @doc "Emit a conditional event that is evaluated on flush"
  def emit_conditional(pid, event_type, data, condition_fn) do
    GenServer.cast(pid, {:emit_conditional, event_type, data, condition_fn})
  end

  # Internal: when flushing, evaluate each conditional event's condition_fn.
  # If condition returns true, include in flush batch. Otherwise discard.
  # This prevents chat mute/archive patches from being applied before
  # their target messages exist in the store.

  # Sync state machine:
  # :connecting → :awaiting_initial_sync → :syncing → :online
  # Buffer starts at :awaiting_initial_sync, flushes at :online transition.
  # 20-second timeout forces :online if no history sync message arrives.
end
```

### 6.6 Store (GenServer + ETS)

File: `lib/baileys_ex/connection/store.ex`

```elixir
defmodule BaileysEx.Connection.Store do
  use GenServer

  # ETS table for concurrent reads
  # GenServer serializes writes
  # Stores: auth credentials, signal context ref, connection metadata
  # Persistence behaviour callback on write
end
```

### 6.7 Tests

- `:gen_statem` state transitions (mock WebSocket)
- Frame reassembly (split frames, concatenated frames)
- Keep-alive timer fires correctly
- Reconnection after disconnect
- Supervisor restart behavior
- Event emitter subscribe/dispatch
- Store read/write with ETS

---

## Acceptance Criteria

- [ ] Connection state machine transitions correctly through all states
- [x] Noise handshake integrates with WebSocket transport up to `:authenticating`
- [ ] Frame encoding/decoding with length prefix works
- [ ] Keep-alive prevents timeout disconnection
- [ ] Reconnection works after unexpected disconnect
- [ ] Supervisor :rest_for_one restarts children correctly
- [ ] Event emitter dispatches to subscribers
- [ ] Store reads are concurrent via ETS
- [ ] ACK/NACK behavior matches current Baileys/WhatsApp Web parity rules and does not blanket-send successful ACKs (GAP-03)
- [ ] Logout sends `remove-companion-device` and disconnects (GAP-18)
- [ ] EventEmitter supports all 25+ event types (GAP-07)
- [ ] Event buffering accumulates events and flushes on demand (GAP-22)
- [ ] Buffer auto-flushes after 30 seconds (GAP-22)
- [ ] Dirty bit notifications trigger appropriate refresh (GAP-24)
- [ ] Platform type correctly mapped for device registration (GAP-27)
- [ ] Unified session sent on connection open and presence available (GAP-33)
- [ ] Init queries (props, blocklist, privacy) fetched in parallel on connection open (GAP-34)
- [ ] Conditional chat updates held during sync, evaluated on flush (GAP-48)
- [ ] Sync state machine: connecting → awaiting_initial_sync → syncing → online (GAP-48)

## Files Created/Modified

- `lib/baileys_ex/connection/config.ex` — accepted in the current slice; includes browser/platform identification (GAP-27)
- `lib/baileys_ex/connection/frame.ex` — accepted in the current slice; pure 3-byte frame codec
- `lib/baileys_ex/connection/transport.ex` — accepted in the current slice; evented transport seam for the socket runtime
- `lib/baileys_ex/connection/transport/mint_adapter.ex` — accepted in the current slice; narrow Mint adapter for deterministic tests
- `lib/baileys_ex/connection/transport/mint_web_socket.ex` — accepted in the current slice; real Mint-backed WebSocket transport
- `lib/baileys_ex/connection/socket.ex` — prototype state machine now covers real transport-open + Noise handshake to `:authenticating`
- `lib/baileys_ex/connection/supervisor.ex`
- `lib/baileys_ex/connection/event_emitter.ex` — full event catalog (GAP-07), buffering support with auto-flush (GAP-22)
- `lib/baileys_ex/connection/store.ex`
- `test/baileys_ex/connection/config_test.exs`
- `test/baileys_ex/connection/frame_test.exs`
- `test/baileys_ex/connection/socket_test.exs`
- `test/baileys_ex/connection/transport/mint_web_socket_test.exs`
- `test_helpers/connection/noise_server.exs`
- `test/baileys_ex/connection/event_emitter_test.exs`
- `test/baileys_ex/connection/store_test.exs`
