# Changelog

## [0.1.0-alpha.6] - 2026-03-20

### Added

- `Signal.Store.transaction/3` now passes explicit transaction handles — no more hidden process dictionary state
- `TransactionBuffer` module extracts reusable ETS-based transaction caching

### Changed

- Signal store internals redesigned: all consumers receive `tx_store` explicitly through closures

### Fixed

- Weak test assertions (`assert %{} =`) replaced with strict equality checks

## [0.1.0-alpha.5] - 2026-03-20

### Changed

- Extracted shared crash-safe file IO into `PersistenceIO` and key-index merge into `PersistenceHelpers`
- Replaced exception-driven `JSON.decode!` with explicit `JSON.decode` in compatibility backend

### Fixed

- Migration publish now uses backup-and-swap for both empty and existing targets
- Nil propagation in compatibility JSON decoders for malformed input
- Credo nesting depth violation in `read_data`

## [0.1.0-alpha.4] - 2026-03-19

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
