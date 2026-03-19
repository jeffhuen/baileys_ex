# Baileys rc9 vs BaileysEx Surface Matrix

Current comparison reference for the pinned Baileys 7.00rc9 source in
`dev/reference/Baileys-master/`.

Purpose:

- keep the current Baileys JS vs BaileysEx support comparison in one place
- distinguish true source-backed gaps from false positives
- track top-level facade parity separately from lower-level implementation parity

Updated: 2026-03-18

---

## Confirmed Non-Gaps

These were easy to overstate, but they are **not** current source-backed parity gaps.

| Topic | Current conclusion |
|---|---|
| `buttonsMessage`, `listMessage`, `interactiveMessage`, `orderMessage`, `albumMessage`, `stickerPackMessage` outbound builder support | These message types exist in WAProto, but they are not part of Baileys rc9 `AnyMessageContent` generation in `src/Types/Message.ts` and `src/Utils/messages.ts`. They are not current `sendMessage` parity work. |
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
| Vision/OCR/STT/video understanding | No | No | No | Baileys rc9 is a WhatsApp protocol client, not a multimodal AI layer. |

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
