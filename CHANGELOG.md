# Changelog

## [Unreleased]

## [0.1.0-alpha.10] - 2026-06-02

Maintenance release focused on reducing receive-path overhead and improving
large app-state resync behavior without changing the public API.

### Changed

- Message receive diagnostics now run at debug level and avoid building
  expensive protocol-message summaries unless debug logging is enabled.
- Large app-state resyncs now preserve mutation order without repeatedly
  appending to growing lists, reducing memory churn during reconnect and
  initial sync catch-up.
- Successful app-state resync diagnostics now log at debug level instead of
  warning level. Actual resync failures still log warnings.
- App-state resync events now keep collection-level chat updates in the
  requested sync order when multiple collections are returned together.

## [0.1.0-alpha.9] - 2026-06-02

WhatsApp/Baileys v7 compatibility update. This release moves BaileysEx from the
Baileys v7 rc9 behavior set to `v7.0.0-rc13` and brings over the rc10-rc13
protocol fixes that affect pairing, message resend, app-state sync, trusted
contact tokens, device lists, newsletters, groups, and account-limit handling.

### Upgrade Impact

- No public BaileysEx function was intentionally removed or renamed.
- QR pairing payloads now use Baileys rc13's linked-device format. Regenerate
  any in-flight QR codes after upgrading.
- Direct 1:1 message sends may now attach trusted-contact tokens or issue fresh
  tokens after sending. Apps that inspect raw stanzas or count outbound
  protocol traffic may see additional token-related traffic.
- Missing/unavailable messages can now emit Baileys-shaped placeholder stubs and
  request a resend from the phone device. Message consumers should tolerate
  unavailable-message placeholders and later replacement messages.
- App-state sync can now retry with snapshots, park collections while waiting
  for missing app-state keys, and resume when a key-share arrives. This improves
  recovery after reconnects and key rotation, but sync completion may now
  proceed with partial state when WhatsApp sends an individually corrupted sync
  record.
- Device-list removals now clear stale sessions. This can cause a session to be
  rebuilt on the next send instead of reusing an outdated device session.
- New account restriction and message-cap notifications can be emitted when
  WhatsApp reports reachout timelocks or new-chat limits.
- Parsed events may include new fields such as usernames, group participant
  usernames, and group online counts.

### Added

- `fetch_account_reachout_timelock/2` and
  `fetch_new_chat_message_cap/2` for WhatsApp account-limit checks.
- Reachout timelock and new-chat-limit events from MEX notifications.
- Trusted-contact token persistence, post-send issuance, identity-change
  reissue, expiry cleanup, and sender timestamp preservation.
- Username lookup support in USync results.
- Album message sending.
- Group `@all` mentions.
- Group participant usernames and group online counts in parsed events.
- Device-list notification handling for add, remove, and update changes.
- Newsletter v2 join/leave support and multi-child newsletter notification
  handling.

### Changed

- Updated the compatibility target from Baileys v7 rc9 behavior to
  `v7.0.0-rc13`.
- Default WhatsApp Web version and linked-device QR pairing output now match
  Baileys rc13.
- Direct 1:1 sends now follow Baileys' trusted-contact-token rules: existing
  tokens are attached only for eligible user messages, peer/AppStateSync
  messages are excluded, and fresh tokens are issued after eligible sends.
- App-state sync is more resilient after reconnects and key rotation: missing
  keys retry with a snapshot before parking, parked collections retry when a new
  app-state key arrives, and corrupted individual sync records no longer abort
  the whole sync pass.
- Incoming unavailable-message placeholders now use the Baileys rc10 resend
  behavior, including phone-device requests for missing messages and safety
  skips for bot, hosted, view-once, and old unavailable stanzas.
- Retry and bad-ack handling now preserves Baileys error semantics, including
  unknown retry codes and 463 account-restriction updates.
- Pre-key uploads no longer use a default throttle, matching the Baileys rc10
  send path.
- Media downloads now fall back across direct-path hosts when WhatsApp returns
  a CDN URL that cannot be fetched directly.
- Offline notifications are processed in Baileys-compatible FIFO batches with
  buffered event flushing, reducing event churn during reconnect catch-up.

### Fixed

- Linked-device sync messages routed by WhatsApp as outgoing self stanzas are
  now treated as `from_me`, even when the stanza omits an explicit `recipient`.
  This prevents valid history sync, app-state key-share, LID mapping, and
  peer-data operation responses from being skipped after reconnects or
  companion sync flows.
- Self-only protocol sync messages are ignored when they arrive from another
  sender, preventing peer-originated stanzas from mutating local sync state.
- Privacy-token notifications no longer drop the stored sender timestamp used to
  avoid duplicate trusted-contact token issuance.
- Direct peer messages no longer include `tctoken` nodes that WhatsApp rejects.
- Protocol message parsing now handles WhatsApp's newer peer-routed self-stanza
  shape without dropping legitimate self sync messages.

## [0.1.0-alpha.8] - 2026-05-22

Library-guideline cleanup.

### Changed

- Removed the unused `BaileysEx.Application` callback and global singleton supervisors; connection runtimes are now only caller-owned per-connection supervisors
- File persistence convenience defaults now use literal cwd-based paths instead of `Application.get_env/2`

## [0.1.0-alpha.7] - 2026-03-21

DRY audit and bug-fix pass. Duplicated transport wrappers across feature
and media modules had diverged silently, producing a runtime crash path.

### Added

- `Connection.TransportAdapter` — shared transport dispatch replacing diverged copies across 12 modules
- `Signal.Store.wrap_running/1` — centralized signal store resolution

### Fixed

- `Media.Upload` crash when given `{module, pid}` queryable tuples from runtime APIs
- `Store.put/3` with `nil` silently preserving old values instead of deleting
- Stale LTHash state on Syncd retry-from-scratch due to nil writes being dropped
- EventEmitter silently losing events after dispatcher process death

### Changed

- EventEmitter dispatch hardened with queue-based delivery, monitor/restart, and `throw`/`exit`/`raise` isolation

## [0.1.0-alpha.6] - 2026-03-20

Eliminates the last JS-shaped design pattern in the codebase. Signal store
transactions previously used a zero-argument closure with hidden state in
the process dictionary — a literal port of Baileys' `keys.transaction(async
() => ...)`. Transactions now pass an explicit handle through the closure,
matching the Ecto `Repo.transaction(fn repo -> ... end)` convention. This
makes transaction state visible, testable, and composable without hidden
coupling to the calling process.

### Added

- `Signal.Store.transaction/3` now passes explicit transaction handles
- `TransactionBuffer` module extracts reusable ETS-based transaction caching

### Changed

- Signal store internals redesigned: all consumers receive `tx_store` explicitly through closures

### Fixed

- Weak test assertions (`assert %{} =`) replaced with strict equality checks

## [0.1.0-alpha.5] - 2026-03-20

Post-merge hardening of the persistence architecture from alpha.4. Shared
write primitives extracted, exception-driven JSON parsing replaced with
explicit error handling, and migration edge cases closed.

### Changed

- Extracted shared crash-safe file IO into `PersistenceIO` and key-index merge into `PersistenceHelpers`
- Replaced exception-driven `JSON.decode!` with explicit `JSON.decode` in compatibility backend

### Fixed

- Migration publish now uses backup-and-swap for both empty and existing targets
- Nil propagation in compatibility JSON decoders for malformed input
- Credo nesting depth violation in `read_data`

## [0.1.0-alpha.4] - 2026-03-19

Major persistence architecture overhaul. The library previously used a
generic Elixir term serializer on top of JSON — encoding atoms, structs,
and tuples with custom tags — which caused fresh-VM crashes, atom table
exhaustion risks, and ongoing allowlist maintenance. This release separates
persistence into two backends: a durable ETF-based native backend
(recommended) and a Baileys-compatible JSON backend rewritten with explicit
codecs. Also fixes several Elixir antipatterns across the codebase.

### Added

- `NativeFilePersistence` — durable ETF-based file backend with crash-safe writes, recommended for Elixir-first deployments
- `PersistenceMigration` — staged atomic migration from compatibility JSON to native format
- `PersistenceIO` — shared crash-safe file write primitives (temp + fsync + rename + dir fsync)
- Format versioning and manifest support for both persistence backends
- Cross-backend contract tests and fresh-VM regression tests for persistence decoding
- `Auth.Persistence` behaviour extended with context-aware optional callbacks

### Changed

- `FilePersistence` rewritten with explicit Baileys-shaped JSON codecs — no more generic tagged Elixir term serialization
- Docs and README recommend `NativeFilePersistence` as default for Elixir apps

### Fixed

- Atom table exhaustion risk from `String.to_atom` on untrusted disk data
- Flaky CI test from PBKDF2 timing — iteration count now injectable at socket startup
- Quadratic list appending in protobuf decoder, history sync, message sender, and other hot paths
- Nil-punning (`value && value.field`) replaced with pattern matching across feature modules
- Dialyzer and Credo strict warnings resolved

## [0.1.0-alpha.3] - 2026-03-19

### Changed

- Event emission no longer blocks callers on slow subscribers
- Protocol and connection logging demoted from warning to debug level
- Improved binary node encoding and decoding performance

### Fixed

- Programmer errors in Noise protocol functions are no longer silently swallowed
- Rust NIF error handling hardened to eliminate panic paths

## [0.1.0-alpha.2] - 2026-03-19

Initial alpha release.

### Added

- Connect to WhatsApp Web via the multi-device protocol with QR code or phone number pairing
- End-to-end encrypt all messages via a pure Elixir Signal Protocol implementation
- Send and receive 27+ message types: text, images, video, audio, documents, stickers, contacts, location, polls, reactions, forwards, edits, deletes, and more
- Upload and download encrypted media with AES-256-CBC and HKDF-derived keys
- Manage groups and communities: create, update, leave, add/remove/promote/demote participants, invite flows
- Subscribe to and manage newsletters
- Send presence updates and subscribe to contact presence
- Sync app state (archive, mute, pin, star, read) across linked devices via the Syncd protocol with LTHash integrity verification
- Fetch and manage business profiles, catalogs, collections, and orders
- Reject calls and create call links
- Manage privacy settings and blocklists
- Persist credentials to disk via `FilePersistence` with automatic reconnection
- Encode and send WAM analytics buffers for Baileys wire parity
- Emit telemetry events under the `[:baileys_ex]` prefix for connection, messaging, media, and NIF operations
- Noise Protocol transport encryption via `snow` Rust NIF
- XEdDSA signing via `curve25519-dalek` Rust NIF
- `:gen_statem` connection state machine with automatic reconnection
- ETS-backed concurrent signal key store
- Supervised process tree with `:rest_for_one` strategy
