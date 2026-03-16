# Phase 12: Polish

**Goal:** Telemetry instrumentation, public API finalization, documentation,
example application, hex.pm preparation, and WAM analytics parity.

**Status:** COMPLETE

**Depends on:** All previous phases

---

## Tasks

### 12.1 Telemetry

File: `lib/baileys_ex/telemetry.ex`

Emit telemetry events for key operations:

```elixir
defmodule BaileysEx.Telemetry do
  @prefix [:baileys_ex]

  # Connection events
  # [:baileys_ex, :connection, :start | :stop | :exception]
  # [:baileys_ex, :connection, :reconnect]

  # Message events
  # [:baileys_ex, :message, :send, :start | :stop | :exception]
  # [:baileys_ex, :message, :receive]

  # Media events
  # [:baileys_ex, :media, :upload, :start | :stop | :exception]
  # [:baileys_ex, :media, :download, :start | :stop | :exception]

  # NIF events
  # [:baileys_ex, :nif, :signal, :encrypt | :decrypt]
  # [:baileys_ex, :nif, :noise, :encrypt | :decrypt]

  def span(event_name, metadata, fun) do
    :telemetry.span(@prefix ++ event_name, metadata, fn ->
      result = fun.()
      {result, metadata}
    end)
  end
end
```

### 12.2 Public API facade

File: `lib/baileys_ex.ex`

```elixir
defmodule BaileysEx do
  @moduledoc """
  BaileysEx — Elixir WhatsApp Web API library.

  ## Quick Start

      # Load or create auth state
      {:ok, auth} = BaileysEx.Auth.FilePersistence.load_credentials()
      auth = auth || BaileysEx.Auth.State.new()

      # Connect
      {:ok, conn} = BaileysEx.connect(auth,
        on_qr: fn qr -> IO.puts("Scan QR: \#{qr}") end,
        on_connection: fn state -> IO.puts("Connection: \#{state}") end
      )

      # Send a message
      BaileysEx.send_message(conn, "1234567890@s.whatsapp.net", %{text: "Hello!"})

      # Subscribe to incoming messages
      BaileysEx.subscribe(conn, fn
        {:message, msg} -> IO.inspect(msg)
        _ -> :ok
      end)
  """

  defdelegate connect(auth_state, opts \\ []), to: BaileysEx.Connection.Supervisor, as: :start_connection
  defdelegate disconnect(conn), to: BaileysEx.Connection.Supervisor, as: :stop_connection
  defdelegate send_message(conn, jid, content, opts \\ []), to: BaileysEx.Message.Sender, as: :send
  defdelegate subscribe(conn, handler), to: BaileysEx.Connection.EventEmitter
  defdelegate request_pairing_code(conn, phone), to: BaileysEx.Auth.Phone, as: :request_code

  # Convenience re-exports
  defdelegate group_create(conn, subject, participants), to: BaileysEx.Feature.Group, as: :create
  defdelegate presence_update(conn, presence), to: BaileysEx.Feature.Presence, as: :send_presence
  defdelegate download_media(message, opts \\ []), to: BaileysEx.Media.Download, as: :download
end
```

### 12.3 Documentation

- `@moduledoc` on every public module
- `@doc` on every public function
- Typespecs on all public functions
- Guide pages in `guides/`:
  - `getting-started.md`
  - `authentication.md`
  - `sending-messages.md`
  - `receiving-messages.md`
  - `media.md`
  - `groups.md`
  - `custom-persistence.md`

### 12.4 Example application

File: `examples/echo_bot.exs`

Simple bot that echoes received messages — demonstrates the full API.

### 12.5 Hex.pm preparation

- `mix.exs`: description, package metadata, links
- `LICENSE` file
- Verify `mix hex.build` succeeds
- Verify `mix docs` generates clean documentation

### 12.6 CI setup

- GitHub Actions workflow
- Steps: compile, format check, credo, dialyzer, test
- Rust compilation cached via `actions/cache`

### 12.7 WAM analytics parity

**Baileys reference:** `src/WAM/` — 100+ analytics event definitions, `sendWAMBuffer()`

WAM (WhatsApp Analytics/Metrics) is WhatsApp's internal telemetry system. Baileys
includes event encoding and `sendWAMBuffer()` in the socket layer (already stubbed
in Phase 6). The event definitions in `src/WAM/constants.ts` describe 100+ metric
types with field schemas.

For full Baileys parity, implement the binary encoding from `src/WAM/encode.ts`
and wire it to the existing `sendWAMBuffer` stub. If the library exposes a user
opt-out, that must be an explicit configuration deviation from Baileys-compatible
default behavior, not an undocumented omission.

---

## Acceptance Criteria

- [x] Telemetry events fire for all key operations
- [x] Public API covers all major features
- [x] Documentation generates without warnings
- [x] Example bot runs successfully
- [x] `mix hex.build` succeeds
- [x] CI passes all checks
- [x] WAM buffer encoding matches Baileys for the supported event set, with any opt-out documented as an explicit deviation

## Files Created/Modified

- `lib/baileys_ex.ex` (rewrite)
- `lib/baileys_ex/telemetry.ex`
- `lib/baileys_ex/wam.ex`
- `lib/baileys_ex/wam/*.ex`
- `priv/wam/definitions.json`
- `dev/scripts/generate_wam_definitions.mjs`
- `guides/*.md`
- `examples/echo_bot.exs`
- `.github/workflows/ci.yml`
