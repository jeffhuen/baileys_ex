# Baileys rc13 vs BaileysEx Surface Matrix

Current comparison reference target for Baileys v7.0.0-rc13 source in
`dev/reference/Baileys-master/`.

Purpose:

- keep the current Baileys JS vs BaileysEx support comparison in one place
- distinguish true source-backed gaps from false positives
- track top-level facade parity separately from lower-level implementation parity

Updated: 2026-06-02

Note: this matrix was originally closed against rc9 in Phase 14. Phase 17 now
records the rc10-rc13 delta audit against the rc13 reference source.

---

## Phase 17 rc10-rc13 Classification

The rc10 release candidate is not just internal hardening. The bounded deltas
ported in Phase 17 include compatibility-affecting behavior:

| Category | BaileysEx status | User-visible impact |
|---|---|---|
| Linked-device QR format and WA version | Ported | Pairing QR payloads and advertised Web version match rc13. |
| Trusted-contact token lifecycle | Ported | Direct sends attach/issue tokens like Baileys, peer messages skip rejected `tctoken` nodes, identity changes reissue tokens, and sender timestamps survive persistence/notification updates. |
| Unavailable-message resend and retry | Ported | Missing 1:1 messages can request phone-device resend and emit Baileys-shaped placeholder stubs. |
| 463/reachout/new-chat-limit handling | Ported | Account restriction and message-cap events are queryable and emitted to callers. |
| Device-list notifications | Ported | Device add/remove/update notifications update cached device state and remove stale sessions. |
| USync username, group usernames, group online count | Ported | Parsed contact/group/presence payloads expose the newer fields. |
| Album messages and group `@all` mentions | Ported | Outbound message builders can produce the newer WAProto shapes. |
| Newsletter v2 and MEX notifications | Ported | Newsletter join/leave and rc10 notification payloads are handled. |
| Media direct-path fallback | Ported | Downloads retry compatible CDN host variants when WhatsApp returns a direct path that does not fetch. |
| Baileys JS mutex/cache/test-infra changes | Elixir-native / not literal | These are runtime hardening details; BaileysEx preserves observable behavior using BEAM-native primitives rather than copying JS internals. |
| App-state resilience and offline batching | Ported | Missing-key syncs retry with forced snapshots before parking, parked collections resync on key arrival, corrupted mutation records are skipped, aggregate LTHash mismatches preserve partial state or stop remaining patches, and offline nodes drain FIFO in batches of 10 with event buffering. |

## rc10 Source-Backed Callsite Audit

| Upstream area | Baileys rc10-rc13 source | BaileysEx classification |
|---|---|---|
| Version and linked-device QR | `src/Defaults/index.ts`, `src/Socket/socket.ts`, auth helpers | Ported in config defaults, QR helpers, socket pairing tests. |
| Message receive self-stanzas | `src/Utils/decode-wa-message.ts`, `src/Utils/process-message.ts` | Ported for rc12 self-only guards and rc13 peer-routed `from_me` recovery. |
| Unavailable-message resend | `src/Socket/messages-recv.ts`, retry manager helpers | Ported with placeholder stubs, phone-device requests, retry-code mapping, and safety skips. |
| App-state sync resilience | `src/Utils/chat-utils.ts`, `src/Utils/sync-action-utils.ts`, `src/Socket/chats.ts` | Ported in `Syncd.Codec`, `Feature.AppState`, `ActionMapper`, and coordinator blocked-collection retry. |
| Offline notification batching | `src/Utils/offline-node-processor.ts` | Ported with caller-owned FIFO queue, batch size 10, event buffering, and focused tests. |
| TC token lifecycle | `src/Utils/tc-token-utils.ts`, send/presence/profile callsites | Ported for store/update/expiry, post-send issuance, identity-change reissue, sender timestamp, and peer-message exclusions. |
| Device list and LID/PN mappings | `src/Signal/lid-mapping.ts`, notifications, history/contact/mex sources | Ported for notification add/remove/update, contact/history/MEX mapping ingestion, and stale session cleanup. |
| USync username and interop | `src/WAUSync/*`, JID/type updates | Ported for username query parsing and newer LID/PN result fields. |
| Groups/newsletters/business/account helpers | `src/Socket/groups.ts`, `newsletter.ts`, `business.ts`, `chats.ts` | Ported for group usernames, group online count, newsletter v2 join/leave, multi-child newsletter notifications, and WMex account limit helpers. |
| Media upload/download handling | `src/Utils/messages-media.ts` | Ported where observable to callers: direct-path CDN fallback and upload dispatch compatibility through project-owned media modules. Node-specific fetch dispatcher details are not applicable. |
| WABinary child lookup cache | `src/WABinary/generic-utils.ts` | Elixir-native/not literal. Observable child lookup results match; WeakMap caching is a JS memory/performance detail. |
| Mutex redesign | `src/Utils/make-mutex.ts`, transaction callsites | Elixir-native. Signal/app-state serialization uses supervised BEAM tasks and explicit store transactions, not JS mutex objects. |
| Release/test infrastructure | `*.test.ts`, e2e workflow, AGENTS/SECURITY docs | Not runtime API parity. Project docs and test coverage were updated where they affect BaileysEx behavior. |
| Existing primitive parity fixtures | `test/fixtures/parity/{signal,media,syncd,wam}/baileys_rc9.json` | Audited unchanged for rc13-covered primitive vectors: Signal fixture is library boundary data, media HKDF/AES vectors are unchanged, Syncd HKDF/MAC/protobuf vectors still match, and WAM definitions are unchanged for covered tests. No behavior-changing rc13 fixture regeneration was required. |

---

## Confirmed Non-Gaps

These were easy to overstate, but they are **not** current source-backed parity gaps.

| Topic | Current conclusion |
|---|---|
| `buttonsMessage`, `listMessage`, `interactiveMessage`, `orderMessage`, `albumMessage`, `stickerPackMessage` outbound builder support | These message types exist in WAProto. Re-check their current `AnyMessageContent` and builder status during the Phase 17 rc13 surface audit before treating them as gaps. |
| `waitForMessage`, dirty-bit cleanup, bulk receipts, PN->LID lookup, transport acks | Already covered elsewhere in BaileysEx and should not be reopened as standalone gaps without a demonstrated behavior mismatch. |

---

## Area Matrix

Legend:

- `Yes` = top-level `BaileysEx` facade already covers the source surface at a useful level
- `Partial` = lower-level implementation exists, but top-level facade is thinner
- `No` = not currently implemented in lower-level modules

| Area | Baileys JS socket | BaileysEx top-level | BaileysEx lower-level | Current note |
|---|---|---|---|---|
| Connection/auth/session | Yes | Yes | Yes | QR, pairing code, auth persistence, version helpers, cached group metadata are exposed. |
| Events/runtime | Yes | Yes | Yes | Public subscribe helpers and raw event emitter access are exposed. |
| Core messaging/media | Yes | Yes | Yes | Text/media send, status send, media download, media refresh are exposed. |
| Chat/app-state helpers | Yes | Yes | Yes | Top-level facade now exposes the current source-backed chat/app-state helper set. |
| User/profile/query helpers | Yes | Yes | Yes | `on_whatsapp`, status fetch, business profile, profile mutations, and read receipts are exposed. |
| Call helpers | Yes | Yes | Yes | `reject_call` and `create_call_link` are exposed on the top-level facade. |
| Groups | Yes | Yes | Yes | The broader group admin/invite/participant/settings surface is exposed. |
| Privacy | Yes | Yes | Yes | The current privacy mutation/query surface is exposed on the top-level facade. |
| Business/catalog | Yes | Yes | Yes | Catalog, collections, product, and order helpers are exposed. |
| Newsletters/channels | Yes | Yes | Yes | The broader newsletter management/query surface is exposed. |
| Communities | Yes | Yes | Yes | The broader community management/query surface is exposed. |
| Vision/OCR/STT/video understanding | No | No | No | Baileys is a WhatsApp protocol client, not a multimodal AI layer. |

---

## Phase 14 Closure

The remaining release-facing facade gap tracked in Phase 14 is closed.

Implemented top-level wrapper families:

- Chat/App State: `archive_chat`, `mute_chat`, `pin_chat`, `star_messages`, `mark_chat_read`, `clear_chat`, `delete_chat`, `delete_message_for_me`, `read_messages`, `update_link_previews_privacy`
- User/Profile/Queries: `on_whatsapp`, `fetch_status`, `business_profile`, `update_profile_name`, `update_profile_picture`, `remove_profile_picture`
- Calls: `reject_call`, `create_call_link`
- Groups: participant/admin/invite/approval/settings/fetch wrappers across the current `Feature.Group` surface
- Privacy: blocklist plus the current privacy mutation set
- Business: cover photo, collections, product, and order wrappers
- Newsletters: create/update/delete/query/mute/react/owner-management wrappers
- Communities: subgroup/link/participant/invite/approval/settings/fetch wrappers across the current `Feature.Community` surface

Notes:

- This matrix tracks socket-surface parity, not raw WAProto breadth.
- A few Elixir wrappers accept optional keyword opts for runtime wiring even where the JS method is a fixed-arity helper; the source of truth remains the observable socket behavior and returned payloads.
