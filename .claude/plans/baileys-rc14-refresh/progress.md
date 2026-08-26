# Baileys rc14 refresh progress

## State

- Workflow: `phx-full`
- Current state: COMPLETED
- Branch: `phase-18-rc14-upstream-refresh`
- Upstream source: WhiskeySockets/Baileys `v7.0.0-rc14` (`7e7b075`)

## Workstreams

- [x] Discover official rc13-to-rc14 delta and all upstream runtime callsites.
- [x] Discover local Elixir implementation, test, documentation, and tracker surfaces.
- [x] Create and validate Phase 18 plan artifacts.
- [x] Refresh the pinned upstream reference.
- [x] Implement version, TC-token/profile, and Android behavior.
- [x] Update target docs, parity matrix, and progress trackers.
- [x] Run focused verification and all project delivery gates.
- [x] Complete independent review passes and resolve findings.
- [x] Capture the reusable solution and commit the completed phase.

## Invariants

- `Baileys v7.0.0-rc14` is the behavioral spec.
- Query TC-token nodes and direct message-relay TC-token nodes remain separate APIs.
- All nondeterministic test inputs are injected or literal.
- No new process is introduced; the changes are pure payload/config construction.
- The user's untracked `.claude/settings.json` is never staged or modified.

## Verification ledger

- `mix format --check-formatted` — passed.
- `mix compile --warnings-as-errors` — passed on Elixir 1.20.3/OTP 29.
- `mix credo --strict` — passed with no issues.
- `mix dialyzer` — passed with zero errors, skips, or unnecessary skips.
- Focused RC14 runtime tests — 108 passed.
- Focused compiler-cleanup regression tests — 167 passed.
- `mix test` — 956 passed, including 13 properties; 20 parity-tagged tests excluded.
- `bash dev/scripts/run_parity_suite.sh` — 20 passed.
- `mix docs` — passed without warnings.
- `mix hex.build` — package built successfully.
- Upstream reference comparison — 196 tracked files, 0 mismatches.
- Independent reviews — upstream parity and Elixir design clean; three
  scope/completeness findings resolved and parity rerun successfully.
