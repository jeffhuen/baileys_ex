# Phase 14: Verified Parity Gaps

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the remaining verified parity gaps between BaileysEx and Baileys 7.00rc9 for socket/message flows and the release-facing socket facade.

**Architecture:** Measure parity by observable behavior, event payloads, send/receive semantics, wire-affecting config, and the top-level public facade for source-supported socket features. Do not treat JS socket method count as the target. If BaileysEx already produces the same behavior under different Elixir module boundaries, that is not a gap until package-facing facade parity matters.

**Tech Stack:** Elixir 1.19+/OTP 28, existing `Connection.*`, `Message.*`, `Feature.*`, `Media.*`, and WAProto modules, with Baileys 7.00rc9 reference in `dev/reference/Baileys-master/`.

**Status:** COMPLETE (2026-03-18)

---

## 1. Scope Rules

- This phase is source-driven. Use:
  - `dev/reference/Baileys-master/src/Utils/process-message.ts`
  - `dev/reference/Baileys-master/src/Utils/messages.ts`
  - `dev/reference/Baileys-master/src/Socket/messages-send.ts`
  - `dev/reference/Baileys-master/src/Socket/messages-recv.ts`
  - `dev/reference/Baileys-master/src/Socket/chats.ts`
  - `dev/reference/Baileys-master/src/Types/Events.ts`
  - `dev/reference/Baileys-master/src/Types/Socket.ts`
  - `dev/reference/Baileys-master/WAProto/WAProto.proto`
- A Baileys JS helper is not a gap if BaileysEx already implements the same behavior elsewhere.
- A missing top-level `BaileysEx.*` delegate is not a wire-behavior gap by itself, but it is now in scope when the underlying feature is already implemented and directly exposed by the Baileys socket surface.
- Do not re-open items already satisfied by existing code under different names.

---

## 2. Verified Equivalents

These were previously classified as missing, but the current codebase already covers the underlying behavior closely enough that they should not drive this phase as standalone tasks.

| Baileys Behavior | Current BaileysEx Equivalent | Notes |
|---|---|---|
| `waitForMessage` | `BaileysEx.Connection.Socket.query/3` | Pending-query registration and tagged reply delivery already provide the request/response wait behavior. |
| `updateServerTimeOffset` | `BaileysEx.Connection.Socket` maintains `server_time_offset_ms` | Offset is already updated from inbound node timestamps and used for unified-session timing. |
| `cleanDirtyBits` | `Connection.Coordinator`, `Feature.Group.handle_dirty_update/3`, `Feature.Community.handle_dirty_update/3` | Account-sync and groups dirty-bucket cleaning already exists; do not schedule a fresh implementation task for it. |
| `sendReceipts` / `readMessages` behavior | `BaileysEx.Message.Receipt.read_messages/4` and `send_receipt/6` | Bulk receipt aggregation already exists, even though the exported function name differs. |
| `sendPeerDataOperationMessage` | `BaileysEx.Message.PeerData.send_request/3` and `fetch_message_history/5` | The peer-data request transport already exists. |
| `pnFromLIDUSync` | Background PN->LID lookup in `Connection.Coordinator` | Signal repository already gets a PN->LID lookup callback backed by USync. |
| transport message acks | `Connection.Coordinator.build_transport_ack/2` and `send_notification_ack/2` | Message/receipt/notification ack behavior exists; do not treat `sendMessageAck` as completely absent. Remaining parity work is about edge semantics, not existence. |
| media retry request/apply primitives | `BaileysEx.Media.Retry.request_reupload/4`, `decode_notification_event/1`, `apply_media_update/3` | Building blocks exist; the missing piece is the composed helper equivalent to Baileys `updateMediaMessage`. |

---

## 3. Completed Work

### Gap A: Group stub side effects are incomplete

**Status:** Resolved in code and tests.

Baileys emits higher-level side effects from group stub messages in `Utils/process-message.ts`, including:

- `group-participants.update`
- `groups.update`
- `group.join-request`
- `chats.update` read-only flips when the current user is added/removed

BaileysEx now ports the shared stub-side-effect behavior through
`Message.StubSideEffects` and emits the corresponding higher-level events from
`Message.NotificationHandler`, including the Baileys-style `chats_update`
side effects for read-only flips, subject changes, and description changes.

### Gap B: Group sends lack `cachedGroupMetadata` / automatic participant resolution

**Status:** Resolved in code and tests.

BaileysEx `Message.Sender` now resolves group fanout in Baileys order: explicit
`group_participants:`, then `cached_group_metadata`, then live group metadata.
The cache contract accepts both Baileys-style bare maps and `{:ok, map}` tuples.

### Gap C: `limitSharing` send-message parity is missing, and local WAProto is not ready

**Status:** Resolved in code and tests.

BaileysEx now supports `limit_sharing` in `Message.Builder`, backed by the
minimal matching WAProto additions in `message_messages.ex`.

### Gap D: No composed helper equivalent to Baileys `updateMediaMessage`

**Status:** Resolved in code and tests.

Baileys `updateMediaMessage` does all of the following in one call:

1. Builds the media retry request
2. Sends it
3. Waits for the matching `messages.media-update` event
4. Decrypts the retry payload
5. Applies the refreshed `directPath` / `url`

BaileysEx now exposes the composed helper as `BaileysEx.update_media_message/3`
and emits `messages_update` after a successful refresh, matching Baileys'
observable output.

---

## 4. Deferred Work

These may still be worthwhile, but they are **not** current parity blockers for this phase.

- `wait_for_connection` convenience wrappers
- JS socket method-count parity
- Separate `sendReceipts` wrapper purely for naming parity
- Separate `sendMessageAck` task unless a concrete ack-semantics mismatch is demonstrated
- Raw WAProto coverage for `listMessage`, `orderMessage`, `interactiveMessage`, `albumMessage`, and `stickerPackMessage` beyond what is needed for current parity gaps. These types exist in WAProto, but they are not part of the Baileys rc9 `AnyMessageContent` builder in `src/Types/Message.ts` and `src/Utils/messages.ts`, so they are not source-verified send-message parity work right now.

---

## 5. Reopened Gap: Public Facade Surface Is Still Thinner Than Baileys rc9

**Status:** Resolved in code, tests, and release-facing docs.

The remaining verified gap is no longer on-the-wire behavior. It is the top-level
`BaileysEx` facade over source-supported socket methods that already exist in
lower-level Elixir feature modules.

This gap is now in scope because:

- the implementation already exists in `Feature.*` modules
- the package is being prepared for public release
- the current thin facade forces callers onto `queryable/1` for operations that Baileys exposes directly on the socket object

This slice must remain source-driven:

- use the pinned Baileys rc9 README and socket-layer return surfaces as the spec
- do not add wrappers for WAProto message types or helpers Baileys rc9 does not currently expose through its own content builder or socket surface
- preserve the current JS-vs-Elixir comparison matrix under `dev/parity/` for later reference

Resolved wrapper parity now includes:

- chat/app-state helpers backed by `Feature.Chat` and `Feature.AppState`
- user/profile/query helpers backed by `Feature.Profile`, `Feature.PhoneValidation`, and `Message.Receipt`
- call helpers backed by `Feature.Call`
- broader group/admin wrappers backed by `Feature.Group`
- broader privacy wrappers backed by `Feature.Privacy`
- broader business/newsletter/community wrappers backed by their existing feature modules

---

## 6. Implementation Tasks

### Task 1: Port shared group stub side effects from `process-message.ts`

**Files:**
- Create: `lib/baileys_ex/message/stub_side_effects.ex`
- Modify: `lib/baileys_ex/message/notification_handler.ex`
- Modify: `test/baileys_ex/message/notification_handler_test.exs`
- Create: `test/baileys_ex/message/stub_side_effects_test.exs`
- Reference: `dev/reference/Baileys-master/src/Utils/process-message.ts`
- Reference: `dev/reference/Baileys-master/src/Types/Events.ts`

**Required outcome:** group stub notifications produce the same higher-level side effects Baileys emits, not just synthetic stub messages.

- [x] **Step 1: Write focused failing reducer tests for stub-derived side effects**

Cover at least:
- participant `add`, `remove`, `promote`, `demote`, `modify`
- `GROUP_CHANGE_SUBJECT`
- `GROUP_CHANGE_DESCRIPTION`
- `GROUP_CHANGE_ANNOUNCE`
- `GROUP_CHANGE_RESTRICT`
- `GROUP_MEMBER_ADD_MODE`
- `GROUP_MEMBERSHIP_JOIN_APPROVAL_MODE`
- `GROUP_MEMBERSHIP_JOIN_APPROVAL_REQUEST_NON_ADMIN_ADD`
- chat `read_only` flips when the current user is removed/added

- [x] **Step 2: Run the new reducer tests and verify they fail**

Run: `mix test test/baileys_ex/message/stub_side_effects_test.exs`

Expected: FAIL because the reducer module does not exist yet.

- [x] **Step 3: Implement `BaileysEx.Message.StubSideEffects` as the single source of truth**

The reducer should accept a normalized stub message payload and return explicit side effects such as:
- `{:group_participants_update, payload}`
- `{:groups_update, payload}`
- `{:group_join_request, payload}`
- `{:chats_update, payload}`

Match Baileys semantics from `process-message.ts`, adapted to local snake_case atoms.

- [x] **Step 4: Call the reducer from `Message.NotificationHandler` before emitting the synthetic stub upsert**

Do not inline the mapping logic in `NotificationHandler`. Keep the translation reusable.

- [x] **Step 5: Add end-to-end notification-handler tests**

Verify that a `w:gp2` notification now emits both:
- the existing synthetic `messages_upsert`
- the higher-level side effects (`group_participants_update`, `groups_update`, etc.) when applicable

- [x] **Step 6: Run the affected test files**

Run: `mix test test/baileys_ex/message/stub_side_effects_test.exs test/baileys_ex/message/notification_handler_test.exs`

Expected: PASS

- [x] **Step 7: Commit**

```bash
git add lib/baileys_ex/message/stub_side_effects.ex lib/baileys_ex/message/notification_handler.ex test/baileys_ex/message/stub_side_effects_test.exs test/baileys_ex/message/notification_handler_test.exs
git commit -m "feat(message): port group stub side effects from baileys"
```

---

### Task 2: Add `cached_group_metadata` parity for group fanout

**Files:**
- Modify: `lib/baileys_ex/connection/config.ex`
- Modify: `lib/baileys_ex/connection/coordinator.ex`
- Modify: `lib/baileys_ex/message/sender.ex`
- Modify: `test/baileys_ex/message/sender_test.exs`
- Modify: `test/baileys_ex/public_api_test.exs`
- Reference: `dev/reference/Baileys-master/src/Socket/messages-send.ts`
- Reference: `dev/reference/Baileys-master/src/Types/Socket.ts`

**Required outcome:** group sends can resolve participants from cached metadata first, then fall back to live group metadata, while still allowing explicit `group_participants:` overrides.

- [x] **Step 1: Write failing sender tests for cached metadata resolution**

Cover:
- cached metadata function hit
- live metadata fallback when cache returns `nil`
- `use_cached_group_metadata: false` bypasses cache
- explicit `group_participants:` still wins

- [x] **Step 2: Run the sender tests and verify the new cases fail**

Run: `mix test test/baileys_ex/message/sender_test.exs`

Expected: FAIL on the new group metadata cases.

- [x] **Step 3: Add `:cached_group_metadata` to `Connection.Config`**

Default it to `nil`. Keep the option connection-scoped, matching Baileys config semantics.

- [x] **Step 4: Thread metadata callbacks into sender context**

`Connection.Coordinator.sender_context/2` should provide the sender with:
- a cached metadata callback when configured
- a live group-metadata fallback callback using the existing runtime socket

- [x] **Step 5: Teach `Message.Sender` group fanout to resolve participants automatically**

Resolution order:
1. explicit `group_participants:` opt
2. cached metadata, unless `use_cached_group_metadata: false`
3. live group metadata query

Use the resolved participant list to drive sender-key fanout.

- [x] **Step 6: Run the affected test files**

Run: `mix test test/baileys_ex/message/sender_test.exs test/baileys_ex/public_api_test.exs`

Expected: PASS

- [x] **Step 7: Commit**

```bash
git add lib/baileys_ex/connection/config.ex lib/baileys_ex/connection/coordinator.ex lib/baileys_ex/message/sender.ex test/baileys_ex/message/sender_test.exs test/baileys_ex/public_api_test.exs
git commit -m "feat(sender): add cached group metadata parity for group relay"
```

---

### Task 3: Restore `limitSharing` parity by first syncing the minimal proto surface

**Files:**
- Modify: `lib/baileys_ex/protocol/proto/message_messages.ex`
- Modify: `lib/baileys_ex/message/builder.ex`
- Modify: `test/baileys_ex/message/builder_test.exs`
- Modify: `test/baileys_ex/protocol/proto_test.exs`
- Reference: `dev/reference/Baileys-master/src/Utils/messages.ts`
- Reference: `dev/reference/Baileys-master/WAProto/WAProto.proto`

**Required outcome:** `Builder.build/2` can produce the same `ProtocolMessage(Type.LIMIT_SHARING)` payload Baileys generates.

- [x] **Step 1: Add failing proto and builder tests**

Cover:
- `ProtocolMessage` can encode/decode `LIMIT_SHARING`
- `Builder.build(%{limit_sharing: true}, ...)` emits the expected protocol payload
- injected timestamps are respected for deterministic tests

- [x] **Step 2: Run the proto and builder tests and verify failure**

Run: `mix test test/baileys_ex/protocol/proto_test.exs test/baileys_ex/message/builder_test.exs`

Expected: FAIL because the local proto surface lacks `LIMIT_SHARING`.

- [x] **Step 3: Port the minimal WAProto fields into `message_messages.ex`**

Add only the pieces needed for current parity:
- `Message.LimitSharing`
- `ProtocolMessage.Type.LIMIT_SHARING`
- `ProtocolMessage.limit_sharing`

Do not expand unrelated proto fields in this task.

- [x] **Step 4: Add the `limit_sharing` builder clause**

Match Baileys `Utils/messages.ts` semantics:
- `sharing_limited`
- trigger value `1`
- injected or current millisecond timestamp
- `initiated_by_me: true`

- [x] **Step 5: Re-run the affected tests**

Run: `mix test test/baileys_ex/protocol/proto_test.exs test/baileys_ex/message/builder_test.exs`

Expected: PASS

- [x] **Step 6: Commit**

```bash
git add lib/baileys_ex/protocol/proto/message_messages.ex lib/baileys_ex/message/builder.ex test/baileys_ex/protocol/proto_test.exs test/baileys_ex/message/builder_test.exs
git commit -m "feat(proto): add limit sharing message parity"
```

---

### Task 4: Add a composed `update_media_message` helper

**Files:**
- Modify: `lib/baileys_ex/media/retry.ex`
- Modify: `lib/baileys_ex.ex`
- Modify: `test/baileys_ex/media/retry_test.exs`
- Modify: `test/baileys_ex/public_api_test.exs`
- Reference: `dev/reference/Baileys-master/src/Socket/messages-send.ts`

**Required outcome:** callers can request a media reupload and receive an updated message in one operation, matching Baileys `updateMediaMessage` behavior.

- [x] **Step 1: Write failing tests for the composed helper**

Cover:
- successful request -> wait -> decrypt -> apply flow
- error result from `messages_media_update`
- timeout when no matching update arrives

- [x] **Step 2: Run the retry/public API tests and verify failure**

Run: `mix test test/baileys_ex/media/retry_test.exs test/baileys_ex/public_api_test.exs`

Expected: FAIL because there is no composed helper yet.

- [x] **Step 3: Extend `BaileysEx.Media.Retry` with the wait/apply orchestration**

The helper should:
1. build and send the retry request
2. subscribe or wait for the matching `:messages_media_update`
3. filter by message id
4. apply the refreshed media payload
5. return `{:ok, updated_message}` or `{:error, reason}`

- [x] **Step 4: Add a public facade method in `BaileysEx`**

Expose the connection-scoped helper so callers do not need to manually wire socket pid, `me_id`, and event emitter access.

- [x] **Step 5: Re-run the affected tests**

Run: `mix test test/baileys_ex/media/retry_test.exs test/baileys_ex/public_api_test.exs`

Expected: PASS

- [x] **Step 6: Commit**

```bash
git add lib/baileys_ex/media/retry.ex lib/baileys_ex.ex test/baileys_ex/media/retry_test.exs test/baileys_ex/public_api_test.exs
git commit -m "feat(media): add update media message helper parity"
```

---

### Task 5: Expand the top-level `BaileysEx` facade for remaining source-supported socket features

**Files:**
- Modify: `lib/baileys_ex.ex`
- Modify: `test/baileys_ex/public_api_test.exs`
- Create: `dev/parity/baileys-js-vs-baileys-ex-surface-matrix.md`
- Modify: `README.md`
- Reference: `dev/reference/Baileys-master/README.md`
- Reference: `dev/reference/Baileys-master/src/Socket/chats.ts`
- Reference: `dev/reference/Baileys-master/src/Socket/groups.ts`
- Reference: `dev/reference/Baileys-master/src/Socket/business.ts`
- Reference: `dev/reference/Baileys-master/src/Socket/newsletter.ts`
- Reference: `dev/reference/Baileys-master/src/Socket/communities.ts`

**Required outcome:** the top-level `BaileysEx` module exposes the remaining
source-supported socket helpers that already exist in lower-level feature modules,
and the current Baileys rc9 vs BaileysEx comparison is preserved under `dev/parity/`.

- [x] **Step 1: Write failing public API tests for the missing facade wrappers**

Cover at least:
- chat/app-state wrappers
- user/profile/query wrappers
- call wrappers
- expanded group wrappers
- expanded privacy wrappers
- expanded business wrappers
- expanded newsletter wrappers
- expanded community wrappers

- [x] **Step 2: Run the public API test file and verify the new cases fail**

Run: `mix test test/baileys_ex/public_api_test.exs`

Expected: FAIL on missing top-level wrapper functions.

- [x] **Step 3: Add the missing top-level `BaileysEx` wrapper functions**

Delegate through `with_queryable/2` to the existing feature modules. Keep the
public naming consistent with the current Elixir snake_case facade.

- [x] **Step 4: Save the Baileys rc9 vs BaileysEx support matrix in `dev/parity/`**

Record:
- confirmed non-gaps
- top-level facade coverage
- lower-level feature coverage
- remaining explicit deferrals, if any

- [x] **Step 5: Update the public README summary**

Reflect the expanded facade at a high level without turning the README into a
full API reference.

- [x] **Step 6: Run the affected tests**

Run: `mix test test/baileys_ex/public_api_test.exs`

Expected: PASS

- [x] **Step 7: Run the relevant broader suite**

Run: `mix test`

Expected: PASS

- [ ] **Step 8: Commit**

```bash
git add lib/baileys_ex.ex test/baileys_ex/public_api_test.exs dev/parity/baileys-js-vs-baileys-ex-surface-matrix.md README.md dev/implementation_plan/14-parity-gaps.md dev/implementation_plan/PROGRESS.md
git commit -m "feat(api): expand top-level facade parity"
```

---

## 7. Exit Criteria

This phase is complete when all of the following are true:

- Group stub notifications emit the same higher-level side effects Baileys emits from `process-message.ts`
- Group sends no longer require callers to hand-supply `group_participants:` in the common case
- `limit_sharing` is supported with the correct proto shape
- A composed `update_media_message` helper exists and is covered by tests
- The top-level `BaileysEx` facade covers the remaining source-supported socket helpers that are already implemented in lower-level feature modules
- The phase file remains aligned with actual source-backed gaps rather than JS method-count parity or unsupported WAProto message types

---

## 8. Notes for Future Phases

- If raw WAProto coverage is later expanded, revisit `listMessage`, `orderMessage`, `interactiveMessage`, `albumMessage`, and `stickerPackMessage` as a **proto parity** phase, not as a fake `send_message` builder parity task unless Baileys rc9 actually exposes them.
- Keep `dev/parity/baileys-js-vs-baileys-ex-surface-matrix.md` current when new source-backed parity questions come up.
