# BaileysEx Implementation Progress

> Auto-tracked. Update checkboxes as tasks complete.
> Last updated: 2026-03-14
> Checkboxes indicate accepted completion against the phase file, delivery gates, and Baileys-reference parity.
> Prototype files may exist before a task or acceptance criterion is checked off.
> File status legend: `✅ accepted`, `🟡 prototype exists`, `⬜ not started`

---

## Phase Summary

| # | Phase | Tasks | Status | Depends On | Blocks |
|---|-------|-------|--------|------------|--------|
| 1 | Foundation | 7 | COMPLETE | — | All |
| 2 | Crypto | 3 | COMPLETE | 1 | 7, 9 |
| 3 | Protocol Layer | 10 | COMPLETE | 1 | 6 |
| 4 | Noise NIF | 6 | IN PROGRESS | 1 | 6 |
| 5 | Signal Protocol | 8 | COMPLETE | 1, 2 | 7, 8 |
| 6 | Connection | 7 | COMPLETE | 3, 4 | 7, 8 |
| 7 | Authentication | 10 | COMPLETE | 5, 6 | 8 |
| 8 | Messaging Core | 13 | COMPLETE | 5, 6, 7 | 9, 10 |
| 9 | Media | 9 | COMPLETE | 2, 8 | 12 |
| 10 | Features | 17 | IN PROGRESS | 8 | 11 |
| 11 | Advanced Features | 5 | NOT STARTED | 10 | 12 |
| 12 | Polish | 7 | NOT STARTED | All | — |

**Parallel-safe pairs:** 2+3+4 (after 1), 5 ∥ 3+4 (after 2), 9 ∥ 10 (after 8)

---

## Phase 1: Foundation

**Status:** COMPLETE · **Depends on:** — · **Blocks:** All

### Tasks

- [x] 1.1 Update mix.exs with dependencies
- [x] 1.2 Update application.ex
- [x] 1.3 Create Application supervisor
- [x] 1.4 Scaffold Rust NIF crate
- [x] 1.5 Create NIF module stubs
- [x] 1.6 Core type definitions
- [x] 1.7 Directory structure

### Acceptance Criteria

- [x] `mix deps.get` succeeds
- [x] `mix compile` succeeds (NIF stubs load with nif_error)
- [x] `mix test` passes (basic smoke test)
- [x] Rust crate compiles: `cd native/baileys_nif && cargo check`
- [x] Application starts: `iex -S mix` launches supervision tree
- [x] Registry, DynamicSupervisor, TaskSupervisor visible in observer

### Files

| File | Status |
|------|--------|
| `mix.exs` | ✅ |
| `lib/baileys_ex/application.ex` | ✅ |
| `lib/baileys_ex/types.ex` | ✅ |
| `lib/baileys_ex/native/noise.ex` | ✅ |
| `lib/baileys_ex/native/xeddsa.ex` | ✅ |
| `native/baileys_nif/` (Rust crate scaffold) | ✅ |

---

## Phase 2: Crypto (Pure Elixir / Erlang :crypto)

**Status:** COMPLETE · **Depends on:** Phase 1 · **Blocks:** 7, 9

> **Current snapshot:** `lib/baileys_ex/crypto.ex`, vector tests, and property tests are all implemented and green. Phase 2 stays pure Elixir/`:crypto`, matching the intended architecture; the remaining future media/auth work will build on this module rather than reopening the phase.

### Tasks

- [x] 2.1 Core crypto module (wrappers around `:crypto`)
- [x] 2.2 Test with known test vectors (NIST/RFC)
- [x] 2.3 Property-based tests (StreamData)

### Acceptance Criteria

- [x] All crypto functions work with Erlang `:crypto` (no NIF dependency)
- [x] NIST/RFC test vectors pass for every algorithm
- [x] HKDF implementation matches RFC 5869 test vectors
- [x] Property-based roundtrip tests pass
- [x] Typespecs on all public functions
- [x] `mix test test/baileys_ex/crypto_test.exs` passes
- [x] Media key expansion mirrors Baileys' HKDF info-string mapping for the same input

### Files

| File | Status |
|------|--------|
| `lib/baileys_ex/crypto.ex` | ✅ |
| `test/baileys_ex/crypto_test.exs` | ✅ |
| `test/baileys_ex/crypto_property_test.exs` | ✅ |

---

## Phase 3: Protocol Layer

**Status:** COMPLETE · **Depends on:** Phase 1 · **Blocks:** 6

> **Current snapshot:** `BinaryNode`, `Constants`, `JID`, Baileys-style `BinaryNode` helpers, `USync`, `WMex`, `MessageStubType`, and the minimal transport/auth protobuf boundary are all implemented with focused tests. The current BinaryNode implementation preserves Baileys' string-vs-bytes distinction by requiring raw bytes to be wrapped explicitly as `{:binary, bytes}`. Broad `WAProto` message/auth code generation is deferred to the later phases that consume it.

### Tasks

- [x] 3.1 WABinary Node Types
- [x] 3.2 WABinary Constants / Dictionaries
- [x] 3.3 WABinary Encoder
- [x] 3.4 WABinary Decoder
- [x] 3.5 JID Module
- [x] 3.6 USync Query Infrastructure
- [x] 3.6a Message Stub Type Constants (GAP-28)
- [x] 3.6b WMex Query Engine (GAP-43)
- [x] 3.7 Minimal Protobuf Boundary
- [x] 3.8 Tests

### Acceptance Criteria

- [x] BinaryNode encode/decode roundtrip works for covered node types
- [x] JID parse/to_string covers core WhatsApp JID formats
- [x] JID handles LID (`@lid`) and PN (`@s.whatsapp.net`) addressing
- [x] USync query builder constructs correct nodes for all 5 supported protocol types
- [x] USync response parser extracts user results correctly
- [x] Minimal transport/auth protobuf modules compile and roundtrip
- [x] Message stub types define the current 20 group notification mappings
- [x] WMex query engine constructs correct IQ nodes with JSON variables
- [x] WMex response parser extracts data by XWA path

### Files

| File | Status |
|------|--------|
| `lib/baileys_ex/protocol/binary_node.ex` | ✅ |
| `lib/baileys_ex/protocol/constants.ex` | 🟡 |
| `lib/baileys_ex/protocol/jid.ex` | ✅ |
| `lib/baileys_ex/protocol/usync.ex` | ✅ |
| `lib/baileys_ex/protocol/wmex.ex` | ✅ |
| `lib/baileys_ex/protocol/message_stub_type.ex` | ✅ |
| `lib/baileys_ex/protocol/proto/noise_messages.ex` | ✅ |
| `priv/proto/*.proto` | 🟡 |
| `test/baileys_ex/protocol/binary_node_test.exs` | ✅ |
| `test/baileys_ex/protocol/jid_test.exs` | ✅ |
| `test/baileys_ex/protocol/usync_test.exs` | ✅ |
| `test/baileys_ex/protocol/wmex_test.exs` | ✅ |
| `test/baileys_ex/protocol/proto_test.exs` | ✅ |

---

## Phase 4: Noise Protocol NIF

**Status:** IN PROGRESS · **Depends on:** Phase 1 · **Blocks:** 6

> **Current snapshot:** the repo now has a reference-aligned `Protocol.Noise` implementation that mirrors `dev/reference/Baileys-master/src/Utils/noise-handler.ts`: protobuf handshake messages, certificate validation, handshake hash/key mixing, and transport framing/counters all live at the protocol layer. The low-level `noise.rs` / `Native.Noise` boundary remains available as a raw `snow` wrapper, but it is no longer the intended WhatsApp handshake surface.

### Tasks

- [x] 4.1 Implement noise.rs (Rust — raw `snow` wrapper)
- [x] 4.2 Elixir Noise wrapper (NIF bindings)
- [x] 4.3 Higher-level Noise protocol module
- [x] 4.3a Certificate Validation (GAP-21)
- [x] 4.4 Tests
- [ ] 4.5 Native Resource Hardening / Leak Verification

### Acceptance Criteria

- [x] Noise XX handshake completes successfully in test
- [x] Transport encrypt/decrypt roundtrip works
- [x] ResourceArc lifecycle is smoke-tested via repeated create/use/drop without crashes
- [x] Concurrent handshakes work (multiple ResourceArcs)
- [x] High-level error handling: `BaileysEx.Protocol.Noise` returns `{:error, reason}` for bad data instead of crashing callers
- [x] Certificate chain validated after Noise handshake step 2 (GAP-21)
- [ ] Native leak verification completed with dedicated tooling for `ResourceArc` teardown

Native `ResourceArc` lifecycle now has explicit smoke coverage for repeated create/use/drop,
which is useful evidence of lifecycle correctness. It is not proof of leak freedom; that
remains an open hardening task until verified with dedicated native tooling.

### Files

| File | Status |
|------|--------|
| `native/baileys_nif/src/noise.rs` | 🟡 |
| `lib/baileys_ex/native/noise.ex` | 🟡 |
| `lib/baileys_ex/protocol/noise.ex` | 🟡 |
| `test/baileys_ex/native/noise_test.exs` | ✅ |
| `test/baileys_ex/protocol/noise_test.exs` | 🟡 |

---

## Phase 5: Signal Protocol (libsignal-compatible boundary)

**Status:** COMPLETE · **Depends on:** Phases 1, 2 · **Blocks:** 7, 8

### Tasks

- [x] 5.1 Minimal native Signal boundary + verification helper boundary
- [x] 5.2 Signal repository boundary (address translation, inject/validate/encrypt/decrypt/delete contracts)
- [x] 5.3 LID mapping store + session migration
- [x] 5.4 Sender-key group crypto + distribution processing
- [x] 5.5 Signal identity handling (TOFU + invalidation)
- [x] 5.6 Store contract for sessions, pre-keys, sender-keys, mappings, identities
- [x] 5.7 Cross-validation tests against Baileys-compatible data

### Acceptance Criteria

- [x] Repository boundary and Elixir-owned Signal behavior match Baileys for the implemented surfaces
- [x] PN sessions migrate to LID sessions without losing device separation
- [x] LID mapping storage mirrors Baileys' forward/reverse key convention for persistent stores
- [x] TOFU identity storage detects key changes and invalidates stale sessions
- [x] Sender-key encrypt/decrypt and distribution interoperate with Baileys
- [x] Signal store contract covers sessions, pre-keys, sender-key-memory, LID mappings, device lists, tc tokens, and identity keys
- [x] Cross-validation uses committed Baileys-generated address, mapping, and sender-key data
- [x] Native boundary is no broader than necessary for correctness, interop, and performance

Phase 5 intentionally stops at the compatibility boundary. A concrete 1:1 session
engine still lives behind `BaileysEx.Signal.Repository.Adapter` and is not being
falsely marked as implemented here.

### Files

| File | Status |
|------|--------|
| `lib/baileys_ex/signal/curve.ex` | ✅ |
| `lib/baileys_ex/signal/repository.ex` | ✅ |
| `lib/baileys_ex/signal/lid_mapping_store.ex` | ✅ |
| `lib/baileys_ex/signal/address.ex` | ✅ |
| `lib/baileys_ex/signal/group/sender_key_name.ex` | ✅ |
| `lib/baileys_ex/signal/group/sender_chain_key.ex` | ✅ |
| `lib/baileys_ex/signal/group/sender_message_key.ex` | ✅ |
| `lib/baileys_ex/signal/group/sender_key_state.ex` | ✅ |
| `lib/baileys_ex/signal/group/sender_key_record.ex` | ✅ |
| `lib/baileys_ex/signal/group/sender_key_distribution_message.ex` | ✅ |
| `lib/baileys_ex/signal/group/sender_key_message.ex` | ✅ |
| `lib/baileys_ex/signal/group/session_builder.ex` | ✅ |
| `lib/baileys_ex/signal/group/cipher.ex` | ✅ |
| `lib/baileys_ex/signal/identity.ex` | ✅ |
| `lib/baileys_ex/signal/store.ex` | ✅ |
| `lib/baileys_ex/signal/store/memory.ex` | ✅ |
| `lib/baileys_ex/native/xeddsa.ex` | ✅ |
| `test/baileys_ex/signal/curve_test.exs` | ✅ |
| `test/baileys_ex/signal/address_test.exs` | ✅ |
| `test/baileys_ex/signal/store_test.exs` | ✅ |
| `test/baileys_ex/signal/repository_test.exs` | ✅ |
| `test/baileys_ex/signal/lid_mapping_store_test.exs` | ✅ |
| `test/baileys_ex/signal/group_test.exs` | ✅ |
| `test/baileys_ex/signal/identity_test.exs` | ✅ |
| `test/baileys_ex/signal/cross_validation_test.exs` | ✅ |
| `test/fixtures/signal/baileys_v7.json` | ✅ |
| `dev/tools/generate_signal_fixtures.mts` | ✅ |

---

## Phase 6: Connection

**Status:** COMPLETE · **Depends on:** Phases 3, 4 · **Blocks:** 7, 8

> **Current snapshot:** the Phase 6 runtime is now in-tree and complete for its
> current scope. `Connection.Socket` reaches `:connected` once the
> auth-success seam is satisfied, emits `connection_update` `:connecting` /
> `:open` / `:close` / `:qr` / `:is_new_login` transitions, sends
> `passive/active` plus `unified_session` on open and presence-available, runs
> `w:p` keep-alive pings, handles `offline_preview`, `offline`, and
> `edge_routing`, and supports explicit logout plus rc.9 `pair-device` /
> `pair-success` pairing.
> `Connection.EventEmitter` now covers `process/2`, internal runtime taps,
> the rc.9 bufferable event set, `create_buffered_function/2`, flush/auto-flush,
> mixed `messages_upsert` boundaries, and conditional `chats_update`
> preservation. `Connection.Supervisor`, `Connection.Coordinator`, and
> `Connection.Store` now provide auto-connect/reconnect, `creds_update`
> persistence, ETS-backed concurrent reads, init queries, dirty-bit handling,
> and the `connecting -> awaiting_initial_sync -> syncing -> online`
> runtime choreography. Remaining auth persistence / pre-key upload work now
> belongs to Phase 7+, not Phase 6.

### Tasks

- [x] 6.1 Connection config (browser/platform — GAP-27)
- [x] 6.2 Connection socket (`:gen_statem`, `makeSocket` parity)
- [x] 6.3 Frame handling (3-byte length prefix)
- [x] 6.4 Per-connection supervisor / reconnect wrapper (`:rest_for_one`)
- [x] 6.5 Event emitter + buffered event contract (25+ types — GAP-07, buffering — GAP-22)
- [x] 6.6 Store (GenServer + ETS, creds/runtime metadata, LID mappings)
- [x] 6.7 Tests and parity verification

### Acceptance Criteria

- [x] State machine transitions through all states correctly
- [x] Noise handshake integrates with WebSocket transport up to `:authenticating`
- [x] Frame encoding/decoding with length prefix works
- [x] `connection.update` mirrors rc.9 field sequencing (`connecting`, `open`, `close`, `qr`, `isNewLogin`, `receivedPendingNotifications`, `isOnline`, `lastDisconnect`)
- [x] Keep-alive uses `w:p` IQ ping and closes after `interval + 5s` without inbound traffic
- [x] `offline_preview`, `offline`, and `edge_routing` handlers match rc.9 behavior
- [x] Reconnect works after unexpected disconnect via the supervisor/wrapper layer without inventing new raw-socket semantics
- [x] Supervisor `:rest_for_one` restarts children correctly
- [x] Event emitter dispatches to subscribers and supports batched `process` handling
- [x] Store reads are concurrent via ETS
- [x] Raw socket does not blanket-send successful ACKs; per-message ACK/NACK parity remains in the receive pipeline (GAP-03)
- [x] Logout sends `remove-companion-device` and disconnects (GAP-18)
- [x] EventEmitter supports all 25+ event types (GAP-07)
- [x] EventEmitter covers Utils-driven events: messaging_history_set, messages_reaction, group_participants_update, group_join_request, group_member_tag_update, lid_mapping_update, settings_update, chats_lock
- [x] Event buffering accumulates events, flushes on demand, and preserves conditional chat updates (GAP-22, GAP-48)
- [x] Buffer auto-flushes after 30 seconds (GAP-22)
- [x] Dirty bit notifications trigger appropriate refresh (GAP-24)
- [x] `account_sync` dirty handling persists `lastAccountSyncTimestamp`; group/community dirty refresh reuses correct clean bucket (GAP-24)
- [x] Platform type correctly mapped for device registration (GAP-27)
- [x] Unified session sent on connection open and on presence available (GAP-33)
- [x] Init queries (props, blocklist, privacy) fetched in parallel and cache `lastPropHash` deltas (GAP-34)
- [x] Conditional chat updates held during sync (GAP-48)
- [x] Sync state machine: connecting → awaiting_initial_sync → syncing → online (GAP-48)

### Files

| File | Status |
|------|--------|
| `lib/baileys_ex/connection/config.ex` | ✅ |
| `lib/baileys_ex/connection/frame.ex` | ✅ |
| `lib/baileys_ex/connection/transport.ex` | ✅ |
| `lib/baileys_ex/connection/transport/mint_adapter.ex` | ✅ |
| `lib/baileys_ex/connection/transport/mint_web_socket.ex` | ✅ |
| `lib/baileys_ex/auth/pairing.ex` | ✅ |
| `lib/baileys_ex/auth/qr.ex` | ✅ |
| `lib/baileys_ex/connection/socket.ex` | ✅ |
| `lib/baileys_ex/connection/coordinator.ex` | ✅ |
| `lib/baileys_ex/connection/supervisor.ex` | ✅ |
| `lib/baileys_ex/connection/event_emitter.ex` | ✅ |
| `lib/baileys_ex/connection/store.ex` | ✅ |
| `lib/baileys_ex/protocol/proto/adv_messages.ex` | ✅ |
| `test/baileys_ex/connection/config_test.exs` | ✅ |
| `test/baileys_ex/connection/frame_test.exs` | ✅ |
| `test/baileys_ex/connection/socket_test.exs` | ✅ |
| `test/baileys_ex/connection/transport/mint_web_socket_test.exs` | ✅ |
| `test/baileys_ex/connection/event_emitter_test.exs` | ✅ |
| `test/baileys_ex/connection/supervisor_test.exs` | ✅ |
| `test/baileys_ex/connection/store_test.exs` | ✅ |

---

## Phase 7: Authentication

**Status:** COMPLETE · **Depends on:** Phases 5, 6 · **Blocks:** 8

### Tasks

- [x] 7.1 Auth state struct
- [x] 7.2 Persistence behaviour
- [x] 7.3 File-based persistence (default)
- [x] 7.4 QR code pairing
- [x] 7.5 Phone number pairing
- [x] 7.6 Pre-key upload
- [x] 7.7 Transactional Signal Key Storage (GAP-44)
- [x] 7.8 Connection validation (login/registration nodes)
- [x] 7.9 Pre-key management (advanced — rotation, min count)
- [x] 7.10 Tests

### Acceptance Criteria

- [x] New auth state generates valid crypto keys
- [x] File persistence saves and loads credentials correctly
- [x] File persistence serializes binaries safely and guards per-file writes with a mutex
- [x] QR code data format matches WhatsApp expectations
- [x] Phone pairing key derivation matches Baileys output
- [x] Pre-key upload constructs correct binary nodes
- [x] Custom persistence backend can be swapped via behaviour
- [x] Login node constructed correctly for returning users
- [x] Registration node includes device props, history sync config, platform type
- [x] Pair-success HMAC and ADV signature verification passes
- [x] Companion-finish waits for the query result before `registered: true` is emitted
- [x] Pre-key upload triggered automatically when server count is low
- [x] Socket-owned post-auth pre-key ordering matches rc.9 before `connection.update(:open)`
- [x] Signed pre-key rotation works correctly
- [x] Key store transactions serialize concurrent read/write bursts (GAP-44)
- [x] Transaction commits roll back to the previous persisted snapshot on failure (GAP-44)
- [x] Read-through cache prevents redundant persistence lookups during sync
- [x] Key store supports lid-mapping, device-list, identity-key, sender-key-memory, and tctoken datasets

### Files

| File | Status |
|------|--------|
| `lib/baileys_ex/auth/state.ex` | ✅ |
| `lib/baileys_ex/auth/persistence.ex` | ✅ |
| `lib/baileys_ex/auth/file_persistence.ex` | ✅ |
| `lib/baileys_ex/auth/pairing.ex` | ✅ |
| `lib/baileys_ex/auth/qr.ex` | ✅ |
| `lib/baileys_ex/auth/phone.ex` | ✅ |
| `lib/baileys_ex/auth/key_store.ex` | ✅ |
| `lib/baileys_ex/auth/connection_validator.ex` | ✅ |
| `lib/baileys_ex/protocol/proto/client_payload_messages.ex` | ✅ |
| `lib/baileys_ex/connection/config.ex` | ✅ |
| `lib/baileys_ex/signal/prekey.ex` (extend) | ✅ |
| `lib/baileys_ex/connection/socket.ex` | ✅ |
| `lib/baileys_ex/connection/coordinator.ex` | ✅ |
| `lib/baileys_ex/connection/supervisor.ex` | ✅ |
| `test/baileys_ex/auth/state_test.exs` | ✅ |
| `test/baileys_ex/auth/file_persistence_test.exs` | ✅ |
| `test/baileys_ex/auth/key_store_test.exs` | ✅ |
| `test/baileys_ex/auth/qr_test.exs` | ✅ |
| `test/baileys_ex/auth/phone_test.exs` | ✅ |
| `test/baileys_ex/auth/connection_validator_test.exs` | ✅ |
| `test/baileys_ex/auth/connection_validator_runtime_test.exs` | ✅ |
| `test/baileys_ex/connection/socket_test.exs` | ✅ |
| `test/baileys_ex/connection/supervisor_test.exs` | ✅ |
| `test/baileys_ex/signal/prekey_test.exs` | ✅ |

---

## Phase 8: Messaging Core

**Status:** COMPLETE · **Depends on:** Phases 5, 6, 7 · **Blocks:** 9, 10

Current branch progress:
- Phase 8 is complete on `phase-08-messaging`.
- The branch now includes the WAProto subset and runtime helpers required for the full rc.9 message path: builder/parser parity for the sendable content set, repo-threaded direct/group/status send fanout, USync-backed device discovery caching, padded message wire helpers, receive-side decrypt/decode/event emission, and end-to-end roundtrip tests.
- The messaging runtime also now includes the remaining rc.9 support surfaces: offline FIFO batching, LID-aware envelope decoding, receipt send/process helpers, retry/PDO handling, history sync, bad-ack handling, verified-name extraction, identity-change refresh, normalization/decryption side effects, reporting tokens, and the raw node dispatch seam from `Connection.Socket` through `Connection.Coordinator`.

### Tasks

- [x] 8.1 Message builder (ALL message types)
- [x] 8.2 Message sender (build → encrypt → encode → send)
- [x] 8.3 Message receiver (decode → decrypt → parse → emit)
- [x] 8.3a Offline node processor (FIFO batching of offline nodes)
- [x] 8.3b Envelope decode and protocol-message side effects
- [x] 8.4 Receipt handling (delivered, read, played)
- [x] 8.5 Retry logic (14 reason codes, MAC error cooldown)
- [x] 8.5a Peer Data Operations (history sync on-demand, placeholder resend transport)
- [x] 8.6 Device discovery (multi-device)
- [x] 8.7 Bad ACK handling (GAP-40)
- [x] 8.7a Verified Name Certificates (GAP-35)
- [x] 8.8 Notification handler (11 notification types)
- [x] 8.9 History sync (download, decompress, PN-LID fallback — GAP-45)
- [x] 8.10 Identity change handler
- [x] 8.11 Message normalization (JIDs, reactions, polls, LID/PN)
- [x] 8.12 Tests

### Acceptance Criteria

- [x] Text message send/receive pipeline works end-to-end
- [x] Signal encryption/decryption integrated into pipeline
- [x] Device discovery queries and caches device lists
- [x] Receipts sent correctly
- [x] Retry logic handles failed decryption
- [x] Builder covers ALL message types explicitly (no catch-all)
- [x] Events emitted for received messages
- [x] Reactions send/receive correctly
- [x] Polls create with message secret, correct version (V1/V2/V3)
- [x] Contacts: single → contactMessage, multiple → contactsArrayMessage
- [x] Location and live location produce correct proto
- [x] Message delete (revoke) constructs correct protocolMessage
- [x] Message edit constructs correct protocolMessage with :MESSAGE_EDIT
- [x] Disappearing messages toggle via protocolMessage
- [x] Pin/unpin in chat with duration
- [x] Forward increments forwarding_score, sets is_forwarded
- [x] Status/stories send to `status@broadcast` with viewer list
- [x] Parser unwraps ephemeral/viewOnce/template wrappers
- [x] Parser detects content type for all known message types
- [x] Inbound interactive messages parsed without crash
- [x] Notification handler processes all 11 notification types
- [x] Group notifications produce correct stub types (20+ types)
- [x] History sync downloads, decompresses, processes correctly
- [x] History sync emits correct events by sync type
- [x] DSM wrapper sent to own devices for 1:1 messages
- [x] Group messages distribute SKD to new devices
- [x] Sender key memory tracked per group
- [x] Message ID format matches Baileys (3EB0 + timestamp + random)
- [x] Participant hash V2 computed and sent as phash attribute
- [x] Retry manager handles 14 reason codes
- [x] MAC errors trigger immediate session recreation (1-hour cooldown)
- [x] Recent-message cache and scheduled phone requests match MessageRetryManager semantics when enabled
- [x] Identity change notifications trigger session refresh
- [x] Placeholder resend requests via PDO with dedup
- [x] Peer Data Operation requests sent to self with peer message attributes
- [x] ProtocolMessage side effects cover history sync, app-state key share, PDO responses, label-change, edit/revoke, and LID migration mapping sync
- [x] Decode path preserves alt addressing fields and uses LID mapping for decryption routing
- [x] Received messages normalized
- [x] Received event responses decrypt and update the source event message when the message secret is available
- [x] Reporting tokens attached to applicable types (GAP-32)
- [x] Bad ACK errors emit messages.update with ERROR status (GAP-40)
- [x] History sync extracts PN-LID mappings with fallback (GAP-45)
- [x] Offline node processor drains FIFO batches of 10 without long scheduler monopolization

### Files

| File | Status |
|------|--------|
| `lib/baileys_ex/message/builder.ex` | ✅ |
| `lib/baileys_ex/message/parser.ex` | ✅ |
| `lib/baileys_ex/message/sender.ex` | ✅ |
| `lib/baileys_ex/message/receiver.ex` | ✅ |
| `lib/baileys_ex/message/decode.ex` | ✅ |
| `lib/baileys_ex/message/receipt.ex` | ✅ |
| `lib/baileys_ex/message/retry.ex` | ✅ |
| `lib/baileys_ex/message/peer_data.ex` | ✅ |
| `lib/baileys_ex/message/notification_handler.ex` | ✅ |
| `lib/baileys_ex/message/history_sync.ex` | ✅ |
| `lib/baileys_ex/message/identity_change_handler.ex` | ✅ |
| `lib/baileys_ex/message/normalizer.ex` | ✅ |
| `lib/baileys_ex/message/reporting.ex` | ✅ |
| `lib/baileys_ex/signal/device.ex` | ✅ |
| `lib/baileys_ex/signal/session.ex` | ✅ |
| `test/baileys_ex/message/builder_test.exs` | ✅ |
| `test/baileys_ex/message/parser_test.exs` | ✅ |
| `test/baileys_ex/message/sender_test.exs` | ✅ |
| `test/baileys_ex/message/receiver_test.exs` | ✅ |
| `test/baileys_ex/message/decode_test.exs` | ✅ |
| `test/baileys_ex/message/receipt_test.exs` | ✅ |
| `test/baileys_ex/message/retry_test.exs` | ✅ |
| `test/baileys_ex/message/peer_data_test.exs` | ✅ |
| `test/baileys_ex/message/notification_handler_test.exs` | ✅ |
| `test/baileys_ex/message/history_sync_test.exs` | ✅ |
| `test/baileys_ex/message/identity_change_handler_test.exs` | ✅ |
| `test/baileys_ex/message/integration_test.exs` | ✅ |
| `test/baileys_ex/signal/device_test.exs` | ✅ |

---

## Phase 9: Media

**Status:** COMPLETE · **Depends on:** Phases 2, 8 · **Parallel with:** Phase 10

**Current branch note:** Phase 9 is now complete on `phase-09-media`.
`BaileysEx.Media.Types`, `Crypto`, `Upload`, `Download`, `Thumbnail`,
`Retry`, and `MessageBuilder` now cover the rc.9 media surface: streaming
encrypt/decrypt, CDN upload/download, aligned ranged fetches, explicit
thumbnail/waveform dependency errors, expired-media re-upload requests and
media-update application, store-backed `media_conn` caching with host retry,
and sender-side media preparation before `BaileysEx.Message.Builder`. The
phase now includes a committed Baileys rc.9 media fixture under
`test/fixtures/media/baileys_v7.json` for cross-validation. Streamed download
parity intentionally matches Baileys by skipping trailer MAC verification;
full-payload verified decrypts still go through `BaileysEx.Media.Crypto.decrypt/3`.

### Tasks

- [x] 9.1 Media crypto (single-pass streaming — GAP-46)
- [x] 9.2 Media upload (HTTP to WhatsApp CDN)
- [x] 9.3 Media download (streaming + decryption)
- [x] 9.4 Media types (image, video, audio, doc, sticker)
- [x] 9.5 Thumbnail and waveform generation
- [x] 9.5a Media Re-upload Flow (GAP-47)
- [x] 9.6 Media connection and retry
- [x] 9.7 Integrate with message builder
- [x] 9.8 Tests

### Acceptance Criteria

- [x] Media encrypt/decrypt roundtrip for all core media message types
- [x] MAC verification works (pass and fail cases)
- [x] Upload constructs correct HTTP request
- [x] Download handles streaming
- [x] Message builder integrates media handling
- [x] Cross-validation with Baileys-encrypted media
- [x] Image thumbnails generated when `image` package available
- [x] Video thumbnails via ffmpeg when available
- [x] Audio waveform computed (64 samples)
- [x] Media connection refreshed and cached
- [x] Media upload retry works for failed messages
- [x] Media encryption uses single-pass streaming (GAP-46)
- [x] Media re-upload request sent for expired media (GAP-47)

### Files

| File | Status |
|------|--------|
| `lib/baileys_ex/media/crypto.ex` | ✅ |
| `lib/baileys_ex/media/upload.ex` | ✅ |
| `lib/baileys_ex/media/download.ex` | ✅ |
| `lib/baileys_ex/media/types.ex` | ✅ |
| `lib/baileys_ex/media/thumbnail.ex` | ✅ |
| `lib/baileys_ex/media/message_builder.ex` | ✅ |
| `lib/baileys_ex/media/retry.ex` | ✅ |
| `lib/baileys_ex/message/builder.ex` (extend) | ✅ |
| `lib/baileys_ex/message/notification_handler.ex` (extend) | ✅ |
| `lib/baileys_ex/message/sender.ex` (extend) | ✅ |
| `lib/baileys_ex/protocol/proto/media_retry_messages.ex` | ✅ |
| `test/baileys_ex/media/crypto_test.exs` | ✅ |
| `test/baileys_ex/media/cross_validation_test.exs` | ✅ |
| `test/baileys_ex/media/upload_test.exs` | ✅ |
| `test/baileys_ex/media/download_test.exs` | ✅ |
| `test/baileys_ex/media/types_test.exs` | ✅ |
| `test/baileys_ex/media/thumbnail_test.exs` | ✅ |
| `test/baileys_ex/media/message_builder_test.exs` | ✅ |
| `test/baileys_ex/media/retry_test.exs` | ✅ |

---

## Phase 10: Features

**Status:** IN PROGRESS · **Depends on:** Phase 8 · **Parallel with:** Phase 9 · **Blocks:** 11

**Current branch note:** Batch 1 is landed on `phase-10-features`.
`BaileysEx.Feature.Group` now covers the core `groups.ts` query surface:
group CRUD/query helpers, participant mutations, invite v3/v4 operations,
invite-v4 invalidation plus synthetic `GROUP_PARTICIPANT_ADD` side effects,
the relay-backed `GROUP_MEMBER_LABEL_CHANGE` path, ephemeral/settings toggles,
metadata extraction, participating-group fetch, and coordinator-driven
dirty-group refetch/clean behavior.
`BaileysEx.Feature.PhoneValidation` now implements `on_whatsapp/3` via the
USync contact protocol and filters to confirmed contacts only. `BaileysEx.Feature.Chat`
plus the early `BaileysEx.Feature.AppState` surface now map chat modifications
to Baileys-aligned patch structures with nested Syncd timestamps and validated
last-message ranges ahead of full Syncd transport work in `10.5`.
`BaileysEx.Feature.Presence` now covers Baileys-style availability/chatstate sends,
presence subscribe with explicit message tags, incoming presence/chatstate parsing,
and coordinator event emission. `BaileysEx.Feature.BotDirectory` now mirrors
`getBotListV2`. `BaileysEx.Feature.TcToken` now covers direct-message relay
attachment, presence-subscribe attachment, privacy-token fetch/storage, and
notification handling; profile-picture query attachment remains open with the
profile surface. Remaining open work after this batch is the broader Phase 10
surface: privacy, full Syncd push/resync runtime, profile/labels/contacts, and
quick replies.

### Tasks

- [x] 10.1 Group management (CRUD, participants, invites v3/v4)
- [x] 10.1a Phone number validation (`on_whatsapp` via USync)
- [x] 10.2 Chat operations (archive, mute, pin, star, clear, delete)
- [x] 10.3 Presence (online/offline/composing/recording)
- [ ] 10.3a Trusted Contact Tokens (GAP-23)
- [x] 10.3b Bot Directory (GAP-37)
- [ ] 10.4 Privacy settings (8 categories + block list + disappearing)
- [ ] 10.5a App state sync — key expansion + snapshot decode
- [ ] 10.5b App state sync — patch encode/decode + MAC verification
- [ ] 10.5c App state sync — ChatMutationMap + process patches → emit events
- [ ] 10.5d App state sync — full resync + push patch flow
- [ ] 10.6 LTHash utility
- [ ] 10.7 Profile management (picture, name, status, business)
- [ ] 10.8 Label management (CRUD, associations)
- [ ] 10.9 Contact management (add/edit/remove via app state)
- [ ] 10.10 Quick replies
- [ ] 10.11 Tests

### Acceptance Criteria

- [x] Group operations construct correct binary nodes
- [x] Presence updates send and receive correctly
- [x] Chat operations build Baileys-aligned app-state patches
- [ ] Privacy: all 8 categories query and update via IQ nodes
- [ ] Privacy: default disappearing mode set/fetch
- [ ] Privacy: block list fetch/block/unblock
- [ ] App state sync initial fetch works
- [ ] LTHash verification matches Baileys
- [ ] Sync actions emit contacts, LID mappings, labels, settings, and chat-lock updates correctly
- [ ] Profile: update/remove picture constructs correct IQ
- [ ] Profile: picture URL query and response parsing
- [ ] Profile: update name via app state sync
- [ ] Profile: update status text via IQ
- [ ] Profile: fetch status via USync query
- [ ] Profile: business profile query and response parsing
- [ ] Labels: CRUD via app state patches
- [ ] Labels: chat/message association via app state patches
- [ ] Contacts: add/edit/remove via app state patches
- [ ] Quick replies: add/edit/remove via app state patches
- [x] `on_whatsapp` validates phone numbers via USync
- [x] Group setting update (announcement/locked toggles)
- [x] Group member add mode and join approval mode
- [x] Pending join request list and approve/reject
- [x] V4 invite accept and revoke operations, including invite invalidation side effects
- [x] Group dirty updates refetch participating groups, emit `groups.update`, and clean the `groups` bucket
- [x] App-state patch timestamps live under `sync_action`, and last-message ranges are validated/normalized
- [ ] TC tokens built and attached to presence/profile queries (GAP-23)
- [x] Privacy token notifications stored correctly (GAP-23)
- [x] Bot directory fetched via IQ query (GAP-37)
- [x] Group member label update constructs correct protocol message (GAP-39)
- [x] Link preview privacy toggle maps to Baileys `updateDisableLinkPreviewsPrivacy/1`

### Files

| File | Status |
|------|--------|
| `lib/baileys_ex/feature/group.ex` | ✅ |
| `lib/baileys_ex/feature/chat.ex` | ✅ |
| `lib/baileys_ex/feature/presence.ex` | ✅ |
| `lib/baileys_ex/feature/bot_directory.ex` | ✅ |
| `lib/baileys_ex/feature/privacy.ex` | ⬜ |
| `lib/baileys_ex/feature/profile.ex` | ⬜ |
| `lib/baileys_ex/feature/label.ex` | ⬜ |
| `lib/baileys_ex/feature/contact.ex` | ⬜ |
| `lib/baileys_ex/feature/quick_reply.ex` | ⬜ |
| `lib/baileys_ex/feature/app_state.ex` | 🟡 |
| `lib/baileys_ex/feature/phone_validation.ex` | ✅ |
| `lib/baileys_ex/feature/tc_token.ex` | 🟡 |
| `lib/baileys_ex/util/lt_hash.ex` | ⬜ |
| `test/baileys_ex/feature/group_test.exs` | ✅ |
| `test/baileys_ex/feature/presence_test.exs` | ✅ |
| `test/baileys_ex/feature/bot_directory_test.exs` | ✅ |
| `test/baileys_ex/feature/privacy_test.exs` | ⬜ |
| `test/baileys_ex/feature/profile_test.exs` | ⬜ |
| `test/baileys_ex/feature/chat_test.exs` | ✅ |
| `test/baileys_ex/feature/phone_validation_test.exs` | ✅ |
| `test/baileys_ex/feature/tc_token_test.exs` | 🟡 |
| `test/baileys_ex/feature/app_state_test.exs` | ✅ |
| `test/baileys_ex/util/lt_hash_test.exs` | ⬜ |

---

## Phase 11: Advanced Features

**Status:** NOT STARTED · **Depends on:** Phase 10 · **Blocks:** 12

### Tasks

- [ ] 11.1 Business operations (profile update, cover, catalog, products, orders)
- [ ] 11.2 Newsletters (19 functions, mixed WMex/IQ/message transport)
- [ ] 11.3 Communities (23 functions, subgroup linking)
- [ ] 11.4 Call handling (offer/reject, call links — GAP-36)
- [ ] 11.5 Tests

### Acceptance Criteria

- [ ] Newsletter: all 19 functions construct correct WMex/IQ/message nodes
- [ ] Community: all 23 functions construct correct IQ nodes
- [ ] Community: subgroup linking/unlinking works
- [ ] Community: fetch_linked_groups returns correct structure
- [ ] Business: profile update with hours/website arrays
- [ ] Business: cover photo upload via media upload pipeline
- [ ] Business: product CRUD operations
- [ ] Business: order-details query uses the `fb:thrift_iq` namespace from Baileys
- [ ] Call: reject constructs correct call node
- [ ] Call events emitted correctly
- [ ] All node formats match Baileys reference
- [ ] Call link creation uses `call/link_create` and returns token for audio/video (GAP-36)

### Files

| File | Status |
|------|--------|
| `lib/baileys_ex/feature/business.ex` | ⬜ |
| `lib/baileys_ex/feature/newsletter.ex` | ⬜ |
| `lib/baileys_ex/feature/community.ex` | ⬜ |
| `lib/baileys_ex/feature/call.ex` | ⬜ |
| `test/baileys_ex/feature/business_test.exs` | ⬜ |
| `test/baileys_ex/feature/newsletter_test.exs` | ⬜ |
| `test/baileys_ex/feature/community_test.exs` | ⬜ |
| `test/baileys_ex/feature/call_test.exs` | ⬜ |

---

## Phase 12: Polish

**Status:** NOT STARTED · **Depends on:** All previous phases

### Tasks

- [ ] 12.1 Telemetry events for all key operations
- [ ] 12.2 Public API facade (`lib/baileys_ex.ex` rewrite)
- [ ] 12.3 Documentation (ex_doc, guides)
- [ ] 12.4 Example application (echo bot)
- [ ] 12.5 Hex.pm preparation (`mix hex.build`)
- [ ] 12.6 CI setup (GitHub Actions)
- [ ] 12.7 WAM analytics encoding (optional/deferred)

### Acceptance Criteria

- [ ] Telemetry events fire for all key operations
- [ ] Public API covers all major features
- [ ] Documentation generates without warnings
- [ ] Example bot runs successfully
- [ ] `mix hex.build` succeeds
- [ ] CI passes all checks

### Files

| File | Status |
|------|--------|
| `lib/baileys_ex.ex` (rewrite) | ⬜ |
| `lib/baileys_ex/telemetry.ex` | ⬜ |
| `guides/*.md` | ⬜ |
| `examples/echo_bot.exs` | ⬜ |
| `.github/workflows/ci.yml` | ⬜ |

---

## Totals

| Metric | Count |
|--------|-------|
| Phases | 12 |
| Tasks | 101 |
| Acceptance Criteria | 148 |
| Source Files | ~80 |
| Test Files | ~30 |
| GAP items resolved | 48/48 |
