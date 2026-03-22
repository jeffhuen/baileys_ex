# DRY Audit

> Last updated: 2026-03-21
> Scope: handwritten Elixir code only. Generated protobuf modules and intentionally repeated protocol definitions are out of scope for this audit.

This file tracks duplicate logic clusters discovered during Gate 6 reviews so the
cleanup work is visible in-repo instead of being stranded in terminal history.

## Completed In This Slice

- [x] Extract lock lifecycle orchestration shared by the built-in Signal stores.
  - Shared helper: `lib/baileys_ex/signal/store/lock_manager.ex`
  - Callsites updated:
    - `lib/baileys_ex/signal/store/memory.ex`
    - `lib/baileys_ex/auth/key_store.ex`
  - Verification:
    - `test/baileys_ex/signal/store_test.exs`
    - `test/baileys_ex/auth/key_store_test.exs`

- [x] Extract Signal public-key normalization shared by session builder/cipher flows.
  - Shared helper: `lib/baileys_ex/signal/curve.ex`
  - Callsites updated:
    - `lib/baileys_ex/signal/session_builder.ex`
    - `lib/baileys_ex/signal/session_cipher.ex`
  - Verification:
    - `test/baileys_ex/signal/curve_test.exs`
    - `test/baileys_ex/signal/session_builder_test.exs`
    - `test/baileys_ex/signal/session_cipher_test.exs`

## Remaining High-Value Clusters

- [x] Feature transport adapter wrappers — extracted to `Connection.TransportAdapter` (alpha.7).
  - Representative callsites:
    - `lib/baileys_ex/feature/business.ex`
    - `lib/baileys_ex/feature/bot_directory.ex`
    - `lib/baileys_ex/feature/call.ex`
    - `lib/baileys_ex/feature/community.ex`
    - `lib/baileys_ex/feature/group.ex`
    - `lib/baileys_ex/feature/newsletter.ex`
    - `lib/baileys_ex/feature/phone_validation.ex`
    - `lib/baileys_ex/feature/presence.ex`
    - `lib/baileys_ex/feature/privacy.ex`
    - `lib/baileys_ex/feature/profile.ex`
    - `lib/baileys_ex/feature/tc_token.ex`
    - `lib/baileys_ex/media/upload.ex`

- [ ] Manifest/index persistence helpers are still mirrored between the compatibility and native auth backends.
  - Representative files:
    - `lib/baileys_ex/auth/file_persistence.ex`
    - `lib/baileys_ex/auth/native_file_persistence.ex`

- [ ] The built-in store transaction shell is still duplicated between the in-memory and persistence-backed stores.
  - Representative files:
    - `lib/baileys_ex/signal/store/memory.ex`
    - `lib/baileys_ex/auth/key_store.ex`

- [ ] Smaller utility clones remain and should be folded into existing shared boundaries when adjacent work touches them.
  - `merge_maps/2`
    - `lib/baileys_ex/auth/state.ex`
    - `lib/baileys_ex/connection/socket.ex`
  - Signal-store wrapping helper
    - `lib/baileys_ex/connection/coordinator.ex`
    - `lib/baileys_ex/connection/socket.ex`

## Notes

- Treat this as a working audit backlog, not a mandate to refactor all duplicates at once.
- Preference order for the next DRY slice:
  1. Feature transport adapter wrappers
  2. Shared auth persistence manifest/index helpers
  3. Shared transaction harness for built-in stores
