# BaileysEx

**Behaviour-accurate Elixir port of [Baileys 7.00rc9](https://github.com/WhiskeySockets/Baileys)** —
a WhatsApp Web API library. The goal is a **drop-in replacement** for Elixir apps
currently using Baileys (Node.js) as a sidecar. Same wire behaviour, same protocol
semantics, idiomatic Elixir implementation. Targets Elixir 1.19+/OTP 28.

Rust NIFs are currently used for Noise protocol (`snow`) and the narrow XEdDSA
helper (`curve25519-dalek`). Signal protocol is pure Elixir.

Reference source: `dev/reference/Baileys-master/` (pinned at 7.00rc9)

### Baileys Is the Spec

**Do not deliberate about what to implement or how the protocol should behave.**
Baileys 7.00rc9 (`dev/reference/Baileys-master/`) is the authoritative reference for
all wire behaviour, protocol semantics, message formats, handshake flows, and feature
scope. When you are unsure what to do:

1. **Read the Baileys source.** Find the corresponding TypeScript file and understand
   what it does.
2. **Port the behaviour faithfully.** Match the observable behaviour — same messages
   on the wire, same protocol flows, same error handling semantics.
3. **Implement idiomatically in Elixir.** Use BEAM patterns (processes, supervisors,
   ETS, pattern matching) instead of JS patterns (callbacks, promises, mutexes). The
   *what* comes from Baileys; the *how* is SOTA Elixir.
4. **Do not invent new behaviour.** If Baileys doesn't do it, neither do we (yet).
   If Baileys does do it, we must too.

This means: no asking "should we support X?" — check Baileys. No asking "how should
this handshake work?" — read the Baileys handshake code. No designing from scratch
when a working reference exists 50 feet away in `dev/reference/`.

### Implementation Tracking

| Resource | Path | Purpose |
|----------|------|---------|
| Phase plans | `dev/implementation_plan/01-foundation.md` … `12-polish.md` | Detailed specs per phase |
| Overview | `dev/implementation_plan/00-overview.md` | Architecture, dependency graph |
| Agent rules | `dev/implementation_plan/CLAUDE.md` | Phase workflow, native-first policy |
| Progress | `dev/implementation_plan/PROGRESS.md` | Task/file/acceptance-criteria tracker |
| Reference source | `dev/reference/Baileys-master/` | Authoritative Baileys rc.9 behavior and wire semantics |

---

## Baileys Architecture Reference

### Source Structure (TypeScript original)

| Directory | Purpose |
|-----------|---------|
| `src/Socket/` | Layered socket composition — connection lifecycle, message send/recv, groups, chats, business, newsletters, communities |
| `src/Signal/` | Signal Protocol wrapper (`libsignal.ts`), LID-to-phone mapping, group sender keys |
| `src/Utils/` | 27 utility files — crypto, noise handler, media processing, auth, event buffering, mutexes, retry, LTHash, pre-key mgmt |
| `src/WABinary/` | Binary XMPP-style node encoding/decoding, JID utilities, protocol constants |
| `src/WAProto/` | Protocol Buffer definitions for all WhatsApp message types |
| `src/Types/` | TypeScript type definitions (auth, messages, events, groups) |
| `src/WAM/` | WhatsApp Analytics/Metrics |
| `src/WAUSync/` | User sync protocol |
| `src/Defaults/` | Default configuration values |

### Socket Composition Chain

Each layer wraps the previous and extends it:

1. `makeSocket` — base WebSocket lifecycle, Noise handshake, query/sendNode primitives
2. `makeNewsletterSocket` — newsletter subscriptions
3. `makeChatsSocket` — privacy settings, presence, app state sync
4. `makeMessagesSocket` — message relay, Signal encryption, device discovery
5. `makeMessagesRecvSocket` — message decryption, retry logic, receipt handling
6. `makeGroupsSocket` — group CRUD, participant management
7. `makeBusinessSocket` — business profiles, catalogs
8. `makeCommunitySocket` — community creation/linking

Final export `makeWASocket` returns the fully composed socket object.

### Protocols

**Noise Protocol (Transport Security)**
- Establishes encrypted transport over WebSocket before any application-level communication
- Curve25519 ECDH key exchange, AES-256-GCM frame encryption, HKDF key derivation, SHA-256 hashing
- Handshake: client ephemeral key → server ephemeral + encrypted static + encrypted cert → derive transport keys
- Post-handshake: separate read/write counters for IV generation; all frames Noise-encrypted
- Implementation: `src/Utils/noise-handler.ts`

**Signal Protocol (E2E Encryption)**
- Per-device message encryption (each recipient device gets separately encrypted copy)
- Two message types: pre-key whisper (session establishment) and standard whisper
- Group messaging via Sender Keys (one encryption op, distribution messages enable decryption)
- Session management: create/validate/store/delete sessions, detect identity key changes
- LID mapping: translates phone numbers ↔ logical device IDs for multi-device protocol
- Implementation: `src/Signal/libsignal.ts`, `src/Signal/lid-mapping.ts`

**Binary XMPP (Wire Format)**
- WhatsApp's proprietary compact binary encoding of XMPP-style nodes (tag, attributes, children/content)
- `encodeBinaryNode()` / `decodeBinaryNode()` for serialization
- JID utilities for Jabber ID format (user@server, device IDs, LID/PN variants)
- Implementation: `src/WABinary/`

**Protocol Buffers (Message Serialization)**
- `protobufjs` for all message content (text, media refs, reactions, polls, etc.)
- Structures content before Signal encryption
- Implementation: `src/WAProto/`

**App State Sync ("Syncd")**
- Versioned state snapshots with CRC verification and LTHash
- Syncs mute/pin/star/archive across devices via patches
- Implementation: `src/Utils/lt-hash.ts`, chats socket layer

### Key Features to Port

**Message Types:** text, images, video/GIF, audio/voice notes, documents, stickers,
contacts/vCards, location, live location, reactions, polls, events, lists, buttons,
orders, products, native flows, group invites, URL previews

**Message Pipeline:** `generateWAMessage()` → `prepareWAMessageMedia()` (media) →
`relayMessage()` → device discovery → per-device Signal encryption → binary encoding →
Noise-encrypted WebSocket write

**Message Receiving:** queue-based pipeline (online/offline paths), decryption within
mutex, auto-retry on pre-key errors, receipt handling (delivery ACKs, read receipts)

**Media Handling:**
- Streaming architecture (never loads entire buffer into memory)
- AES-256-CBC with random 32-byte media key, HKDF-expanded to 112 bytes (IV + cipher key + MAC key + ref key)
- Type-specific HKDF info strings (`"WhatsApp Image Keys"`, `"WhatsApp Audio Keys"`, etc.)
- Upload to WhatsApp CDN via authenticated HTTP; download with encrypted blob decryption
- HMAC-SHA256 authentication (10-byte truncated digest)

**Group Management:** create, update subject/description, leave, add/remove/promote/demote
participants, invite codes (v3/v4), join approval, ephemeral messages, announcement mode

**Other:** newsletter subscriptions, business profiles/catalogs, community management,
presence updates, privacy settings, call events, link previews

### Authentication & Pairing

**Auth State (`AuthenticationCreds`):** noise key pair, pairing ephemeral key pair, ADV
secret key, identity keys, signed pre-key, account/device identity, signal identities,
pre-key tracking, sync timestamps, platform info, pairing code, routing info

**Signal Key Store:** pre-keys, sessions, sender-keys, sender-key memory,
app-state-sync-keys/versions, LID mappings, device lists, identity keys, tokens

**QR Code Pairing:** server sends QR challenge → client renders → user scans with
WhatsApp mobile → multi-device identity established

**Phone Number Pairing:** `requestPairingCode(phoneNumber)` → returns numeric code →
user enters in WhatsApp mobile → PBKDF2 (131,072 iterations, SHA-256)

**Credential Persistence:** each credential type in separate files, signal sessions
update on every message (must persist immediately), in-memory caching layer,
atomic multi-key read/write with retry

### WebSocket / Connection Management

- Connects to `wss://web.whatsapp.com` with routing info as base64 query param
- Noise handshake on connect → derive encryption keys → send registration/login node
- Request/response: auto-generated message tags, timeout-based response matching
- Keep-alive: configurable ping interval, disconnect if elapsed > interval + 5s
- Connection states: `connecting` → `open` → `close` (auto-reconnect unless logged out)
- Event buffering: defers non-critical notifications until offline processing completes
- Pre-key upload: minimum interval, concurrent prevention, exponential backoff (3 retries)
- Concurrency: separate mutexes for messages, app state patches, receipts, notifications

### Native First, Rust NIF Only When Necessary

**Philosophy: use Elixir/Erlang ecosystem first.** Erlang `:crypto` (OTP 28) handles
all cryptographic primitives natively. Rust NIFs are reserved exclusively for complex
protocol crates that have no Elixir/Erlang equivalent.

**Erlang `:crypto` handles (NO Rust NIF):**
AES-256-GCM/CBC/CTR, HMAC-SHA256/512, SHA-256, MD5, PBKDF2, Curve25519 ECDH,
Ed25519 sign/verify, random bytes. HKDF implemented in pure Elixir using `:crypto.mac/4`.

**Rust NIFs (Rustler ~> 0.37) — only for crates with no native equivalent:**

| Rust Crate | Used For | Why NIF? |
|------------|----------|----------|
| `snow` | Noise Protocol Framework | No Elixir/Erlang implementation exists |
| `curve25519-dalek` | XEdDSA sign/verify (~80 lines Rust) | Montgomery↔Edwards key conversion — no native equivalent |

**Signal Protocol: Phase 5 implementation in progress**
The target is a Baileys-compatible Signal boundary in Elixir, with the smallest
native surface justified by correctness, interoperability, and measured cost.
Do not assume a broad Signal NIF and do not assume a full pure-Elixir ratchet
implementation until Phase 5 finalizes that boundary.

**What stays in Elixir:** connection management, event handling, state machines,
supervision trees, caching, business logic, message routing, all crypto primitives,
Signal protocol, binary encoding/decoding, protobuf (via `protox`) — everything that
benefits from BEAM concurrency, fault tolerance, or has native support.

### Key Dependencies (Baileys → Elixir/Rust mapping)

| Baileys Dep | Role | BaileysEx Approach |
|-------------|------|-------------------|
| `ws` | WebSocket transport | `Mint.WebSocket` (process-less, explicit encode/decode for Noise layer) |
| `libsignal` | Signal Protocol | Baileys-compatible Elixir boundary; narrow native helpers only where justified |
| `whatsapp-rust-bridge` | Crypto (HKDF, MD5) | **Erlang `:crypto`** (native — no NIF needed) |
| Noise handshake (custom) | Transport encryption | Rustler NIF wrapping `snow` crate |
| `protobufjs` | Protobuf serialization | `protox` (pure Elixir, good codegen) |
| `pino` | Structured logging | `Logger` (stdlib) |
| `async-mutex` | Concurrency | Process-based (BEAM handles this natively) |
| `@hapi/boom` | Error objects | Tagged tuples / custom exception structs |
| `lru-cache` / `node-cache` | Caching | ETS tables (built-in, concurrent, fast) |

---

## Agent Workflow — How to Work on This Project

These rules apply to all agents (main session, teammates, subagents). They reinforce
the detailed protocols in `dev/implementation_plan/CLAUDE.md` — that file is canonical.
This section adds behavioural expectations.

### Planning and Execution

- **Baileys is the spec.** When unsure what to build or how something should behave,
  read the Baileys source in `dev/reference/Baileys-master/`. Do not ask — look it up.
- **Plan before building.** Enter plan mode for any non-trivial task (3+ steps or
  architectural decisions). If execution diverges from the plan, stop and re-plan —
  don't push through a broken approach.
- **Native-first.** For every non-trivial decision, evaluate the best path available
  today — Elixir 1.19+/OTP 28 primitives, stdlib, battle-tested Hex packages — not
  last year's patterns. Rust NIFs only when no native equivalent exists. See
  `dev/implementation_plan/CLAUDE.md` § Native-First Decision Policy.
- **Elegance within scope.** For the requested change, find the cleanest implementation.
  "Knowing everything I know now, is there a more elegant way?" But do not expand scope —
  elegance means less code, not more features.

### Subagent and Teammate Strategy

- **Protect the main context window.** Offload research, exploration, code review, and
  parallel analysis to subagents (`Explore`, `Agent`, teammates). One focused task per
  subagent.
- **Use worktree isolation for parallel work.** When tasks have non-overlapping file
  scope and no decision coupling, dispatch `batch-worker` teammates in isolated
  worktrees. See `dev/implementation_plan/CLAUDE.md` § Task Dispatch Modes.
- **Throw compute at hard problems.** For complex debugging, multi-perspective review,
  or design exploration — use multiple subagents with competing hypotheses rather than
  serial iteration in a single context.

### Autonomous Execution

- **Bug reports: just fix them.** Diagnose from logs, errors, and failing tests. Resolve
  without asking for hand-holding. Zero context switching required from the user.
- **Failing CI: go fix it.** Don't wait to be told how. Read the failure, trace the root
  cause, implement the fix, verify it passes.
- **Root causes only.** No temporary fixes, no workarounds, no suppressing symptoms.
  Senior developer standards — find and fix the actual problem.

### Verification and Learning

- **Prove it works before claiming done.** Run all 11 delivery gates from
  `dev/implementation_plan/CLAUDE.md` § Delivery Gates. None are optional.
  Evidence before assertions.
- **After any user correction:** update auto-memory (`.claude/projects/.../memory/`)
  with the pattern so the same mistake never repeats. Review memory at session start.
- **Challenge your own work.** Before presenting: "Would this survive code review by
  someone who understands BEAM semantics?" If not, fix it first.
