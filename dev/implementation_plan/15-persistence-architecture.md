# Phase 15: Persistence Architecture Alignment

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Separate Baileys-compatible auth persistence from the recommended Elixir-native persistence path, replace the generic Elixir-term-over-JSON codec with explicit compatibility serialization, and add a durable OTP-native backend that survives restarts and partial-write failures.

**Architecture:** This phase keeps `BaileysEx.Auth.FilePersistence` as the Baileys-compatible multi-file helper where on-disk JSON shape is part of the compatibility promise, but rewrites it around an explicit schema-driven JSON codec instead of generic tagged Elixir-term roundtripping. In parallel, it adds a durable native backend for Elixir-first deployments, backed by ETF (`:erlang.term_to_binary` / `:erlang.binary_to_term`) plus crash-safe file writes, format versioning, and migration support. `ETS` remains a runtime cache only; durability lives on disk.

**Retirement intent:** The compatibility JSON helper remains only as a migration
bridge for users coming from Baileys JS sidecars or other code that depends on
the `useMultiFileAuthState` on-disk contract. Once that migration pressure is
gone, the native backend should remain the product path and the compatibility
layer can be retired in a future major release.

**Tech Stack:** Elixir 1.19+/OTP 28, `:erlang.term_to_binary`, `:erlang.binary_to_term([:safe])`, existing `Auth.Persistence` / `Auth.KeyStore` behaviour surfaces, current file-backed Signal store integration, and Baileys 7.00rc9 `useMultiFileAuthState` / `BufferJSON` reference code in `dev/reference/Baileys-master/src/Utils/`.

**Status:** COMPLETE (2026-03-19)

---

## 1. Scope Rules

- Preserve Baileys-compatible behaviour and file-layout promises for `BaileysEx.Auth.FilePersistence.use_multi_file_auth_state/1`.
- Do not silently replace the compatibility helper's on-disk JSON format with ETF or another BEAM-only encoding.
- Add a **durable**, Elixir-native backend. `ETS` or in-memory state alone is not sufficient; the backend must survive VM restarts and incomplete writes.
- Do not keep generic tagged Elixir-term-over-JSON serialization. Compatibility JSON must be encoded and decoded from explicit known schemas.
- Persisted formats we explicitly promise to mirror count as observable behaviour. Internal JS mutexes, helper decomposition, and generic serialization tricks do not.
- Keep custom persistence backends swappable through the existing behaviour.

---

## 2. Why This Phase Exists

Phase 7 delivered a working Baileys-compatible multi-file auth helper and a swappable persistence behaviour, but it mixed two goals into one module:

1. a compatibility helper that mirrors Baileys' JSON file layout and helper semantics
2. a de facto default persistence story for Elixir deployments

That overlap created avoidable complexity:

- JSON compatibility pushed us toward generic term serialization for atoms and nested maps
- hardening that serializer exposed fresh-VM atom reconstruction problems that Baileys JS never has
- the current file helper carries production recommendations it should not have to carry alone

The repo guidance now explicitly says "match observable behaviour, not JS internals." This phase applies that rule to persistence:

- keep the compatibility helper where compatibility matters
- introduce a more reliable Elixir-native durable backend where compatibility does not
- document the distinction clearly so future work does not drift back into "copy JS internals everywhere"
- treat the compatibility layer as transitional glue, not a permanent center of gravity for the Elixir architecture

---

## 3. Design Decisions

### 3.1 Two persistence backends, one runtime contract

`BaileysEx.Auth.Persistence` remains the shared contract. This phase adds:

- `BaileysEx.Auth.FilePersistence` as the Baileys-compatible JSON backend
- `BaileysEx.Auth.NativeFilePersistence` as the recommended durable file backend for Elixir-first deployments

Both must satisfy the same runtime auth/key-store behaviour for the same logical inputs.

### 3.2 Durable native backend, not ephemeral caching

The native backend must be durable on disk, not just "Elixir-native" in memory:

- file-backed, not ETS-backed alone
- ETF-based term storage for BEAM-native fidelity
- crash-safe temp-file + fsync + rename discipline where supported
- explicit format versioning and corruption/error handling

`ETS` remains a read-through cache and transactional working set, not the source of truth.

### 3.3 Compatibility JSON should be explicit, not generic

The compatibility backend should encode Baileys-shaped data explicitly:

- binary values as BufferJSON-style tagged objects
- map keys as strings
- enum-like values as strings such as `"pn"` / `"lid"`
- structs and nested datasets decoded by explicit family schema

This removes the atom allowlist treadmill from the compatibility path without abandoning the JSON format we explicitly mirror.

### 3.4 Migration is part of the plan, not cleanup

This phase must include a migration path from the current shipped JSON persistence format. Existing auth directories must not become orphaned by the architecture cleanup.

---

## 4. Tasks

### 15.1 Reframe persistence architecture and plan docs

**Files:**
- Modify: `dev/implementation_plan/00-overview.md`
- Modify: `dev/implementation_plan/07-authentication.md`
- Modify: `dev/implementation_plan/CLAUDE.md`
- Modify: `dev/implementation_plan/PROGRESS.md`

**Required outcome:** the plan docs clearly distinguish compatibility persistence from the recommended native persistence path, without implying that JS internals are a general implementation target.

- [x] Add an explicit Phase 7 follow-up note so this phase reads as architecture alignment, not as a silent reopening of delivered auth behaviour.
- [x] Keep the "Baileys is the spec" rule tied to observable behaviour, public compatibility promises, and named helper contracts.
- [x] Update overview/dependency-map text so Phase 14 and Phase 15 are both reflected accurately.

### 15.2 Add a durable native file backend

**Files:**
- Create: `lib/baileys_ex/auth/native_file_persistence.ex`
- Create: `test/baileys_ex/auth/native_file_persistence_test.exs`
- Modify: `lib/baileys_ex/auth/persistence.ex`
- Modify: `lib/baileys_ex/auth/key_store.ex`

**Required outcome:** BaileysEx ships a durable, Elixir-native file persistence backend suitable for BEAM-only deployments.

- [x] Store credentials and key-store datasets as ETF binaries on disk.
- [x] Use crash-safe write semantics (temp file + flush/fsync + atomic rename) rather than best-effort overwrite.
- [x] Provide the same `use_*_auth_state` helper shape as the compatibility backend so callers can opt in without custom glue.
- [x] Keep the backend file-based and restart-safe; do not substitute an ETS-only or runtime-only approach.

### 15.3 Replace generic JSON term serialization in `FilePersistence`

**Files:**
- Modify: `lib/baileys_ex/auth/file_persistence.ex`
- Create: `test/baileys_ex/auth/file_persistence_compat_test.exs`
- Modify: `test/baileys_ex/auth/file_persistence_test.exs`
- Reference: `dev/reference/Baileys-master/src/Utils/use-multi-file-auth-state.ts`
- Reference: `dev/reference/Baileys-master/src/Utils/generics.ts`

**Required outcome:** the compatibility backend mirrors Baileys JSON intentionally, without relying on generic Elixir-term encoding tricks.

- [x] Remove generic atom/module reconstruction as the persistence mechanism.
- [x] Encode/decode each persisted family (`creds`, `session`, `sender-key`, `device-list`, etc.) through explicit known JSON shapes.
- [x] Keep compatibility with Baileys-style buffer tagging and per-file naming.
- [x] Preserve the observable helper contract of `use_multi_file_auth_state/1`.

### 15.4 Add format versioning and migration tooling

**Files:**
- Create: `lib/baileys_ex/auth/persistence_migration.ex`
- Modify: `lib/baileys_ex/auth/file_persistence.ex`
- Modify: `lib/baileys_ex/auth/native_file_persistence.ex`
- Create: `test/baileys_ex/auth/persistence_migration_test.exs`

**Required outcome:** current persisted auth directories continue to load, and migration between compatibility JSON and native durable storage is explicit and test-covered.

- [x] Version the persisted format for each built-in backend.
- [x] Load the current shipped JSON layout without forcing users to delete auth state.
- [x] Provide a one-step migration path from compatibility JSON to native durable storage.
- [x] Fail clearly on corrupt or unsupported data rather than silently dropping auth state.

### 15.5 Expose backend selection and update public guidance

**Files:**
- Modify: `lib/baileys_ex.ex`
- Modify: `README.md`
- Modify: `user_docs/guides/authentication-and-persistence.md`
- Modify: `user_docs/getting-started/first-connection.md`
- Modify: `user_docs/reference/configuration.md`
- Modify: `user_docs/troubleshooting/authentication-issues.md`

**Required outcome:** users can intentionally choose between the compatibility backend and the recommended native backend, and the docs explain the trade-off clearly.

- [x] Keep the Baileys-compatible helper available and documented as such.
- [x] Recommend the native durable backend for Elixir-first applications.
- [x] Explain that custom SQL/NoSQL backends remain supported via behaviour without making them mandatory for this phase.

### 15.6 Add cross-backend contract, survivability, and fresh-VM coverage

**Files:**
- Modify: `test/baileys_ex/public_api_test.exs`
- Modify: `test/baileys_ex/auth/key_store_test.exs`
- Modify: `test/baileys_ex/auth/file_persistence_test.exs`
- Modify: `test/baileys_ex/auth/native_file_persistence_test.exs`
- Create: `test/baileys_ex/auth/persistence_contract_test.exs`

**Required outcome:** both built-in backends are proven to produce the same runtime auth/key-store outcomes, and the durable backend is verified against restart and partial-write failure modes.

- [x] Add shared contract tests that exercise both backends through the same logical datasets.
- [x] Keep fresh-VM tests for the compatibility loader so warm-VM state never masks failures.
- [x] Add crash-survivability tests for native file writes, including interrupted-write and recovery paths where practical.
- [x] Verify the connection/runtime behaviour is backend-neutral for built-in helper usage.

---

## 5. Acceptance Criteria

- [x] `BaileysEx.Auth.FilePersistence` remains the Baileys-compatible multi-file helper and no longer relies on generic Elixir-term-over-JSON serialization.
- [x] `BaileysEx.Auth.NativeFilePersistence` provides a durable on-disk backend using OTP-native serialization and crash-safe file writes.
- [x] Existing persisted JSON auth directories from the current shipped format continue to load or migrate without requiring re-pairing.
- [x] The native backend is durable across restarts and partial-write failures; it is not an ETS-only or runtime-only solution.
- [x] Backend choice is explicit in public docs and helper surfaces: compatibility JSON vs recommended native durable storage.
- [x] `Auth.Persistence`, `Auth.KeyStore`, and the connection runtime continue to support custom persistence backends via behaviour.
- [x] Shared contract tests prove both built-in backends yield the same logical auth state and key-store behaviour for the same datasets.
- [x] Fresh-VM tests continue to cover compatibility persistence, and native persistence adds restart/recovery coverage.
- [x] `README.md`, `user_docs`, `00-overview.md`, `07-authentication.md`, and `PROGRESS.md` all describe the same persistence architecture.
- [x] The implementation plan no longer suggests that mirroring JS internals is a goal beyond observable behaviour and explicit compatibility promises.

## 6. Files Created/Modified

- `dev/implementation_plan/15-persistence-architecture.md`
- `dev/implementation_plan/00-overview.md`
- `dev/implementation_plan/07-authentication.md`
- `dev/implementation_plan/CLAUDE.md`
- `dev/implementation_plan/PROGRESS.md`
- `lib/baileys_ex/auth/persistence.ex`
- `lib/baileys_ex/auth/state.ex`
- `lib/baileys_ex/auth/file_persistence.ex`
- `lib/baileys_ex/auth/native_file_persistence.ex`
- `lib/baileys_ex/auth/persistence_migration.ex`
- `lib/baileys_ex/auth/key_store.ex`
- `lib/baileys_ex.ex`
- `README.md`
- `user_docs/guides/authentication-and-persistence.md`
- `user_docs/getting-started/first-connection.md`
- `user_docs/reference/configuration.md`
- `user_docs/troubleshooting/authentication-issues.md`
- `test/baileys_ex/auth/file_persistence_test.exs`
- `test/baileys_ex/auth/file_persistence_compat_test.exs`
- `test/baileys_ex/auth/native_file_persistence_test.exs`
- `test/baileys_ex/auth/persistence_migration_test.exs`
- `test/baileys_ex/auth/persistence_contract_test.exs`
- `test/baileys_ex/auth/key_store_test.exs`
- `test/baileys_ex/public_api_test.exs`
