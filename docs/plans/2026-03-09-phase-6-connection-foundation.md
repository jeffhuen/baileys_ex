# Phase 6 Connection Foundation Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Start Phase 6 with a narrow, honest foundation: connection config, a pure 3-byte frame codec, and a minimal `:gen_statem` socket skeleton with a test seam for transport startup.

**Architecture:** Keep the frame codec as a pure function module. Keep the connection runtime as a real `:gen_statem` because it owns state transitions. Do not introduce the per-connection supervisor, event emitter, or runtime store in this slice; they belong to later Phase 6 tasks once the socket contract is stable.

**Tech Stack:** Elixir 1.19, OTP `:gen_statem`, ExUnit, stdlib only.

---

### Task 1: Add connection foundation tests

**Files:**
- Create: `test/baileys_ex/connection/config_test.exs`
- Create: `test/baileys_ex/connection/frame_test.exs`
- Create: `test/baileys_ex/connection/socket_test.exs`

**Step 1: Write the failing tests**

Cover:
- config defaults and platform mapping
- 3-byte frame encode/decode, including incomplete tails
- socket initial state, successful connect transition via injected transport, failed connect behavior, and not-connected send behavior

**Step 2: Run tests to verify they fail**

Run:
```bash
mix test test/baileys_ex/connection/config_test.exs test/baileys_ex/connection/frame_test.exs test/baileys_ex/connection/socket_test.exs
```

Expected: failures for missing modules/functions.

### Task 2: Implement minimal connection foundation

**Files:**
- Create: `lib/baileys_ex/connection/config.ex`
- Create: `lib/baileys_ex/connection/frame.ex`
- Create: `lib/baileys_ex/connection/transport.ex`
- Create: `lib/baileys_ex/connection/socket.ex`

**Step 1: Implement `Connection.Config`**

Add:
- struct defaults aligned with `06-connection.md`
- `new/1`
- `platform_type/1`

**Step 2: Implement `Connection.Frame`**

Add:
- `encode/1`
- `decode_stream/1`
- oversized payload rejection

**Step 3: Implement `Connection.Transport` behavior and socket skeleton**

Add:
- transport behavior for `connect/2`, `disconnect/1`, `send/2`
- `BaileysEx.Connection.Socket` as `:gen_statem`
- states: `:disconnected`, `:connecting`, `:noise_handshake`
- public API: `start_link/1`, `connect/1`, `disconnect/1`, `state/1`, `snapshot/1`, `send_payload/2`

**Step 4: Run targeted tests**

Run:
```bash
mix test test/baileys_ex/connection/config_test.exs test/baileys_ex/connection/frame_test.exs test/baileys_ex/connection/socket_test.exs
```

Expected: pass.

### Task 3: Update phase docs and verify gates

**Files:**
- Modify: `dev/implementation_plan/06-connection.md`
- Modify: `dev/implementation_plan/PROGRESS.md`

**Step 1: Update docs honestly**

Record:
- Phase 6 has started
- config/frame foundation exists
- socket is still a skeleton, not a complete transport/auth runtime

**Step 2: Run all delivery gates**

Run:
```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix test
mix credo --all
mix dialyzer
mix docs
```

Expected: all pass.

**Step 3: Commit**

```bash
git add docs/plans/2026-03-09-phase-6-connection-foundation.md \
  lib/baileys_ex/connection \
  test/baileys_ex/connection \
  dev/implementation_plan/06-connection.md \
  dev/implementation_plan/PROGRESS.md
git commit -m "feat(connection): add phase 6 foundation"
```
