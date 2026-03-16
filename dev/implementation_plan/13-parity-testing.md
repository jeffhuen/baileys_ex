# Phase 13: Internal Parity Validation

**Goal:** Internal-only parity tooling that proves BaileysEx matches the pinned
Baileys reference offline, plus a manual live-validation harness for dedicated
WhatsApp test accounts.

**Depends on:** Phase 12 (Polish)
**Blocks:** —
**Status:** NOT STARTED

**Internal-only note:** Nothing in this phase is part of the public library
surface, Hex package, or `user_docs/`. Keep all implementation under `dev/`,
`test/`, `test/support/`, and optional internal CI workflows.

**Baileys reference:**
- `dev/reference/Baileys-master/src/WABinary/*.ts`
- `dev/reference/Baileys-master/src/Utils/*.ts`
- `dev/reference/Baileys-master/src/Signal/**/*.ts`
- `dev/reference/Baileys-master/src/Socket/**/*.ts`
- `dev/reference/Baileys-master/WAProto/index.js`

---

## Design Decisions

**Offline parity is the hard gate.**
Phase 13 completes when the repo can execute deterministic offline parity checks
against the pinned Node.js Baileys reference for representative protocol,
auth, messaging, feature, media, syncd, and WAM surfaces. This phase must not
depend on owning live WhatsApp accounts.

**Observable behavior parity is the target, not just bytes.**
The parity harness must compare the same externally visible behavior Baileys
produces for the same inputs:
- returned values and parsed outputs,
- emitted events and their sequencing where deterministic,
- error tuples / failure semantics,
- serialized nodes and protobuf bytes where those are the observable contract,
- and deterministic state transitions or side effects that can be asserted
  without a live WhatsApp session.

**Live validation is real, but manual.**
The phase also adds a live-validation harness shape for dedicated internal test
accounts. That harness is intentionally manual and gated; it exists so the team
can validate the true end-to-end purpose of the project without pretending that
public CI or Hex users should run it.

**The Node reference is the oracle.**
Do not duplicate expected values in Elixir when the Baileys reference can
generate them. Prefer:
- direct Node-vs-Elixir same-input comparisons,
- committed Baileys-generated fixtures,
- or vector generators that execute the pinned reference source.

**This phase ships no user-facing behavior.**
No public API additions, no `user_docs/`, no Hex-package expansion, and no
public CI gate changes. Internal workflows may be added under `.github/`, but
they must be opt-in and clearly marked as contributor-only parity jobs.

---

## Tasks

### 13.1 Offline parity harness foundation

Create a reusable bridge that lets ExUnit run the pinned Baileys reference and
compare normalized outputs with Elixir implementations.

**Files:**
- `dev/tools/run_baileys_reference.mts`
- `test/support/parity/node_bridge.ex`
- `test/support/parity/case.ex`

The bridge should accept structured JSON input, execute a named Baileys
operation from the pinned reference tree, normalize the output to stable JSON,
and return it to Elixir for parity assertions.

### 13.2 Fixture and vector generation pipeline

Consolidate the existing ad hoc Baileys-generated fixtures into an explicit
internal parity dataset pipeline and add new generators where the current suite
still relies on hand-written expectations.

**Files:**
- `dev/tools/generate_signal_fixtures.mts` (fold into parity pipeline)
- `dev/scripts/generate_syncd_vectors.mjs` (fold into parity pipeline)
- `dev/tools/generate_parity_vectors.mts`
- `test/fixtures/parity/**/*`

This task should make it obvious which fixtures come from Baileys, how to
regenerate them, and which subsystem each fixture covers.

### 13.3 Offline parity suites by subsystem

Add a dedicated `:parity` test area that covers the highest-risk offline
surfaces with same-input same-output comparisons against Baileys.

**Files:**
- `test/baileys_ex/parity/protocol_test.exs`
- `test/baileys_ex/parity/auth_test.exs`
- `test/baileys_ex/parity/message_test.exs`
- `test/baileys_ex/parity/feature_test.exs`
- `test/baileys_ex/parity/syncd_test.exs`
- `test/baileys_ex/parity/wam_test.exs`

Representative parity targets:
- binary node encode/decode, JID normalization, and decoded output shape,
- login/registration payload serialization plus parsed output semantics,
- message content/build serialization, returned send metadata, and deterministic
  normalization for injected message inputs,
- feature-level IQ/message node construction plus parsed response/output shapes,
- syncd encoding/decoding, patch processing, emitted mutation results, and
  version/hash side effects,
- WAM encoding for supported event definitions.

### 13.4 Internal parity commands and contributor docs

Document the internal-only parity workflow and provide stable entrypoints for
contributors without exposing any of it as public documentation.

**Files:**
- `dev/parity/README.md`
- `dev/scripts/run_parity_suite.sh`
- `dev/scripts/regenerate_parity_fixtures.sh`

This should define:
- required local tools,
- how to regenerate fixtures,
- how to run just the parity suite,
- and how to interpret a Baileys-vs-Elixir mismatch.

### 13.5 Internal CI hook for offline parity

Add an opt-in workflow for contributors and maintainers that runs the offline
parity suite without making it part of the public delivery gate.

**Files:**
- `.github/workflows/parity-internal.yml`

Use `workflow_dispatch` and/or restricted triggers. This job is for internal use
only and must not become a default public PR requirement.

### 13.6 Manual live-validation harness skeleton

Add a manual harness for dedicated internal WhatsApp test accounts so the team
can validate the real end-to-end behavior when accounts are available.

**Files:**
- `dev/parity/live/README.md`
- `dev/scripts/run_live_validation.exs`
- `dev/parity/live/checklist.md`

The harness should be env-driven, explicitly manual, and cover:
- QR pairing,
- phone-code pairing,
- connect/open/reconnect,
- send/receive text,
- send/receive one media type,
- one app-state sync change,
- and one group/community sanity path.

---

## Acceptance Criteria

- [ ] All Phase 13 tooling lives only under `dev/`, `test/`, `test/support/`, and optional internal CI files
- [ ] Offline parity runner executes the pinned Baileys reference and returns normalized outputs to ExUnit
- [ ] Existing Baileys-generated media, Signal, syncd, and WAM vectors are folded into a single internal parity program
- [ ] Dedicated `:parity` test suites cover representative protocol, auth, messaging, feature, syncd, and WAM surfaces
- [ ] For the covered surfaces, the parity harness asserts the same observable behavior Baileys produces for the same inputs: outputs, parsed values, emitted events, deterministic side effects, and error semantics
- [ ] Offline parity assertions derive expectations from Baileys or committed Baileys-generated fixtures, not duplicated Elixir logic
- [ ] Offline parity tests are contributor-only and not required for end users or Hex consumers
- [ ] Internal CI can run the offline parity suite on demand without changing the public delivery gates
- [ ] A manual live-validation harness exists for dedicated test accounts, with env-driven setup and a written checklist
- [ ] Phase completion does not require live-account access, but the live harness is ready when accounts exist
- [ ] `PROGRESS.md`, `00-overview.md`, and internal parity docs clearly mark this phase as non-shipping internal tooling

## Files Created/Modified

- `dev/implementation_plan/13-parity-testing.md`
- `dev/parity/README.md`
- `dev/parity/live/README.md`
- `dev/parity/live/checklist.md`
- `dev/tools/run_baileys_reference.mts`
- `dev/tools/generate_parity_vectors.mts`
- `dev/scripts/run_parity_suite.sh`
- `dev/scripts/regenerate_parity_fixtures.sh`
- `dev/scripts/run_live_validation.exs`
- `test/support/parity/node_bridge.ex`
- `test/support/parity/case.ex`
- `test/baileys_ex/parity/**/*_test.exs`
- `test/fixtures/parity/**/*`
- `.github/workflows/parity-internal.yml`
