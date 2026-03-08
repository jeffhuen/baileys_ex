# BaileysEx

Full-featured Elixir port of [Baileys](https://github.com/WhiskeySockets/Baileys) — a WhatsApp Web API library.

- **Signal protocol** implemented in pure Elixir (~1,500 lines across ~20 modules)
- **Rust NIFs only** for Noise protocol (`snow`) and XEdDSA signing (`curve25519-dalek`)
- **All crypto** via Erlang `:crypto` (OTP 28) — no crypto NIFs
- Targets Elixir 1.19+ / OTP 28

> **Status:** Pre-implementation. Architecture and detailed implementation plan complete (12 phases, 97 tasks, 48 gap items resolved). See `dev/implementation_plan/PROGRESS.md`.

## Architecture

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
| Signal Protocol | Pure Elixir (X3DH, Double Ratchet, Sender Keys, sessions) |
| Noise Protocol | Rust NIF (`snow` crate) — no Elixir equivalent exists |
| XEdDSA signing | Rust NIF (`curve25519-dalek`) — Montgomery-Edwards conversion |
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

## Usage

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

Reference source in `dev/reference/Baileys-master/` (not tracked in git).

## License

MIT
