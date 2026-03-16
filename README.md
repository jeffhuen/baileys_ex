# BaileysEx

Behavior-accurate Elixir port of [Baileys 7.00rc9](https://github.com/WhiskeySockets/Baileys), the WhatsApp Web API library.

BaileysEx follows the Baileys wire protocol and feature surface closely while exposing an Elixir-first runtime: supervisors, ETS-backed stores, explicit transports, and typed public modules.

## Installation

```elixir
def deps do
  [
    {:baileys_ex, "~> 0.1.0"}
  ]
end
```

## Quick Start

```elixir
alias BaileysEx.Auth.FilePersistence
alias BaileysEx.Auth.State

auth_path = "tmp/baileys_auth"

{:ok, auth_state} = FilePersistence.load_credentials(auth_path)

{:ok, connection} =
  BaileysEx.connect(auth_state,
    on_qr: fn qr -> IO.puts("Scan QR: #{qr}") end,
    on_connection: fn update -> IO.inspect(update, label: "connection") end
  )

unsubscribe =
  BaileysEx.subscribe(connection, fn
    {:message, message} -> IO.inspect(message, label: "incoming")
    {:connection, update} -> IO.inspect(update, label: "connection")
    _other -> :ok
  end)

{:ok, _sent} =
  BaileysEx.send_message(connection, "1234567890@s.whatsapp.net", %{text: "Hello from Elixir"})

{:ok, latest_auth_state} = BaileysEx.auth_state(connection)
:ok = FilePersistence.save_credentials(auth_path, struct(State, latest_auth_state))

unsubscribe.()
:ok = BaileysEx.disconnect(connection)
```

## Public API

Top-level facade:

- `BaileysEx.connect/2`
- `BaileysEx.disconnect/1`
- `BaileysEx.subscribe/2`
- `BaileysEx.subscribe_raw/2`
- `BaileysEx.send_message/4`
- `BaileysEx.send_status/3`
- `BaileysEx.send_wam_buffer/2`
- `BaileysEx.request_pairing_code/3`
- `BaileysEx.download_media/2`
- `BaileysEx.download_media_to_file/3`

Major feature wrappers:

- Groups: `group_create/4`, `group_metadata/3`, `group_leave/2`
- Communities: `community_create/4`, `community_metadata/3`
- Presence: `send_presence_update/4`, `presence_subscribe/3`
- Profile: `profile_picture_url/4`, `update_profile_status/3`
- Privacy: `privacy_settings/2`
- Business: `update_business_profile/3`, `business_catalog/2`
- Newsletters: `newsletter_metadata/4`, `newsletter_follow/3`, `newsletter_unfollow/3`

Advanced callers can use:

- `BaileysEx.queryable/1` to obtain the `{socket_module, socket_pid}` transport tuple expected by lower-level feature modules
- `BaileysEx.event_emitter/1` to access the raw emitter
- `BaileysEx.signal_store/1` and `BaileysEx.auth_state/1` for persistence and runtime inspection
- `BaileysEx.WAM` to build ordered WAM analytics buffers before sending them

## Telemetry

BaileysEx emits telemetry under the `[:baileys_ex]` prefix.

Implemented event families:

- `[:baileys_ex, :connection, :start, :start | :stop | :exception]`
- `[:baileys_ex, :connection, :stop, :start | :stop | :exception]`
- `[:baileys_ex, :connection, :reconnect]`
- `[:baileys_ex, :message, :send, :start | :stop | :exception]`
- `[:baileys_ex, :message, :receive]`
- `[:baileys_ex, :media, :upload, :start | :stop | :exception]`
- `[:baileys_ex, :media, :download, :start | :stop | :exception]`
- `[:baileys_ex, :nif, :signal, :encrypt | :decrypt]`
- `[:baileys_ex, :nif, :noise, :encrypt | :decrypt]`

## Guides

- [Getting Started](guides/getting-started.md)
- [Authentication](guides/authentication.md)
- [Sending Messages](guides/sending-messages.md)
- [Receiving Messages](guides/receiving-messages.md)
- [Media](guides/media.md)
- [Groups and Communities](guides/groups.md)
- [Custom Persistence](guides/custom-persistence.md)

Legacy implementation notes remain under `user_docs/`.

## Example App

An end-to-end echo bot example is included at [`examples/echo_bot.exs`](examples/echo_bot.exs).

Show usage:

```bash
mix run examples/echo_bot.exs -- --help
```

## Development

```bash
mix format
mix compile
mix test
mix credo
mix dialyzer
mix docs
mix hex.build
```

## Reference

Baileys is the spec. The pinned upstream reference used for this port lives in `dev/reference/Baileys-master/`.

When BaileysEx behavior and a design instinct disagree, prefer Baileys.
