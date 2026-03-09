# Phase 6 Mint/Noise Transport Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add the next Phase 6 slice: an evented transport boundary, a Mint-backed WebSocket transport implementation, and real Noise handshake progression in `Connection.Socket` up to `:authenticating`.

**Architecture:** Keep `Connection.Socket` as the sole owner of connection and Noise state. Widen `Connection.Transport` into an evented runtime seam, implement `Connection.Transport.MintWebSocket`, and use an injected client payload binary as the temporary pre-Phase-7 auth seam.

**Tech Stack:** Elixir 1.19, OTP `:gen_statem`, Mint, Mint.WebSocket, ExUnit.

---

### Task 1: Add failing tests for the widened transport and handshake flow

**Files:**
- Modify: `test/baileys_ex/connection/socket_test.exs`
- Create: `test/baileys_ex/connection/transport/mint_web_socket_test.exs`
- Create: `test_helpers/connection/noise_server.exs`
- Modify: `test/test_helper.exs`

**Step 1: Write the failing socket tests**

Cover:
- `connect/1` leaves the socket in `:connecting` until the transport emits `:connected`
- on `:connected`, the socket sends a real Noise client hello and moves into `:noise_handshake`
- on a valid server hello, the socket sends client finish and transitions to `:authenticating`
- on handshake error, the socket returns to `:disconnected` and records `last_error`

Use a scripted test transport that emits transport events through `handle_info/2`.

**Step 2: Write the failing Mint transport tests**

Cover:
- `connect/3` parses config URL and issues HTTP connect + WebSocket upgrade via the adapter
- upgrade-complete stream messages emit `:connected`
- inbound binary WebSocket frames emit `{:binary, data}`
- `send_binary/2` encodes a binary WebSocket frame and writes it via the adapter

**Step 3: Add reusable Noise server helpers**

Move or recreate the deterministic server-hello builder logic used in
`test/baileys_ex/protocol/noise_test.exs` into `test_helpers/connection/noise_server.exs`
so the socket tests can exercise the real handshake without duplicating crypto logic.

**Step 4: Run the targeted tests to verify RED**

Run:
```bash
mix test test/baileys_ex/connection/socket_test.exs test/baileys_ex/connection/transport/mint_web_socket_test.exs
```

Expected: failures for missing transport callbacks, missing Mint transport module, and missing handshake progression.

### Task 2: Widen the transport behaviour and update the socket

**Files:**
- Modify: `lib/baileys_ex/connection/transport.ex`
- Modify: `lib/baileys_ex/connection/socket.ex`

**Step 1: Expand `Connection.Transport`**

Add the evented runtime callbacks:
- `connect/3`
- `handle_info/2`
- `send_binary/2`
- `disconnect/1`

Document the event contract:
- `:connected`
- `{:binary, data}`
- `{:closed, reason}`
- `{:error, reason}`

Update the `Noop` implementation to satisfy the new behaviour.

**Step 2: Extend `Connection.Socket` state**

Add fields for:
- `noise`
- `client_payload`

Keep the existing `last_error`, `retry_count`, and transport state ownership.

**Step 3: Implement connect/open handling**

Change the socket flow so:
- `connect/1` transitions to `:connecting`
- transport `connect/3` returns a runtime transport state
- the socket waits for transport events instead of jumping directly to `:noise_handshake`

**Step 4: Implement handshake progression**

When the transport emits `:connected`:
- initialize `Protocol.Noise`
- encode/send client hello
- transition to `:noise_handshake`

When the transport emits `{:binary, server_hello}` in `:noise_handshake`:
- call `Protocol.Noise.process_server_hello/3`
- build/send client finish with the injected client payload
- transition to `:authenticating`

On error:
- disconnect transport
- return to `:disconnected`
- increment `retry_count`
- record `last_error`

**Step 5: Run the targeted tests to verify GREEN**

Run:
```bash
mix test test/baileys_ex/connection/socket_test.exs
```

Expected: pass.

### Task 3: Implement the Mint WebSocket transport

**Files:**
- Create: `lib/baileys_ex/connection/transport/mint_web_socket.ex`
- Create: `lib/baileys_ex/connection/transport/mint_adapter.ex`
- Modify: `lib/baileys_ex/connection/config.ex`

**Step 1: Add any config support the transport needs**

Only add fields if required by implementation, such as transport opts or TLS defaults.
Do not over-design reconnect or keep-alive config in this slice.

**Step 2: Add a narrow Mint adapter module**

Wrap the Mint calls used by the transport:
- `Mint.HTTP.connect/4`
- `Mint.WebSocket.upgrade/5`
- `Mint.WebSocket.stream/2`
- `Mint.WebSocket.new/4`
- `Mint.WebSocket.encode/2`
- `Mint.WebSocket.stream_request_body/3`
- `Mint.HTTP.close/1`

Keep this adapter minimal so transport tests can inject a fake adapter.

**Step 3: Implement `MintWebSocket` transport**

Responsibilities:
- parse `config.ws_url`
- open HTTP/TLS connection
- issue WebSocket upgrade
- track phases `:upgrade_pending` and `:open`
- translate owner mailbox messages into transport events
- send binary WebSocket frames
- normalize errors without raising

**Step 4: Run the Mint transport tests**

Run:
```bash
mix test test/baileys_ex/connection/transport/mint_web_socket_test.exs
```

Expected: pass.

### Task 4: Update docs and run all gates

**Files:**
- Modify: `README.md`
- Modify: `dev/implementation_plan/00-overview.md`
- Modify: `dev/implementation_plan/06-connection.md`
- Modify: `dev/implementation_plan/PROGRESS.md`

**Step 1: Update docs honestly**

Record:
- Phase 6 now has a real Mint transport implementation in-tree
- the socket reaches `:authenticating` through a real Noise handshake
- auth response handling, keep-alive, supervisor, emitter, and store remain open

**Step 2: Run the full gate bundle**

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
git add docs/plans/2026-03-09-phase-6-mint-noise-transport-design.md \
  docs/plans/2026-03-09-phase-6-mint-noise-transport.md \
  test/test_helper.exs \
  test_helpers/connection/noise_server.exs \
  test/baileys_ex/connection/socket_test.exs \
  test/baileys_ex/connection/transport/mint_web_socket_test.exs \
  lib/baileys_ex/connection/config.ex \
  lib/baileys_ex/connection/socket.ex \
  lib/baileys_ex/connection/transport.ex \
  lib/baileys_ex/connection/transport/mint_adapter.ex \
  lib/baileys_ex/connection/transport/mint_web_socket.ex \
  README.md \
  dev/implementation_plan/00-overview.md \
  dev/implementation_plan/06-connection.md \
  dev/implementation_plan/PROGRESS.md
git commit -m "feat(connection): add mint noise transport handshake"
```
