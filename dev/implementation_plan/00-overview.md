# BaileysEx — Architecture Overview

## Vision

**Behaviour-accurate Elixir port of Baileys 7.00rc9** (WhatsApp Web API). The goal is a
**drop-in replacement** for Elixir apps currently using Baileys (Node.js) as a sidecar.
Same wire behaviour, same protocol semantics, idiomatic Elixir implementation.

Baileys 7.00rc9 (`dev/reference/Baileys-master/`) is the authoritative reference for
all wire behaviour, protocol semantics, message formats, handshake flows, and feature
scope. The *what* comes from Baileys; the *how* is SOTA Elixir.

The current architectural direction is to keep connection management, state machines,
concurrency, and business logic in Elixir, while exposing battle-tested native crypto
or narrowly-scoped Signal helpers only where they are actually required. The
WhatsApp-specific Noise handler mirrors the Baileys reference in Elixir rather than
delegating the whole handshake to a generic raw XX engine.

**Baileys source inventory:** ~90 files, ~570+ functions, ~300+ types across 8
directories (Socket, Signal, Utils, Types, WABinary, WAProto, WAUSync, WAM, Defaults).
WAM (WhatsApp Analytics/Metrics) is optional — see Phase 12.7.

## Core Principles

1. **Native first, Rust NIF only when necessary** — Use Erlang `:crypto` (OTP 28) and
   pure Elixir for generic crypto, framing, and orchestration. Use Rust NIFs only for
   protocol pieces or curve conversions that are not safely or efficiently available
   from OTP. The higher-level Noise choreography stays in Elixir so it can match
   `dev/reference/Baileys-master/src/Utils/noise-handler.ts`, and the Phase 5 Signal
   boundary should stay adapter-driven until a broader native surface is proven needed.
2. **No process without a runtime reason** — Modules organize code; processes manage
   runtime state, concurrency, or fault isolation.
3. **GenServer is a bottleneck by design** — Use ETS for concurrent reads, GenServer
   only for serialized writes. Avoid single-process throughput bottlenecks.
4. **`:gen_statem` for explicit state machines** — Connection lifecycle has clear states;
   use `:gen_statem` directly rather than overloading GenServer.
5. **Functions over processes for feature layers** — Groups, chats, presence, etc. are
   stateless function modules that construct binary nodes and send through the socket.
   They don't need their own processes.
6. **Behaviours for extensibility** — Credential persistence, event handling, and store
   backends use behaviours so users can swap implementations.
7. **Runtime Signal store boundary** — Phase 5's Signal store is a process-backed
   runtime contract (`get/set/transaction`) with ETS-backed reads. Phase 7 owns
   durable persistence implementations that satisfy that contract.

## Supervision Tree

```
BaileysEx.Application (Supervisor)
├── Registry (BaileysEx.Registry — named connections)
├── DynamicSupervisor (BaileysEx.ConnectionSupervisor)
│   └── Per-connection Supervisor (:rest_for_one)
│       ├── BaileysEx.Connection.Socket     (:gen_statem)
│       │   - Owns WebSocket + Noise transport state
│       │   - States: disconnected → connecting → noise_handshake → authenticating → connected
│       │   - Mirrors Baileys `makeSocket`: query/send runtime, keep-alive, logout,
│       │     unified_session, and transport-level offline/routing callbacks
│       ├── BaileysEx.Connection.Store       (GenServer + ETS)
│       │   - Signal session state, auth credentials
│       │   - ETS :read_concurrency for lookups
│       │   - GenServer serializes writes + persistence
│       ├── BaileysEx.Connection.EventEmitter (GenServer)
│       │   - Subscriber registry, batched event dispatch, buffer/flush/process API
│       │   - Internal tap path for runtime coordination without breaking buffered app delivery
│       │   - Mirrors Baileys `makeEventBuffer` semantics during offline processing
│       └── Task.Supervisor (BaileysEx.Connection.TaskSupervisor)
│           - Concurrent ops: device discovery, media upload/download
│           - async_nolink for fault isolation
└── Task.Supervisor (BaileysEx.TaskSupervisor — global one-off tasks)
```

### Why :rest_for_one

Child ordering matters:
1. **Socket** — if it crashes, Store and EventEmitter restart (stale state)
2. **Store** — if it crashes, EventEmitter restarts (may have stale refs)
3. **EventEmitter** — if it crashes, only it restarts
4. **TaskSupervisor** — independent, but ordered last

Reconnect policy belongs to the per-connection runtime wrapper around the socket,
not to invented raw-socket semantics. Baileys rc.9 recreates the socket in
consumer code based on `connection.update(connection: 'close')`; the Elixir port
may internalize that in supervision, but the socket contract must still match the
reference behavior first.

## Module Architecture

### Layer 1a: Native Crypto (Erlang `:crypto` — NO Rust NIF needed)

All cryptographic primitives use Erlang's built-in `:crypto` module (OTP 28):

```
lib/baileys_ex/crypto.ex    # Thin wrappers around :crypto
```

| Operation | `:crypto` function | OTP version |
|-----------|-------------------|-------------|
| AES-256-GCM | `crypto_one_time_aead/6,7` | 22+ |
| AES-256-CBC + PKCS7 | `crypto_one_time/5` with `pkcs_padding` | 22+ |
| AES-256-CTR | `crypto_one_time/4,5` | 22+ |
| HMAC-SHA256/512 | `mac(hmac, sha256\|sha512, key, data)` | 22+ |
| SHA-256, MD5 | `hash(sha256\|md5, data)` | ancient |
| HKDF | Custom impl using `:crypto.mac/4` (or `hkdf_erlang` hex) | — |
| PBKDF2-SHA256 | `pbkdf2_hmac/5` | 24.2+ |
| Curve25519 ECDH | `generate_key(ecdh, x25519)` + `compute_key/4` | 21+ |
| Ed25519 sign/verify | `sign(eddsa, none, msg, [key, ed25519])` | 22+ |
| Random bytes | `strong_rand_bytes/1` | ancient |

### Layer 1b: Rust NIFs (ONLY for crates with no Elixir equivalent)

```
lib/baileys_ex/native/
├── noise.ex      # Noise protocol — no Elixir/Erlang equivalent
└── xeddsa.ex     # Narrow XEdDSA helper used by Noise/Signal verification

native/baileys_nif/
├── Cargo.toml
└── src/
    ├── lib.rs       # Rustler setup
    ├── noise.rs     # snow crate wrapper
    └── xeddsa.rs    # narrow curve helper
```

**NIF state strategy:**
- Noise: `NoiseSession` ResourceArc with enum (Handshake | Transport) behind Mutex.
- Signal: start with Elixir repository/address/orchestration layers and keep any future
  native session/key boundary as small as possible.
- Signature helper: stateless XEdDSA functions for the verification primitive Phase 4
  and Phase 5 already need.
- **No generic crypto NIF** — AES/HMAC/HKDF/PBKDF2 stay in Erlang `:crypto` / Elixir.

### Layer 2: Wire Protocol (pure functions, no processes)

```
lib/baileys_ex/protocol/
├── binary_node.ex    # WABinary encode/decode (Elixir or Rust NIF)
├── jid.ex            # JID parsing: user@server, device IDs, LID/PN
├── constants.ex      # Protocol dictionaries, tags, token maps
└── proto/            # Generated protobuf modules (from .proto files)
```

### Layer 3: Connection (processes — runtime reasons: state + concurrency + fault isolation)

```
lib/baileys_ex/connection/
├── frame.ex          # Pure 3-byte length-prefixed frame codec
├── transport.ex      # Transport behaviour seam for the socket runtime
├── transport/
│   ├── mint_adapter.ex    # Narrow adapter over Mint for deterministic tests
│   └── mint_web_socket.ex # Real Mint-backed WebSocket transport
├── config.ex         # Connection configuration struct
├── supervisor.ex     # Per-connection :rest_for_one supervisor
├── socket.ex         # :gen_statem — WebSocket + Noise transport
├── store.ex          # GenServer + ETS — Signal sessions, credentials
└── event_emitter.ex  # GenServer — subscriber registry, event dispatch
```

### Layer 4: Feature Modules (plain functions, no processes)

```
lib/baileys_ex/
├── auth/
│   ├── state.ex          # Auth credentials struct
│   ├── pairing.ex        # Pair-success ADV verification/signing helper used by the socket
│   ├── qr.ex             # QR payload helper shared by socket pairing and Phase 7 auth flow
│   ├── phone.ex          # Phone number pairing flow
│   └── persistence.ex    # Behaviour for credential storage backends
├── signal/                # Phase 5 area — curve/address/repository first, deeper session logic later
│   ├── store.ex           # Store behaviour for signal state persistence
│   ├── identity.ex        # TOFU identity storage + invalidation semantics
│   ├── session_cipher.ex  # Elixir-side orchestration around native sessions
│   ├── session_builder.ex # Outgoing/incoming session orchestration
│   ├── prekey.ex          # Pre-key generation, upload, rotation
│   ├── key_helper.ex      # Convenience key generation utilities
│   ├── device.ex          # Multi-device discovery
│   └── group/             # Sender-key group state and crypto
│       ├── cipher.ex
│       ├── session_builder.ex
│       ├── sender_key_record.ex
│       └── sender_key_message.ex
├── message/
│   ├── builder.ex        # Construct WAProto messages from ALL types
│   ├── parser.ex         # Normalize/unwrap inbound messages, detect content type
│   ├── sender.ex         # Send pipeline: build → encrypt → encode → send
│   ├── receiver.ex       # Receive pipeline: decode → decrypt → parse → emit
│   ├── receipt.ex        # Delivery ACKs, read receipts, played receipts
│   └── retry.ex          # Retry logic for failed decryption
├── media/
│   ├── crypto.ex         # Media-specific encryption (HKDF expand, AES-CBC)
│   ├── upload.ex         # HTTP upload to WhatsApp CDN
│   ├── download.ex       # Streaming download + decryption
│   └── types.ex          # Media type structs (image, video, audio, doc, sticker)
├── feature/
│   ├── group.ex          # Group CRUD, participants, invites
│   ├── chat.ex           # Chat operations: archive, mute, pin, star, clear, delete
│   ├── presence.ex       # Online/offline/composing/recording status
│   ├── privacy.ex        # All 8 privacy categories + block list + disappearing mode
│   ├── profile.ex        # Profile picture, name, status text, business profile
│   ├── label.ex          # Label CRUD, chat/message label associations
│   ├── contact.ex        # Contact add/edit/remove (app state sync)
│   ├── quick_reply.ex    # Quick reply management
│   ├── business.ex       # Business profiles, catalogs
│   ├── newsletter.ex     # Newsletter subscriptions
│   ├── community.ex      # Community management
│   ├── call.ex           # Call offer/reject handling, call links
│   └── app_state.ex      # Syncd protocol, app state patches
└── util/
    ├── lt_hash.ex        # LTHash for app state verification
    └── event_buffer.ex   # Event buffering during offline processing
```

### Layer 5: Public API

```
lib/baileys_ex.ex   # Facade — connect/disconnect, send_message, subscribe, etc.
```

## Dependency Map

```
Phase 1: Foundation ──────────────────────────────────────────────
  mix.exs deps, project structure, type definitions

Phase 2: Crypto (pure Elixir/:crypto) ────────────────────────────
  Thin wrappers around Erlang :crypto + HKDF implementation
  Depends on: Phase 1

Phase 3: Protocol Layer ──────────────────────────────────────────
  WABinary, JID, USync, WMex, and the minimal protobuf boundary needed by
  the transport/auth layers
  Depends on: Phase 1
  (parallel with Phase 2)

Phase 4: Noise NIF ───────────────────────────────────────────────
  Rust NIF wrapping snow crate (no Elixir equivalent exists)
  Depends on: Phase 1 (NIF scaffold)

Phase 5: Signal Protocol (adapter-driven boundary) ──────────────
  Elixir Signal compatibility boundary: address translation, LID mapping,
  sender-key group crypto, identity handling, runtime store contract,
  and Baileys-generated cross-validation fixtures
  Depends on: Phase 1 (foundation), Phase 2 (Crypto)
  (parallel with Phase 4)

Phase 6: Connection ──────────────────────────────────────────────
  WebSocket + :gen_statem + Noise integration + supervision tree
  Depends on: Phase 3 (binary protocol), Phase 4 (Noise)

Phase 7: Authentication ──────────────────────────────────────────
  QR pairing, phone pairing, credential persistence
  Depends on: Phase 2 (Crypto), Phase 5 (Signal), Phase 6 (Connection)

Phase 8: Messaging Core ──────────────────────────────────────────
  Send/receive pipeline, Signal encryption integration, receipts
  Depends on: Phase 5 (Signal), Phase 6 (Connection), Phase 7 (Auth)

Phase 9: Media ───────────────────────────────────────────────────
  Media encrypt/decrypt, CDN upload/download, streaming
  Depends on: Phase 2 (Crypto), Phase 8 (Messaging)

Phase 10: Features ───────────────────────────────────────────────
  Groups, chats, presence, app state sync
  Depends on: Phase 8 (Messaging)
  (parallel with Phase 9)

Phase 11: Advanced Features ──────────────────────────────────────
  Business, newsletters, communities
  Depends on: Phase 10 (Features)

Phase 12: Polish ─────────────────────────────────────────────────
  Telemetry, docs, examples, hex publish
  Depends on: All phases

Phase 13: Internal Parity Validation ────────────────────────────
  Dev-only Baileys parity tooling: offline Node-vs-Elixir checks plus a
  manual live-validation harness for dedicated test accounts
  Depends on: Phase 12 (Polish)
```

## Parallelization Opportunities

```
              Phase 1 (Foundation)
           /       |          \
  Phase 2      Phase 3      Phase 4
  (Crypto)   (Protocol)   (Noise NIF)
      |          |           |
      +--- Phase 5 -------------------+
      |  (Signal: adapter-driven      |
      |   redesign)                   |
      |          |             |
       \         |            /
        Phase 6 (Connection)
              |
        Phase 7 (Auth)
              |
        Phase 8 (Messaging)
          /         \
    Phase 9        Phase 10
    (Media)        (Features)
       \         /
       Phase 11 (Advanced)
            |
       Phase 12 (Polish)
            |
  Phase 13 (Internal Parity)
```

Phases 2, 3, and 4 can run in parallel after Phase 1.
Phase 5 (Signal) depends on Phase 2 (Crypto) but is parallel with Phases 3 and 4.

## Public API Design (target ergonomics)

```elixir
# Start a connection
{:ok, conn} = BaileysEx.connect(auth_state, opts)

# Subscribe to events
BaileysEx.subscribe(conn, fn
  {:message, msg} -> handle_message(msg)
  {:group_update, update} -> handle_group(update)
  {:connection, :open} -> Logger.info("Connected!")
end)

# Send messages
BaileysEx.send_message(conn, "1234567890@s.whatsapp.net", %{text: "Hello!"})
BaileysEx.send_message(conn, jid, %{image: {:file, "/path/to/img.jpg"}, caption: "Check this out"})

# Group operations
BaileysEx.Group.create(conn, "My Group", [jid1, jid2])
BaileysEx.Group.update_subject(conn, group_jid, "New Name")

# Presence
BaileysEx.Presence.update(conn, :available)
BaileysEx.Presence.subscribe(conn, contact_jid)

# Disconnect
BaileysEx.disconnect(conn)
```

## Testing Strategy

- **NIF layer**: Property-based tests (StreamData) for encode/decode roundtrips,
  crypto operations against known test vectors.
- **Protocol layer**: Unit tests with captured binary data from Baileys test fixtures.
- **Connection layer**: Integration tests with mock WebSocket server.
- **Feature modules**: Unit tests constructing/parsing binary nodes.
- **Internal parity tooling**: dev-only Node-backed parity tests compare Elixir output
  against the pinned `dev/reference/Baileys-master/` implementation offline, plus a
  manual live-validation harness for dedicated WhatsApp test accounts.
- **End-to-end**: Optional integration test suite against WhatsApp sandbox (manual, not CI).
