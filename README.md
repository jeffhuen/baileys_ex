# BaileysEx

Behavior-accurate Elixir port of [Baileys 7.00rc9](https://github.com/WhiskeySockets/Baileys), the WhatsApp Web API library.

BaileysEx follows the Baileys wire protocol and feature surface closely while exposing an Elixir-first runtime: supervisors, ETS-backed stores, explicit transports, and typed public modules.

## Installation

Prerequisites:

- Elixir 1.19+
- OTP 28
- Rust toolchain available on the machine that runs `mix compile`

```elixir
def deps do
  [
    {:baileys_ex, "~> 0.1.0-alpha.1"}
  ]
end
```

This package is currently published as an alpha prerelease, so the prerelease
version must be requested explicitly.

## Quick Start

```elixir
alias BaileysEx.Auth.FilePersistence
alias BaileysEx.Connection.Transport.MintWebSocket

auth_path = "tmp/baileys_auth"
parent = self()

{:ok, persisted_auth} = FilePersistence.use_multi_file_auth_state(auth_path)

{:ok, connection} =
  BaileysEx.connect(
    persisted_auth.state,
    Keyword.merge(persisted_auth.connect_opts, [
      transport: {MintWebSocket, []},
      on_qr: fn qr -> IO.puts("Scan QR: #{qr}") end,
      on_connection: fn update ->
        IO.inspect(update, label: "connection")
        send(parent, {:connection_update, update})
      end
    ])
  )

_unsubscribe =
  BaileysEx.subscribe_raw(connection, fn events ->
    if Map.has_key?(events, :creds_update) do
      {:ok, latest_auth_state} = BaileysEx.auth_state(connection)
      :ok = persisted_auth.save_creds.(latest_auth_state)
    end
  end)

receive do
  {:connection_update, %{connection: :open}} -> :ok
after
  30_000 -> raise "connection did not open"
end

unsubscribe =
  BaileysEx.subscribe(connection, fn
    {:message, message} -> IO.inspect(message, label: "incoming")
    {:connection, update} -> IO.inspect(update, label: "connection")
    _other -> :ok
  end)

unsubscribe.()
:ok = BaileysEx.disconnect(connection)
```

Outbound `send_message/4` and `send_status/3` use the built-in production Signal
adapter by default when the auth state includes `signed_identity_key`,
`signed_pre_key`, and `registration_id`. Use `:signal_repository` or
`:signal_repository_adapter` only when you need to override that default.

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
- `BaileysEx.update_media_message/3`

Major feature wrappers:

- Chat/App State: archive, mute, pin, star, read, clear, delete, delete-for-me, and link-preview privacy wrappers
- Groups: create, metadata, leave, participant/admin updates, invite flows, join approval, and settings wrappers
- Communities: create, metadata, subgroup/link management, invite flows, join approval, and settings wrappers
- Presence: `send_presence_update/4`, `presence_subscribe/3`
- Profile & Queries: picture/status helpers plus `on_whatsapp/3`, `fetch_status/3`, `business_profile/3`, and profile mutation wrappers
- Privacy: privacy settings, blocklist, and the current privacy mutation/query surface
- Calls: `reject_call/4`, `create_call_link/4`
- Business: business profile, catalog, cover photo, collections, product, and order wrappers
- Newsletters: metadata, follow/unfollow, create/update/delete, mute/react, fetch, and owner-management wrappers

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

- [Installation](user_docs/getting-started/installation.md)
- [First Connection](user_docs/getting-started/first-connection.md)
- [Send Your First Message](user_docs/getting-started/sending-your-first-message.md)
- [Messages](user_docs/guides/messages.md)
- [Media](user_docs/guides/media.md)
- [Groups and Communities](user_docs/guides/groups.md)
- [Presence](user_docs/guides/presence.md)
- [Events and Subscriptions](user_docs/guides/events-and-subscriptions.md)
- [Authentication and Persistence](user_docs/guides/authentication-and-persistence.md)
- [Advanced Features](user_docs/guides/advanced-features.md)
- [Manage App State Sync](user_docs/guides/manage-app-state-sync.md)

## Example App

An end-to-end echo bot example is included at [`examples/echo_bot.exs`](examples/echo_bot.exs) with a companion docs page at [`examples/echo-bot.md`](examples/echo-bot.md).

Show usage:

```bash
mix run examples/echo_bot.exs -- --help
```

## Reference

Baileys is the spec. BaileysEx tracks the Baileys `7.00rc9` behavior surface as its upstream reference.

When BaileysEx behavior and a design instinct disagree, prefer Baileys.
