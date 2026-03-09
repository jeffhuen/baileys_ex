# Phase 6 Mint/Noise Transport Design

## Goal

Implement the next honest Phase 6 slice: a real Mint-backed WebSocket transport and
the real Baileys-style Noise handshake flow inside `BaileysEx.Connection.Socket`,
ending when the client has sent the `client_finish` handshake message and entered
the `:authenticating` state.

## Recommended Approach

Keep `BaileysEx.Connection.Socket` as the state machine owner and widen the
`BaileysEx.Connection.Transport` behaviour just enough to support real inbound
transport events. Add a `BaileysEx.Connection.Transport.MintWebSocket`
implementation behind that boundary instead of collapsing Mint internals directly
into the socket.

This preserves the right ownership model:

- the socket owns connection state, retry/error transitions, and `Protocol.Noise`
- the transport owns HTTP/WebSocket setup and raw binary frame send/receive
- Phase 7 auth remains outside this slice

## Why This Approach

### Option 1: Socket owns state, Mint behind the transport boundary

This is the recommended design.

Pros:
- keeps the `:gen_statem` as the single source of truth for connection state
- preserves deterministic tests by allowing a scripted transport in socket tests
- introduces real Mint runtime behavior without coupling the socket directly to Mint
- leaves room for supervisor/event/store work later without redoing the socket contract

Cons:
- requires widening the transport behaviour now
- the Mint transport needs a small adapter seam for deterministic unit tests

### Option 2: Put Mint directly in the socket

Pros:
- fewer modules
- superficially closer to the final runtime shape

Cons:
- state-machine tests become harder and more coupled to Mint internals
- transport-specific complexity leaks into the socket too early
- the seam for future alternative transports or deterministic tests disappears

### Option 3: Only add Noise handshake on top of the fake transport

Pros:
- smallest code change
- easiest tests

Cons:
- defers the real runtime risk again
- does not materially advance the actual connection layer

## Final Design

### Ownership

`BaileysEx.Connection.Socket` remains the owner of:

- socket lifecycle state
- retry count and last error
- `BaileysEx.Protocol.Noise` state
- handshake progression
- the transition from transport-open to `:noise_handshake` to `:authenticating`

`BaileysEx.Connection.Transport` owns:

- HTTP connect + WebSocket upgrade
- translating owner-process messages into transport events
- binary WebSocket frame send
- close/disconnect

### Transport Behaviour

The current transport behaviour is widened from a write-only seam into an evented
runtime seam. The socket will call transport functions and feed owner-process
messages back through the transport for interpretation.

Expected transport responsibilities:

- `connect/3` or equivalent: create the runtime transport state
- `handle_info/2`: consume owner-process messages (`:tcp`, `:ssl`, Mint responses, test-script messages)
- emit transport events such as:
  - `:connected`
  - `{:binary, data}`
  - `{:closed, reason}`
  - `{:error, reason}`
- `send_binary/2`
- `disconnect/1`

The transport must not interpret Noise or WABinary payloads.

### Mint Transport

Add `BaileysEx.Connection.Transport.MintWebSocket`.

It will:

- parse `config.ws_url`
- connect via `Mint.HTTP.connect/4`
- issue the WebSocket upgrade via `Mint.WebSocket.upgrade/5`
- process owner mailbox messages through `Mint.WebSocket.stream/2`
- emit `:connected` only when the upgrade is complete and a `Mint.WebSocket` state exists
- decode inbound WebSocket binary frames and emit raw `{:binary, data}` events

It will use a narrow adapter seam internally so tests can drive it deterministically
without a live server.

### Socket Handshake Flow

The socket state progression for this slice is:

`disconnected -> connecting -> noise_handshake -> authenticating`

Detailed flow:

1. `connect/1` transitions to `:connecting`
2. socket asks the transport to connect
3. transport emits `:connected` once WebSocket upgrade is ready
4. socket initializes `BaileysEx.Protocol.Noise`
5. socket sends the encoded client hello over the transport as a binary frame
6. transport emits `{:binary, server_hello_bytes}`
7. socket processes server hello via `Protocol.Noise.process_server_hello/3`
8. socket builds the client-finish message using an injected client payload binary
9. socket sends the client-finish message over the transport
10. socket transitions to `:authenticating`

This slice stops there. It does not yet process the registration/login response node,
emit connection events, or start keep-alive.

### Temporary Auth Seam

Phase 7 is not implemented yet, but `client_finish` requires a payload.

This slice introduces an explicit temporary seam: the socket accepts an injected
already-encoded client payload binary. That keeps this slice honest:

- we do not fake Phase 7 auth logic
- we still exercise the real Noise handshake
- later auth work can replace the seam with a real payload builder

This seam is internal development plumbing, not the final public API.

### Error Handling

The socket should:

- keep transport and Noise errors as tagged runtime reasons
- return to `:disconnected` on connect/upgrade/handshake failure
- persist `last_error`
- increment `retry_count` on failed connect/handshake attempts in this slice

The transport should:

- normalize Mint connect/upgrade/decode failures into tagged transport errors
- never crash the socket process by raising

### Testing Strategy

This slice should be test-driven at two levels.

Socket tests:
- keep a scripted fake transport
- prove state transitions through `:connecting`, `:noise_handshake`, and `:authenticating`
- prove real Noise handshake progression using deterministic server-hello fixtures
- prove handshake failure returns to `:disconnected` with an error

Mint transport tests:
- do not use a real network server
- inject a fake Mint adapter that returns known `connect`, `upgrade`, `stream`, `new`, and `encode` results
- prove upgrade completion emits `:connected`
- prove inbound binary WebSocket data becomes `{:binary, data}`
- prove send path encodes binary frames and writes them to the request body

### Non-Goals

This slice does not implement:

- keep-alive timers
- reconnect scheduling policy
- per-connection supervision
- event emitter or buffering
- connection store
- registration/login node generation
- post-handshake application node parsing

## Success Criteria

The slice is complete when:

- the socket performs a real `Protocol.Noise` handshake through the transport seam
- a real Mint transport exists in-tree
- tests prove deterministic transport-open and handshake transitions
- the docs and progress tracker reflect the narrower accepted scope accurately
