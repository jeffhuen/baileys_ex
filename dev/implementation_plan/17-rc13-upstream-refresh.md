# Phase 17: Baileys rc13 Upstream Refresh

**Goal:** Retarget the project from Baileys rc9 to Baileys v7.0.0-rc13, port the
latest release-candidate fixes, and audit the larger rc10 surface without hiding
unfinished parity work.

**Reference:** Official WhiskeySockets/Baileys tags `v7.0.0-rc.9`,
`v7.0.0-rc10`, `v7.0.0-rc12`, and `v7.0.0-rc13`.

## Current Findings

- rc10 is the large delta from rc9. It touches socket send/receive, retries,
  app-state resilience, TC tokens, LID mappings, newsletters, groups, WABinary,
  USync, and many tests.
- rc10 includes compatibility-affecting protocol behavior. It is not only
  internal plumbing: QR pairing, trusted-contact tokens, unavailable-message
  resend, bad-ack handling, device-list updates, album sends, `@all` mentions,
  USync username data, WMex account limits, and MEX notifications can all change
  what callers observe or what WhatsApp receives.
- rc12 adds the security-relevant protocolMessage guard for self-only protocol
  messages and two small runtime fixes: media upload dispatcher handling in
  Node fetch and `PresenceData.groupOnlineCount`.
- rc13 fixes the follow-on regression by marking peer-routed self stanzas as
  `fromMe` even when WhatsApp omits the `recipient` attribute.
- JS-only implementation details such as WeakMap child caches, Node fetch
  dispatchers, and Baileys' exact mutex implementation are not copied literally;
  BaileysEx ports the observable behavior with BEAM-native modules, supervised
  tasks, ETS-backed stores, and explicit callback boundaries.
- The remaining rc10 app-state stability changes are now ported: missing-key
  syncs retry once with a forced snapshot before parking, parked collections
  resync when an app-state key arrives, corrupted mutation records are skipped
  without poisoning the whole sync pass, snapshot MAC mismatch keeps partial
  state, and patch LTHash mismatch stops the remaining patch sequence.
- Offline node batching was audited against `offline-node-processor.ts`.
  BaileysEx keeps the queue caller-owned instead of process-owned, drains in
  batches of 10, preserves FIFO order, buffers emitted events while backlog
  remains, and flushes once drained.

## Tasks

- [x] 17.1 Compare official rc9/rc10/rc12/rc13 source tags and identify the
  source-backed latest-fix set.
- [x] 17.2 Port rc12/rc13 message receive fixes:
  - self-only protocolMessage side effects are ignored unless `from_me` is true
  - peer-routed self stanzas without `recipient` decode as `from_me: true`
  - presence updates parse `count` into `group_online_count`
- [x] 17.3 Replace or repin `dev/reference/Baileys-master/` so local reference
  source actually matches the rc13 target instead of package rc.9.
- [x] 17.4 Audit rc10 source deltas by callsite and classify each as already
  covered, missing, not applicable to Elixir, or blocked.
- [x] 17.4a Port rc10-rc13 bounded observable deltas identified in this pass:
  - linked-device QR pairing format and rc13 default WhatsApp Web version
  - direct-path media download host fallback
  - unknown retry-code mapping and base-key retry cache helpers
  - unavailable-message placeholder resend and phone-device requests
  - bad-ack 463 account-restriction updates and reachout timelock WMex fetch
  - device-list add/remove/update notification handling
  - trusted-contact token storage, post-send issuance, identity-change reissue,
    expiry cleanup, and sender timestamp preservation
  - peer-message `tctoken` exclusion
  - USync username parsing
  - album messages and group `@all` mentions
  - group online counts and group participant usernames
  - newsletter v2 join/leave and multi-child notification handling
  - MEX reachout timelock, message-capping, linked-profile, and LID mapping
    notifications
- [x] 17.5 Regenerate parity fixtures that are still explicitly rc9-based where
  the corresponding upstream behavior changed.
- [x] 17.6 Finish source-backed rc10 audit for app-state resilience/offline
  batching surfaces and any fixture-backed behavior that changed outside the
  bounded deltas above.

## Acceptance Criteria

- [x] Project-level docs name Baileys v7.0.0-rc13 as the target reference.
- [x] rc12 self-only protocolMessage guard is covered by a regression test.
- [x] rc13 peer-routed self-stanza decoding is covered by a regression test.
- [x] rc12 group online presence count parsing is covered by a regression test.
- [x] `dev/reference/Baileys-master/` describes or contains the rc13 target source.
- [x] The bounded rc10-rc13 ported deltas above are covered by focused tests.
- [x] The remaining rc10 delta audit is recorded in `dev/parity/` with a concrete
  owner for every source-backed gap.
- [x] Any changed wire/parity fixtures are regenerated from rc13 and committed,
  or audited as unchanged primitive vectors that still match rc13 behavior.

## Files

| File | Status |
|------|--------|
| `AGENTS.md` | ✅ |
| `CLAUDE.md` | ✅ |
| `README.md` | ✅ |
| `dev/implementation_plan/00-overview.md` | ✅ |
| `dev/implementation_plan/CLAUDE.md` | ✅ |
| `dev/implementation_plan/PROGRESS.md` | ✅ |
| `dev/implementation_plan/17-rc13-upstream-refresh.md` | ✅ |
| `dev/parity/baileys-js-vs-baileys-ex-surface-matrix.md` | ✅ |
| `dev/reference/Baileys-master/` | ✅ |
| `lib/baileys_ex/message/decode.ex` | ✅ |
| `lib/baileys_ex/message/receiver.ex` | ✅ |
| `lib/baileys_ex/feature/presence.ex` | ✅ |
| `lib/baileys_ex/feature/account.ex` | ✅ |
| `lib/baileys_ex/feature/tc_token.ex` | ✅ |
| `lib/baileys_ex/message/sender.ex` | ✅ |
| `lib/baileys_ex/message/notification_handler.ex` | ✅ |
| `lib/baileys_ex/message/retry.ex` | ✅ |
| `lib/baileys_ex/media/download.ex` | ✅ |
| `lib/baileys_ex/protocol/usync.ex` | ✅ |
| `lib/baileys_ex/syncd/codec.ex` | ✅ |
| `lib/baileys_ex/feature/app_state.ex` | ✅ |
| `lib/baileys_ex/message/offline_queue.ex` | ✅ |
| `lib/baileys_ex/connection/coordinator.ex` | ✅ |
| `test/baileys_ex/message/decode_test.exs` | ✅ |
| `test/baileys_ex/message/receiver_test.exs` | ✅ |
| `test/baileys_ex/feature/presence_test.exs` | ✅ |
| `test/baileys_ex/feature/account_test.exs` | ✅ |
| `test/baileys_ex/feature/tc_token_test.exs` | ✅ |
| `test/baileys_ex/message/sender_test.exs` | ✅ |
| `test/baileys_ex/message/notification_handler_test.exs` | ✅ |
| `test/baileys_ex/message/retry_test.exs` | ✅ |
| `test/baileys_ex/media/download_test.exs` | ✅ |
| `test/baileys_ex/protocol/usync_test.exs` | ✅ |
| `test/baileys_ex/syncd/codec_test.exs` | ✅ |
| `test/baileys_ex/syncd/runtime_test.exs` | ✅ |
| `test/baileys_ex/message/offline_queue_test.exs` | ✅ |
| `test/baileys_ex/connection/supervisor_test.exs` | ✅ |
