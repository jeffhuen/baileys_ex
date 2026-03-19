# Changelog

## [0.1.0-alpha.1] - 2025-XX-XX

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
