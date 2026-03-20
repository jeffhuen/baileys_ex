# Phase 16: Signal Store Transaction Redesign

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the hidden caller-local `Signal.Store.transaction/3` model with an explicit transaction-scoped store contract, rewrite both built-in store implementations and all internal consumers in one pass, and preserve Baileys-visible runtime behavior.

**Architecture:** This phase keeps the `BaileysEx.Signal.Store` boundary, because protocol/session code still needs a small runtime store seam independent from durable persistence. What changes is the transaction model: instead of zero-argument closures plus hidden process-dictionary state, `transaction/3` will pass an explicit transaction-scoped store handle into the closure, and all reads/writes inside the transaction will operate through that handle. The redesign is intentionally all-at-once: no compatibility shim for the old transaction closure API, no dual-mode implementations, and no leftover hidden-state artifacts.

**Tech Stack:** Elixir 1.19+/OTP 28, ETS, existing `Signal.Store`, `Signal.Store.Memory`, `Auth.KeyStore`, `Signal.Repository`, and the Phase 15 native persistence architecture.

**Status:** COMPLETE

---

## 1. Scope Rules

- Preserve Baileys-visible behavior: session establishment, sender-key handling, app-state sync behavior, device discovery, message send/receive semantics, and public `connect/2` behavior must stay unchanged for normal consumers.
- Keep `BaileysEx.Signal.Store` as the runtime seam. Do not collapse store logic into repository, feature, or persistence modules.
- Remove hidden caller-local transaction state from the built-in store implementations. No `Process.get/put`-backed transaction context should remain in `Signal.Store.Memory` or `Auth.KeyStore`.
- Redesign the contract in one pass. Do not add a transitional compatibility layer for the old zero-argument transaction closure shape.
- Treat this as an internal architecture rewrite for standard consumers and a breaking change only for authors of custom `signal_store_module` implementations. `BaileysEx.connect/2`, the built-in auth helpers, and downstream apps such as Let It Claw that use those built-in paths should not need API or workflow changes.
- Do not weaken the current concurrency and rollback guarantees while removing the hidden transaction state.

---

## 2. Why This Phase Exists

Phase 5 introduced the runtime Signal store seam and Phase 7 added the persistence-backed `Auth.KeyStore`. That got the behavior right, but the transaction contract mirrored Baileys' `keys.transaction(async () => ...)` shape too literally:

- zero-argument transaction closures
- hidden transaction cache/mutation context in the caller process
- transaction semantics that are hard to type-check or reason about from the function boundary

That implementation is coherent, but it is not the clean Elixir/OTP 28 shape we want before the project hardens:

- transaction state should be explicit in the handle passed through the call graph
- runtime store semantics should remain swappable without requiring process-dictionary tricks
- nested transaction behavior should be expressed in the store contract, not inferred from hidden caller state

This phase applies the repo rule that Baileys is the observable-behavior spec, not the internal implementation template.

---

## 3. Design Decisions

### 3.1 Keep the store seam, redesign the transaction contract

`BaileysEx.Signal.Store` stays as the runtime boundary. Signal/session code still needs a small contract for:

- keyed reads
- batched writes/deletes
- per-key serialized work
- swappable implementations

The seam is justified. The current transaction API shape is not.

### 3.2 Explicit transaction-scoped store handles

The new transaction model should look like this at the call site:

```elixir
SignalStore.transaction(store, "session:alice", fn tx_store ->
  existing = SignalStore.get(tx_store, :session, ["alice.0"])
  :ok = SignalStore.set(tx_store, %{session: %{"alice.0" => updated}})
  existing
end)
```

Key properties:

- the closure receives an explicit transaction-scoped store handle
- `get/3`, `set/2`, `clear/1`, and `in_transaction?/1` continue to operate on the store handle
- no hidden caller-local mutation context exists outside the handle
- nested transactions reuse the explicit transactional handle instead of consulting process-local state

### 3.3 No compatibility shim for the old closure shape

This phase is intentionally a single break inside the library boundary:

- built-in stores are updated together
- internal consumers are updated together
- tests and docs move together

We do **not** keep both `fn -> ... end` and `fn tx_store -> ... end` transaction modes.

### 3.4 Standard consumers stay stable; custom store implementers must migrate

For normal consumers:

- `BaileysEx.connect/2` stays the same
- built-in auth helpers stay the same
- Let It Claw-style downstream apps using the built-in store/auth path should see no behavioral or workflow change

For custom `signal_store_module` implementers:

- this is the only public-facing contract change in the phase
- docs and types must say so clearly
- the migration is handled in this phase, not deferred behind compatibility glue

---

## 4. Tasks

### 16.1 Reframe the Signal store contract in the plan/docs

**Files:**
- Modify: `dev/implementation_plan/00-overview.md`
- Modify: `dev/implementation_plan/05-signal-protocol.md`
- Modify: `dev/implementation_plan/PROGRESS.md`

**Required outcome:** the plan docs clearly state that the Signal store seam remains, but the old hidden transaction model is being intentionally replaced before the project hardens.

- [x] Add a Phase 5 follow-up note so this phase reads as a contract cleanup, not a protocol reopening.
- [x] Update the overview/dependency map to include Phase 16 as a post-Phase-15 architecture follow-up.
- [x] Record clearly that this is behavior-neutral for standard consumers using the built-in store/auth path, but a breaking contract update for custom `signal_store_module` implementers.

### 16.2 Redesign `BaileysEx.Signal.Store`

**Files:**
- Modify: `lib/baileys_ex/signal/store.ex`
- Create or modify any supporting transaction handle module(s) under `lib/baileys_ex/signal/store/`
- Modify: `test/baileys_ex/signal/store_test.exs`

**Required outcome:** the runtime store contract uses explicit transaction-scoped store handles instead of hidden caller-local state.

- [x] Replace the zero-argument `transaction/3` callback contract with an explicit transaction-store argument.
- [x] Update `Store.transaction/3` facade types/docs so the new contract is unambiguous.
- [x] Keep `get/3`, `set/2`, `clear/1`, and `in_transaction?/1` behaviorally consistent from the caller's point of view.
- [x] Add focused contract tests for explicit transaction-handle semantics and nested transaction reuse.

### 16.3 Rewrite `Signal.Store.Memory` around explicit transaction state

**Files:**
- Modify: `lib/baileys_ex/signal/store/memory.ex`
- Modify: `test/baileys_ex/signal/store_test.exs`

**Required outcome:** the in-memory store keeps current behavior but no longer uses process dictionary state.

- [x] Remove `Process.get/put/delete` transaction state from the memory store.
- [x] Store transaction cache/mutation state on the explicit transaction handle or its owned runtime data structure.
- [x] Preserve per-key serialization, nested transaction reuse, and current read/write semantics.
- [x] Extend tests to prove the new transaction handle carries the state previously hidden in the caller process.

### 16.4 Rewrite `Auth.KeyStore` around explicit transaction state

**Files:**
- Modify: `lib/baileys_ex/auth/key_store.ex`
- Modify: `test/baileys_ex/auth/key_store_test.exs`

**Required outcome:** the persistence-backed store preserves caching, locking, rollback, and retry behavior without hidden caller-local transaction state.

- [x] Remove `Process.get/put/delete` transaction state from `Auth.KeyStore`.
- [x] Keep ETS-backed hot reads and cached misses.
- [x] Preserve rollback to the previous persisted snapshot when batch commit fails.
- [x] Preserve pre-key deletion safeguards and transaction-key locking behavior.
- [x] Add tests that prove the explicit transaction handle preserves commit/rollback correctness.

### 16.5 Migrate all internal store consumers in one pass

**Files:**
- Modify: `lib/baileys_ex/signal/adapter/signal.ex`
- Modify: `lib/baileys_ex/signal/prekey.ex`
- Modify: `lib/baileys_ex/signal/identity.ex`
- Modify: `lib/baileys_ex/signal/lid_mapping_store.ex`
- Modify: `lib/baileys_ex/feature/app_state.ex`
- Modify any additional internal consumer using `Store.transaction/3`
- Modify corresponding tests under `test/baileys_ex/signal/`, `test/baileys_ex/feature/`, `test/baileys_ex/auth/`, and `test/baileys_ex/public_api_test.exs`

**Required outcome:** all internal runtime consumers use the explicit transaction-store contract; no old transaction closure shape remains in library code.

- [x] Rewrite every `Store.transaction(store, key, fn -> ... end)` callsite to the explicit transaction-store form.
- [x] Update nested transaction callsites to reuse the explicit transaction handle instead of relying on hidden caller state.
- [x] Update test-only store implementations and fakes to match the new contract.
- [x] Confirm no `Signal.Store` implementation or internal consumer relies on hidden transaction state after the migration.

### 16.6 Document the contract and verify standard-consumer neutrality

**Files:**
- Modify: `lib/baileys_ex.ex`
- Modify: `user_docs/reference/configuration.md`
- Modify: `user_docs/guides/authentication-and-persistence.md`
- Modify: `README.md`
- Modify any API docs mentioning custom `signal_store_module`
- Modify: `test/baileys_ex/public_api_test.exs`
- Modify: `test/baileys_ex/auth/persistence_contract_test.exs`

**Required outcome:** docs and tests clearly distinguish standard-consumer stability from the custom-store contract change.

- [x] Document that standard consumers using built-in helpers and `connect/2` do not need workflow or API changes.
- [x] Document that custom `signal_store_module` implementers must update to the new explicit transaction-store contract.
- [x] Keep built-in helper/runtime tests proving the connection stack remains behavior-neutral for normal consumers.
- [x] Ensure all public-facing docs describe the same store/persistence story after the redesign.

---

## 5. Acceptance Criteria

- [x] `BaileysEx.Signal.Store.transaction/3` uses an explicit transaction-scoped store handle and no longer relies on hidden caller-local state.
- [x] `BaileysEx.Signal.Store.Memory` contains no process-dictionary transaction state and preserves current lock/commit behavior.
- [x] `BaileysEx.Auth.KeyStore` contains no process-dictionary transaction state and preserves current rollback/retry/pre-key safeguards.
- [x] All internal runtime consumers of `Store.transaction/3` are migrated in the same phase; no legacy zero-arg transaction closures remain in library code.
- [x] Standard consumers using `BaileysEx.connect/2` and the built-in auth helpers remain behaviorally unchanged and do not need workflow or API changes.
- [x] The docs explicitly call out that custom `signal_store_module` implementations must migrate to the new contract.
- [x] `PROGRESS.md`, `00-overview.md`, and `05-signal-protocol.md` all describe the same post-Phase-16 Signal store architecture.
- [x] Full store, auth, signal, feature, and public API tests cover the explicit transaction-store model and pass under the new contract.

## 6. Files Expected To Change

- `dev/implementation_plan/00-overview.md`
- `dev/implementation_plan/05-signal-protocol.md`
- `dev/implementation_plan/16-signal-store-transaction-redesign.md`
- `dev/implementation_plan/PROGRESS.md`
- `lib/baileys_ex/signal/store.ex`
- `lib/baileys_ex/signal/store/memory.ex`
- `lib/baileys_ex/auth/key_store.ex`
- `lib/baileys_ex/signal/adapter/signal.ex`
- `lib/baileys_ex/signal/prekey.ex`
- `lib/baileys_ex/signal/identity.ex`
- `lib/baileys_ex/signal/lid_mapping_store.ex`
- `lib/baileys_ex/feature/app_state.ex`
- `lib/baileys_ex.ex`
- `README.md`
- `user_docs/reference/configuration.md`
- `user_docs/guides/authentication-and-persistence.md`
- `test/baileys_ex/signal/store_test.exs`
- `test/baileys_ex/auth/key_store_test.exs`
- `test/baileys_ex/public_api_test.exs`
- relevant tests under `test/baileys_ex/signal/` and `test/baileys_ex/feature/`
