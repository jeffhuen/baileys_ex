# Internal Parity Tooling

This directory is internal-only contributor tooling for Phase 13.

Nothing here is part of the public Hex package, public API, or `user_docs/`.
The goal is offline Baileys-vs-Elixir behavior checks against the pinned
reference in `dev/reference/Baileys-master/`.

The parity suite is excluded from default `mix test` runs and from the public
CI workflow. Run it only through the dedicated commands in this directory or
through `.github/workflows/parity-internal.yml`.

## Prerequisites

- Elixir 1.19+/OTP 28
- Node.js 20+
- the pinned Baileys reference checkout in `dev/reference/Baileys-master/`
- the reference checkout's `node_modules` present, including
  `dev/reference/Baileys-master/node_modules/.bin/tsx`

## Run The Current Parity Suite

From the repo root:

```bash
dev/scripts/run_parity_suite.sh
```

To run a narrower slice:

```bash
dev/scripts/run_parity_suite.sh test/baileys_ex/parity/protocol_test.exs
```

## Regenerate Internal Parity Fixtures

From the repo root:

```bash
dev/scripts/regenerate_parity_fixtures.sh
```

This refreshes the committed internal parity dataset under
`test/fixtures/parity/` by folding together:

- Signal fixtures from `dev/tools/generate_signal_fixtures.mts`
- Syncd vectors from `dev/scripts/generate_syncd_vectors.mjs`
- WAM definitions from `dev/scripts/generate_wam_definitions.mjs`
- the committed Baileys-generated media fixture already in tree

## Current Coverage

The offline parity suite currently covers these representative surfaces:

- protocol: WABinary `encodeBinaryNode` and `decodeBinaryNode`, plus core JID helpers
- auth: pairing-code key derivation and companion hello pairing payload construction
- messaging: deterministic WAProto content generation for text, reaction, and `limitSharing`
- features: presence send/subscribe/parse behavior and privacy IQ node construction
- syncd: committed Baileys-generated HKDF, MAC, LTHash, and WAProto vectors
- WAM: registry counts plus mixed global/event payload encoding

The Node runner lives at `dev/tools/run_baileys_reference.mts`.
The ExUnit bridge lives at `test/support/parity/node_bridge.ex`.
Shared parity helpers live at `test/support/parity/case.ex`.
The committed fixture dataset lives at `test/fixtures/parity/manifest.json`.

## Adding A New Offline Parity Target

1. Add one named operation to `dev/tools/run_baileys_reference.mts`.
2. Normalize the Baileys output to stable JSON.
3. Add or extend an ExUnit test under `test/baileys_ex/parity/`.
4. Compare the Baileys output directly against the Elixir implementation for the
   same input.
5. If the target needs committed fixtures, update `dev/tools/generate_parity_vectors.mts`
   and re-run `dev/scripts/regenerate_parity_fixtures.sh`.
6. Run `dev/scripts/run_parity_suite.sh`.

Keep the harness deterministic. Expectations should come from Baileys or from
committed Baileys-generated fixtures, not duplicated Elixir logic.

## Manual Live Validation

The offline suite is the hard gate for Phase 13, but a manual live harness also
exists for dedicated internal WhatsApp test accounts:

- overview: `dev/parity/live/README.md`
- checklist: `dev/parity/live/checklist.md`
- env-driven entrypoint: `mix run dev/scripts/run_live_validation.exs`
