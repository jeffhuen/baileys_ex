# Implementation Plan — Agent Instructions

## Agent Onboarding — Read This First

Every fresh agent entering this project **must** orient in this order before touching any code.

1. **Root `CLAUDE.md`** — project purpose, architecture overview, native-first policy.
2. **`dev/implementation_plan/CLAUDE.md`** (this file) — workflow rules, delivery gates, dispatch modes.
3. **`dev/implementation_plan/PROGRESS.md`** — canonical task-level tracker. Find the first unchecked task. That is your starting point.
4. **The active phase file** — e.g., `01-foundation.md`. Read the full phase file, then focus on the active task spec.
5. **Read the Antipatterns docs** to avoid repeating historical mistakes:
   - `dev/implementation_plan/ANTIPATTERNS.md` — architectural and procedural failure modes to avoid.
   - `dev/implementation_plan/elixir-antipatterns.md` — Elixir-specific code, design, and OTP failure modes.
6. **Invoke the relevant thinking skill(s)** before writing any `.ex`/`.exs` file:
   - `/elixir-thinking` — always, for any Elixir code
   - `/otp-thinking` — for GenServer, Supervisor, Task, ETS, `:gen_statem`
   - `/rust-best-practices` — for Rust NIF code

**Before writing any code, run:**
```bash
git branch --show-current
```
The branch name tells you which phase you are on. Cross-check it against the first unchecked task in `PROGRESS.md`. If they don't match, stop and report — do not guess.

**Rules that apply immediately:**

- Do not begin implementation until you have completed steps 1–5 above and the branch/progress cross-check passes.
- Do not skip or reorder tasks in PROGRESS.md. Work sequentially within a phase.
- Every task must pass all delivery gates before committing.
- If a task's phase file is not yet written, stop and report — do not invent scope.
- **Baileys 7.00rc9 is the spec.** `dev/reference/Baileys-master/` is the authoritative
  reference for all wire behaviour, protocol semantics, message formats, handshake flows,
  and feature scope. When unsure what to implement or how something should behave, **read
  the Baileys source — do not ask, do not deliberate, do not design from scratch.** Port
  the behaviour faithfully, implement idiomatically in Elixir. The goal is a drop-in
  replacement for Elixir apps currently using Baileys (Node.js) as a sidecar.
- **Sequential by default; parallel only when safe.** See § Task Dispatch Modes below.
- **Deterministic by default.** Every function must produce identical output for
  identical input. All sources of non-determinism (random bytes, timestamps, UUIDs)
  must be injectable via options with sensible production defaults. See root `CLAUDE.md`
  § Deterministic by Default for the full policy including test vector requirements.

---

## Working Memory — Task Scratch Files

Agents lose context. Scratch files are the solution. Every agent working on a task **must** maintain a scratch file as external working memory.

**Location:** `dev/implementation_plan/scratch/task-N.N.md` (gitignored)

**Create it** when you start a task. Write to it continuously as you work.

**Minimum contents:**

```markdown
# Task N.N — <task name>
**Started:** YYYY-MM-DD
**Status:** in-progress | blocked | gates-passing | done

## What's done
- <bullet per completed sub-step>

## What's next
- <immediate next action>

## Decisions made
- <any non-obvious choice and why>

## Blockers
- <anything that stopped progress>

## Files created/modified
- <path> — <why>
```

**Context pressure rule — mandatory:** When your context window reaches ~10% remaining, you **must**:
1. Flush current state to `scratch/task-N.N.md` — be specific, not vague.
2. Commit the scratch file: `git add dev/implementation_plan/scratch/ && git commit -m "chore(scratch): flush task N.N working state — context handoff"`.
3. Stop. Do not start new work. The next agent reads the scratch file first.

**On resume after context loss or crash:**
1. Run `git branch --show-current` — confirm which phase branch you are on.
2. Check `git log --oneline -5` — see what was last committed.
3. Check `git status` — see what's staged or modified but not committed.
4. Read `dev/implementation_plan/scratch/task-N.N.md` if it exists — this is your working state.
5. Read `dev/implementation_plan/PROGRESS.md` — confirm which task is active.
6. **Cross-check:** the branch name must match the active phase in PROGRESS.md. If they don't match, stop and report.
7. Re-run delivery gates on current state before continuing. Do not assume prior work passed.
8. Continue from "What's next" in the scratch file.

**When a task is fully complete and gates pass:**
- Delete the scratch file (it's gitignored; no cleanup commit needed).
- Mark the task `[x]` in PROGRESS.md and commit.

**After a phase completes — starting the next phase:**
1. `git checkout main` — return to main.
2. Read `PROGRESS.md` — confirm the completed phase is done and identify the next phase.
3. `git checkout -b phase-NN-short-name` — create the next phase branch from main. Never start work on main directly.
4. Read the next phase file in full, then begin Task N.1.

---

## Branch and PR Convention

- **One branch per phase:** `phase-NN-short-name` (e.g. `phase-01-foundation`). Nothing commits to `main` directly.
- **One PR per phase** after all acceptance criteria pass.
- **Hotfixes:** go to `main`, then rebase the phase branch — never merge `main` into the branch.
- **PROGRESS.md on main** only reflects merged phases. In-progress phase tasks show unchecked on main — expected.

---

## Delivery Gates

Every task must pass these gates before committing.

**Gate 1 — Formatting:** `mix format --check-formatted`

**Gate 2 — Static analysis:** `mix compile --warnings-as-errors && mix credo --strict`
- If the task touches `native/baileys_nif`, also run `cargo fmt --check` and `cargo check` in `native/baileys_nif`.
- Boundary mistakes, dead code, compile warnings, and Credo violations are not optional cleanup. Fix them in the same task.

**Gate 3 — Type checking:** `mix dialyzer`
- Zero warnings.
- All public functions must have `@spec`.

**Gate 4 — Tests:** `mix test`
- All tests pass. Assertions must test actual values, not just shapes (`{:ok, _}` is not acceptable when the value is knowable).
- **Deterministic tests with pinned vectors:** All sources of non-determinism (random
  bytes, timestamps, UUIDs) must be injectable via function options. Tests must inject
  deterministic values and assert against pinned known-answer vectors — pre-computed
  literal binaries or hex digests, not recomputed expected values. Recomputing the
  expected value with the same algorithm you're testing (e.g.,
  `assert hash == :crypto.hash(:sha256, input)`) only proves consistency, not
  correctness. Pin the actual bytes: `assert hash == <<0xAB, 0xCD, ...>>`.
- **Property tests complement vectors:** Use StreamData properties to prove invariants
  (roundtrip, idempotency, bit-flip detection). Use pinned vectors to prove correctness
  against an external reference.
- If the task changes wire behavior, binary encoding/decoding, auth/session flows,
  Signal/Noise behavior, public socket surface, or parity fixtures, also run:
  `bash dev/scripts/run_parity_suite.sh`

**Gate 5 — Documentation (manual review required):** `mix docs`
- Docs must build without warnings.
- Follow [`documentation-system.md`](./documentation-system.md).
- No internal references in Layer 1 docs: `@moduledoc`, `@doc`, and code comments must not reference phase numbers, task numbers, gate numbers, or `dev/implementation_plan/*`.
- Glossary terms must match [`user_docs/glossary.md`](../../user_docs/glossary.md).
- Any task adding or changing a public configuration option must update [`user_docs/reference/configuration.md`](../../user_docs/reference/configuration.md) in the same commit.
- If the task changes a user-facing workflow, setup step, or failure mode, update the relevant page under `user_docs/getting-started/`, `user_docs/guides/`, or `user_docs/troubleshooting/` in the same commit.

**Gate 6 — DRY / existing-surface check (manual review required):**
- Verify the diff does not duplicate functionality that already exists in `Connection.*`, `Feature.*`, `Message.*`, `Media.*`, `Signal.*`, or `Protocol.*`.
- Re-read [`ANTIPATTERNS.md`](./ANTIPATTERNS.md) and [`elixir-antipatterns.md`](./elixir-antipatterns.md) for the failure modes relevant to the touched area.
- If the task adds a public helper, confirm the behavior is not already available under another module boundary before creating a second surface.

**Gate 7 — Native-first compliance (when applicable):**
- Use Erlang/Elixir/OTP primitives first. Rust NIF work is allowed only when the root `CLAUDE.md` native-first policy justifies it.
- If a task introduces or expands native code, the Elixir/Rust boundary must remain narrow, justified, and documented in the touched phase/task notes.
- Never move behavior into Rust just for familiarity or micro-optimization.

**Gate 8 — Baileys source parity (manual review required):**
- Cross-check the touched behavior against `dev/reference/Baileys-master/` at the relevant callsites, not just one obvious export.
- The implementation must match Baileys 7.00rc9 observable behavior for the same inputs: wire nodes, event output, helper return shape, config semantics, and error behavior.
- Do not invent new protocol behavior. If Baileys does not do it, we do not add it under the name of parity.
- If the parity understanding changes, update the active phase file, `PROGRESS.md`, and `dev/parity/` artifacts in the same task.

**Gate 9 — Full gate check (one-liner):**
```bash
mix format --check-formatted && \
mix compile --warnings-as-errors && \
mix credo --strict && \
mix dialyzer && \
mix test && \
mix docs
```
- This runs the standard Elixir commands for Gates 1–5. It does **not** cover the manual review parts of Gates 5–8.
- If native code was touched, also run the native commands from Gate 2.
- If parity-sensitive code was touched, also run `bash dev/scripts/run_parity_suite.sh`.

**Gate 10 — Task completion protocol (plan housekeeping — always required):**
1. Update the active phase file so the task/substep checkboxes reflect the actual completed state.
2. Update `dev/implementation_plan/PROGRESS.md`:
   - mark the task `[x]`
   - update the corresponding acceptance criteria checkboxes
   - update the file status table
3. Record every meaningful deviation from the plan in the active phase file. If the deviation affects later work, add a note in the downstream phase/task file too.
4. If the task changed parity understanding, update `dev/parity/baileys-js-vs-baileys-ex-surface-matrix.md` or the relevant parity artifact in the same commit.
5. If a scratch file exists for the task, delete it only after all gates are passing and the task is truly complete.

**Gate 11 — Commit** (only after Gates 1–10 pass).

---

## Task Dispatch Modes

Phases with 3+ tasks may use the orchestrator protocol. The lead agent acts as orchestrator — it does not implement tasks itself.

Single-task phases and hotfixes do not need this protocol.

### Mode 1: Sequential (default)

One agent per task. This is the default for all implementation work.

**Use when any of these apply:**
- Task involves design decisions or architectural choices
- Task depends on output or decisions from a prior task
- Task modifies shared contracts (behaviours, protocols, type specs)
- Task scope is not fully specified

### Mode 2: Parallel with worktree isolation

Multiple agents dispatched simultaneously, each with `isolation: "worktree"`.

**Use only when ALL three conditions hold:**
1. **Fully specified transformation** — no design decisions needed
2. **Non-overlapping file scope** — zero file intersection between workers
3. **No decision coupling** — no worker's choice affects another

**Safe parallel examples:**
- Writing independent test files for different modules
- Adding `@spec` to public functions, partitioned by directory
- Implementing independent feature modules with fully defined APIs

**Not safe for parallel:**
- Tasks that both touch `mix.exs`, `PROGRESS.md`, or config files
- Tasks where one defines an API and another implements a caller

### Mode 3: Research and exploration

Read-only work. Results feed back to the orchestrator for decision-making.

**Use for:**
- Exploring Baileys reference source to answer a design question
- Investigating competing approaches before choosing one
- Code review with multiple perspectives

**Tools:** `Explore` subagents for codebase searches. `Agent` for deeper research.

### Orchestrator responsibilities

1. Read the phase file to understand scope and task order.
2. For each task, determine the dispatch mode.
3. Dispatch workers.
4. After workers complete, run the verification checklist.
5. **Report results to the user and wait for go-ahead.** Do not auto-dispatch.
6. On user approval, dispatch the next task or batch.

The orchestrator **never writes implementation code**.

### Prompt templates

**Sequential worker:**
```
You are implementing Task N.N for the BaileysEx project.

**Branch:** <phase-branch-name>
**Task:** N.N — <task title>

## Onboarding
1. Read `CLAUDE.md` (root)
2. Read `dev/implementation_plan/CLAUDE.md`
3. Read `dev/implementation_plan/PROGRESS.md` — confirm this task is next
4. Run `git branch --show-current` — confirm correct branch
5. Invoke `/elixir-thinking` (and `/otp-thinking` if OTP work)

## Task spec
<paste the active task section from the phase file>

## Execution
1. Create scratch file: `dev/implementation_plan/scratch/task-N.N.md`
2. Implement the task following the spec.
3. Pass delivery gates:
   mix format --check-formatted && mix compile --warnings-as-errors && mix test
4. Update PROGRESS.md checkboxes.
5. Commit with specific files staged.
6. Delete the scratch file.
```

**Batch worker:**
```
You are a batch-worker for BaileysEx.

**Transformation:** <exact description of the change>
**Scope:** <list of files or directories this worker owns>

## Rules
- Apply ONLY the transformation described above to ONLY the files in scope.
- Do NOT make design decisions. If ambiguous, stop and report.
- Do NOT modify files outside your scope.

## Verification
mix format --check-formatted && mix compile --warnings-as-errors && mix test
```

---

## BaileysEx-Specific Rules

### How to Use This Plan

Each file (`01-foundation.md` through `12-polish.md`) is a self-contained phase.
`00-overview.md` has the full architecture and dependency graph.

1. **Work one phase at a time** unless phases are marked as parallel-safe.
2. **Read the phase doc completely** before starting any work.
3. **Follow the dependency graph** in `00-overview.md` — never start a phase before
   its dependencies are complete.
4. **Check acceptance criteria** at the end of each phase — all must pass before
   moving on.
5. **Baileys is the spec** — `dev/reference/Baileys-master/` (7.00rc9) is the
   authoritative reference. Read it first, don't guess or ask.

### First Step for Every Task

Before writing any code for a task, open the corresponding Baileys source file(s)
listed in the phase header, list every exported function, and verify each has a home
in the plan. The plan is the skeleton — the Baileys source is the spec for filling
in the details. If you find an exported function not covered by the plan, add it to
the appropriate task before proceeding.

### Parallel-Safe Phase Pairs

These can be worked on simultaneously (e.g., by worktree-isolated teammates):
- Phase 2 (Crypto) + Phase 3 (Protocol Layer) + Phase 4 (Noise NIF)
- Phase 5 (Signal — Pure Elixir) can start once Phase 2 completes, parallel with 3 + 4
- Phase 9 (Media) + Phase 10 (Features)

### Native-First Decision Policy

Before choosing any library, pattern, or approach:
1. **Elixir/Erlang first** — Use stdlib, OTP, or battle-tested Hex packages
2. **Prefer stdlib over deps** — `JSON` over Jason, `:crypto` over crypto NIFs,
   `Logger` over custom logging
3. **Rust NIF only when no native equivalent exists** — Noise protocol, XEdDSA
4. **Check OTP 28 capabilities** — many things previously needing deps are now built-in
   (PBKDF2, Ed25519, X25519, ML-KEM post-quantum, etc.)
5. Document WHY in the code if choosing a less obvious approach

### File Layout Convention

```
lib/baileys_ex/
├── native/      # Rust NIF wrappers (thin, typespecs only)
├── protocol/    # Wire protocol (binary encoding, protobuf, JID)
├── connection/  # OTP processes (gen_statem, GenServer, Supervisor)
├── auth/        # Authentication flows and persistence
├── signal/      # Signal protocol integration helpers
├── message/     # Message build/send/receive pipeline
├── media/       # Media encrypt/upload/download
├── feature/     # Stateless feature modules (groups, chats, etc.)
└── util/        # Shared utilities
```
