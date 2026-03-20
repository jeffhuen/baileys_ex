# Phase 5: Signal Protocol

**Status:** COMPLETE

> **Phase 16 follow-up:** Phase 5's accepted behavior remains correct. Phase 16
> completed the runtime store transaction-contract cleanup introduced in 5.6:
> built-in stores now use explicit transaction-scoped handles instead of hidden
> caller-local state. Signal protocol semantics and Baileys-visible behavior
> were not reopened.

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

- a concrete 1:1 session-cipher engine behind `BaileysEx.Signal.Repository.Adapter`
- receive-path `pkmsg` identity extraction wired through the later messaging layer

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

Completed:
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
- `BaileysEx.Signal.Store`
  - low-level `get/3`, `set/2`, `transaction/3`, `clear/1`, and
    `is_in_transaction?/1` boundary matching the Baileys `keys` contract shape
- `BaileysEx.Signal.Store.Memory`
  - in-memory runtime implementation with ETS-backed reads, owner-process
    serialized writes, and per-key transaction locks
- store-backed `BaileysEx.Signal.Identity`
  - canonical `:"identity-key"` storage via the shared runtime store
- store-backed `BaileysEx.Signal.LIDMappingStore`
  - canonical `:"lid-mapping"` storage via the shared runtime store
  - coalesced miss behavior through the transaction boundary instead of
    immutable-struct-local state
- repository integration:
  - `Repository` now depends on an explicit Signal store handle
  - identity and PN<->LID operations no longer thread mutable mapping/identity
    structs through repository returns
  - device-list reads for PN->LID session migration come from the Signal store,
    not adapter-local state

Explicit non-goal for 5.6:
- file, ETS-backed durable persistence, or database-backed persistence selection
  is not being forced into Phase 5. The runtime contract is now stable; Phase 7
  owns auth persistence implementations that satisfy it.
- removing the hidden caller-local transaction model. That cleanup is now
  complete in Phase 16, which preserved the store boundary while replacing the
  zero-argument closure contract with explicit transaction-scoped handles.

### 5.7 Cross-validation

Completed:
- committed Baileys-generated fixtures under `test/fixtures/signal/baileys_v7.json`
- local generator script at `dev/tools/generate_signal_fixtures.mts`
- fixture-driven Elixir tests covering the implemented Baileys-dependent surfaces:
  - `jidToSignalProtocolAddress` parity
  - PN<->LID mapping forward/reverse parity
  - sender-key distribution bytes, ciphertext body parity, and decrypt interoperability
  - direct-message `pkmsg` and `msg` ciphertext parity against Baileys/libsignal
  - XEdDSA sign/verify compatibility for sender-key signatures

---

## Acceptance Criteria

Phase 5 is complete only when:

- the repository boundary and its Elixir-owned behavior match Baileys for the
  currently implemented surfaces: address translation, mapping, migration, identity,
  store access, and sender-key orchestration
- PN-addressed sessions can migrate to LID-addressed sessions without losing
  per-device separation
- TOFU identity storage detects key changes and invalidates stale sessions
- 1:1 session establishment and direct-message ciphertexts interoperate with
  Baileys/libsignal
- sender-key encrypt/decrypt and distribution flows interoperate with Baileys
- the Signal store contract covers the required logical key families
- interoperability is proven with committed Baileys-generated fixtures, not only
  self-generated roundtrips
- the native boundary remains no broader than necessary

## Current Files

Implemented:
- `lib/baileys_ex/signal/curve.ex`
- `lib/baileys_ex/signal/address.ex`
- `lib/baileys_ex/signal/whisper_message.ex`
- `lib/baileys_ex/signal/pre_key_whisper_message.ex`
- `lib/baileys_ex/signal/session_record.ex`
- `lib/baileys_ex/signal/session_builder.ex`
- `lib/baileys_ex/signal/session_cipher.ex`
- `lib/baileys_ex/signal/adapter/signal.ex`
- `lib/baileys_ex/signal/repository.ex`
- `lib/baileys_ex/signal/lid_mapping_store.ex`
- `lib/baileys_ex/signal/store.ex`
- `lib/baileys_ex/signal/store/memory.ex`
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
- `test/baileys_ex/signal/whisper_message_test.exs`
- `test/baileys_ex/signal/pre_key_whisper_message_test.exs`
- `test/baileys_ex/signal/session_record_test.exs`
- `test/baileys_ex/signal/session_builder_test.exs`
- `test/baileys_ex/signal/session_cipher_test.exs`
- `test/baileys_ex/signal/adapter/signal_test.exs`
- `test/baileys_ex/signal/repository_test.exs`
- `test/baileys_ex/signal/lid_mapping_store_test.exs`
- `test/baileys_ex/signal/group_test.exs`
- `test/baileys_ex/signal/identity_test.exs`
- `test/baileys_ex/signal/store_test.exs`
- `test/baileys_ex/signal/cross_validation_test.exs`
- `test/fixtures/signal/baileys_v7.json`
- `dev/tools/generate_signal_fixtures.mts`
