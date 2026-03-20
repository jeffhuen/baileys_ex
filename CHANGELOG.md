# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Common Changelog](https://common-changelog.org/).

## [0.1.0-alpha.5] - 2026-03-20

### Added

- Durable native file persistence backend, recommended for Elixir apps
- Migration tooling from Baileys-compatible JSON to native persistence
- Format versioning for persisted auth state

### Changed

- Compatibility JSON persistence rewritten with explicit Baileys-shaped codecs
- Docs and README recommend native persistence as default

### Fixed

- Auth state loading could crash in a fresh VM due to atom reconstruction
- Flaky CI from PBKDF2 timing sensitivity in pairing tests
- Quadratic list operations in message encoding hot paths
- Malformed persistence files now fail clearly instead of crashing

## [0.1.0-alpha.3] - 2026-03-19

### Changed

- Event emission no longer blocks callers on slow subscribers
- Protocol and connection logging demoted from warning to debug level

### Fixed

- Noise protocol errors are no longer silently swallowed
- Rust NIF error handling hardened to eliminate panic paths

## [0.1.0-alpha.2] - 2026-03-19

Initial alpha release.

### Added

- Connect to WhatsApp Web via multi-device protocol with QR or phone pairing
- End-to-end encryption via pure Elixir Signal Protocol implementation
- Send and receive text, media, stickers, contacts, location, polls, reactions, and more
- Encrypted media upload and download
- Group and community management
- Newsletter subscriptions
- Presence updates and privacy settings
- App state sync across linked devices
- Business profiles and catalogs
- File-based credential persistence with automatic reconnection
- Telemetry events for observability
