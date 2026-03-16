# Phase 13 Parity Testing Design

## Purpose

Add an internal-only parity-validation phase that proves BaileysEx matches the
pinned `dev/reference/Baileys-master/` implementation more directly than the
current unit and simulated integration tests.

This phase is not product surface. It must not change the public API, `user_docs/`,
or the Hex package artifact set.

## Scope

Phase 13 is split into two validation tracks:

1. **Offline parity tooling** — required for phase completion
2. **Live WhatsApp validation harness** — manual scaffold, not a completion gate

The offline track compares Elixir outputs against the pinned Baileys reference
using direct Node execution and committed Baileys-generated fixtures. That
comparison is about observable behavior, not only serialization: returned
values, parsed output shape, deterministic event emission, error semantics, and
wire bytes where those bytes are themselves the contract. The live track gives
contributors a repeatable way to validate real sessions once dedicated accounts
exist.

## Non-Goals

- No public docs
- No end-user mix tasks
- No default public CI requirement
- No claim that live interoperability is proven without real accounts

## Architecture

### Offline parity

- A Node bridge under `dev/tools/` executes named Baileys reference operations.
- ExUnit helpers under `test/support/parity/` invoke that bridge and normalize results.
- Dedicated `test/baileys_ex/parity/` suites compare same-input same-output behavior.
- Existing media, Signal, syncd, and WAM vectors become part of one explicit parity program.
- Covered assertions must include outputs and behavior semantics, not just raw
  bytes. If Baileys returns a parsed structure, emits a deterministic event map,
  or fails with a known semantic outcome, the Elixir side should be compared at
  that same observable boundary.

### Live validation

- Manual harness scripts live under `dev/scripts/` and `dev/parity/live/`.
- Configuration is env-driven and assumes dedicated internal accounts/devices.
- The harness records what was exercised; it does not become a public or CI default.

## Success Criteria

- Contributors can run a single internal offline parity flow against the pinned
  Baileys reference.
- Parity coverage is broad enough to catch behavior drift across protocol,
  auth, messaging, features, syncd, and WAM.
- Covered parity suites compare functional output and expected behavior, not
  only low-level serialization.
- The repo contains a documented manual path for real-account validation when
  dedicated accounts are available.
