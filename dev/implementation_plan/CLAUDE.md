# Implementation Plans — Agent Instructions

> **Engineering rules** (dependency gates, SOTA policy, quality priorities, doc discipline) live in [`dev/CLAUDE.md`](../CLAUDE.md). Read that file too — it applies to all work in this project.

## Agent Onboarding — Read This First

Every fresh agent entering this project **must** orient in this exact order before touching any code.

Steps 1–2 are files you likely traversed to reach this file. Confirm you have read them — do not skip them if you haven't.

1. **Root `CLAUDE.md`** — project purpose, architecture overview, key modules. *(You arrived here through this.)*
2. **`dev/CLAUDE.md`** — engineering rules: dependency gates, SOTA policy, quality priorities, doc discipline. *(You arrived here through this.)*
3. **`dev/implementation_plan/README.md`** (this directory) — phased build order, delivery gates (all 10), phase completion protocol, vertical slice checkpoints. **Read fully. No skipping.**
4. **`dev/implementation_plan/progress.md`** — canonical task-level tracker. Find the first unchecked task. That is your starting point. Do not start any other task.
5. **The active phase file** — listed in progress.md next to your task (e.g., `phase-01.md`). Read the full phase file, then read only the active task spec.
6. **`dev/implementation_plan/ANTIPATTERNS.md`** — 20 antipatterns documented from real failures. Read before writing any code.
7. **`dev/AGENTS.md`** — dependency usage rules (Ash, Spark, Igniter, etc.). Consult before using any package.
8. **`dev/implementation_plan/boundary-usage.md`** — Boundary ~> 0.10 usage guide for this project. Read before writing any `use Boundary` declaration or touching `mix.exs` boundary config. Covers: unclassified-module warnings, phased setup, `top_level?`, `deps:`, `exports:`, test support, and common mistakes.
9. **`dev/docs/elixir-antipatterns.md`** — 25+ code-level BAD/GOOD patterns covering style, design, processes, macros, and memory. Cross-check your code against these before committing.
10. **Invoke the relevant thinking skill(s)** before writing any `.ex`/`.exs` file. Skills contain paradigm-specific guidance that prevents the antipatterns in steps 6 and 9. See the routing table in `dev/CLAUDE.md` § Required Skill Invocation.

**Before writing any code, run:**
```bash
git branch --show-current
```
The branch name tells you which phase you are on. Cross-check it against the first unchecked task in `progress.md`. If they don't match, stop and report — do not guess.

**Rules that apply immediately:**

- Do not begin implementation until you have completed steps 1–10 above and the branch/progress cross-check passes.
- Do not skip or reorder tasks in progress.md. Work sequentially.
- Every task must pass all 11 delivery gates before committing. The shell one-liner is necessary but not sufficient — Gates 4–8 have manual review requirements. See the Delivery Gates section below.
- If a task's phase file is not yet written, stop and report — do not invent scope.
- Never create a file without checking `filesystem-organization.md` first.
- **Never handwrite database migrations.** All schema changes must be driven declaratively through Ash resources. Always use `mix ash.codegen --name <name>` to generate migrations and `mix ash.migrate` to apply them. These commands are data layer agnostic and ensure drop-in compatibility across different database backends (e.g., SQLite, Postgres).
- **Sequential by default; parallel only when safe.** This project prioritises accuracy over speed. Three dispatch modes are available — the orchestrator selects the appropriate mode per task. See § Task Dispatch Modes below for full details.
  1. **Sequential** (default) — one `phase-worker` agent per task, full onboarding and delivery gates. Used for all design-heavy, dependency-coupled, or contract-defining work.
  2. **Parallel with worktree isolation** — multiple `batch-worker` agents, each in its own git worktree. Used only when all three conditions hold: (a) fully specified transformation, (b) non-overlapping file scope, (c) no decision coupling. Orchestrator merges worktree branches and re-runs gates on the combined result.
  3. **Read-only research** — no files written, results feed a single decision (e.g. exploring reference repos to answer a design question). Use `Explore` subagents or Agent Teams.

## Working Memory — Task Scratch Files

Agents lose context. Scratch files are the solution. Every agent working on a task **must** maintain a scratch file as external working memory.

**Location:** `dev/implementation_plan/scratch/task-N.N.md` (gitignored — not committed unless explicitly promoted)

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
1. Run `git branch --show-current` — confirm which phase branch you are on (e.g. `phase-01-foundation`).
2. Check `git log --oneline -5` — see what was last committed.
3. Check `git status` — see what's staged or modified but not committed.
4. Read `dev/implementation_plan/scratch/task-N.N.md` if it exists — this is your working state.
5. Read `dev/implementation_plan/progress.md` — confirm which task is active.
6. **Cross-check:** the branch name must match the active phase in `progress.md`. If they don't match, stop and report — do not guess or continue.
7. Re-run delivery gates on current state before continuing. Do not assume prior work passed.
8. Continue from "What's next" in the scratch file.

**When a task is fully complete and gates pass:**
- Delete the scratch file (it's gitignored; no cleanup commit needed).
- Mark the task `[x]` in progress.md and commit normally per the delivery gate protocol.

**After a phase PR merges — starting the next phase:**
1. `git checkout main && git pull origin main` — confirm you are on updated main.
2. Read `progress.md` — confirm the completed phase is stamped ✅ and identify the next phase.
3. `git checkout -b phase-NN-short-name` — create the next phase branch from updated main. Never start work on main.
4. If the next phase opens immediately after a VSC, run the checkpoint smoke test before writing any code.
5. Read the next phase file in full, then begin Task N.1.

If you are not sure which phase comes next, check `progress.md` — the first unchecked phase heading is your target.

## Task Dispatch Modes — Multi-Task Phase Execution

Phases with 3+ tasks **must** use the orchestrator protocol. The lead agent acts as orchestrator — it does not implement tasks itself. It selects the dispatch mode, dispatches workers, verifies completion, reports to the user, and waits for approval before dispatching the next task or batch.

Single-task phases and hotfixes do not need this protocol.

Custom agent definitions for all roles live in `.claude/agents/`:
- **`orchestrator.md`** — Haiku model. Dispatch, verification, and communication. Never writes code.
- **`phase-worker.md`** — Sonnet model. Sequential implementation with full onboarding and delivery gates.
- **`batch-worker.md`** — Sonnet model, `isolation: worktree`. Parallel transformations in isolated worktrees.

### Dispatch mode selection

For each task (or group of tasks), the orchestrator selects one of three modes:

#### Mode 1: Sequential (default)

One `phase-worker` per task, dispatched via the Task tool. This is the default for all implementation work.

**Use when any of these apply:**
- Task involves design decisions or architectural choices
- Task depends on output or decisions from a prior task
- Task modifies shared contracts (behaviours, protocols, type specs used by other modules)
- Task scope is not fully specified (agent must interpret or invent)

#### Mode 2: Parallel with worktree isolation

Multiple `batch-worker` agents dispatched simultaneously, each with `isolation: "worktree"`. Each worker gets its own copy of the repo and works independently.

**Use only when ALL three conditions hold:**
1. **Fully specified transformation** — the change is completely defined in the dispatch prompt. No design decisions, no interpretation needed. The agent applies a known pattern.
2. **Non-overlapping file scope** — each worker's expected file set has zero intersection with other workers'. Verify before dispatch.
3. **No decision coupling** — no worker needs to make a choice that another worker must respect.

**Examples of safe parallel work:**
- Adding `@spec` to all public functions, partitioned by subsystem directory
- Mass module renames with the transformation fully defined
- Applying the same mechanical fix (e.g., deprecation migration) across independent subsystems
- Writing independent test files for different modules

**Examples that look parallel but aren't safe:**
- Two tasks that both touch a shared behaviour or protocol
- Tasks that both update `mix.exs`, `progress.md`, or config files
- Tasks where one defines an API and another implements a caller of that API

#### Mode 3: Research and exploration

Read-only work that produces no file changes. Results feed back to the orchestrator for decision-making.

**Use for:**
- Exploring reference repos to answer a design question
- Investigating competing approaches before choosing one
- Code review with multiple perspectives (security, performance, test coverage)

**Tools:** `Explore` subagents for simple searches. Agent Teams (experimental) for work that benefits from inter-agent debate or competing hypotheses — e.g., debugging with multiple theories, multi-perspective code review, or design exploration where agents should challenge each other's findings.

### Orchestrator responsibilities

1. Read the phase file once to understand scope and task order.
2. For each task, determine the dispatch mode (see above).
3. Dispatch workers:
   - Sequential: one `phase-worker` at a time via Task tool.
   - Parallel: multiple `batch-worker` agents via Task tool with `isolation: "worktree"`.
   - Research: `Explore` subagents or Agent Teams as appropriate.
4. After workers complete, run the verification checklist (below).
5. **Report results to the user and wait for go-ahead.** Do not auto-dispatch.
6. On user approval, dispatch the next task or batch. On rejection, discuss with user.

The orchestrator **never writes implementation code**. Its job is dispatch, verification, and communication.

### Sequential dispatch — subagent prompt template

Each `phase-worker` receives a structured prompt. Adapt this template per task:

```
You are implementing Task N.N for the Let It Claw project.

**Branch:** <phase-branch-name>
**Task:** N.N — <task title>

## Mandatory onboarding — complete before writing any code

1. Read `CLAUDE.md` (root)
2. Read `dev/CLAUDE.md`
3. Read `dev/implementation_plan/CLAUDE.md` — full file
4. Read `dev/implementation_plan/progress.md` — confirm this task is the next unchecked item
5. Run `git branch --show-current` — confirm you are on the correct phase branch
6. Read `dev/implementation_plan/ANTIPATTERNS.md`
7. Read `dev/AGENTS.md`
8. Read `dev/implementation_plan/boundary-usage.md`
9. Read `dev/docs/elixir-antipatterns.md` — 25+ code-level BAD/GOOD patterns
10. Invoke the relevant thinking skill(s) before writing any code:
    - `/elixir-thinking` — always, for any Elixir code
    - `/use-ash` — for any Ash related resources, actions, domain modeling
    - `/phoenix-thinking` — for LiveView, channels, components
    - `/otp-thinking` — for GenServer, Supervisor, Task, ETS
    - `/ecto-thinking` — for schemas, changesets, queries
    - `/oban-thinking` — for background jobs, workflows
    Invoke all that apply. Skills are the HOW; antipattern docs are the WHAT NOT TO DO.

## Task spec

<paste or reference only the active task section from the phase file — not the entire phase>

## Context budget rules

- Read only the files listed in the task spec's **Files:** section and files you need to modify.
- Do NOT read the entire phase file — you have the task spec above.
- Do NOT read other tasks' specs, completed task specs, or reference repos (unless the task spec says to).
- Use an Explore subagent for any research (codebase search, pattern discovery). This protects your context window.
- Write to your scratch file continuously, not just at context pressure.

## Execution protocol

1. Create scratch file: `dev/implementation_plan/scratch/task-N.N.md`
2. Implement the task following the spec.
3. Pass all 11 delivery gates. Run the gate one-liner:
   mix format --check-formatted && mix compile --warnings-as-errors && mix credo --strict && mix dialyzer && mix test && mix docs
4. Complete Gate 10 (STATUS banner, deviations, progress.md update).
5. Commit (Gate 11) with specific files staged.
6. Delete the scratch file after successful commit.

If you hit context pressure (~10% remaining), flush scratch file, commit it, and stop.
If gates fail, fix the issue and re-run. Do not skip gates.
```

### Parallel dispatch — batch prompt template

Each `batch-worker` receives a focused transformation prompt. No onboarding sequence — the transformation is self-contained:

```
You are a batch-worker for the Let It Claw project.

**Transformation:** <exact description of the change to apply>
**Scope:** <list of files or directories this worker owns>

## Rules

- Apply ONLY the transformation described above to ONLY the files in scope.
- Do NOT make design decisions. If something is ambiguous, stop and report.
- Do NOT modify files outside your scope.

## Verification

Run delivery gates in your worktree before committing:
mix format --check-formatted && mix compile --warnings-as-errors && mix credo --strict && mix dialyzer && mix test && mix docs

If gates pass, commit. If gates fail and the fix is within your transformation scope, fix and re-run. If the fix requires a design decision, stop and report.
```

### Orchestrator verification checklist

**After sequential dispatch (per task):**

1. `git log --oneline -3` — confirm the worker committed.
2. `git diff HEAD~1 --stat` — review files changed.
3. `mix format --check-formatted && mix compile --warnings-as-errors && mix test` — spot-check gates.
4. Check `progress.md` — confirm the task is marked `[x]`.

**After parallel dispatch (per batch) — additional merge step:**

1. Confirm all batch-workers committed in their worktrees.
2. Merge each worktree branch into the phase branch.
3. Run **full** delivery gates on the merged result:
   `mix format --check-formatted && mix compile --warnings-as-errors && mix credo --strict && mix dialyzer && mix test && mix docs`
4. If merge conflicts or gate failures occur, report to user — do not auto-fix.
5. Update `progress.md` for all completed tasks in the batch.

**Report to the user:**
- Task ID(s) and title(s)
- Files created/modified (from git diff)
- Any deviations noted in task files
- Gate spot-check result (pass/fail)
- For batches: merge result and combined gate status

**Wait for user go-ahead before dispatching the next task or batch.**

### Failure handling

- **Gates fail:** Report failure to user. Do not auto-retry. The user decides whether to re-dispatch, fix manually, or adjust scope.
- **Context pressure:** Worker flushes scratch file (sequential) or stops (batch). Report to user. User decides: resume or start the task fresh.
- **Regression:** If a worker's commit breaks a previously-passing test, the orchestrator catches this in the gate spot-check. Report to user — do not dispatch next task until resolved.
- **Merge conflict (parallel):** Report the conflict to the user with the conflicting files and workers. Do not auto-resolve. The user decides: manual resolution, re-dispatch sequentially, or adjust scope.
- **Worker diverges from spec:** The orchestrator does not review code quality — that's the user's job during the pause. The orchestrator only verifies mechanical gate passage.

## Branch and PR Convention (quick reference)

Full rules: [`README.md#branch-and-pr-convention`](./README.md#branch-and-pr-convention).

- **One branch per phase:** `phase-NN-short-name` (e.g. `phase-01-foundation`). Nothing commits to `main` directly.
- **One PR per phase** after Phase Completion protocol is done. VSCs are always PR boundaries.
- **Split PRs** only when a sub-group is independently verifiable and the split is declared in the phase file before work begins.
- **Hotfixes:** go to `main`, then rebase the phase branch — never merge `main` into the branch.
- **progress.md on main** only reflects merged phases. In-progress phase tasks show unchecked on main — expected.

## Delivery Gates

Full definitions: [`README.md#delivery-gates`](./README.md#delivery-gates). Every task must pass **all 11 gates** before committing. The shell commands are necessary but not sufficient — several gates require manual review that no command can automate.

**Gate 1 — Formatting:** `mix format --check-formatted`

**Gate 2 — Static Analysis:** `mix compile --warnings-as-errors && mix credo --strict`
- Boundary violations are compile errors. New subsystem modules must declare `use Boundary` in the same task (AP-P18).

**Gate 3 — Type Checking:** `mix dialyzer`
- Zero warnings. All public functions must have `@spec`.

**Gate 4 — Tests:** `mix test`
- All tests pass. But passing is not enough — assertions must test actual values, not just shapes (`{:ok, _}` is not acceptable when the value is knowable). Apply the "can this test fail?" rule. See README for full assertion quality standard.

**Gate 5 — Documentation (manual review required):** `mix docs`
- **Read [`documentation-system.md`](./documentation-system.md) before writing any `@moduledoc` or `@doc`.** This is the single source of truth for the four-layer documentation model.
- **No internal references in Layer 1:** `@moduledoc`, `@doc`, and code comments must never reference `dev/docs/` paths, `dev/implementation_plan/` paths, ADR numbers, phase numbers, task numbers, or gate numbers. These are internal artifacts invisible to ExDoc readers.
- Glossary terms must match `user_docs/glossary.md` definitions. Developer-only terms go in `dev/docs/glossary.md`.
- Any task adding or changing a TOML config key must update `user_docs/reference/config.md` in the same commit.
- **User workflow coverage (Gate 5f):** If the feature requires setup steps, introduces a user workflow, or can produce new errors → the corresponding `getting-started/`, `guides/`, or `troubleshooting/` page must exist or be updated. Reference docs alone (`config.md`) are not sufficient. See [`documentation-system.md` § User Workflow Coverage](./documentation-system.md#user-workflow-coverage-gate-5f).

**Gate 6 — DRY Check (manual review required):**
- Verify nothing in this task's diff duplicates functionality that already exists. Check the DRY Catalogue in `dev/docs/designs/behavioral-audit-master.md`.

**Gate 7 — Licensable Feature Readiness (when applicable):**
- Adapter seam exists, OSS baseline preserved, runtime gating explicit, fallback defined and tested.

**Gate 8 — PHO Foundation Compliance (when applicable):**
- PHO docs updated together, migration runbook present, fleet telemetry preserved, boundary compatibility preserved.

**Gate 9 — Full Gate Check (one-liner):**
```bash
mix format --check-formatted && mix compile --warnings-as-errors && mix credo --strict && mix dialyzer && mix test && mix docs
```
This runs Gates 1–5 commands in sequence. Gates 4–8 also have manual review requirements above that this command does not check.

**Gate 10 — Task Completion Protocol (plan housekeeping — always required):**
1. Add `> **STATUS: COMPLETE** — YYYY-MM-DD. All gates passed.` banner to the task file (line 2).
2. Document every deviation from the plan as a `> **D-N:** ...` blockquote below the banner.
3. For each deviation with downstream impact: open the affected task/phase file and add a note or `⚠️ WIRE-IN REQUIRED` block. For deferred work: create a new `Task N.Xb` file and add it to `progress.md`.
4. Verify `progress.md` has `[x]` for this task.

**Gate 11 — Commit** (only after Gates 1–10 pass).

---

## BaileysEx-Specific Plan Rules

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
3. **Rust NIF only when no native equivalent exists** — Signal protocol, Noise protocol
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
