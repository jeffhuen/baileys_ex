# Phase 6 Connection Parity Runtime Design

## Goal

Implement the next honest Phase 6 slice after the Mint/Noise transport work:
the remaining Baileys 7.0.0-rc.9 connection/runtime behavior that lives in
`socket.ts`, `event-buffer.ts`, and the connection-facing parts of `chats.ts`.

This repo is a port, not a reinterpretation. The design target is behavioral
parity with the reference under `dev/reference/Baileys-master`, then an OTP
wrapper around that parity surface.

## Recommended Approach

Keep the accepted transport + Noise handshake slice intact and add the next
runtime layers in the same shape Baileys uses:

1. `Connection.Socket` mirrors `makeSocket`
2. `Connection.EventEmitter` mirrors `makeEventBuffer`
3. the per-connection runtime above them owns OTP-specific reconnect policy
4. the initial sync choreography mirrors `makeChatsSocket`, not the raw socket

## Why This Approach

### Option 1: Match Baileys layering, then wrap it in OTP

This is the recommended design.

Pros:
- keeps the port reference-anchored instead of inventing a new connection model
- makes it obvious which behaviors belong to `socket.ts` versus `chats.ts`
- allows the Elixir supervisor to provide ergonomics without mutating the raw socket contract
- keeps Phase 7 auth and Phase 8 message receive responsibilities cleanly separated

Cons:
- requires more discipline about module boundaries
- means some sync-state behavior is specified in Phase 6 but fully exercised only once the receive pipeline exists

### Option 2: Push sync-state and reconnect logic into the raw socket

Pros:
- fewer modules on paper
- superficially easier to drive from `:gen_statem`

Cons:
- does not match Baileys rc.9 structure
- blurs `makeSocket` and `makeChatsSocket` responsibilities
- makes later parity work harder because the raw socket starts owning higher-level concerns

### Option 3: Build the Elixir supervisor/store/event stack first and fit Baileys into it later

Pros:
- fast local progress on OTP structure

Cons:
- backwards from the stated goal of a drop-in port
- high risk of encoding the wrong public/runtime contract before the reference behavior is captured

## Final Design

### `Connection.Socket` ownership

`Connection.Socket` is the Elixir equivalent of rc.9 `makeSocket`. It owns:

- WebSocket/Mint transport lifecycle
- Noise handshake and post-handshake frame encryption/decryption
- request/response query primitives
- `connection.update` transitions for `connecting`, `open`, and `close`
- keep-alive ping IQs on `xmlns='w:p'`
- logout via `remove-companion-device`
- unified session emission
- handling `offline_preview`, `offline`, and `edge_routing`

It does not own the `AwaitingInitialSync -> Syncing -> Online` choreography.

### `Connection.EventEmitter` ownership

`Connection.EventEmitter` is the Elixir equivalent of rc.9 `makeEventBuffer`.
It owns:

- the event catalog and subscriber dispatch
- `process`, `buffer`, `flush`, and nested buffered-function semantics
- the 12 bufferable event types from rc.9
- 30-second auto-flush behavior
- special handling for mixed `messages.upsert` types
- preserving conditional chat updates across flushes

It does not own the transport/Noise state machine.

### Per-connection wrapper ownership

The per-connection supervisor/wrapper is the OTP shell around the parity pieces.
It may:

- recreate the raw socket after unexpected `connection.update(connection: :close)` events
- keep reconnect policy out of the raw socket contract
- coordinate store, event emitter, socket, and task supervisor lifecycle with `:rest_for_one`

This maps to how Baileys examples recreate the socket externally on close, except
the Elixir port can internalize that at the supervision boundary.

### Store ownership

`Connection.Store` should own concurrent-read/runtime-write state that the
connection runtime needs immediately:

- credentials updates that must persist promptly
- `routingInfo`
- `lastPropHash`
- `lastAccountSyncTimestamp`
- `accountSyncCounter`
- LID/PN mappings and other connection runtime metadata

ETS should serve concurrent reads; a GenServer should serialize writes.

### Initial sync choreography

The runtime above the raw socket should mirror the rc.9 `chats.ts` connection-side flow:

1. on `connection.update(connection: :open)`, run init queries in parallel and send presence
2. on `connection.update(received_pending_notifications: true)`, enter `:awaiting_initial_sync` and start buffering
3. if history sync is disabled, go directly to `:online` and flush on the next turn
4. if the first processable history sync message arrives, transition to `:syncing`
5. run app-state sync
6. transition to `:online`, flush buffered events, and increment `accountSyncCounter`

This is a Phase 6 contract even though the full trigger path is completed together
with the receive pipeline work in Phase 8.

## Immediate Next Slice

The next implementation slice after the accepted Mint/Noise work should focus on:

- post-handshake `Connection.Socket` parity for `connection.update`, keep-alive, unified session, logout, and offline/routing handlers
- `Connection.EventEmitter` parity for batching/buffering
- store hooks for creds/runtime metadata
- the supervised reconnect wrapper contract

The QR/pair-success details remain tied to Phase 7 auth work, but the socket
contract should already reserve those event/update paths.

## Non-Goals

This design update does not claim that the following are already implemented:

- full QR/pairing flow
- full login/registration response handling
- full history/message receive pipeline
- app-state patch decoding
- full group/community dirty refresh execution

It only corrects where those behaviors belong and what the remaining Phase 6
parity target actually is.
