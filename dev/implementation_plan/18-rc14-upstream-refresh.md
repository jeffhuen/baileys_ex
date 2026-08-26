# Phase 18: Baileys rc14 Upstream Refresh

**Goal:** Retarget the project from Baileys v7.0.0-rc13 to
Baileys v7.0.0-rc14 and port every observable runtime delta in the official
`v7.0.0-rc13...v7.0.0-rc14` comparison.

**Reference:** Official WhiskeySockets/Baileys tags `v7.0.0-rc13` and
`v7.0.0-rc14` (tag commit `7e7b075`).

## Current Findings

- rc14 contains eight commits and fourteen changed upstream files. The runtime
  delta is bounded to the default WhatsApp Web version, query-side trusted-contact
  token encoding/profile-picture placement, and experimental Android client
  payload support.
- Query-side `tctoken` nodes now require the stored timestamp as a string `t`
  attribute. Missing timestamps make otherwise-present tokens unusable and trigger
  the same cleanup path as expired tokens.
- Profile-picture queries nest the query-side `tctoken` inside `picture`. They only
  include it for non-self PN/LID user JIDs while the server property gate is enabled.
- Presence subscriptions use the same timestamped query-side TC-token builder.
- Direct message relay is a separate upstream callsite. Its `tctoken` node keeps
  empty attributes, so the Elixir API must keep separate query and relay builders.
- Android is selected when the browser tuple's second element contains `android`
  case-insensitively. Android client payloads use user-agent platform `ANDROID`,
  omit `webInfo`, register as `ANDROID_PHONE`, and emit the upstream experimental
  warning.
- The `Long` type-only import and release workflow changes have no Elixir runtime
  equivalent. The pinned reference tree still updates to the exact official tag.

## Tasks

- [x] 18.1 Pin `dev/reference/Baileys-master/` to the exact official rc14 source
  and record the source-backed delta audit.
- [x] 18.2 Update the default WhatsApp Web version to
  `[2, 3000, 1_043_857_760]` and synchronize user/project documentation.
- [x] 18.3 Add timestamped query TC-token construction, missing-timestamp cleanup,
  profile-picture nesting/eligibility, and presence query coverage while preserving
  direct relay wire behavior.
- [x] 18.4 Add Android browser construction/detection, login and registration
  payload semantics, and the experimental connection warning.
- [x] 18.5 Update the parity matrix, phase trackers, and rc14 target references.
- [x] 18.6 Run focused parity checks and all delivery gates, then complete
  independent Elixir, test, and parity/security reviews.

## Acceptance Criteria

- [x] Project-level docs name Baileys v7.0.0-rc14 as the authoritative target.
- [x] Every upstream-tracked file in `dev/reference/Baileys-master/` exactly
  matches the official rc14 tag. Generated `node_modules/`, `lib/`, and
  `bun.lock` outputs are excluded from that comparison.
- [x] Query-side TC tokens contain `attrs: %{"t" => Integer.to_string(timestamp)}`;
  a token without a timestamp is cleaned and not emitted.
- [x] Profile-picture TC tokens are nested under `picture`, are omitted for self and
  non-user JIDs, and respect the rc14 server-property default/gate.
- [x] Presence subscription TC tokens use the timestamped query shape.
- [x] Direct message-relay TC tokens retain empty attributes.
- [x] Android login payloads use platform `ANDROID` and omit `web_info`; Android
  registration payloads use `ANDROID_PHONE` device props.
- [x] Android selection is case-insensitive and emits the upstream experimental
  warning when a socket starts.
- [x] Focused tests, the full suite, parity scripts, compile, format, Credo,
  Dialyzer, and docs all pass.

## Files

| File | Status |
|------|--------|
| `AGENTS.md` | ✅ |
| `CLAUDE.md` | ✅ |
| `README.md` | ✅ |
| `CHANGELOG.md` | ✅ |
| `dev/implementation_plan/00-overview.md` | ✅ |
| `dev/implementation_plan/CLAUDE.md` | ✅ |
| `dev/implementation_plan/PROGRESS.md` | ✅ |
| `dev/implementation_plan/18-rc14-upstream-refresh.md` | ✅ |
| `dev/parity/baileys-js-vs-baileys-ex-surface-matrix.md` | ✅ |
| `dev/reference/Baileys-master/` | ✅ |
| `dev/tools/run_baileys_reference.mts` | ✅ |
| `user_docs/reference/configuration.md` | ✅ |
| `lib/baileys_ex.ex` | ✅ |
| `lib/baileys_ex/auth/connection_validator.ex` | ✅ |
| `lib/baileys_ex/connection/config.ex` | ✅ |
| `lib/baileys_ex/connection/frame.ex` | ✅ |
| `lib/baileys_ex/connection/socket.ex` | ✅ |
| `lib/baileys_ex/crypto.ex` | ✅ |
| `lib/baileys_ex/feature/presence.ex` | ✅ |
| `lib/baileys_ex/feature/profile.ex` | ✅ |
| `lib/baileys_ex/feature/tc_token.ex` | ✅ |
| `lib/baileys_ex/media/crypto.ex` | ✅ |
| `lib/baileys_ex/media/download.ex` | ✅ |
| `lib/baileys_ex/media/thumbnail.ex` | ✅ |
| `lib/baileys_ex/message/receiver.ex` | ✅ |
| `lib/baileys_ex/protocol/binary_node.ex` | ✅ |
| `lib/baileys_ex/protocol/noise.ex` | ✅ |
| `lib/baileys_ex/protocol/proto/noise_messages.ex` | ✅ |
| `lib/baileys_ex/signal/group/sender_key_message.ex` | ✅ |
| `lib/baileys_ex/signal/session_cipher.ex` | ✅ |
| `lib/baileys_ex/signal/whisper_message.ex` | ✅ |
| `test/baileys_ex/auth/connection_validator_test.exs` | ✅ |
| `test/baileys_ex/connection/config_test.exs` | ✅ |
| `test/baileys_ex/connection/socket_test.exs` | ✅ |
| `test/baileys_ex/connection/transport/mint_web_socket_test.exs` | ✅ |
| `test/baileys_ex/connection/version_test.exs` | ✅ |
| `test/baileys_ex/feature/presence_test.exs` | ✅ |
| `test/baileys_ex/feature/profile_test.exs` | ✅ |
| `test/baileys_ex/feature/tc_token_test.exs` | ✅ |
| `test/baileys_ex/media/crypto_test.exs` | ✅ |
| `test/baileys_ex/media/download_test.exs` | ✅ |
| `test/baileys_ex/message/sender_test.exs` | ✅ |
| `test/baileys_ex/native/noise_test.exs` | ✅ |
| `test/baileys_ex/parity/feature_test.exs` | ✅ |
| `test/baileys_ex/protocol/noise_test.exs` | ✅ |
| `test/baileys_ex/public_api_test.exs` | ✅ |
| `test/baileys_ex/signal/whisper_message_test.exs` | ✅ |

## Plan Deviations

- The required `mix compile --warnings-as-errors` gate runs under Elixir 1.20.3
  in this workspace and exposed already-bound bitstring-size variables plus six
  unreachable/redundant branches in pre-existing code. Phase 18 includes the
  behavior-preserving pins and dead-clause cleanups needed to keep the compiler
  gate green; focused regression tests cover every touched runtime module.
- The full suite exposed a monitor-attachment race in the native Noise resource
  cleanup test. Replacing `spawn` plus a later `Process.monitor/1` with atomic
  `spawn_monitor/1` removes the race without changing production behavior.
- The ignored reference directory retains generated dependency/build outputs
  needed by parity tooling. Reference verification therefore compares all 196
  upstream-tracked files byte-for-byte rather than claiming the whole working
  directory contains no generated extras.
