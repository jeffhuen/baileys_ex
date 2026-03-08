# Gap Analysis: BaileysEx Plan vs Baileys Source

**Date:** 2026-03-07
**Method:** Every exported function across all 8 Baileys socket layers, 27 utility files,
and type definitions audited against our 12 implementation phase documents.
**Updated:** 2026-03-08 — Added GAP-36 through GAP-43 from line-by-line Socket layer audit.

**Rule:** Implementation approach (pure Elixir Signal, `:crypto`, etc.) can differ.
Behavioral outputs and feature surface area must be 1:1.

---

## CRITICAL GAPS (would break core functionality)

### GAP-01: LID/PN Dual Addressing Mode [RESOLVED IN PLAN]
**Baileys:** Every message, group, and query handles two addressing modes — LID
(Logical Device ID) and PN (Phone Number). `addressingMode` field on groups,
`senderAlt`/`recipientAlt` extraction, LID↔PN mapping storage and lookup,
`pnFromLIDUSync()` for mapping, `getDecryptionJid()` for routing.

**Source detail (from audit):**
- `messages-recv.ts` L1200-1218: On every inbound message, checks for `participantAlt`/`remoteJidAlt`, stores LID↔PN mapping via `signalRepository.lidMapping.storeLIDPNMappings()`, then calls `signalRepository.migrateSession()` to copy sessions across identities.
- `messages-send.ts` L800-862: In 1:1 relay, selects `ownId = meLid` or `meId` based on whether the conversation target is `@lid` or `@s.whatsapp.net`. Group relay uses `groupAddressingMode` field (`'lid'` default) to pick `groupSenderIdentity`.
- `groups.ts` L325: `extractGroupMetadata()` reads `addressing_mode` attr and maps to `WAMessageAddressingMode.LID` or `.PN`.
- `socket.ts` L944-969: On login success, stores own LID↔PN mapping and migrates own session.
- JID utilities: `isLidUser()`, `isPnUser()`, `isHostedLidUser()`, `isHostedPnUser()` are used pervasively across all layers.

**Our plan:** Not mentioned anywhere. JID handling in Phase 3 covers `user@server`
but doesn't distinguish LID vs PN addressing or handle the dual-address mapping.

**Impact:** Messages would fail to decrypt in multi-device scenarios. Group
participant resolution would break.

**Fix:** Add to Phase 3 (JID module) + Phase 6 (connection Store for mappings) +
Phase 8 (message decryption routing).

---

### GAP-02: USync Query Infrastructure [RESOLVED IN PLAN]
**Baileys:** `executeUSyncQuery()` is a general-purpose mechanism used by 6+ features:
- Device discovery (`withDeviceProtocol`)
- Phone validation (`withContactProtocol` → `onWhatsApp()`)
- Status fetch (`withStatusProtocol`)
- Disappearing duration (`withDisappearingModeProtocol`)
- LID mapping (`withLIDProtocol`)
- Presence/contact sync

**Our plan:** Individual uses are scattered (device discovery in 8.6, status fetch in
10.7) but there is no centralized USync query builder module.

**Fix:** Add `BaileysEx.Protocol.USync` module to Phase 3 with query builder pattern
(protocols, users, context, mode). Individual features compose on top.

---

### GAP-03: Message ACK (`sendMessageAck`) [RESOLVED IN PLAN]
**Baileys:** Every received message, receipt, and notification MUST be acknowledged
with an `ack` stanza. Without this, the server will re-send and eventually disconnect.

**Source detail (from audit):**
- `messages-recv.ts` L345-380: `sendMessageAck()` builds an `ack` node with `id`, `to` (from original `from`), `class` (original tag). Conditionally includes `participant`, `recipient`, `type`, and `from` (for unavailable messages). Error code can be passed.
- Acks are sent in `finally` blocks of `handleReceipt` (L1141), `handleNotification` (L1178), and throughout `handleMessage` (multiple paths).
- Error code `NACK_REASONS.ParsingError` is sent for missing-key decryption failures. `NACK_REASONS.MissingMessageSecret` for `msmsg` type. `NACK_REASONS.UnhandledError` for ciphertext stubs.

**Our plan:** Phase 8 mentions sending receipts but never mentions the lower-level
`ack` that must be sent for ALL received nodes (not just messages).

**Fix:** Add to Phase 6 (connection socket) as an automatic ack for all inbound
nodes with an `id` attribute.

---

### GAP-04: Connection Validation Nodes [RESOLVED IN PLAN]
**Baileys:** After Noise handshake, two specific nodes must be sent:
- `generateLoginNode()` — for returning users (has credentials)
- `generateRegistrationNode()` — for new registrations (includes device props,
  registration ID, pre-keys, platform type, history sync config)

**Our plan:** Phase 6 mentions transitioning to `:authenticating` state and Phase 7
covers auth, but neither defines these specific node construction functions or the
`ClientPayload` protobuf structure they require.

**Fix:** Add explicit login/registration node builders to Phase 7 with all fields
(platform mapping, history sync config, device props).

---

### GAP-05: History Sync / Offline Message Processing [RESOLVED IN PLAN]
**Baileys:** Three critical mechanisms:
1. `downloadAndProcessHistorySyncNotification()` — downloads, decompresses, decodes
   history sync messages (types: INITIAL_BOOTSTRAP, PUSH_NAME, RECENT, FULL, ON_DEMAND)
2. `makeOfflineNodeProcessor()` — queues offline nodes, processes in batches of 10
   with event loop yields to avoid blocking
3. `fetchMessageHistory()` — on-demand history fetch via Peer Data Operation (PDO)

**Source detail (from audit):**
- `chats.ts` L85-101: Three-state sync machine — `SyncState.Connecting → AwaitingInitialSync → Syncing → Online`. Governs when events are buffered vs flushed.
- `chats.ts` L1082-1098: Transitions from `AwaitingInitialSync` to `Syncing` when first processable history msg arrives. Has a 20-second timeout (L1207-1214) — if no history sync message arrives, forces `Online` state.
- `chats.ts` L1100-1113: `doAppStateSync()` runs `resyncAppState(ALL_WA_PATCH_NAMES)` during `Syncing`, then transitions to `Online` and flushes all buffered events.
- `chats.ts` L1134-1138: If `appStateSyncKeyShare` arrives while in `Syncing`, triggers immediate app state sync.
- `messages-recv.ts` L127-148: `fetchMessageHistory()` is a user-facing API, sends PDO with `HISTORY_SYNC_ON_DEMAND` type.
- `messages-recv.ts` L1528-1581: `makeOfflineNodeProcessor()` uses FIFO queue, processes 4 node types (message, call, receipt, notification) with `BATCH_SIZE = 10` and `setImmediate` yield between batches.

**Our plan:** Phase 6 mentions "event buffering during offline processing" in one
sentence. No detail on history sync download, decompression, processing by type,
or PDO-based on-demand fetch.

**Impact:** New connections would never receive chat history. Offline message
processing would block the BEAM scheduler.

**Fix:** Add Phase 8 tasks for history sync processing. Add batched node processing
to Phase 6 (using `Task.Supervisor.async_nolink` with concurrency limits).

---

### GAP-06: Notification Processing (All Types) [RESOLVED IN PLAN]
**Baileys:** `processNotification()` handles 11 notification types, each with
specific parsing and event emission:

| Type | Events Emitted |
|------|---------------|
| `w:gp2` | Group updates (20+ stub types) |
| `encrypt` | Identity changes, pre-key count |
| `devices` | Device list changes |
| `picture` | Profile picture changes → `contacts.update` |
| `account_sync` | Disappearing mode, blocklist → `blocklist.update` |
| `server_sync` | App state resync trigger |
| `mediaretry` | Media retry → `messages.media-update` |
| `newsletter` | Reactions, views, participants, settings |
| `mex` | Newsletter metadata updates |
| `link_code_companion_reg` | Pairing completion |
| `privacy_token` | TC token storage |

**Our plan:** Phase 8 receiver has `handle_notification(node, conn)` as a one-line
comment. No detail on any notification type.

**Fix:** Expand Phase 8 with explicit notification handler for each type, including
the 20+ group stub types.

---

### GAP-07: Full Event Map [RESOLVED IN PLAN]
**Baileys:** Emits 25+ distinct event types that consumers subscribe to:

| Event | Description |
|-------|-------------|
| `connection.update` | State changes, QR codes, online status |
| `creds.update` | Credential changes (must persist immediately) |
| `messages.upsert` | New messages (with type: notify/append) |
| `messages.update` | Status changes, edits, reactions |
| `messages.delete` | Deleted messages |
| `messages.media-update` | Media retry results |
| `message-receipt.update` | Per-user read/delivery in groups |
| `contacts.upsert` | New contacts |
| `contacts.update` | Contact changes (picture, name) |
| `chats.upsert` | New chats |
| `chats.update` | Chat modifications |
| `chats.delete` | Deleted chats |
| `presence.update` | Presence changes |
| `groups.upsert` | New groups |
| `groups.update` | Group metadata changes |
| `blocklist.update` | Block/unblock |
| `call` | Call events |
| `labels.edit` | Label changes |
| `labels.association` | Label↔chat/message associations |
| `newsletter-settings.update` | Newsletter settings |
| `newsletter-participants.update` | Newsletter admin changes |
| `newsletter.reaction` | Newsletter reactions |
| `newsletter.view` | Newsletter views |

**Our plan:** Phase 6 EventEmitter is a skeleton. No event type catalog.

**Fix:** Define the full event type catalog in Phase 6 with typed event structs.

---

### GAP-08: Device Sent Message (DSM) [RESOLVED IN PLAN]
**Baileys:** When sending a 1:1 message, the sender's OTHER devices receive a
`deviceSentMessage` wrapper containing the original message + destination JID.
This is how multi-device stays in sync.

**Source detail (from audit):**
- `messages-send.ts` L640-646: DSM is constructed as `{ deviceSentMessage: { destinationJid, message }, messageContextInfo }` — wraps the original message with destination context.
- `messages-send.ts` L864-907: In 1:1 relay, recipients are split into `meRecipients` (own devices) and `otherRecipients`. Own devices get the DSM wrapper, other devices get the raw message. `createParticipantNodes()` is called twice in parallel — once for each group.
- `messages-send.ts` L549-561: `createParticipantNodes` also supports a `dsmMessage` parameter for per-recipient message selection — if the recipient is own-user but not the exact sender device, it substitutes the DSM message.

**Our plan:** Not mentioned. Phase 8 sender encrypts for recipient devices but
doesn't show the DSM wrapper for own devices.

**Fix:** Add DSM construction to Phase 8 sender pipeline.

---

### GAP-09: Sender Key Distribution in Relay Flow [RESOLVED IN PLAN]
**Baileys:** When sending to a group, the relay flow:
1. Checks sender key memory for which devices already have the key
2. For new devices: sends `SenderKeyDistributionMessage` in separate `pkmsg` nodes
3. Encrypts actual message with group sender key (`skmsg`)
4. Updates sender key memory

**Source detail (from audit):**
- `messages-send.ts` L696-802: Full group relay flow. Fetches `sender-key-memory` from key store (L712), iterates devices, tracks who needs SKD (L759-773), encrypts SKD for those recipients via `createParticipantNodes` (L789), then encrypts actual content as `skmsg` (L795-799), and persists updated sender key memory (L801).
- `messages-send.ts` L750-757: Uses `groupAddressingMode` (default `'lid'`) to select `groupSenderIdentity` for `encryptGroupMessage`.
- `messages-send.ts` L763-767: Skips hosted LID/PN users and device 99 from SKD distribution.
- `messages-recv.ts` L1021-1023: On retry in groups, sender key memory is cleared (`null`) to force re-distribution.

**Our plan:** Phase 5 has the `SenderKeyDistributionMessage` module, and Phase 8
mentions `encrypt_for_devices`, but the relay flow doesn't show the SKD
distribution step or sender key memory management.

**Fix:** Expand Phase 8 sender to explicitly handle SKD distribution, sender key
memory tracking, and the group vs 1:1 encryption branching.

---

## IMPORTANT GAPS (missing features users would expect)

### GAP-10: `onWhatsApp` Phone Number Validation [RESOLVED IN PLAN]
**Baileys:** `onWhatsApp(...phoneNumbers)` — checks if phone numbers are registered
on WhatsApp via USync contact protocol. Returns array of `{exists, jid}`.

**Our plan:** Not in any phase. Essential for any bot/automation use case.

**Fix:** Add to Phase 10 (Features) or Phase 6 (connection utility).

---

### GAP-11: Newsletter API (13 Missing Functions) [RESOLVED IN PLAN]
**Baileys:** 19 newsletter functions. Our plan has 6.

**Source detail (from audit):**
- `newsletter.ts` L44-227: All functions use `executeWMexQuery` (GraphQL-over-binary, see GAP-43) with specific `QueryIds` and `XWAPaths` constants.
- `newsletterReactMessage` (L137-153): Uses a direct `message` stanza (not IQ) with `type: 'reaction'` and `server_id` attr — distinct from regular reactions.
- `subscribeNewsletterUpdates` (L186-200): IQ query to `xmlns: 'newsletter'` with `live_updates` tag, returns `{ duration }` for subscription TTL.
- `newsletterFetchMessages` (L156-183): Also uses `xmlns: 'newsletter'` IQ (not WMex), with `message_updates` tag supporting `count`, `since`, `after` pagination.
- Inbound newsletter handling is in `messages-recv.ts` L194-343: `handleNewsletterNotification` (reaction/view/participant/update/message) and `handleMexNewsletterNotification` (settings/admin via JSON parsing).

Missing:
- `newsletterSubscribers(jid)` — subscriber count
- `newsletterUpdate(jid, updates)` — general update
- `newsletterReactMessage(jid, serverId, reaction)` — react to newsletter message
- `newsletterFetchMessages(jid, count, since, after)` — paginated message fetch
- `subscribeNewsletterUpdates(jid)` — live update subscription
- `newsletterAdminCount(jid)` — admin count
- `newsletterChangeOwner(jid, newOwnerJid)` — ownership transfer
- `newsletterDemote(jid, userJid)` — demote admin
- `newsletterDelete(jid)` — delete newsletter
- `newsletterUpdateName(jid, name)` — update name
- `newsletterUpdateDescription(jid, description)` — update description
- `newsletterUpdatePicture(jid, content)` — update picture
- `newsletterRemovePicture(jid)` — remove picture

**Fix:** Expand Phase 11 newsletter section.

---

### GAP-12: Community API (18 Missing Functions) [RESOLVED IN PLAN]
**Baileys:** 23 community functions. Our plan has 5.

**Source detail (from audit):**
- `communities.ts` L22-431: Full community socket layer. Uses same `w:g2` xmlns as groups but with `community` tag instead of `group` in responses.
- `communityCreate` (L115-151): Creates with `description`, `parent`, `allow_non_admin_sub_group_creation`, and `create_general_chat` tags.
- `communityCreateGroup` (L152-171): Links subgroup via `linked_parent` tag in create stanza.
- `communityFetchLinkedGroups` (L214-251): Queries `sub_groups` tag. Auto-detects if given JID is community or subgroup (fetches metadata first to check `linkedParent`).
- `communityParticipantsUpdate` (L287-303): Same as group but `remove` action adds `linked_groups: 'true'` attr to cascade.
- `communityJoinApprovalMode` (L425-429): Uses `community_join` tag (vs `group_join` for groups).
- `communityAcceptInviteV4` (L353-405): Same V4 flow as groups but emits community-specific events.
- Dirty bits handler (L102-110): Listens for `type: 'communities'` dirty notifications.

Missing:
- `communityCreateGroup(subject, participants, parentJid)` — create subgroup
- `communityLeave(id)` — leave community
- `communityUpdateSubject(jid, subject)` — rename
- `communityFetchLinkedGroups(jid)` — list subgroups
- All participant operations (request list, approve/reject, add/remove/promote/demote)
- All invite operations (get/revoke/accept v3 and v4, get info)
- Setting operations (ephemeral, announcement, locked, member add mode, join approval)
- `communityFetchAllParticipating()` — list all communities

**Fix:** Expand Phase 11 community section to mirror group operations.

---

### GAP-13: Business API (4 Missing Functions) [RESOLVED IN PLAN]
**Baileys:** 9 business functions. Our plan has 5.

**Source detail (from audit):**
- `business.ts` L16-424: Full business socket layer with `xmlns: 'w:biz'` for profiles and `xmlns: 'w:biz:catalog'` for products.
- `updateBussinesProfile` (L20-93): Supports `address`, `email`, `description`, `websites[]`, and `business_hours` with per-day `{ day_of_week, mode, open_time, close_time }` configs.
- `updateCoverPhoto` (L95-129): Uploads via `waUploadToServer` with `mediaType: 'biz-cover-photo'`, returns `fbid`. Sets cover_photo with `op: 'update'`, `token: meta_hmac`, `ts`.
- `getCatalog` (L157-206): Uses `product_catalog` tag with `allow_shop_source: 'true'`, supports cursor-based pagination.
- `getCollections` (L208-252): Queries `collections` by `biz_jid` with `collection_limit` and `item_limit`.
- `getOrderDetails` (L254-298): Uses `xmlns: 'fb:thrift_iq'` (different namespace!) with `smax_id: '5'`.
- `productCreate/Update/Delete` (L300-409): CRUD via `product_catalog_add/edit/delete` tags. Images are uploaded first via `uploadingNecessaryImagesOfProduct()` helper.

Missing:
- `updateBussinesProfile(args)` — full business profile update (address, hours, etc.)
- `updateCoverPhoto(photo)` — cover photo with media upload
- `removeCoverPhoto(id)` — remove cover photo
- `productCreate/productUpdate/productDelete` — CRUD for catalog products

**Fix:** Expand Phase 11 business section.

---

### GAP-14: Group Advanced Features (6 Missing Functions) [RESOLVED IN PLAN]
**Baileys:** 19 group functions. Our plan has ~13.

Missing:
- `groupGetInviteInfo(code)` — preview group before joining
- `groupSettingUpdate(jid, setting)` — announcement/locked toggles
- `groupMemberAddMode(jid, mode)` — who can add members
- `groupJoinApprovalMode(jid, mode)` — require approval
- `groupRequestParticipantsList(jid)` — pending join requests
- `groupRequestParticipantsUpdate(jid, participants, action)` — approve/reject
- V4 invite operations

**Fix:** Add to Phase 10 group module.

---

### GAP-15: Message Retry Manager Sophistication [RESOLVED IN PLAN]
**Baileys:** `MessageRetryManager` class with:
- 14 retry reason codes (enums)
- MAC error detection (codes 4, 7) with immediate session recreation
- Session recreation cooldown (1 hour between recreations per JID)
- Phone request scheduling (3s delay for placeholder resend)
- LRU cache for recent messages (512, 5 min TTL)
- `shouldRecreateSession()` logic

**Source detail (from audit):**
- `messages-send.ts` L98: `enableRecentMessageCache` config flag controls whether `MessageRetryManager` is instantiated.
- `messages-send.ts` L1038-1040: On successful send, message is added to retry cache via `messageRetryManager.addRecentMessage()`.
- `messages-recv.ts` L404-551: `sendRetryRequest()` — full retry receipt flow. Builds `retry` receipt with `count`, `v: '1'`, `error: '0'`. On `retryCount > 1 || forceIncludeKeys`, attaches fresh pre-keys bundle (`getNextPreKeys`). Session recreation triggered via `shouldRecreateSession()` when `enableAutoSessionRecreation` && `retryCount > 1`.
- `messages-recv.ts` L447-465: Session recreation deletes existing session from key store (`session: { [sessionId]: null }`) and forces `forceIncludeKeys = true`.
- `messages-recv.ts` L467-486: On `retryCount <= 2`, schedules phone PDO request via `messageRetryManager.schedulePhoneRequest(msgId, callback)` with fallback to immediate `requestPlaceholderResend`.
- `messages-recv.ts` L954-1048: `sendMessagesAgain()` — outbound retry. Tries retry cache first (`getRecentMessage`), falls back to `getMessage` callback. Clears sender key memory for groups. Uses `assertSessions([participant], true)` to force new session.

**Our plan:** Phase 8 has a simple counter with `@max_retries 3`.

**Fix:** Expand Phase 8 retry module with proper reason codes, session recreation
logic, and phone request scheduling.

---

### GAP-16: Identity Change Handling [RESOLVED IN PLAN]
**Baileys:** `handleIdentityChange(node, ctx)` — handles identity key changes for
contacts. Filters companion devices, skips self-primary and offline notifications,
debounces with cache, triggers session refresh.

**Source detail (from audit):**
- `messages-recv.ts` L553-578: `handleEncryptNotification()` — dispatches on `from`. If from `S_WHATSAPP_NET`, checks pre-key count and uploads if `< MIN_PREKEY_COUNT`. Otherwise delegates to `handleIdentityChange()` with `{ meId, meLid, validateSession, assertSessions, debounceCache, logger }` context.
- `messages-recv.ts` L123: `identityAssertDebounce` — `NodeCache<boolean>` with 5-second TTL to prevent burst session refreshes for same JID.

**Our plan:** Not mentioned anywhere.

**Fix:** Add to Phase 8 (receiver notifications) or Phase 10.

---

### GAP-17: Media Thumbnails and Waveforms [RESOLVED IN PLAN]
**Baileys:**
- Image thumbnails via sharp/jimp (32x32 default)
- Video thumbnails via ffmpeg
- Audio waveform generation (64 samples for voice notes)
- Dimension extraction from EXIF/metadata

**Our plan:** Phase 9 mentions streaming encryption/upload/download but no
thumbnail generation, waveform computation, or dimension extraction.

**Fix:** Add thumbnail/waveform tasks to Phase 9. Consider optional deps
(like `image` hex package) or require user-supplied callbacks.

---

### GAP-18: Logout [RESOLVED IN PLAN]
**Baileys:** `logout(msg?)` — sends `remove-companion-device` IQ, ends connection.

**Source detail (from audit):**
- `socket.ts` L722-746: `logout()` sends `iq` with `xmlns: 'md'`, `type: 'set'` containing `remove-companion-device` tag with own JID and `reason: 'user_initiated'`. Then calls `end()` with `DisconnectReason.loggedOut`.

**Our plan:** Phase 6 has `disconnect` but no explicit `logout` that removes the
device registration from the server.

**Fix:** Add `logout` to Phase 6 connection socket.

---

### GAP-19: Pre-Key Management Sophistication [RESOLVED IN PLAN]
**Baileys:**
- `uploadPreKeysToServerIfRequired()` — checks server count, uploads if needed
- `rotateSignedPreKey()` — rotates signed pre-key, emits `creds.update`
- `digestKeyBundle()` — sends digest of key bundle
- `PreKeyManager` class — per-key-type queues, deletion validation, transaction support

**Source detail (from audit):**
- `socket.ts` L456-469: `getAvailablePreKeysOnServer()` — queries `xmlns: 'encrypt'` with `count` tag.
- `socket.ts` L476-537: `uploadPreKeys()` — generates via `getNextPreKeysNode()` inside `keys.transaction()`, uploads to server, has exponential backoff retry (max 3), timeout protection via `UPLOAD_TIMEOUT`, and minimum interval tracking via `lastUploadTime` / `MIN_UPLOAD_INTERVAL`.
- `socket.ts` L539-581: `uploadPreKeysToServerIfRequired()` — checks both server count and local storage for current pre-key existence. Uploads if `preKeyCount <= count` OR `currentPreKeyId` missing from storage.
- `socket.ts` L238-254: `rotateSignedPreKey()` — increments key ID, generates new signed key pair, sends `rotate` IQ with `xmlns: 'encrypt'`.
- `socket.ts` L224-235: `digestKeyBundle()` — validates key bundle on server; on failure triggers `uploadPreKeys()`.

**Our plan:** Phase 7 mentions pre-key upload but these specific management
functions aren't detailed.

**Fix:** Expand Phase 7 pre-key section.

---

### GAP-20: Placeholder Resend [RESOLVED IN PLAN]
**Baileys:** `requestPlaceholderResend(messageKey, msgData?)` — requests real content
for unavailable/placeholder messages via Peer Data Operation. Includes:
- Cache with 1-hour TTL to prevent duplicate requests
- 2-second delay before actual request
- 8-second timeout for phone offline detection

**Source detail (from audit):**
- `messages-recv.ts` L150-191: Full flow — checks `placeholderResendCache` for duplicate, stores original message metadata (`key`, `messageTimestamp`, `pushName`, `participant`, `verifiedBizName`) for later PDO response correlation, delays 2s, rechecks cache (if message arrived in meantime, returns `'RESOLVED'`), builds PDO with `PLACEHOLDER_MESSAGE_RESEND` type, sets 8s timeout to clear cache if phone offline.
- `messages-recv.ts` L1240-1298: Caller in `handleMessage` — filters out `bot_unavailable_fanout`, `hosted_unavailable_fanout`, `view_once_unavailable_fanout` unavailable types. Checks `PLACEHOLDER_MAX_AGE_SECONDS` for old messages. On success, emits `messages.update` with PDO requestId in `messageStubParameters[1]`.

**Our plan:** Not mentioned.

**Fix:** Add to Phase 8.

---

## MODERATE GAPS (completeness items for 1:1 parity)

### GAP-21: Noise Certificate Validation [RESOLVED IN PLAN]
**Baileys:** During handshake, validates certificate chain (leaf cert, intermediate
cert, issuer serial verification). Our Phase 4 wraps `snow` but doesn't mention
WA-specific cert validation that happens AFTER the Noise handshake.

**Fix:** Add cert validation to Phase 4 or Phase 6.

---

### GAP-22: Event Buffering Details [RESOLVED IN PLAN]
**Baileys:** 12 bufferable event types, 30-second auto-flush timeout, conditional
chat updates with validation functions, `createBufferedFunction` wrapper,
message type consistency checking (flushes if upsert type changes).

**Source detail (from audit):**
- `chats.ts` L1008-1018: Event buffering starts on `process.nextTick` if logged in (`creds.me?.id`). Emits initial `connection.update` with `connection: 'connecting'`.
- `chats.ts` L1169-1215: On `receivedPendingNotifications`, transitions to `AwaitingInitialSync` and calls `ev.buffer()`. If history sync disabled by config, immediately transitions to `Online` and flushes.
- `chats.ts` L479,1059: `resyncAppState` and `upsertMessage` are wrapped with `ev.createBufferedFunction` — ensures they auto-buffer/flush around their execution.
- `chats.ts` L838-852: After `appPatch()`, if `config.emitOwnEvents`, decodes own patch mutations and fires them through `onMutation`.

**Our plan:** One sentence in Phase 6 EventEmitter.

**Fix:** Expand Phase 6 EventEmitter with full buffering spec.

---

### GAP-23: TC Tokens (Trusted Contact) [RESOLVED IN PLAN]
**Baileys:** `buildTcTokenFromJid()` retrieves tokens from store, appends to
presence subscribe and profile picture queries. `getPrivacyTokens()` fetches
tokens for JIDs.

**Source detail (from audit):**
- `messages-send.ts` L1016-1027: In `relayMessage`, TC token is fetched from `authState.keys.get('tctoken', [destinationJid])` and appended as `<tctoken>` child node to message stanza for non-group, non-status, non-retry messages.
- `messages-send.ts` L1110-1136: `getPrivacyTokens(jids)` — sends `xmlns: 'privacy'` IQ with `tokens` tag containing `token` nodes per JID (`type: 'trusted_contact'`).
- `messages-recv.ts` L895-923: `handlePrivacyTokenNotification()` — on `privacy_token` notification, extracts `trusted_contact` tokens from `token` nodes and stores via `authState.keys.set({ tctoken: { [from]: { token, timestamp } } })`.
- `chats.ts` L639-660: `profilePictureUrl()` calls `buildTcTokenFromJid()` to include TC token in profile picture queries.
- `chats.ts` L730-741: `presenceSubscribe()` also calls `buildTcTokenFromJid()`.

**Our plan:** Not mentioned.

**Fix:** Add to Phase 10 (privacy/presence) as a utility.

---

### GAP-24: Dirty Bit Handling [RESOLVED IN PLAN]
**Baileys:** Server sends `CB:ib,,dirty` notifications with type `groups` or
`account_sync`. Client must call `cleanDirtyBits()` and refresh affected data.

**Source detail (from audit):**
- `chats.ts` L443-463: `cleanDirtyBits(type, fromTimestamp?)` — sends `iq` with `xmlns: 'urn:xmpp:whatsapp:dirty'`, `type: 'set'`, `clean` tag with type and optional timestamp.
- `chats.ts` L1144-1167: `CB:ib,,dirty` handler — for `account_sync`, saves `lastAccountSyncTimestamp` to creds and calls `cleanDirtyBits`. For `groups`, delegates to `groups.ts`.
- `groups.ts` L76-84: Group dirty handler — calls `groupFetchAllParticipating()` to refresh all groups, then `cleanDirtyBits('groups')`.
- `communities.ts` L102-110: Community dirty handler — calls `communityFetchAllParticipating()`, then `cleanDirtyBits('groups')` (reuses group dirty type).

**Our plan:** Not mentioned.

**Fix:** Add to Phase 6 (connection) or Phase 10 (app state sync).

---

### GAP-25: `generateMessageIDV2` [RESOLVED IN PLAN]
**Baileys:** Timestamp + user-ID based message ID generation.

**Our plan:** Phase 8 has `generate_message_id` using random bytes, which would
work but wouldn't match Baileys' format exactly.

**Fix:** Match Baileys format in Phase 8.

---

### GAP-26: Participant Hash V2 [RESOLVED IN PLAN]
**Baileys:** `generateParticipantHashV2(participants)` — SHA256-based hash of sorted
participant JIDs, sent as `phash` attribute in message relay. Server uses this
for participant list validation.

**Our plan:** Not mentioned.

**Fix:** Add to Phase 8 sender.

---

### GAP-27: Browser/Platform Identification [RESOLVED IN PLAN]
**Baileys:** `Browsers` object maps platform names to `[platform, browser, version]`
tuples. `getPlatformId()` maps to `proto.DeviceProps.PlatformType`.

**Our plan:** Phase 6 config has `browser: {"BaileysEx", "Chrome", "1.0"}` but no
platform type mapping.

**Fix:** Add platform mapping to Phase 6 or Phase 7.

---

### GAP-28: Message Stub Types [RESOLVED IN PLAN]
**Baileys:** 20+ group notification types map to `messageStubType` values:
create, ephemeral, not_ephemeral, modify, promote, demote, remove, add, leave,
subject, description, announcement, not_announcement, locked, unlocked, invite,
member_add_mode, membership_approval_mode, created_membership_requests,
revoked_membership_requests.

**Our plan:** Not enumerated.

**Fix:** Define stub type enum in Phase 3 (types) and handle in Phase 8 receiver.

---

### GAP-29: Link Preview Generation [RESOLVED IN PLAN]
**Baileys:** `getUrlInfo(text)` — extracts URLs, fetches Open Graph metadata,
generates thumbnails. Optional callback-based.

**Our plan:** Phase 8 builder has `link_preview` fields but no generation logic.

**Fix:** Add optional link preview fetching to Phase 8 or Phase 12 (polish).
Can be a user-supplied callback like Baileys does.

---

### GAP-30: `cleanMessage` Normalization [RESOLVED IN PLAN]
**Baileys:** `cleanMessage(message, meId, meLid)` — normalizes JIDs in received
messages, processes reactions/polls, handles hosted/LID users.

**Our plan:** Phase 8 parser normalizes wrappers but doesn't mention JID
normalization or reaction/poll post-processing in received messages.

**Fix:** Add to Phase 8 parser.

---

## LOW-PRIORITY GAPS (nice-to-have for completeness)

### GAP-31: WAM Analytics [RESOLVED IN PLAN]
**Baileys:** `sendWAMBuffer(wamBuffer)` — sends analytics data via `xmlns: 'w:stats'`
with `add` tag and Unix timestamp. Not critical for functionality but WA may expect it.

### GAP-32: Reporting Tokens [RESOLVED IN PLAN]
**Baileys:** `messages-send.ts` L992-1014: 28+ message types with reporting field
configurations. `getMessageReportingToken()` generates token from encoded message
and `messageContextInfo.messageSecret`. Attached as child node to message stanza.
`shouldIncludeReportingToken()` checks if message type requires it. Server may
expect these for abuse reporting.

### GAP-33: `sendUnifiedSession` [RESOLVED IN PLAN]
**Baileys:** `socket.ts` L1067-1097. Sends `ib` node with `unified_session` tag.
Session ID is computed as `(now + 3 days) % 7 days` using server time offset.
Called on connection open (L942) and when presence changes to `available` (L696).
Purpose: session deduplication across reconnects within a 7-day window.

### GAP-34: `executeInitQueries` [RESOLVED IN PLAN]
**Baileys:** `chats.ts` L1055-1057. Runs `Promise.all([fetchProps(), fetchBlocklist(),
fetchPrivacySettings()])` on connection open. `fetchProps()` (L856-892) queries
`xmlns: 'w'` with `protocol: '2'` and caches `lastPropHash` on creds. These
props are server-side feature flags. Called from `connection.update` handler
(L1171-1173) when `fireInitQueries` config is true.

### GAP-35: Verified Name Certificates [RESOLVED IN PLAN]
**Baileys:** Parses verified business name certificates from received messages.
Display-only feature.

---

## ADDITIONAL GAPS (from line-by-line Socket layer audit, 2026-03-08)

### GAP-36: `createCallLink(type, event?)` [RESOLVED IN PLAN]
**Baileys:** `chats.ts` L662-682. Creates persistent call links (audio/video) with
optional scheduled events. Returns a token string. Uses `xmlns: 'call'` → `@call`.

**Baileys signature:** `createCallLink(type: 'audio' | 'video', event?: { startTime: number }): Promise<string>`

**Our plan:** Phase 11 mentions call rejection but not link creation.

**Fix:** Add to Phase 11 (Calls).

---

### GAP-37: `getBotListV2()` [RESOLVED IN PLAN]
**Baileys:** `chats.ts` L211-244. Fetches WhatsApp bot directory (AI bots, business
bots) via `xmlns: 'bot'`, `v: '2'`. Returns `BotListInfo[] = { jid, personaId }`.

**Our plan:** Not mentioned in any phase.

**Fix:** Add to Phase 10 or Phase 11 as a query function.

---

### GAP-38: `star(jid, messages, star)` — Message Starring [RESOLVED IN PLAN]
**Baileys:** `chats.ts` L919-929. Stars/unstars messages via `chatModify` → app
state sync patch. Takes array of `{ id, fromMe? }` message identifiers.

**Our plan:** Not in Phase 10 chat operations.

**Fix:** Add to Phase 10 `Feature.Chat` module.

---

### GAP-39: `updateMemberLabel(jid, memberLabel)` [RESOLVED IN PLAN]
**Baileys:** `messages-send.ts` L389-415. Sets custom label/tag on a group member
via `ProtocolMessage.GROUP_MEMBER_LABEL_CHANGE` with `meta` node containing
`tag_reason: 'user_update'`, `appdata: 'member_tag'`.

**Our plan:** Not in Phase 10 group operations.

**Fix:** Add to Phase 10 `Feature.Group` module.

---

### GAP-40: `handleBadAck` — Error Acknowledgement Handling [RESOLVED IN PLAN]
**Baileys:** `messages-recv.ts` L1453-1498. Listens on `CB:ack,class:message`.
When `attrs.error` is present, emits `messages.update` with `ERROR` status and
error code in `messageStubParameters`. Contains commented-out retry logic for
error 475 (device_fanout).

**Our plan:** Phase 8 doesn't document ack error handling.

**Fix:** Add to Phase 8 receiver pipeline.

---

### GAP-41: `updateDisableLinkPreviewsPrivacy(isDisabled)` [RESOLVED IN PLAN]
**Baileys:** `chats.ts` L907-914. Server-side toggle for link preview generation
(distinct from client-side preview). Uses `chatModify` with
`{ disableLinkPreviews: { isPreviewsDisabled } }`.

**Our plan:** Phase 10 mentions link preview privacy but not this function.

**Fix:** Add explicit function to Phase 10 `Feature.Privacy`.

---

### GAP-42: Media Connection Auth Lifecycle (`refreshMediaConn`) [RESOLVED IN PLAN]
**Baileys:** `messages-send.ts` L103-134. Fetches CDN upload auth credentials
from `xmlns: 'w:m'`. Returns `{ hosts: [{hostname, maxContentLengthBytes}],
auth, ttl }`. Token is lazily cached and only refreshed when TTL expires.
Used by `waUploadToServer` for all media uploads.

**Our plan:** Phase 9 (Media) describes upload/download but not the auth token
lifecycle or the `media_conn` IQ query.

**Fix:** Add media connection management to Phase 9.

---

### GAP-43: WMex Query Engine (`executeWMexQuery`) [RESOLVED IN PLAN]
**Baileys:** `mex.ts` L1-59. Generic GraphQL-over-binary-node transport used by
all newsletter operations. Sends JSON-encoded variables in `xmlns: 'w:mex'` IQ,
parses `result` node, extracts data by path, handles GraphQL error responses.

**Our plan:** Not mentioned. Newsletter functions in Phase 11 don't describe
their transport layer.

**Fix:** Add `BaileysEx.Protocol.WMex` utility module to Phase 3 or Phase 11.

---

### GAP-44: Transactional Signal Key Storage (`addTransactionCapability`) [RESOLVED IN PLAN]
**Baileys:** `auth-utils.ts` L115-344. Wraps Signal Key state operations in transactions using `AsyncLocalStorage`, `p-queue` (concurrency: 1 per key type), and `async-mutex`. Caches reads/writes during the transaction and commits with `commitWithRetry` (to handle SQLite `database is locked` errors).
**Impact:** Essential for preventing race conditions and database locks during the massive parallel read/write bursts seen in history sync and group messaging.
**Our plan:** Phase 7 mentions generic Signal storage but not the critical concurrency and queuing controls needed for SQLite/Repo integration under heavy load.
**Fix:** Add transaction batching and serialized queues (e.g., via `Ecto.Multi` or `Oban` or serialized GenServers per key type) to Phase 7.

---

### GAP-45: History Sync PN-LID Fallback Recovery (`extractPnFromMessages`) [RESOLVED IN PLAN]
**Baileys:** `history.ts` L14-30, L84-88. When processing `INITIAL_BOOTSTRAP` history, Baileys extracts PN-LID mappings. If the explicit `phoneNumberToLidMappings` array is missing, and the `chat.pnJid` is missing, it executes a fallback: it iterates the chat's outgoing messages and extracts the recipient's Phone Number from the `userReceipt` array.
**Impact:** Without this fallback, multi-device sessions will fail to correlate LID with PN for historically synced chats, breaking decryption routing.
**Our plan:** Not mentioned in history sync.
**Fix:** Add this specific fallback extraction logic to Phase 8 sync processing.

---

### GAP-46: Media Upload Streaming & Encryption Pipe [RESOLVED IN PLAN]
**Baileys:** `messages-media.ts` L236-302. Media encryption happens in a single pass: it streams the file, calculating `sha256Plain`, `sha256Enc`, `fileLength`, and `mac` concurrently while encrypting and writing to a temp file/memory buffer. 
**Our plan:** Phase 9 (Media) assumes taking a binary, encrypting it, and calculating SHAs sequentially, which could cause memory spikes for large videos.
**Fix:** Specify a streaming `Stream` pipe in Elixir for Phase 9 to process chunks through `:crypto` and `:crypto.hash` concurrently.

---

### GAP-47: Media Re-upload Flow (`encryptMediaRetryRequest`) [RESOLVED IN PLAN]
**Baileys:** `messages-media.ts` L637-679. When media download returns HTTP 404/410, the client determines the media expired. It constructs a `mediaretry` notification encrypted with `messages_media_retry` HKDF keys and sends it via `iq` to `urn:xmpp:whatsapp:m`. The server eventually responds with a `messages.media-update` event containing the unencrypted media.
**Our plan:** Missing. Phase 9 assumes downloads always succeed if keys exist.
**Fix:** Add the `mediaretry` flow to Phase 9.

---

### GAP-48: Event Buffer Conditional Chat Updates [RESOLVED IN PLAN]
**Baileys:** `event-buffer.ts` L138-146, 345-365. Chat updates generated from sync patches (like mute/archive) are attached as `conditional` (checking if the relevant message ranges match). If in `AwaitingInitialSync` mode, they are buffered until history is fully populated, then applied if the condition passes.
**Our plan:** Phase 6 buffering lacks this condition-evaluation mechanism.
**Fix:** Enhance Phase 6 event buffering to support delayed evaluation of patch conditions.

---

## SUMMARY

| Severity | Count | Resolved | Remaining | Key Areas |
|----------|-------|----------|-----------|-----------|
| CRITICAL | 10 | 10 | 0 | LID/PN addressing, USync, message ACK, connection validation, history sync, notifications, events, DSM, sender key relay, transactional signal storage |
| IMPORTANT | 13 | 13 | 0 | onWhatsApp, newsletter (19 funcs), community (23 funcs), business (11 funcs), group (22 funcs), retry manager, identity change, thumbnails, logout, pre-key mgmt, placeholder resend, PN-LID fallback, media retry |
| MODERATE | 12 | 12 | 0 | Cert validation, event buffering, TC tokens, dirty bits, message ID format, participant hash, browser/platform, stub types, link preview, message normalization, conditional chat updates, media stream pipe |
| LOW | 5 | 5 | 0 | ~~reporting tokens~~, ~~unified session~~, ~~init queries~~, ~~WAM analytics~~, ~~verified names~~ |
| ADDITIONAL | 8 | 8 | 0 | Call links, bot list, star messages, member labels, bad ack handling, link preview privacy, media conn auth, WMex engine |

**Total gaps: 48 — Resolved: 48, Remaining: 0**
