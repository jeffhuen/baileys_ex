# Phase 6 Connection Parity Runtime Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add the next Phase 6 slice: Baileys 7.0.0-rc.9-compatible post-handshake connection behavior and buffered event/runtime foundations on top of the accepted Mint/Noise handshake work.

**Architecture:** Keep `Connection.Socket` aligned with `makeSocket`, keep `Connection.EventEmitter` aligned with `makeEventBuffer`, and put reconnect policy in the per-connection OTP wrapper rather than inventing new raw-socket semantics.

**Tech Stack:** Elixir 1.19, OTP `:gen_statem`, Mint, ETS, ExUnit.

---

### Task 1: Lock the reference behavior in tests

**Files:**
- Modify: `test/baileys_ex/connection/socket_test.exs`
- Create: `test/baileys_ex/connection/event_emitter_test.exs`
- Create: `test/baileys_ex/connection/supervisor_test.exs`

**Step 1: Add failing socket tests for post-handshake runtime behavior**

Cover:
- `connection.update` emits `:connecting`, `:open`, and `:close`-equivalent transitions in the right order
- keep-alive sends `w:p` ping IQs and closes after `keep_alive_interval_ms + 5000` without inbound traffic
- `logout/1` sends `remove-companion-device` and then disconnects
- `offline_preview`, `offline`, and `edge_routing` events trigger the rc.9 behaviors
- `send_unified_session/1` runs on connection open and presence available

**Step 2: Add failing event emitter tests**

Cover:
- `process/2` receives consolidated event maps
- `buffer/1` + `flush/1` delay bufferable events and immediately pass through non-bufferable events
- buffer auto-flushes after 30 seconds
- mixed `messages_upsert` types force a flush boundary
- conditional chat updates survive a flush when their condition is still unresolved

**Step 3: Add failing reconnect-wrapper tests**

Cover:
- the per-connection supervisor recreates the socket after unexpected close
- the supervisor does not auto-reconnect after logged-out close reasons
- `:rest_for_one` ordering restarts downstream children correctly

**Step 4: Run targeted tests to verify RED**

Run:
```bash
mix test test/baileys_ex/connection/socket_test.exs test/baileys_ex/connection/event_emitter_test.exs test/baileys_ex/connection/supervisor_test.exs
```

Expected: failures for missing socket/event-emitter/supervisor behavior.

### Task 2: Implement `Connection.Socket` rc.9 post-handshake parity

**Files:**
- Modify: `lib/baileys_ex/connection/socket.ex`
- Modify: `lib/baileys_ex/connection/config.ex`
- Modify: `lib/baileys_ex/connection/transport.ex`

**Step 1: Add socket runtime fields and public surface**

Add fields and APIs for:
- `last_disconnect`
- inbound activity timestamp
- server time offset
- event-emitter/store references if needed
- `logout/1`

**Step 2: Implement `connection.update` and post-handshake runtime behavior**

Add behavior for:
- `:connecting` emission on startup/connect
- `:open` emission once the auth-success seam is satisfied
- `:close` emission with structured disconnect reason/date
- `offline_preview`, `offline`, and `edge_routing` handling

**Step 3: Implement keep-alive and unified session**

Add:
- `w:p` ping IQ keep-alive timer
- timeout-on-no-inbound-traffic logic
- unified session calculation using server time offset

**Step 4: Implement logout semantics**

Send:
- `iq xmlns='md' type='set'`
- `remove-companion-device jid=... reason='user_initiated'`

Then close the socket with the logged-out reason.

**Step 5: Run targeted socket tests to verify GREEN**

Run:
```bash
mix test test/baileys_ex/connection/socket_test.exs
```

Expected: pass.

### Task 3: Implement `Connection.EventEmitter` parity foundations

**Files:**
- Create: `lib/baileys_ex/connection/event_emitter.ex`

**Step 1: Add the event catalog and subscriber/process API**

Implement:
- `process/2`
- `subscribe/2` or equivalent subscriber registration
- direct emission for non-bufferable events

**Step 2: Implement buffer/flush behavior**

Implement:
- rc.9 bufferable event set
- 30-second auto-flush
- nested buffered-function counting/debounced flush
- mixed `messages_upsert` type boundary flush

**Step 3: Implement conditional chat update preservation**

Keep unresolved conditional updates across flushes until their condition becomes true or false.

**Step 4: Run targeted event-emitter tests**

Run:
```bash
mix test test/baileys_ex/connection/event_emitter_test.exs
```

Expected: pass.

### Task 4: Implement store and reconnect-wrapper foundations

**Files:**
- Create: `lib/baileys_ex/connection/store.ex`
- Create: `lib/baileys_ex/connection/supervisor.ex`

**Step 1: Add the runtime store foundation**

Implement:
- ETS-backed concurrent reads
- serialized writes through a GenServer
- storage for creds/runtime metadata used by Phase 6 (`routingInfo`, `lastPropHash`, `lastAccountSyncTimestamp`, `accountSyncCounter`, LID mappings)

**Step 2: Add the supervisor wrapper**

Implement:
- `:rest_for_one` child ordering
- reconnect-on-close policy outside the raw socket
- no reconnect after logged-out close reason

**Step 3: Run targeted store/supervisor tests**

Run:
```bash
mix test test/baileys_ex/connection/supervisor_test.exs
```

Expected: pass.

### Task 5: Update canonical docs and run verification

**Files:**
- Modify: `README.md`
- Modify: `dev/implementation_plan/00-overview.md`
- Modify: `dev/implementation_plan/06-connection.md`
- Modify: `dev/implementation_plan/PROGRESS.md`

**Step 1: Update docs honestly**

Record:
- the raw socket mirrors `makeSocket`, not `makeChatsSocket`
- reconnect lives in the wrapper/supervision layer
- event buffering mirrors `makeEventBuffer`
- initial sync choreography mirrors `chats.ts`

**Step 2: Run the verification bundle**

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
