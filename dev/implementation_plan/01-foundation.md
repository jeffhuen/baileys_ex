# Phase 1: Foundation

**Goal:** Project structure, dependencies, core type definitions, Rust NIF scaffold.

**Depends on:** Nothing (first phase)
**Parallel with:** Nothing
**Blocks:** All subsequent phases

---

## Tasks

### 1.1 Update mix.exs with dependencies

```elixir
defp deps do
  [
    # Rust NIFs (0.37+ has auto NIF discovery, #[derive(Resource)], ResourceArc monitoring)
    {:rustler, "~> 0.37"},

    # WebSocket
    {:mint_web_socket, "~> 1.0"},
    {:mint, "~> 1.6"},

    # HTTP client (for media upload/download)
    {:req, "~> 0.5"},

    # Protocol Buffers
    {:protox, "~> 1.7"},

    # Telemetry
    {:telemetry, "~> 1.3"},

    # Testing
    {:stream_data, "~> 1.1", only: :test},
    {:mox, "~> 1.2", only: :test},

    # Dev
    {:ex_doc, "~> 0.34", only: :dev, runtime: false},
    {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
    {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
  ]
end
```

### 1.2 Update application.ex

```elixir
def application do
  [
    mod: {BaileysEx.Application, []},
    extra_applications: [:logger, :crypto]
  ]
end
```

### 1.3 Create Application supervisor

File: `lib/baileys_ex/application.ex`

```elixir
defmodule BaileysEx.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: BaileysEx.Registry},
      {DynamicSupervisor, name: BaileysEx.ConnectionSupervisor, strategy: :one_for_one},
      {Task.Supervisor, name: BaileysEx.TaskSupervisor}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: BaileysEx.Supervisor)
  end
end
```

### 1.4 Scaffold Rust NIF crate

```
native/baileys_nif/
├── Cargo.toml
├── .cargo/
│   └── config.toml
└── src/
    ├── lib.rs
    ├── noise.rs
    └── xeddsa.rs
```

Initial `Cargo.toml` (crypto primitives handled by Erlang `:crypto`, NOT Rust):
```toml
[package]
name = "baileys_nif"
version = "0.1.0"
edition = "2021"

[lib]
name = "baileys_nif"
crate-type = ["cdylib"]

[dependencies]
rustler = "0.37"
# Noise protocol (no Elixir/Erlang equivalent)
snow = "0.9"
# XEdDSA: Montgomery↔Edwards key conversion for Signal signing
# curve25519-dalek: 35M+ downloads, used by Tor/Zcash — battle-tested
curve25519-dalek = { version = "4", features = ["digest"] }
sha2 = "0.10"       # Required by curve25519-dalek for nonce derivation
getrandom = "0.2"   # Secure random for XEdDSA nonce
# NOTE: No generic crypto crates here — Erlang :crypto handles AES, HMAC, HKDF, etc.
# NOTE: `libsignal-protocol` is a later-phase dependency, not part of the initial scaffold
```

Initial `lib.rs` (Rustler 0.37+ auto-discovers NIFs, no explicit list needed):
```rust
mod noise;
mod xeddsa;

rustler::init!("Elixir.BaileysEx.Native");
```

### 1.5 Create NIF module stubs

Phase 1 only needs the native scaffolding and the Noise/XEdDSA module stubs. Generic
crypto stays in Erlang `:crypto`, while the final Shape of the Signal native layer is
defined later once the Phase 5 `libsignal-protocol` wrapper is specified.

File: `lib/baileys_ex/native/noise.ex`
```elixir
defmodule BaileysEx.Native.Noise do
  use Rustler, otp_app: :baileys_ex, crate: "baileys_nif"

  # Stubs — replaced by NIF at load time
  def init(_prologue), do: :erlang.nif_error(:nif_not_loaded)
  def handshake_write(_state, _payload), do: :erlang.nif_error(:nif_not_loaded)
  def handshake_read(_state, _message), do: :erlang.nif_error(:nif_not_loaded)
  def finish(_state), do: :erlang.nif_error(:nif_not_loaded)
  def encrypt(_state, _plaintext), do: :erlang.nif_error(:nif_not_loaded)
  def decrypt(_state, _ciphertext), do: :erlang.nif_error(:nif_not_loaded)
end
```

File: `lib/baileys_ex/native/xeddsa.ex`
```elixir
defmodule BaileysEx.Native.XEdDSA do
  @moduledoc """
  XEdDSA signing/verification via curve25519-dalek NIF.

  Required for WhatsApp wire compatibility: identity keys are Curve25519
  (Montgomery form) but must produce Ed25519-compatible signatures for
  signed pre-keys and sender key messages.
  """
  use Rustler, otp_app: :baileys_ex, crate: "baileys_nif"

  # Stubs — replaced by NIF at load time
  def sign(_private_key, _message), do: :erlang.nif_error(:nif_not_loaded)
  def verify(_public_key, _message, _signature), do: :erlang.nif_error(:nif_not_loaded)
end
```

### 1.6 Core type definitions

File: `lib/baileys_ex/types.ex` — shared structs used across modules.

Key types to define:
- `BaileysEx.JID` — struct for WhatsApp JIDs
- `BaileysEx.BinaryNode` — struct for WABinary nodes
- `BaileysEx.Message` — base message struct
- `BaileysEx.ConnectionConfig` — connection options

### 1.7 Directory structure

Create all directories:
```
lib/baileys_ex/
├── native/
├── protocol/
├── connection/
├── auth/
├── signal/
├── message/
├── media/
├── feature/
└── util/
```

---

## Acceptance Criteria

- [x] `mix deps.get` succeeds
- [x] `mix compile` succeeds (NIF stubs load with nif_error)
- [x] `mix test` passes (basic smoke test)
- [x] Rust crate compiles: `cd native/baileys_nif && cargo check`
- [x] Application starts: `iex -S mix` launches supervision tree
- [x] `Registry`, `DynamicSupervisor`, `TaskSupervisor` visible in observer

## Files Created/Modified

- `mix.exs` — deps, application config
- `lib/baileys_ex/application.ex` — supervisor
- `lib/baileys_ex/types.ex` — core types
- `lib/baileys_ex/native/noise.ex` — NIF stub
- `lib/baileys_ex/native/xeddsa.ex` — NIF stub
- `native/baileys_nif/` — Rust crate scaffold
