# BaileysEx

[![Hex.pm](https://img.shields.io/hexpm/v/baileys_ex.svg)](https://hex.pm/packages/baileys_ex)
[![Hex Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/baileys_ex)
[![License](https://img.shields.io/hexpm/l/baileys_ex.svg)](https://github.com/jeffhuen/baileys_ex/blob/main/LICENSE)

**WhatsApp Web API client for Elixir** — a behaviour-accurate port of
[Baileys](https://github.com/WhiskeySockets/Baileys) that brings the full
WhatsApp multi-device protocol to the BEAM.

BaileysEx connects directly to WhatsApp's WebSocket-based protocol. No browser
automation, no headless Chrome, no external Node.js sidecar. Just a supervised
Elixir process tree that handles the Noise handshake, Signal Protocol encryption,
binary XMPP framing, and the complete WhatsApp feature surface — natively.

> **Note:** This library communicates with WhatsApp's servers using a reverse-engineered
> protocol. It is not affiliated with, authorized by, or endorsed by WhatsApp or Meta.
> Use responsibly and in accordance with WhatsApp's Terms of Service.

## Features

### Authentication

- **QR code pairing** — scan from WhatsApp mobile to link a new device
- **Phone number pairing** — enter a numeric code instead of scanning
- **Persistent sessions** — save credentials to disk and reconnect without re-pairing
- **Multi-device protocol** — operates as a linked companion device

### Messaging

- **End-to-end encryption** via the Signal Protocol (pure Elixir implementation)
- **27+ message types** — text, images, video, audio, documents, stickers, contacts, location, polls, reactions, forwards, edits, deletes, and more
- **Quoted replies and mentions** — reply to and reference specific messages
- **Delivery tracking** — delivery receipts, read receipts, played receipts
- **Link previews** — attach URL preview metadata to outbound messages

### Media

- **Upload and download** — images, video, documents, audio, stickers, GIFs, voice notes
- **Streaming architecture** — encrypted media with AES-256-CBC + HMAC, never loads entire files into memory
- **Automatic key management** — HKDF-derived media keys with type-specific info strings
- **Stale URL refresh** — re-request expired media download URLs from paired devices

### Groups and Communities

- **Full group lifecycle** — create, update subject/description, leave, delete
- **Participant management** — add, remove, promote, demote
- **Invite flows** — v3/v4 invite codes, join-by-link, join approval
- **Community support** — create communities, link/unlink subgroups, manage metadata
- **Group settings** — ephemeral messages, announcement mode, membership approval

### Presence and Status

- **Online/offline/typing indicators** — send and subscribe to presence updates
- **Profile management** — get/set profile pictures, push names, status text
- **Contact validation** — check which phone numbers are registered on WhatsApp
- **Business profiles** — fetch and manage business profile data, catalogs, collections

### Newsletters

- **Subscribe/unsubscribe** — follow and unfollow WhatsApp channels
- **Create and manage** — create, update, and delete newsletters
- **Interact** — mute, react, and fetch newsletter content

### App State Sync

- **Cross-device sync** — archive, mute, pin, star, and read state synced across linked devices
- **LTHash integrity** — rolling hash verification detects drift or tampering before applying patches
- **Full Syncd codec** — encode and decode WhatsApp's versioned app state patch format

### Analytics

- **WAM encoding** — build and send WhatsApp Analytics and Metrics buffers for Baileys wire parity

## Why Elixir?

BaileysEx isn't just a translation — it's a reimagining of Baileys for a runtime
built for exactly this kind of work:

| Baileys (Node.js) | BaileysEx (Elixir/OTP) |
|----|-----|
| Callbacks and Promises | Supervised process trees with `:rest_for_one` restart strategy |
| `async-mutex` library | BEAM processes — concurrency is the runtime, not a library |
| Manual reconnect logic | `:gen_statem` state machine with automatic reconnection |
| `node-cache` / `lru-cache` | ETS tables — concurrent, lock-free, built into the VM |
| `pino` logging | `Logger` with structured metadata and configurable backends |
| Single-threaded event loop | Preemptive scheduling across all available cores |
| Process crash = app crash | Supervisor restarts failed children — let it crash |

**Crypto is native too.** All cryptographic primitives (AES, HMAC, SHA, PBKDF2,
Curve25519, Ed25519) use Erlang's built-in `:crypto` module — no external C/Rust
for standard operations. Rust NIFs are used only for the Noise Protocol framework
(`snow`) and XEdDSA signing (`curve25519-dalek`), where no Erlang/Elixir
equivalent exists.

## Quick Start

### Installation

Add `baileys_ex` to your `mix.exs` dependencies:

```elixir
def deps do
  [
    {:baileys_ex, "~> 0.1.0-alpha.2"}
  ]
end
```

**Requirements:** Elixir 1.19+, OTP 28, Rust toolchain (for NIF compilation).

### Connect and pair

```elixir
alias BaileysEx.Auth.FilePersistence
alias BaileysEx.Connection.Transport.MintWebSocket

# Load or create auth state
{:ok, persisted_auth} = FilePersistence.use_multi_file_auth_state("tmp/baileys_auth")

parent = self()

# Start the connection
{:ok, connection} =
  BaileysEx.connect(
    persisted_auth.state,
    Keyword.merge(persisted_auth.connect_opts, [
      transport: {MintWebSocket, []},
      on_qr: fn qr -> IO.puts("Scan QR: #{qr}") end,
      on_connection: fn update -> send(parent, {:connection_update, update}) end
    ])
  )

# Persist credentials on update
BaileysEx.subscribe_raw(connection, fn events ->
  if Map.has_key?(events, :creds_update) do
    {:ok, latest} = BaileysEx.auth_state(connection)
    :ok = persisted_auth.save_creds.(latest)
  end
end)

# Wait for the connection to open
receive do
  {:connection_update, %{connection: :open}} -> :connected!
after
  30_000 -> raise "timed out waiting for connection"
end
```

### Send a message

```elixir
{:ok, _sent} =
  BaileysEx.send_message(connection, "15551234567@s.whatsapp.net", %{
    text: "Hello from BaileysEx!"
  })
```

### Listen for incoming messages

```elixir
BaileysEx.subscribe(connection, fn
  {:message, msg} -> IO.inspect(msg, label: "incoming")
  {:connection, update} -> IO.inspect(update, label: "connection")
  _other -> :ok
end)
```

### Send media

```elixir
{:ok, _sent} =
  BaileysEx.send_message(connection, "15551234567@s.whatsapp.net", %{
    image: {:file, "photo.jpg"},
    caption: "Sent from Elixir"
  })
```

## Documentation

Full guides and API reference are available on [HexDocs](https://hexdocs.pm/baileys_ex).

| Section | What you'll learn |
|---------|-------------------|
| [Installation](https://hexdocs.pm/baileys_ex/installation.html) | Prerequisites, dependency setup, compilation |
| [First Connection](https://hexdocs.pm/baileys_ex/first-connection.html) | QR pairing, phone pairing, credential persistence |
| [Send Messages](https://hexdocs.pm/baileys_ex/messages.html) | Text, replies, reactions, polls, forwards, edits |
| [Media](https://hexdocs.pm/baileys_ex/media.html) | Upload images/video/docs, download, stale URL refresh |
| [Groups](https://hexdocs.pm/baileys_ex/groups.html) | Create, manage participants, invite flows, communities |
| [Events](https://hexdocs.pm/baileys_ex/events-and-subscriptions.html) | Subscribe to connection, message, and presence events |
| [Authentication](https://hexdocs.pm/baileys_ex/authentication-and-persistence.html) | Custom credential storage, Signal key management |
| [Configuration](https://hexdocs.pm/baileys_ex/configuration.html) | All connection and runtime options |
| [Event Catalog](https://hexdocs.pm/baileys_ex/event-catalog.html) | Every event type with payload shapes |
| [Message Types](https://hexdocs.pm/baileys_ex/message-types.html) | Complete message payload reference |

## Example

A complete echo bot is included at [`examples/echo_bot.exs`](examples/echo_bot.exs):

```bash
mix run examples/echo_bot.exs -- --help
```

See the [Echo Bot guide](https://hexdocs.pm/baileys_ex/echo-bot.html) for a
walkthrough.

## Telemetry

BaileysEx emits [Telemetry](https://hexdocs.pm/telemetry) events under the
`[:baileys_ex]` prefix — connection lifecycle, message send/receive, media
upload/download, and NIF operations. Attach your handlers for dashboards,
alerting, or tracing.

## Status

BaileysEx is in **alpha**. The API surface is stabilizing but may change before
1.0. The library tracks Baileys `7.00rc9` as its upstream reference for wire
behaviour and feature scope.

## Acknowledgements

- [Baileys](https://github.com/WhiskeySockets/Baileys) — the TypeScript original
  that defines the protocol behaviour BaileysEx implements
- [whatsmeow](https://github.com/tulir/whatsmeow) — Go implementation, referenced
  for protocol details
- [whatsapp-rust](https://github.com/nicksul/whatsapp-rs) — Rust implementation,
  referenced for documentation patterns

## License

MIT — see [LICENSE](LICENSE) for details.
