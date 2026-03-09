# Phase 5: Signal Protocol

**Status:** IN PROGRESS

**Goal:** Provide a Baileys-compatible Signal boundary while keeping orchestration,
addressing, mapping, and persistence-friendly state transitions in Elixir.

**Reference files:**
- `dev/reference/Baileys-master/src/Signal/libsignal.ts`
- `dev/reference/Baileys-master/src/Signal/lid-mapping.ts`
- `dev/reference/Baileys-master/src/Signal/Group/group-session-builder.ts`
- `dev/reference/Baileys-master/src/Signal/Group/group_cipher.ts`
- `dev/reference/Baileys-master/src/Signal/Group/sender-key-message.ts`
- `dev/reference/Baileys-master/src/Signal/Group/sender-key-distribution-message.ts`
- `dev/reference/Baileys-master/src/__tests__/Signal/Group/sender-key-state-regression.test.ts`
- `dev/reference/Baileys-master/src/Utils/signal.ts`
- `dev/reference/Baileys-master/src/Utils/decode-wa-message.ts`

---

## Approved Architecture

The approved split is:

- Native helpers only where key-format compatibility or CPU cost justifies them.
- Elixir for repository orchestration, JID/address translation, PN<->LID
  (Local Identifier) mapping, session migration rules, and future store
  integration.
- No broad native Signal surface until interoperability tests prove it is needed.

Current implemented surface:

- `BaileysEx.Signal.Curve`
  - Signal-compatible key formatting, ECDH, sign/verify, signed pre-key helpers
- `BaileysEx.Signal.Address`
  - Baileys-style `jidToSignalProtocolAddress` rules, including `_agent`
    domain-type handling and hosted/device-99 rules
- `BaileysEx.Signal.Repository`
  - public Elixir-facing repository boundary for inject/validate/encrypt/decrypt,
    delete, PN<->LID mapping helpers, and session migration
- `BaileysEx.Signal.LIDMappingStore`
  - repository-resident PN<->LID mapping store with reverse lookup, explicit
    Baileys-style forward/reverse key entries, and optional lookup-hook backfill
- `BaileysEx.Signal.Group.*`
  - pure Elixir sender-key state, distribution, and group cipher modules aligned
    to Baileys' group-session-builder/group-cipher flow
  - repository-owned orchestration via `encrypt_group_message/2`,
    `process_sender_key_distribution_message/2`, and `decrypt_group_message/2`
- `BaileysEx.Signal.Identity`
  - repository-resident TOFU identity store with canonical address resolution via
    the LID mapping store and session invalidation when a trusted identity changes

Not implemented yet:

- durable Signal key-store contract
- Baileys cross-validation fixtures for full Signal payload/session interoperability

## Task Order

### 5.1 Minimal Signal helper boundary

Scope:
- implement the smallest compatibility layer needed for Signal-style key handling
- keep Noise/pairing verification logic off the raw crypto modules

Completed:
- `BaileysEx.Signal.Curve`
- Curve/XEdDSA helper tests

### 5.2 Repository boundary and address contract

Scope:
- define the public Elixir repository contract before committing to a larger
  engine or store surface
- match Baileys' JID-to-ProtocolAddress behavior

Completed:
- `inject_e2e_session/2`
- `validate_session/2`
- `encrypt_message/2`
- `decrypt_message/2`
- `delete_session/2`
- `jid_to_signal_protocol_address/1`

### 5.3 LID mapping store and session migration

Scope:
- implement Baileys-style PN<->LID mapping behavior
- support reverse lookup and optional backfill hook
- support PN->LID session migration without losing per-device separation
- treat LID-first sessions as canonical; PN sessions are the migration path, not
  the target model

Completed:
- `BaileysEx.Signal.LIDMappingStore`
- repository helpers:
  - `store_lid_pn_mappings/2`
  - `get_lid_for_pn/2`
  - `get_pn_for_lid/2`
  - `migrate_session/3`
- migration semantics aligned to the reference:
  - only PN/hosted PN -> LID/hosted LID migration is supported
  - device list is required before bulk migration
  - the source device is included if the stored device list is stale
  - hosted companion sessions preserve `@hosted.lid`
  - stored user mappings follow Baileys' forward/reverse key convention
    (`pn_user` and `lid_user_reverse`)
  - reverse PN lookup stays local-store-driven; it is not treated as a server
    discovery API

Explicit non-goal for 5.3:
- cross-call inflight lookup coalescing is not being faked inside the immutable
  repository struct. That behavior belongs in the later process-backed store /
  connection ownership layer, where there is an actual runtime owner for
  concurrent lookups.

### 5.4 Sender-key group crypto and distribution processing

Completed:
- `encrypt_group_message/2`
- `process_sender_key_distribution_message/2`
- `decrypt_group_message/2`
- Baileys-compatible sender-key record handling via nested `BaileysEx.Signal.Group`
  modules:
  - `SenderKeyName`
  - `SenderChainKey`
  - `SenderMessageKey`
  - `SenderKeyState`
  - `SenderKeyRecord`
  - `SenderKeyDistributionMessage`
  - `SenderKeyMessage`
  - `SessionBuilder`
  - `Cipher`

Explicit non-goal for 5.4:
- cross-runtime compatibility is not claimed yet from self-roundtrip tests alone;
  5.7 remains the gate for fixture-based Baileys interoperability validation

### 5.5 Signal identity handling

Completed:
- TOFU identity storage
- identity change detection
- session invalidation semantics matching Baileys/WhatsApp Web expectations
- repository helpers:
  - `save_identity/2`
  - `load_identity_key/2`
- canonical storage semantics aligned to the reference:
  - identity keys are normalized to the Signal-prefixed 33-byte form
  - PN identities resolve through the LID mapping store before persistence when a
    canonical LID mapping already exists
  - changed identities clear the existing canonical session before future traffic
    is re-established

Explicit non-goal for 5.5:
- automatic `pkmsg` identity extraction during decrypt is not being forced into the
  current adapter-agnostic repository API. The core TOFU/change semantics are
  implemented here; receive-path orchestration can layer on top once the richer
  messaging/decrypt surface exists.

### 5.6 Signal store contract

Planned scope:
- durable logical key families:
  - `session`
  - `pre-key`
  - `sender-key`
  - `sender-key-memory`
  - `app-state-sync-key`
  - `app-state-sync-version`
  - `lid-mapping`
  - `device-list`
  - `tctoken`
  - `identity-key`
- process-owned/runtime-backed behavior that can safely support coalesced lookups
  and transactional persistence

### 5.7 Cross-validation

Planned scope:
- Baileys-compatible ciphertext/session fixtures
- interoperability-focused tests instead of self-roundtrip-only checks

---

## Acceptance Criteria

Phase 5 is complete only when:

- repository behavior matches the Baileys Signal wrapper for 1:1 flows
- PN-addressed sessions can migrate to LID-addressed sessions without losing
  per-device separation
- TOFU identity storage detects key changes and invalidates stale sessions
- sender-key encrypt/decrypt and distribution flows interoperate with Baileys
- the Signal store contract covers the required logical key families
- interoperability is proven with Baileys-compatible data, not only self-generated
  roundtrips
- the native boundary remains no broader than necessary

## Current Files

Implemented:
- `lib/baileys_ex/signal/curve.ex`
- `lib/baileys_ex/signal/address.ex`
- `lib/baileys_ex/signal/repository.ex`
- `lib/baileys_ex/signal/lid_mapping_store.ex`
- `lib/baileys_ex/signal/group/sender_key_name.ex`
- `lib/baileys_ex/signal/group/sender_chain_key.ex`
- `lib/baileys_ex/signal/group/sender_message_key.ex`
- `lib/baileys_ex/signal/group/sender_key_state.ex`
- `lib/baileys_ex/signal/group/sender_key_record.ex`
- `lib/baileys_ex/signal/group/sender_key_distribution_message.ex`
- `lib/baileys_ex/signal/group/sender_key_message.ex`
- `lib/baileys_ex/signal/group/session_builder.ex`
- `lib/baileys_ex/signal/group/cipher.ex`
- `lib/baileys_ex/signal/identity.ex`
- `test/baileys_ex/signal/curve_test.exs`
- `test/baileys_ex/signal/address_test.exs`
- `test/baileys_ex/signal/repository_test.exs`
- `test/baileys_ex/signal/lid_mapping_store_test.exs`
- `test/baileys_ex/signal/group_test.exs`
- `test/baileys_ex/signal/identity_test.exs`

Planned:
- `lib/baileys_ex/signal/store.ex`
