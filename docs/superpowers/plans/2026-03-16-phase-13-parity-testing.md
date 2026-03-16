# Phase 13 Parity Testing Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build internal-only parity validation tooling that compares BaileysEx against the pinned Baileys reference offline at the observable-behavior boundary and provides a manual live-validation harness for dedicated WhatsApp test accounts.

**Architecture:** Keep everything dev/test-only. Use a Node bridge under `dev/tools/` as the oracle for offline parity, ExUnit helpers and parity-tagged suites under `test/`, and a separate manual live harness under `dev/` that never becomes part of the public library or Hex package. Compare same-input same-output behavior first: returned values, parsed outputs, event maps, deterministic side effects, and error semantics. Only compare raw bytes directly when wire bytes are the observable contract.

**Tech Stack:** ExUnit, Elixir test support modules, Node.js/TypeScript against `dev/reference/Baileys-master/`, shell scripts, GitHub Actions `workflow_dispatch`

---

## Chunk 1: Offline Harness Foundation

### Task 1: Build the Node reference bridge

**Files:**
- Create: `dev/tools/run_baileys_reference.mts`
- Create: `test/support/parity/node_bridge.ex`
- Create: `test/support/parity/case.ex`
- Modify: `test/test_helper.exs`

- [ ] Add a Node entrypoint that accepts JSON input, dispatches to named Baileys reference operations, and prints normalized JSON output.
- [ ] Add an Elixir bridge wrapper that executes the Node entrypoint and decodes its JSON results.
- [ ] Add a shared parity test case helper for deterministic setup and mismatch formatting.
- [ ] Wire the parity helpers into the test helper without enabling them for ordinary end users.
- [ ] Verify the bridge with one smoke test that compares a trivial reference-backed operation.

### Task 2: Consolidate fixture generation

**Files:**
- Create: `dev/tools/generate_parity_vectors.mts`
- Modify: `dev/tools/generate_signal_fixtures.mts`
- Modify: `dev/scripts/generate_syncd_vectors.mjs`
- Create: `test/fixtures/parity/.gitkeep`

- [ ] Add a single parity-vector generator entrypoint that documents or orchestrates subsystem-specific generators.
- [ ] Refactor the existing Signal and syncd generators into the parity pipeline instead of leaving them as standalone one-offs.
- [ ] Define the directory layout for parity fixtures under `test/fixtures/parity/`.
- [ ] Document regeneration commands inside the generator files.

## Chunk 2: Offline Parity Coverage

### Task 3: Add protocol/auth/message parity suites

**Files:**
- Create: `test/baileys_ex/parity/protocol_test.exs`
- Create: `test/baileys_ex/parity/auth_test.exs`
- Create: `test/baileys_ex/parity/message_test.exs`

- [ ] Write failing parity tests for binary node encoding, JID normalization, and one protocol serialization path.
- [ ] Add auth parity tests for deterministic login/registration payload serialization and parsed output semantics.
- [ ] Add message parity tests for deterministic content/build paths where timestamps, message ids, and randomness are injected, asserting both serialized output and returned metadata where applicable.
- [ ] Verify each suite compares Elixir output and behavior against Baileys output and behavior rather than duplicated expected values.

### Task 4: Add feature/syncd/WAM parity suites

**Files:**
- Create: `test/baileys_ex/parity/feature_test.exs`
- Create: `test/baileys_ex/parity/syncd_test.exs`
- Create: `test/baileys_ex/parity/wam_test.exs`

- [ ] Add feature parity tests for representative IQ/message node builders across groups, privacy, profile, newsletter, and community surfaces, plus parsed response/output shapes where deterministic.
- [ ] Fold the existing syncd vector coverage into a dedicated parity suite structure and assert emitted mutation/output behavior, not just bytes.
- [ ] Add WAM parity assertions against Baileys-derived definitions and encoded bytes.
- [ ] Tag all parity suites clearly so they can be run as an internal group.

## Chunk 3: Internal Operations and Live Validation

### Task 5: Add contributor-only commands and workflow

**Files:**
- Create: `dev/parity/README.md`
- Create: `dev/scripts/run_parity_suite.sh`
- Create: `dev/scripts/regenerate_parity_fixtures.sh`
- Create: `.github/workflows/parity-internal.yml`

- [ ] Document local prerequisites and the internal-only nature of the parity suite.
- [ ] Add a stable shell entrypoint for running the offline parity suite.
- [ ] Add a stable shell entrypoint for regenerating parity fixtures.
- [ ] Add an opt-in internal GitHub Actions workflow for offline parity only.
- [ ] Ensure the workflow does not become a required public delivery gate.

### Task 6: Add the manual live-validation harness

**Files:**
- Create: `dev/parity/live/README.md`
- Create: `dev/parity/live/checklist.md`
- Create: `dev/scripts/run_live_validation.exs`

- [ ] Document the required dedicated test accounts/devices and environment variables.
- [ ] Add a manual harness script shape for pairing, connection, message send/receive, media, app-state, and group/community sanity checks.
- [ ] Add a checklist that contributors can use to record what was exercised in a live run.
- [ ] Keep the harness manual and non-blocking when accounts are unavailable.

## Verification

- [ ] Run the focused parity suite locally once the bridge and first tests exist.
- [ ] Run `mix format --check-formatted`
- [ ] Run `mix compile --warnings-as-errors`
- [ ] Run `mix test`
- [ ] Run `mix credo --all`
- [ ] Run `mix dialyzer`
- [ ] Run `mix docs`
- [ ] Confirm no Phase 13 files are added to public docs or Hex package file lists.

## Tracking

- [ ] Keep `dev/implementation_plan/13-parity-testing.md` aligned with implementation status.
- [ ] Keep `dev/implementation_plan/PROGRESS.md` phase summary, checkboxes, and totals aligned.
- [ ] Keep `dev/implementation_plan/00-overview.md` dependency map aligned.
