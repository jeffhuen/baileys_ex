# BaileysEx

In-progress Elixir port of [Baileys](https://github.com/WhiskeySockets/Baileys) — a WhatsApp Web API library.

- Targets Elixir 1.19+ / OTP 28

## Target Architecture

> **Note:** The tree below describes the intended steady-state architecture, not the current module set in this branch.

```
BaileysEx.Application (Supervisor)
├── Registry (named connections)
├── DynamicSupervisor (per-connection)
│   └── Supervisor (:rest_for_one)
│       ├── Connection.Socket     (:gen_statem — WebSocket + Noise)
│       ├── Connection.Store      (GenServer + ETS — sessions, creds)
│       ├── Connection.EventEmitter (GenServer — pub/sub, buffering)
│       └── Task.Supervisor       (device discovery, media ops)
└── Task.Supervisor (global one-off tasks)
```

### Native-First Philosophy

| Layer | Approach |
|-------|----------|
| Crypto primitives | Erlang `:crypto` (AES, HMAC, SHA, PBKDF2, Curve25519, Ed25519) |
| HKDF | Pure Elixir using `:crypto.mac/4` |
| Signal Protocol | Baileys-compatible Elixir repository boundary with the smallest native helper surface justified by interoperability |
| Noise Protocol | Elixir protocol layer aligned with Baileys, using native crypto primitives and a narrow XEdDSA helper |
| Signature helpers | Narrow XEdDSA helper plus Elixir wrappers that expose the Baileys-compatible verification primitive |
| Wire format | Pure Elixir (WABinary encode/decode) |
| Protobuf | `protox` (pure Elixir codegen) |
| WebSocket | `Mint.WebSocket` (process-less) |

## Installation

```elixir
def deps do
  [
    {:baileys_ex, "~> 0.1.0"}
  ]
end
```

## Planned API

> **Note:** The public API below is not yet implemented. It shows the intended interface for when the messaging and connection layers are complete (Phases 6--8+).

```elixir
# Start a connection
{:ok, conn} = BaileysEx.connect(auth_state, opts)

# Subscribe to events
BaileysEx.subscribe(conn, fn
  {:message, msg} -> handle_message(msg)
  {:connection, :open} -> Logger.info("Connected!")
end)

# Send messages
BaileysEx.send_message(conn, "1234567890@s.whatsapp.net", %{text: "Hello!"})

# Group operations
BaileysEx.Group.create(conn, "My Group", [jid1, jid2])
```

## Development

```bash
mix deps.get
mix compile
mix test
```

Implementation planning and contributor workflow live under `dev/implementation_plan/`.

Reference source in `dev/reference/Baileys-master/` (not tracked in git).

When the docs and reference tree disagree, prefer current Baileys v7 semantics:
- LID means `Local Identifier`
- new Signal/session flows are LID-first
- `on_whatsapp` is not the source of truth for LIDs
- successful delivery ACK parity must match Baileys/WhatsApp Web exactly

## License

MIT
