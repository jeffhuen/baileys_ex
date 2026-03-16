# Send Presence Updates

Use this guide when you want to show that your account is online, offline, composing, or recording, or when you want to subscribe to another chat's presence feed.

## Quick start

Mark the current account as available:

```elixir
:ok = BaileysEx.send_presence_update(connection, :available)
```

## Options

These options matter most for presence work:

- `to_jid` sends a chatstate update such as `:composing`, `:recording`, or `:paused` to one chat
- `me_id:` sets the sender JID for phone-number chats when you send a chatstate update
- `me_lid:` sets the sender JID for LID-addressed chats when you send a chatstate update
- `name:` sets the account name for `:available` and `:unavailable` updates when you call the lower-level helper directly

→ See [Event Catalog Reference](../reference/event-catalog.md) for the emitted `:presence_update` payload.

## Common patterns

### Mark the account online or offline

```elixir
:ok = BaileysEx.send_presence_update(connection, :available)
:ok = BaileysEx.send_presence_update(connection, :unavailable)
```

### Show typing in one chat

```elixir
:ok =
  BaileysEx.send_presence_update(
    connection,
    :composing,
    "15551234567@s.whatsapp.net",
    me_id: "15550001111@s.whatsapp.net"
  )
```

### Subscribe to another chat's presence feed

```elixir
:ok = BaileysEx.presence_subscribe(connection, "15551234567@s.whatsapp.net")
```

### Handle incoming presence updates

```elixir
unsubscribe =
  BaileysEx.subscribe(connection, fn
    {:presence, update} -> IO.inspect(update, label: "presence")
    _other -> :ok
  end)
```

## Limitations

- Chatstate updates such as `:composing` and `:recording` need `me_id:` or `me_lid:` so BaileysEx can build the correct sender JID.
- Presence subscriptions depend on what WhatsApp shares for that chat. Some contacts and groups expose limited presence information.
- Subscription handlers run inside the connection event emitter. Keep them short and move heavier work into a `Task` or your own GenServer.

---

**See also:**
- [Event and Subscription Patterns](events-and-subscriptions.md)
- [Configuration Reference](../reference/configuration.md#connect2-options)
- [Troubleshooting: Connection Issues](../troubleshooting/connection-issues.md)
