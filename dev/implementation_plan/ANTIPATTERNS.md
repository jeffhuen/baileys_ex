# Implementation Plan Antipatterns

> **Purpose:** These are the real failure modes that generated the 2026-02-19/20 gap and audit cycles — 50 issues across 22 phases, requiring a full retroactive repair pass. Each entry explains the root cause and the correct mental model, not just a rule to follow.

---

## AP-P1: The Same Module Created by Two Phases

**What happened (C-001):** `LetItClaw.Channels.DeliveryWorker` appeared under `Create:` in Phase 8b at `lib/let_it_claw/channels/delivery_worker.ex`, and again under `Create:` in Phase 13b at `lib/let_it_claw/workers/delivery_worker.ex`. Both phases described different behavior for what was logically the same outbound delivery worker. An implementer executing Phase 13b would either silently duplicate the module at a different path, or overwrite Phase 8b's work with a different implementation.

**The root failure:** Phase files are written in isolation, and the author of Phase 13b didn't know Phase 8b had already claimed ownership of this module. Without a discipline of checking prior phase ownership before writing `Create:`, every shared module is a collision waiting to happen.

**Why this is dangerous:** The collision doesn't manifest as an error — it manifests as two files that compile separately and diverge silently. One gets used; the other is dead code. The wrong one gets bugfixed. Or both get maintained and they drift. The damage compounds because `filesystem-organization.md` can only hold one canonical path, and any path that disagrees with it is wrong.

**The correct model:** `Create:` means "this is the first time this module exists in the codebase." If the module already exists — even if a previous phase put it at a different path — the task must say `Modify:` and reconcile the paths. Before writing a Files section with `Create:`, look up the module name in `filesystem-organization.md` and grep the prior phase files. If it already appears, the conversation is about ownership, extension, and path canonicalization — not creation.

---

## AP-P2: Dependency Versions That Drift Between Phases

**What happened (C-005, C-006, D-006):** `ash_oban` was pinned to `~> 0.2` in Phases 9 and 14, but Phase 8b had already established `~> 0.4` as the canonical version. `reactor` was declared in Phase 14 with no note about whether it conflicted with Phase 22's `Oban + :digraph` approach. When all phases are compiled together into one application, `mix.exs` has one version of each dep — the inconsistency becomes a conflict resolution problem that blocks compilation.

**The root failure:** Phase files are specifications for different time periods, but the result is one `mix.exs`. Each phase author thinks about their dep in isolation, at the time they need it. Nobody owns the cross-phase view of "what version does the whole application converge on?"

**Why this is dangerous:** Dep version conflicts are caught late — at compilation time, not at plan-writing time. By then, multiple phases may have been implemented assuming their version, and the fix requires auditing which APIs changed between versions and updating all the callers.

**The correct model:** Dependency declarations are global, not per-phase. When writing a task that introduces or references a dep, the version in that task must match the version used by every other phase that mentions the same dep. If you are the first to introduce a dep, you set the canonical version and it stays locked across all phases until a deliberate upgrade decision (which updates all references simultaneously). If you are not the first, use the version already in use. Dep version inconsistency in a plan file is a bug, not a style choice.

---

## AP-P3: Cross-Phase Module Modification That's Invisible to the Reader

**What happened (C-013, G-012):** Phase 19 Task 19.5 introduced `:war_room` session mode, which required adding fan-out routing logic to `SessionServer` — a Phase 3 module. Phase 14 Task 14.3 added `completion_waiters` state to `SessionServer`. Neither task listed `session_server.ex` in its Files section. An implementer reading Phase 19 or Phase 14 would implement the task correctly as described, and then ship code that silently breaks `SessionServer` because the cross-phase modification was never surfaced.

**The root failure:** The Files section of a task is the contract with the implementer: "these are the files you will touch." When a cross-phase file is omitted, the implementer either misses the modification or discovers it mid-implementation and has to figure out what to do without guidance.

**Why this is dangerous:** Cross-phase modifications to central modules like `SessionServer` are the highest-risk changes in the codebase. They affect every subsystem that depends on that module. An undocumented cross-phase modification is one that has never been reviewed for correctness, never been verified against the target module's existing state, and never been confirmed to not break prior behavior.

**The correct model:** Every file a task touches must appear in the Files section — including files owned by prior phases. If Phase 19 modifies `SessionServer`, Phase 19's Files section says `Modify: lib/let_it_claw/sessions/session_server.ex` with a note explaining what changes are needed and why. The author must read the current state of that file (from its owning phase) before writing the modification spec. There are no invisible side effects.

---

## AP-P4: A Phase File That Isn't in the README Index

**What happened (G-001, G-002, G-003):** Phases 7b, 13b, 13c, and 14.7 existed as fully specified plan files but were absent from the master phase index table in `README.md`. An implementer reading the README to understand the project's phases would not find them. They would appear to be orphaned files with no relationship to the implementation sequence.

**The root failure:** The README index was not treated as a required update when a new phase was created. New phases were added to `filesystem-organization.md` but the README was overlooked. Over time, the README drifted from reality.

**Why this is dangerous:** The README index is the entry point — it's where someone starts when understanding the project. A phase missing from the index is a phase that will be discovered by accident (or not at all). It won't be sequenced correctly, its dependencies won't be tracked, and it won't appear in any tool that uses the README as the authoritative list of phases.

**The correct model:** A phase does not exist until it appears in the README index. Creating a phase file is a two-part action: write the file and update the README in the same commit. The README row must include the phase number, file link, one-sentence description, and dependency phase. If you cannot write that row because the phase doesn't have a clear position in the sequence, you don't yet understand the phase well enough to commit it.

---

## AP-P5: Subsystem Directories That Don't Appear in the Canonical Layout

**What happened (G-004, G-005, G-007):** `lib/let_it_claw/directives/`, `lib/let_it_claw/waitpoints/`, and `lib/let_it_claw/a2a/` were created by their respective phases without being registered in `filesystem-organization.md`. The canonical layout in that file is the source of truth for what directories exist and which phase owns them. When it diverges from reality, two implementers working on different phases could independently create the same directory with conflicting assumptions about its contents.

**The root failure:** `filesystem-organization.md` was updated at the start of the project and treated as fixed, when in reality new subsystems are introduced with every phase. The path from "new subsystem concept" to "registered canonical path" was never formalized.

**Why this is dangerous:** The canonical layout is used by implementers to understand where to put code and where to look for it. An unregistered directory is one that can be created in multiple places, named inconsistently, or mistakenly omitted entirely because no phase task points to it. The layout also serves as the basis for cross-phase ownership analysis — you cannot know which phase owns a directory if it's not in the table.

**The correct model:** When a task creates a new top-level directory under `lib/let_it_claw/` or `lib/let_it_claw_web/`, that directory is added to `filesystem-organization.md` in the same commit — both the canonical layout section and the phase-to-path ownership table row. The directory's canonical path, owning phase, and what it contains must all be specified. Creating an unregistered directory is incomplete work.

---

## AP-P6: The Filesystem Ownership Table That Shows Only the First Owner

**What happened (G-006, G-021):** `filesystem-organization.md` listed `lib/let_it_claw/storage/` as Phase 4 ownership, but `blob_store.ex` was created in Phase 13 — Phase 4 only defined the Storage behaviour stub. `message_pipeline/` was listed as Phase 3, but Phases 8b and 13c each added files to it. The table was accurate at the moment Phase 3 and Phase 4 were written and never updated as later phases added to those directories.

**The root failure:** Ownership tables tend to record initial ownership and freeze. But in a multi-phase project, directories evolve. A table that shows only the first phase to touch a directory creates false impressions: it implies Phase 4 built storage, it implies message_pipeline is Phase 3's alone. Implementers reading those rows get wrong mental models.

**Why this is dangerous:** A wrong ownership table is worse than no table. It actively misleads. An implementer who reads "Phase 3: message_pipeline/" and doesn't see Phase 8b listed will be surprised to find Phase 8b files there, and might move or delete them. An implementer who reads "Phase 4: storage/" and looks for blob_store.ex there will not find it, because it's actually in Phase 13's output.

**The correct model:** Ownership is progressive. When Phase M adds files to a directory initially owned by Phase N, Phase M updates `filesystem-organization.md` to show the extension: "Phase N creates [directory] with [initial contents]. Phase M adds [new files]." The table reflects the cumulative reality of what each phase contributes to shared directories, not just who created them.

---

## AP-P7: A Cross-Phase Spec That Exists Only Within One Phase's File

**What happened (G-008, G-009, G-010, G-011):** Session key format was defined inline in Phase 13 Task 13.3, but Phases 13b and 13c both needed to use and match it. The HMAC signature algorithm was referenced in Phase 13b but never formally specified — "HMAC signature" without algorithm, encoding, or signing scope left each developer to implement their own interpretation. The Oban job envelope requirement (`tenant_id`, `instance_id`, `deployment_id`) was stated in the Phase 13 README but each individual task's code examples omitted it, so developers reading only the task file would miss it.

**The root failure:** The author of each phase was thinking about their immediate needs. Session keys made sense inline in Phase 13 because that's where filtering was being designed. HMAC was mentioned in Phase 13b because that's where webhook delivery was being specified. But "inline in the phase that uses it first" means "invisible to every phase that uses it after."

**Why this is dangerous:** Implicit shared specs produce implementations that look correct in isolation but fail at integration. Two webhook endpoints signing with different algorithms will reject each other's signatures. Two session key implementations with different delimiters will fail to match sessions across subsystems. These failures are hard to diagnose because each component, tested alone, appears correct.

**The correct model:** The threshold for extracting a spec is "needed by more than one task or phase." The moment Phase 13b needs to know the session key format that Phase 13 defined, that format must be extracted to `dev/docs/architecture/session-keys.md` and both phases must cite it. The canonical document is the contract; the phase files are consumers of it. Inline-only specs are private to their phase. Anything shared must be promoted before the second phase that needs it is written.

---

## AP-P8: Unnumbered Tasks That Cannot Be Sequenced

**What happened (D-002):** Phase 11 contained `### Task 11.X: Security Audit Command (gap §59)` — the X was a placeholder that was never replaced with a real number. The task had no position in the execution sequence. An implementer executing Phase 11 in order would not know where to place it, and might skip it entirely or execute it at a logically wrong moment (e.g., before the wizard that feeds into it).

**The root failure:** The task was added in a hurry, with the intention to assign a number later. "Later" never happened. Placeholder numbers are debt that accumulates invisibly.

**Why this is dangerous:** Task ordering matters. A task without a number cannot be safely scheduled. Dependencies between tasks — "Task 11.4 must complete before 11.5, which is needed by 11.6" — require knowing the sequence. A task at position X cannot have its dependencies verified. It also signals to an implementer that this task's design is incomplete, which reduces confidence in the entire phase.

**The correct model:** Tasks are numbered when they are written. If the exact position isn't known yet, assign a provisional number at the end of the sequence, note that it's provisional, and commit to resolving it before the phase is implemented. A task heading without a number is a task that is not ready to be committed. The number is not cosmetic — it is the task's position in the execution contract.

---

## AP-P9: OTP Behavior Described from Memory Instead of from the Documentation

**What happened (C-010):** Phase 13c Task 13c.1 stated: "`Task.shutdown(task, :shutdown)` escalates to `:kill` after 5 seconds." This is incorrect. `Task.shutdown/2` accepts either a timeout in milliseconds or `:brutal_kill` as the second argument. A timeout that expires does not auto-escalate — the function returns `nil` if the task doesn't exit within the timeout, and the task is left running. Only `:brutal_kill` immediately terminates. The spec was wrong, and an implementer following it would write interrupt logic that doesn't clean up correctly.

**The root failure:** OTP semantics are precise and counterintuitive. The common mental model — "shutdown with a timeout escalates to kill" — is derived from the Erlang/OTP supervisor shutdown sequence, not from `Task.shutdown/2`. Applying one to the other creates plausible-sounding but wrong specs.

**Why this is dangerous:** Wrong OTP specs produce code that is subtly broken in production. The code works in happy-path testing (the task exits before the timeout, so the wrong return handling is never triggered). The defect only appears under load or during interruption scenarios — exactly when correct behavior matters most.

**The correct model:** Any time a plan specifies OTP behavior — `Task.shutdown`, `GenServer.call` timeout semantics, `Process.exit` signal propagation, `trap_exit`, supervision strategy parameters, `DynamicSupervisor.terminate_child` — the spec must be verified against the current HexDocs or OTP source before being written. Memory is wrong. The test is: "Can I point to the documentation that says this?" If not, look it up. Common traps: Task.shutdown does not auto-escalate; handle_info does not receive EXIT without trap_exit; GenServer.call timeout does not kill the server; `one_for_one` vs `one_for_all` restart semantics.

---

## AP-P10: A Behaviour Interface Designed for the First Implementation Only

**What happened (C-015):** `SchedulerBackend` was defined with only `schedule_cron/3` and `cancel/1`. The intent was to allow alternative implementations (a future Pro backend), but the behaviour's surface area was defined by what the first implementation (Oban) needed for the minimum viable case. When the Pro backend's requirements were considered — `insert/1`, `retry/1`, `schedule_at/2`, `list_jobs/1` — the interface needed to be expanded, which is a breaking change for any existing implementation.

**The root failure:** The behaviour was designed in the context of a single implementation. When you only have one implementation, the behaviour looks like "what does this implementation expose?" But the purpose of a behaviour is to be an interface that multiple implementations can satisfy. Those implementations may have different requirements that the first one didn't need to expose.

**Why this is dangerous:** An under-specified behaviour creates a false contract. The Oban adapter satisfies the behaviour, but its implementation contains methods that the behaviour doesn't declare. When a Pro adapter is written, the author must either (a) use undeclared methods, bypassing the abstraction entirely, or (b) force a breaking interface change that requires updating all existing callers. Both options represent design debt that could have been avoided by thinking through the full interface from the start.

**The correct model:** When defining a behaviour that is expected to have multiple implementations, enumerate all the operations that any reasonable implementation will need to support — including operations that the first implementation doesn't need right now. Look at the behaviour from the perspective of a caller: what does a caller need to be able to do to the backend? That set of operations is the interface, not "what does the Oban adapter expose." Document each callback with its expected semantics, return types, and which implementations cover it.

---

## AP-P11: Runtime State Mutations Without Authorization Gates

**What happened (C-011):** `Events.register/1` accepted trigger registrations from any caller with no authorization check. Any GenServer process, any automation payload, any untrusted input that reached the function could register a new automation trigger that would fire on real events. PHO Non-Negotiable 14 covers external `send_message` actions but registration — an equally sensitive operation — was not covered.

**The root failure:** Authorization was applied at the point of action (sending a message) but not at the point of configuration (registering what causes the action). This is a common security oversight: access control at the leaf operation, but not at the setup operation that determines which leaf operations will be called in the future.

**Why this is dangerous:** An unprotected registration endpoint is effectively a backdoor into the event system. A compromised or malicious automation payload that reaches `Events.register/1` can install persistent triggers that run with system privileges. The damage is not limited to a single event — it affects every future event of the registered type until the trigger is explicitly removed.

**The correct model:** The security model must cover both configuration and execution. Any function that modifies system configuration at runtime — registering triggers, enabling channels, creating workers, configuring integrations — requires the same authorization rigor as the operations those configurations enable. The spec for such a function must include: who is authorized to call it (role check), what happens when an unauthorized caller tries (explicit error), and a test that verifies the rejection. Configuration without authorization is a security gap regardless of what authorizes execution.

---

## AP-P12: Security Invariants Tested Only in the Happy Path

**What happened (C-012):** PHO Non-Negotiable 6 mandates `effective_child_policy = parent ∩ child` for sub-agent delegation — a child session cannot have broader permissions than its parent. Phase 14 implemented `Security.Policy.intersect/2`, which is the enforcement mechanism. But the test section contained no test verifying that a parent in `:readonly` policy could not spawn a child with `:full` autonomy. The constraint existed in code but was not verified by tests.

**The root failure:** Security invariants that are not tested do not exist as invariants — they are assertions. A refactoring that inadvertently removes the constraint will not be caught by tests. The security property is maintained by the programmer's attention, not by the test suite.

**Why this is dangerous:** Security invariant tests are the last line of defense against accidental privilege escalation. When a policy intersection function is refactored for performance, or when a new path through the sub-agent spawning logic is added, the absence of a rejection test means the invariant can be silently broken. The happy-path test (parent and child with same policy produces correct intersection) does not catch the case where intersection is bypassed.

**The correct model:** Every security constraint must be accompanied by a test that attempts to violate it and verifies the violation is rejected. This is not optional or "nice to have" — it is the only way to maintain the constraint through future changes. The rejection test must be at least as specific as the invariant: "parent in `:readonly` attempts to spawn child with `:full` → returns `{:error, :security_policy_violation}` and no child session is created." Test the specific failure mode, not just the general "something fails."

---

## AP-P13: A Later Phase Rebuilds a Module Without Accounting for Prior Extensions

**What happened (C-014):** Phase 14 Task 14.7 extended `dashboard_live.ex` with agent status panels, sub-agent tree visualization, mesh run panels, and MCP connection status. Phase 17a Task 17.2 was described as "rebuild the dashboard home" — a reasonable description for a phase focused on the console. But an implementer executing Phase 17a naturally starts with a clean slate for the dashboard. Phase 14's additions were not listed in Phase 17a's context, so they would be overwritten.

**The root failure:** Phase files are written in temporal order. Phase 14 doesn't know what Phase 17 will do. Phase 17 doesn't remember what Phase 14 added. The plan assumes the implementer has read all prior phases that touched each file — but that assumption fails under real implementation conditions.

**Why this is dangerous:** Overwriting prior phase work produces bugs that look like regressions, not bugs. The Phase 14 panels disappear. Users notice. The cause is a Phase 17 implementer who did exactly what their phase told them to do — they "rebuilt the dashboard home." The defect is in the plan, not the implementation.

**The correct model:** When a phase modifies a module that a prior phase extended, the later phase must explicitly list everything the prior phase added and declare it preserved. "Extends Phase 14 Task 14.7's agent status panels. Do not remove: agent status panel, sub-agent tree, mesh run timeline, MCP connection status." The implementer who reads this knows they must account for those elements in their implementation. The prior work is not an assumption — it is an explicit constraint on the implementation.

---

## AP-P14: Infrastructure-Conditional Features Without Runtime Capability Gates

**What happened (G-019):** Phase 9 Task 9.7 (Memory Compaction Worker) called the embedding model via `ash_ai` without checking whether `ash_ai` was present. `ash_ai` requires a Postgres vector extension — it cannot run on SQLite deployments. On a SQLite deployment, the compaction worker would crash on startup or during execution, producing errors that are confusing and hard to diagnose.

**The root failure:** The compaction worker was designed in the context of a Postgres deployment, and the author did not consider that the same code runs on SQLite. The mental model was "this feature needs `ash_ai`" — not "this feature is only available on deployments that have `ash_ai`."

**Why this is dangerous:** Infrastructure-conditional crashes are silent until they happen. A SQLite user deploys Let It Claw and it appears to work. Then the compaction worker runs. The crash log says something about an undefined function or missing table, which doesn't obviously connect to "this feature requires Postgres." The user has no context for why their deployment is broken or how to fix it.

**The correct model:** Any feature that requires infrastructure beyond the baseline deployment (Postgres, external API, Pro license) must be gated at the point of execution by a capability check that returns a meaningful result when the capability is absent. `LetItClaw.Capabilities.supported?(:memory_compaction)` is checked before calling the embedding model; if false, the worker returns `:ok` and logs a single INFO message explaining that compaction is disabled on this deployment. The task spec must include: the capability key, what the feature does when the capability is absent, and a test verifying graceful degradation on a non-Postgres deployment.

---

## AP-P15: Configuration Keys That Exist in Code but Not in Documentation

**What happened (G-020):** Multiple phases added TOML configuration keys — `[cron]`, `[memory.compaction]`, `[security]`, others — without updating `user_docs/reference/config.md`. Gate 5 of the delivery process requires this, but only as a reminder. There was no enforcement mechanism. Configuration keys were added, the feature worked, the code was committed, and the documentation was never updated.

**The root failure:** Config documentation is a separate artifact from the config key itself. Adding a config key is two actions: write the code, and document it. When these two actions can be performed in any order — or one can be skipped — the documentation will tend to lag. Config documentation is not exciting work and there is no test that fails when it's missing.

**Why this is dangerous:** A user who encounters an undocumented configuration key has no way to know what it does, what values are valid, what the default is, or what happens when it's set incorrectly. From the user's perspective, an undocumented config key doesn't exist — they will never discover it through the documentation, only through reading source code. The absence compounds over time: each undocumented key makes the reference less complete and less trustworthy.

**The correct model:** A config key is not shipped until it is documented. This is a constraint on the commit, not a reminder to do later. Every commit that introduces or modifies a TOML config key must update `user_docs/reference/config.md` in the same commit, with the key path, value type, default, and description. The commit message must name the config key. This is not bureaucracy — configuration is the user interface for operators.

---

## AP-P16: Example Code That Teaches the Wrong Pattern

**What happened (D-004):** Phase 16's example plugin defined `def state_key, do: :example_plugin` explicitly. Phase 20's first-party plugins relied on `use LetItClaw.Plugin`'s default, which derives the key from the module name automatically. The Phase 16 example taught developers to always define `state_key/0` — but the correct pattern is to rely on the default and override only when necessary. Every plugin written by a developer who learned from the Phase 16 example would include unnecessary explicit `state_key/0` definitions.

**The root failure:** The example was correct — it produced working code. But it was not canonical — it showed more than is needed and normalized boilerplate that should be invisible. Developers copy examples. The pattern in the example becomes the pattern in the codebase.

**Why this is dangerous:** Example code propagates. An example that shows explicit boilerplate will be copied exactly, including the boilerplate. Over time, the codebase fills with identical `def state_key, do: :module_name_here` definitions that add noise, create a false impression that this override is required, and hide cases where an intentional override actually means something. Examples that teach the wrong pattern are harder to correct than examples that teach nothing.

**The correct model:** Examples are normative. The example shows what a developer should do, not what is technically possible. If the framework provides a correct default, the example omits the explicit definition and notes the default in a comment: `# state_key/0 is not defined — use LetItClaw.Plugin's default (module underscore name). Override only if you need a custom key.` The example teaches the minimal correct approach; the documentation explains the override case separately.

---

## AP-P17: Delivery Gate Deferral ("I'll Fix It in the Next Commit")

**What it looks like:** A task is implemented. The tests pass but some assertions are weak (`{:ok, _}` patterns, `assert length(results) > 0`). Credo reports a warning. Boundary violations appear but `mix compile --warnings-as-errors` wasn't run. The implementer notes the issues and commits anyway with the intention of cleaning up in the next task. The next task starts, the debt is forgotten, and it compounds.

**The root failure:** "I'll fix it later" is a commitment that is never tracked, never scheduled, and almost never honoured. The moment a commit lands with a gate violation, that violation becomes the new baseline. Future implementers inherit it, work around it, and copy the pattern. One weak test becomes twenty.

**Why this is dangerous:** Gate drift is self-reinforcing. Once one weak assertion exists without consequence, the standard lowers for the next task. Once one `use Boundary` is skipped, the next module feels less urgent. Once one config key goes undocumented, the pattern is established. By the time the debt is visible, it requires the same kind of retroactive repair pass that generated the 50-issue audit this project already went through.

**The correct model:** Gates are binary — pass or block. There is no "mostly passing." If `mix compile --warnings-as-errors` reports a Boundary violation, the task is not done. If a test assertion is `{:ok, _}` where the actual value is knowable, the test is not done. The commit does not happen until every gate is green. The discipline is: **fix the gate failure before moving to the next task, always, without exception.** If a gate failure is genuinely impossible to fix in the current task (e.g., a Boundary dep cycle that requires a refactor spanning multiple modules), it must be filed as a named blocking task in `progress.md` before the current task is marked complete — not left as an implicit "I'll get to it."

---

## AP-P18: A `use Boundary` Declaration Deferred to "Later"

**What it looks like:** A new subsystem module is created — `LetItClaw.Waitpoints`, `LetItClaw.Voice.TTS`, `LetItClaw.Plugins.Discovery` — without a `use Boundary` declaration. The author intends to add it once the subsystem is more complete, or assumes another phase will declare boundaries for the whole system at once.

**The root failure:** Boundary declarations feel like housekeeping, not implementation. They don't affect runtime behavior. The code compiles and the tests pass without them. So they get deferred. But the Boundary compiler only enforces constraints that are declared — a module without `use Boundary` is invisible to the enforcement system, and any caller can import any of its internals without triggering a violation.

**Why this is dangerous:** Every module that ships without a Boundary declaration is a module whose internal structure is now implicitly public. Other modules will call those internals — not maliciously, but because there's no compile-time signal that they shouldn't. When the Boundary declaration is eventually added, it will break those callers, requiring a cross-codebase refactor to route through the public API. The later the declaration, the more callers have accumulated, and the more expensive the fix.

**The correct model:** `use Boundary` is written in the same commit that creates the module — not after the module is "stable," not in a later cleanup phase, not when boundary enforcement is "turned on." Gate 2 (`mix compile --warnings-as-errors`) enforces this: once Task 1.13 is complete, any new module in a boundary-owning namespace that lacks a declaration will produce a warning treated as an error. The rule is: **if you create a top-level subsystem module, it gets `use Boundary` in the same task.** No exceptions, no deferrals.

---

## AP-P19: Tests That Pass Because Mocks Are Too Permissive

**What it looks like:** A module is tested with a mock that returns `:ok` or `{:ok, %{}}` for every call. The implementation changes — a field is renamed, a return type narrows, an error path is added — but the mock still returns the old shape. All tests pass. The bug surfaces at integration time or in production when the real dependency behaves differently from the mock.

**The root failure:** Mocks are written to make tests pass, not to model the real dependency's contract. A mock that returns `{:ok, %{}}` is testing that the code calls the mock — not that the code handles the real return value correctly.

**Why this is dangerous:** A test suite full of permissive mocks is a false safety net. It gives high confidence in a codebase that has not been tested. The integration failures that permissive mocks hide tend to be the worst kind: they appear in specific scenarios, under load, or at the boundary between subsystems — exactly where they're hardest to debug.

**The correct model:** Mocks must return the exact shape that the real dependency returns, including error tuples, specific field values, and edge cases. If the real dependency returns `{:ok, %Session{id: uuid, status: :active, created_at: datetime}}`, the mock returns that shape — not `{:ok, %{}}`. When the real dependency's contract changes, the mock is updated in the same commit. The test for the "can this test fail?" rule (Gate 4) applies to mocks: if you change what the code does with the mock's return value, does the test catch it? If not, the mock is too permissive.

**A second failure mode with the same effect:** The test name says it verifies one branch, but the setup drives a different branch that happens to fail with a "similar enough" error. Example: test says "fails when binary not in PATH" but passes `binary: "/nonexistent/tool"`, which bypasses `System.find_executable/1` and only tests `Port.open` failure. The PATH lookup branch can regress while the test stays green.

**The branch-proof model:** Every branch-specific test needs a branch witness:
- Inject seam functions (`find_executable_fn`, clock fn, filesystem fn) so the target branch is forced deterministically.
- Assert branch-exclusive side effects (for PATH miss, assert process launch/open function was never called).
- Keep adjacent-failure tests separate (one for lookup miss, one for invalid explicit path) so failures pinpoint the broken contract.

---

## AP-P20: Stale Tests That Describe Removed Behaviour

**What it looks like:** A function is refactored. The old behaviour is removed. The tests for the old behaviour still pass — either because the assertions were too loose to catch the change, or because the test setup constructed state that the new code happens to handle correctly by coincidence. The test continues to run and pass in every CI cycle, describing behaviour that no longer exists.

**The root failure:** Tests are written when code is added, but are not systematically reviewed when code changes. A developer modifying a function reads the implementation and the new requirements — they do not read all the tests for that module to check whether any test is now describing a ghost.

**Why this is dangerous:** Stale tests are trust corruptors. A developer reading the test suite takes it as documentation of what the system does. A test describing removed behaviour is misinformation — it tells the developer that a behaviour exists when it doesn't. When that developer extends the system, they may rely on a behaviour that is no longer there. Stale tests also inflate test counts: a suite of 10,000 tests where 2,000 describe removed behaviour is not a 10,000-test suite — it is an 8,000-test suite with 2,000 lies.

**The correct model:** Gate 4's test rot rule is mandatory: when modifying an implementation as part of any task, re-read every test for that module. For each test, ask: "Does this test still describe actual behaviour?" If the answer is no — if the behaviour was changed, removed, or superseded — delete or update the test in the same commit as the implementation change. A stale test is not harmless; it is active misinformation. Deleting a test that describes removed behaviour is not a loss — it is a correction.

---

## AP-P21: Registry Deregistration Is Async — Never Assume It Happens Synchronously with Process Exit

**What it looks like:** A test stops a `SessionServer` (or any Registry-registered GenServer) with `GenServer.stop/2`, waits for the `{:DOWN, ...}` monitor message, and then immediately calls a function that does `Registry.lookup` expecting an empty result. The test passes most of the time but fails intermittently with the dead PID returned as if it were still alive, or with `Process.alive?` returning false for a PID that was just created.

**Discovered in:** Task 3.4 — `ManagerTest` "restores session from database after process stops." Failure rate ~60% when running the manager test suite alone. Root cause confirmed 2026-02-22.

**The root failure:** Two independent actors receive `:DOWN` messages when a process dies: the test process (via `Process.monitor`) and the Registry process (via its own internal monitor). BEAM delivers monitor messages to each monitoring process independently and asynchronously. `assert_receive {:DOWN, ^ref, ...}` only guarantees the **test process** received its DOWN. The Registry process has its own mailbox and processes its DOWN at its own pace — which may be before or after the test process. Calling `Registry.lookup` immediately after `assert_receive` creates a race window where the Registry's deregistration hasn't happened yet, and `lookup` returns the dead PID.

**The cascade:** When the Manager's `get_or_create` calls `Registry.lookup` and finds the dead PID still registered, it returns `{:ok, dead_pid}` — a successfully started session handle that is already dead. Any subsequent `Process.alive?` check or `GenServer.call` to that PID fails.

**Why this is dangerous:** This race is invisible in fast runs and on fast machines. It shows up under load, in CI, or when other concurrent tests are consuming scheduler time. The failure is intermittent, hard to reproduce deterministically, and the error message (`Expected truthy, got false` on `Process.alive?`) points at the wrong place — the `alive?` check, not the upstream `Registry.lookup` race. Without knowing this antipattern, an implementer will add sleeps, restructure assertions, or chase the wrong root cause for hours.

**Every place this bites:**
- `Manager.get_or_create` after stopping a session process (Task 3.4 ✅ fixed)
- Sub-agent lifecycle tests: stopping a child agent and immediately checking its slot is freed (Phase 14, Task 14.2)
- Channel account supervisor tests: crashing an account process and verifying the Registry shows a new PID after restart (Phase 8b, Task 8.16)
- Tool background process lifecycle: stopping a running tool process and verifying it's cleaned up (Phase 4, Task 4.16)
- Any test that calls `GenServer.stop` or `Process.exit` followed by any Registry operation

**The correct model:** After receiving `{:DOWN, ...}` for a Registry-registered process, **synchronize with the Registry partition** before doing any operation that depends on the slot being empty. The Registry is [documented as a supervisor](https://hexdocs.pm/elixir/Registry.html) whose children are partition processes. A synchronous `:sys.get_state/1` call to each partition acts as a message-ordering barrier: once the partition replies, all prior `:DOWN` messages have been processed and ETS entries removed. Zero polling, deterministic.

```elixir
# WRONG — races with Registry's async deregistration
GenServer.stop(pid)
assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
assert {:ok, new_pid} = Manager.get_or_create(key)  # may return dead pid!

# CORRECT — barrier-based sync via LetItClaw.AsyncHelpers
import LetItClaw.AsyncHelpers

GenServer.stop(pid)
assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
wait_for_registry_clear(key)  # sync barrier on partition, no polling
assert {:ok, new_pid} = Manager.get_or_create(key)

# For cases where you only need the barrier (not a key check):
registry_sync()  # syncs all partitions, then you can assert directly
```

Do not reimplement sync helpers locally — `import LetItClaw.AsyncHelpers` and use `registry_sync/0`, `wait_for_registry_clear/1`, or `eventually/2`. See AP-P22.

**Why barrier, not polling:** The initial fix used `eventually/2` polling (adapted from `JidoTest.Eventually`). This works but is fundamentally busy-waiting — repeatedly asking "is it done yet?" when the answer is deterministically knowable. Since messages are processed in order, a single `:sys.get_state` call to the partition that owns the monitor guarantees all prior `:DOWN` signals have been processed. This is instant and deterministic regardless of system load. Reserve `eventually/2` for generic async conditions where no sync barrier exists.

**The same pattern applies to DynamicSupervisor child counts:** after terminating a child, use `:sys.get_state` on the supervisor as a barrier before asserting child counts. The supervisor processes child exits asynchronously in its own mailbox just as the Registry does.

---

## AP-P22: Duplicated Test Helpers Instead of a Shared Module

**What happened:** `wait_until/2` and `wait_for_registry_clear/2` were independently implemented as `defp` in both `ManagerTest` and `SessionServerTest`. The two copies had slightly different semantics (one returned `false` on timeout, the other called `flunk/1`), different default attempt counts, and neither was discoverable to future test authors.

**Discovered in:** DRY review after fixing the flaky directive drain test in `SessionServerTest`. The fix required adding the same polling helper that `ManagerTest` already had — a textbook duplication signal.

**The root failure:** Polling helpers feel like "small local utilities" — too small to extract, too specific to share. Each test author writes their own version because they don't know (or don't think to check) whether one already exists. The result is N copies with N slightly different contracts.

**Why this is dangerous:** Duplicated test helpers diverge. When a bug is found in the polling logic (e.g., the sleep interval is too short, or the timeout calculation is wrong), the fix is applied to one copy and the other copies remain broken. Worse, the inconsistent APIs (boolean return vs `flunk`) make it harder to know what a caller should expect. Future phases that need the same pattern (AP-P21 lists Phase 4, 8b, and 14) will each write yet another copy.

**The correct model:** Test helpers that are needed by more than one test module belong in `test/support/`. This project uses `LetItClaw.AsyncHelpers` (`test/support/async_helpers.ex`) with two mechanisms matched to the situation:

```elixir
import LetItClaw.AsyncHelpers

# Registry deregistration — deterministic barrier, zero polling (AP-P21)
registry_sync()                       # sync all partitions
wait_for_registry_clear("my-key")     # sync + verify key is gone

# Generic async condition — polling with monotonic deadline
# (adapted from JidoTest.Eventually, jido-main/test/support/eventually.ex)
eventually(fn -> some_condition() end)
eventually(fn -> some_condition() end, timeout: 1_000, interval: 10)
```

**Use the right mechanism:** Barrier-based sync (`registry_sync/0`, `wait_for_registry_clear/1`) is deterministic and instant — use it whenever a known OTP process (Registry partition, Supervisor) must finish processing a `:DOWN` signal. Fall back to `eventually/2` only for generic async conditions where no sync barrier is available (e.g., waiting for a GenServer's `handle_info` self-scheduling loop to drain).

**Why `eventually/2` uses deadlines, not attempt counts:** The initial implementation used `attempts * sleep_ms` to approximate a timeout. This is wrong — it doesn't account for the time the predicate itself takes to execute. A slow predicate under load silently extends the actual timeout. `System.monotonic_time(:millisecond)` deadlines give accurate wall-clock timeouts regardless of predicate cost. This matches the pattern used across all Jido test suites.

**The threshold for extraction is the same as AP-P7:** "needed by more than one module." The first test module that needs a helper writes it locally. The moment a second module needs the same helper, extract it to `test/support/` and have both modules import it. Do not wait for a third copy.

---

## AP-P23: Process Cleanup with `Process.alive?` Guard Instead of `try/catch`

**What it looks like:** A test's `on_exit` callback checks `Process.alive?(pid)` before calling `GenServer.stop(pid)`. Most of the time it works. Intermittently, the test fails with `:noproc` — the process died between the alive check and the stop call.

**Discovered in:** Queue test flake investigation, 2026-02-24. The `start_queue` helper's `on_exit` used `if Process.alive?(pid), do: GenServer.stop(pid, :normal)`. Under concurrent test load, Queue processes self-terminated (idle shutdown, drain completion) in the window between the check and the stop.

**The root failure:** This is a classic Time-of-Check to Time-of-Use (TOCTOU) race condition. `Process.alive?/1` returns a snapshot that is immediately stale — by the time the next line executes, the process may have exited. In concurrent systems, there is no safe window between "check if alive" and "act on that check." The check and the action must be atomic or the failure must be handled at the action site.

**Why this is dangerous:** The failure is intermittent and seed-dependent. It only triggers when the process exits in the microsecond window between the alive check and the stop call — which requires specific scheduler timing. The test passes on fast machines, in isolation, and with most random seeds. It fails under load, in CI, or when concurrent tests consume scheduler time. The error message (`:noproc` exit from `GenServer.stop`) points at the stop call, not at the flawed guard that preceded it.

**Every place this bites:**
- Test `on_exit` callbacks that clean up GenServer processes
- Test `setup` blocks that stop processes from prior test runs
- Any production code that checks `Process.alive?` before sending a message or calling a GenServer
- Supervisor-adjacent code that polls process liveness before taking action

**The correct model:** Never guard a process operation with `Process.alive?/1`. Instead, attempt the operation and handle the failure:

```elixir
# WRONG — TOCTOU race between check and stop
on_exit(fn ->
  if Process.alive?(pid), do: GenServer.stop(pid, :normal)
end)

# CORRECT — attempt the stop, handle the expected failure
on_exit(fn ->
  try do
    GenServer.stop(pid, :normal)
  catch
    :exit, _ -> :ok
  end
end)
```

The `try/catch :exit` pattern is idiomatic OTP. It says: "try to stop the process; if it's already dead, that's fine." The `:exit` catch covers `:noproc` (process doesn't exist), `:normal` (process exited normally), and `:killed` (process was killed) — all of which mean "the process is gone," which is exactly the postcondition we want from cleanup code.

**The general principle:** In concurrent systems, never separate a liveness check from the action that depends on it. Either make them atomic (impossible for process operations) or handle the failure at the action site (always possible with `try/catch`). This applies beyond tests — any production code that does `if Process.alive?(pid), do: GenServer.call(pid, ...)` has the same race.

---

## AP-P24: SQLite `pool_size > 1` Creates Write-Lock Contention That No Timeout Can Fix

**What it looks like:** Tests intermittently fail with `Exqlite.Error: Database busy` on INSERT statements. The failures are non-deterministic — they depend on which tests run concurrently and how the scheduler interleaves them. Adding `busy_timeout: 15_000` reduces the rate from ~10% to ~3%. Adding `journal_mode: :wal` reduces it further. But failures persist at ~1–3% under stress because the root cause is structural, not temporal.

**Discovered in:** Test flake investigation, 2026-02-24. Started at ~50% failure rate across the full suite. After fixing five other flake categories (DynamicSupervisor restart cascades, cross-test interference, persistent_term mutation, OTP 26+ map traversal randomization, TOCTOU cleanup races), the remaining ~3% was "Database busy" on session and auth profile INSERTs.

**The root failure:** SQLite is a single-writer database. It supports exactly one write transaction at a time. The test config had `pool_size: 16`, which created 16 database connections. With the Ecto Sandbox, each test checks out a connection and wraps it in a transaction that is held open for the entire test duration (rolled back at cleanup, never committed). When multiple async tests run concurrently, their transactions contend for SQLite's single write lock. The first writer acquires a RESERVED lock; all others wait. With enough concurrent writers, the queue exceeds `busy_timeout` and SQLite returns SQLITE_BUSY.

**Why timeouts and WAL mode don't fix it:** These are mitigations, not solutions:

- `busy_timeout: N` tells a blocked writer to retry for N milliseconds before giving up. This helps when contention is brief, but Sandbox transactions hold locks for the entire test duration (hundreds of milliseconds). With 16 connections queuing behind one writer, the last connection may wait longer than any reasonable timeout.
- `journal_mode: :wal` (Write-Ahead Logging) allows concurrent readers alongside a single writer, which eliminates read-write contention. But write-write contention remains — WAL does not allow concurrent writers. Since the failures are all on INSERTs (write-write contention), WAL doesn't address the root cause.
- Both mitigations reduce the failure rate probabilistically. Neither eliminates it structurally.

**The investigation path that led here:**

1. Initial failure rate: ~50% (5/10 runs). Multiple flake categories interleaved.
2. Fixed `restart: :temporary` on demand-started GenServers → eliminated DynamicSupervisor `max_restarts` cascades.
3. Fixed broad `DynamicSupervisor.which_children` cleanup in `MessagePipelineTest.on_exit` → eliminated cross-test process kills.
4. Fixed `CommandsModelListTest` overwriting `:persistent_term` with mock data → eliminated `ModelsTest` mass failures.
5. Fixed OTP 26+ map traversal randomization in model lookups → eliminated `ModelsTest` bare-name assertion flake.
6. Fixed TOCTOU `Process.alive?` + `GenServer.stop` races (AP-P23) → eliminated `KeyStoreTest` and queue cleanup flakes.
7. Added `busy_timeout: 15_000` and `journal_mode: :wal` → reduced "Database busy" from ~10% to ~3%.
8. **Set `pool_size: 1`** → 0/100 failures. Problem structurally eliminated.

**Why this is dangerous:** The failure mode is subtle and misdirects investigation. "Database busy" looks like a timeout tuning problem, so the natural response is to increase `busy_timeout` or add retry logic. Each mitigation reduces the rate enough to seem like progress, but the failures never reach zero because the structural mismatch (N connections vs 1 writer) remains. A day of investigation can be spent chasing timeout values when the fix is a one-line config change.

**The correct model for tests:** `pool_size: 1` in the test config. One connection means zero write-lock contention — the problem cannot occur. The Ecto Sandbox's shared mode (`{:shared, self()}`) lets spawned processes (SessionServer, DynamicSupervisor children, etc.) reuse the test's single checkout, so all test patterns work. This is actually *faster* than `pool_size: 16` because it eliminates lock acquisition overhead.

```elixir
# WRONG — creates 16 connections contending for SQLite's single write lock
config :my_app, MyApp.Repo,
  database: "test.db",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 16,
  journal_mode: :wal,       # mitigates read-write, not write-write
  busy_timeout: 15_000      # probabilistic, not structural

# CORRECT — one connection, zero contention
config :my_app, MyApp.Repo,
  database: "test.db",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 1
  # journal_mode: :wal is ecto_sqlite3's default — no need to set it
  # busy_timeout is unnecessary with a single connection
```

**The correct model for production SQLite:** `pool_size: 1` serializes reads too, which is a throughput bottleneck. The robust pattern is separate read and write pools:

- **Write Repo:** `pool_size: 1` — serializes writes, matches SQLite's single-writer constraint
- **Read Repo:** `pool_size: N` with WAL mode — concurrent reads alongside the single writer

For most deployments, PostgreSQL eliminates this entire category of problems. SQLite is appropriate for single-node, embedded, or development use cases where write throughput is bounded.

**Note on `ecto_sqlite3` defaults:** As of v0.22, `ecto_sqlite3` already defaults `journal_mode` to `:wal` and `cache_size` to `-64_000`. These do not need to be set explicitly. The only config that matters for eliminating contention is `pool_size: 1`.

## AP-P25: Safe Bin Name-Only Matching Lets `grep -f /etc/passwd` Through

> **Source:** OpenClaw 2026.2.23 security hardening.

**What it looks like:** The safe bins allowlist checks that the binary name (e.g., `grep`) is permitted, but does not validate the argument structure. An agent calls `grep -f /etc/passwd` — the `-f` flag tells grep to read patterns from a file, effectively giving arbitrary file read access. Similarly, `jq --rawfile foo /etc/passwd` reads any file, `sort --compress-program evil` executes an arbitrary binary, and `sort --output /etc/crontab` overwrites arbitrary files.

**Why it's dangerous:** These flags turn "safe" read-only tools into arbitrary file readers, writers, or even command executors. An LLM agent that has been prompt-injected can exploit these flags to exfiltrate data or escalate access, even though the binary name passed the allowlist.

**The fix:** Per-binary argv profiles with `max_positional`, `allowed_value_flags`, `denied_flags`, plus rejection of glob characters and path-like tokens in argument values. See Task 4.3 SafeBins implementation. Additionally, resolve the binary to its full path via `System.find_executable/1` and verify it's in a trusted directory (`/usr/bin`, `/opt/homebrew/bin`, etc.) — prevents PATH hijacking where a malicious `~/bin/grep` shadows the system binary.

**Applies to:** Task 4.3 (Shell Tool), Task 4.2 (Security Policy)

## AP-P26: Auth Cooldown Windows That Extend on Retry

> **Source:** OpenClaw 2026.2.23 bug fix.

**What it looks like:** An auth rate limiter computes a backoff window (e.g., "locked out until T+60s") after N failures. A new failure arrives during the cooldown window. The handler recomputes the backoff from the new failure timestamp, extending the window to T'+60s. If failures keep arriving (e.g., a bot hammering the endpoint), the window extends indefinitely — the legitimate user is locked out forever.

**The fix:** Keep `cooldown_until` / `disabled_until` timestamps immutable during the active window. Only recompute a new backoff window after the previous deadline has expired. During the window, new failures are counted but do not modify the deadline.

```elixir
# WRONG — extends the window on every failure
def record_failure(state, ip) do
  %{state | cooldown_until: DateTime.add(DateTime.utc_now(), 60, :second)}
end

# CORRECT — only set a new window after the old one expires
def record_failure(state, ip) do
  now = DateTime.utc_now()
  if DateTime.compare(now, state.cooldown_until) == :gt do
    %{state | cooldown_until: DateTime.add(now, 60, :second), failure_count: 1}
  else
    %{state | failure_count: state.failure_count + 1}
  end
end
```

**Applies to:** Task 7.5 (Gateway Security), any rate limiter with backoff

## AP-P27: Delivery Queue Retries on Every Restart

> **Source:** OpenClaw 2026.2.23 bug fix.

**What it looks like:** A message delivery queue persists failed entries. On restart, the queue processor retries every entry — including those that failed with permanent errors (invalid recipient, message too large, auth revoked). These permanent failures retry on every restart forever, consuming resources and polluting logs.

**The fix:** Quarantine permanently-failed entries immediately. On known permanent delivery errors, move the entry to `failed/` (or mark it `status: :quarantined`) instead of leaving it in the retry queue. Only transient failures (timeout, network error, rate limit) remain in the retry queue.

```elixir
# Classify delivery errors
defp permanent_error?({:error, :invalid_recipient}), do: true
defp permanent_error?({:error, :message_too_large}), do: true
defp permanent_error?({:error, :auth_revoked}), do: true
defp permanent_error?(_), do: false
```

**Applies to:** Phase 8 (Channel Adapters), any persistent retry queue

## AP-P28: Config Array Diffing Triggers False Restart-Required Reloads

> **Source:** OpenClaw 2026.2.23 bug fix.

**What it looks like:** Config hot-reload compares old and new config to determine if a restart is required. Array-valued config paths (e.g., `allowed_tools = ["shell", "file_read"]`) are compared by reference or string equality of their serialized form. Even when the arrays contain identical elements in the same order, the diff reports a change and triggers an unnecessary restart/reload cycle.

**The fix:** Compare array-valued config paths structurally (element-by-element, order-sensitive) during diffing. Use `Kernel.==/2` in Elixir, which does structural comparison on lists by default. The bug typically appears in languages where array identity ≠ array equality — but in Elixir, beware of comparing config maps that may contain different internal representations of the same data (e.g., charlist vs string, atom vs string keys).

**Applies to:** Phase 1 (Config), any hot-reload or config-change-detection logic

## AP-P29: `start_link` Failure Tests That Assert Only One Failure Shape

**What it looks like:** A test asserts only `{:error, reason} = GenServer.start_link(...)` for a startup failure path. The same code path can legitimately surface as a linked `{:EXIT, pid, reason}` depending on timing, supervision context, and whether the caller traps exits. The test passes on one machine and fails intermittently in CI or when run inside a larger suite.

**The root failure:** The test confuses semantic contract with transport shape. The semantic contract is the reason (`:binary_not_found`, `{:port_open_failed, _}`, etc.). The transport shape (`{:error, reason}` vs linked `EXIT`) is runtime-context-dependent for linked processes.

**Why this is dangerous:** These tests create false flake signals. Teams interpret the failures as "random CI nondeterminism" and add sleeps/retries, when the actual issue is an over-constrained assertion. This drains time and normalizes brittle tests.

**The correct model:** Assert the failure reason across both valid shapes. In unit tests for linked processes:

```elixir
Process.flag(:trap_exit, true)

result = MyGenServer.start_link(config)

case result do
  {:error, :expected_reason} ->
    :ok

  {:ok, pid} ->
    assert_receive {:EXIT, ^pid, :expected_reason}, 5_000
end
```

If the test targets a specific transport shape, make that explicit by controlling context (e.g., supervisor start vs direct `start_link`) and document why shape-specific behavior is part of the contract.

**Applies to:** Any OTP startup-failure test (`GenServer`, `Task`, adapter processes, supervisors)

## AP-P30: Cross-Layer Readiness Signals That Use Different Definitions of "Done"

**What it looks like:** A multi-step auth or startup flow spans several layers:
runtime library, sidecar, supervised transport, CLI. Each layer chooses its own
heuristic for success. One waits for `connection = open`, another polls
`registered = true`, another classifies persisted state as recoverable from a
different set of fields. The user performs one action, but the system flips
between "linked", "needs QR", and "recoverable" because the layers disagree on
what a finished session looks like.

**The root failure:** Readiness was treated as an implementation detail at each
layer instead of a shared contract. A library-internal transitional flag was
promoted to a product-level success criterion in one place, while recovery code
and CLI code used different heuristics elsewhere.

**Why this is dangerous:** These bugs are expensive. They do not fail cleanly.
They produce long live-debug loops, false recoveries, repeated QR refreshes,
status output that disagrees with the real remote platform, and support advice
that keeps changing because the defect appears to move. The deeper problem is
contract drift, not any single branch condition.

**The correct model:** For any cross-layer auth or startup flow, define one
canonical readiness contract in the design docs and make every layer consume the
same signal. Transitional library fields are not automatically valid product
signals. Recovery logic must use the same definition of durable state that the
CLI and runtime use for success. If the contract changes, update all layers
together.

Concrete checklist:

- write down the canonical success event
- write down which persisted artifacts prove durable state
- document which transitional fields are explicitly **not** valid readiness checks
- make CLI, runtime, and recovery code all reference the same contract
- add one live-ish regression test that exercises the full event sequence, not
  only isolated unit branches

**Applies to:** Channel auth/login flows, sidecar-backed runtimes, tunnel/webhook
readiness, any feature with multiple asynchronous layers and persisted state
