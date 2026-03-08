# Implementation Plan — Agent Instructions

## Agent Onboarding — Read This First

Every fresh agent entering this project **must** orient in this order before touching any code.

1. **Root `CLAUDE.md`** — project purpose, architecture overview, native-first policy.
2. **`dev/implementation_plan/CLAUDE.md`** (this file) — workflow rules, delivery gates, dispatch modes.
3. **`dev/implementation_plan/PROGRESS.md`** — canonical task-level tracker. Find the first unchecked task. That is your starting point.
4. **The active phase file** — e.g., `01-foundation.md`. Read the full phase file, then focus on the active task spec.
5. **Invoke the relevant thinking skill(s)** before writing any `.ex`/`.exs` file:
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
- **Cross-reference with Baileys source** in `dev/reference/Baileys-master/` for implementation details not covered in the plan.
- **Sequential by default; parallel only when safe.** See § Task Dispatch Modes below.

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

**Gate 2 — Compilation:** `mix compile --warnings-as-errors`

**Gate 3 — Tests:** `mix test`
- All tests pass. Assertions must test actual values, not just shapes (`{:ok, _}` is not acceptable when the value is knowable).

**Gate 4 — Static analysis:** `mix credo --all`

**Gate 5 — Type checking:** `mix dialyzer`

**Gate 6 — Docs build:** `mix docs`
- Docs must build without warnings.

**Gate 7 — Documentation quality:** Follow [`documentation-system.md`](./documentation-system.md).
- No internal references (phase numbers, GAP IDs, task numbers) in `@moduledoc`/`@doc`
- `@spec` on all public functions
- Guides updated if a user-facing API changes (Phase 12+)

**Gate 8 — Reference and acceptance parity:**
- Cross-check against `dev/reference/Baileys-master/` for the touched behavior.
- Update the active phase file / PROGRESS tracker if the implemented scope or status changed.

**Gate 9 — Task completion housekeeping:**
1. Update the task checkbox `[x]` in PROGRESS.md.
2. Update the corresponding acceptance criteria checkboxes.
3. Update the file status table (⬜ → ✅).

**Gate 10 — Full verification bundle:**
```bash
mix format --check-formatted && \
mix compile --warnings-as-errors && \
mix test && \
mix credo --all && \
mix dialyzer && \
mix docs
```

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
5. **Cross-reference with Baileys source** in `dev/reference/Baileys-master/` for
   implementation details not covered in the plan.

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
