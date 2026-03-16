# Event and Subscription Patterns

Use this guide when you need to react to incoming messages, connection changes, presence, or raw runtime events from one connection.

## Quick start

Subscribe to the normalized public event stream:

```elixir
unsubscribe =
  BaileysEx.subscribe(connection, fn
    {:message, message} -> IO.inspect(message, label: "incoming")
    {:connection, update} -> IO.inspect(update, label: "connection")
    {:presence, update} -> IO.inspect(update, label: "presence")
    {:call, payload} -> IO.inspect(payload, label: "call")
    {:event, name, payload} -> IO.inspect({name, payload}, label: "other")
  end)
```

## Options

You have two main subscription surfaces:

- `BaileysEx.subscribe/2` normalizes the most common events into tuples
- `BaileysEx.subscribe_raw/2` gives you the buffered raw event map exactly as the runtime emits it
- `BaileysEx.connect/2` also accepts `:on_connection`, `:on_qr`, `:on_message`, and `:on_event` callbacks for simple scripts

→ See [Event Catalog Reference](../reference/event-catalog.md) for the full event list and the normalized tuple mapping.

## Common patterns

### Persist credentials when they change

```elixir
alias BaileysEx.Auth.FilePersistence
alias BaileysEx.Auth.State

auth_path = "tmp/baileys_auth"

unsubscribe =
  BaileysEx.subscribe_raw(connection, fn events ->
    if Map.has_key?(events, :creds_update) do
      {:ok, auth_state} = BaileysEx.auth_state(connection)
      :ok = FilePersistence.save_credentials(auth_path, struct(State, auth_state))
    end
  end)
```

### Offload work from the event emitter

```elixir
unsubscribe =
  BaileysEx.subscribe(connection, fn
    {:message, message} ->
      Task.start(fn -> MyBot.handle_message(connection, message) end)

    _other ->
      :ok
  end)
```

### Watch the raw buffered event map

```elixir
unsubscribe =
  BaileysEx.subscribe_raw(connection, fn events ->
    IO.inspect(events, label: "raw events")
  end)
```

## Limitations

- `BaileysEx.subscribe/2` only normalizes connection, message, presence, and call events. Everything else comes through as `{:event, name, payload}`.
- Subscription handlers run in the emitter process. Long-running work blocks later deliveries.
- Raw deliveries can contain multiple event keys in one map because the runtime buffers some update bursts before flushing.

---

**See also:**
- [Send Your First Message](../getting-started/sending-your-first-message.md)
- [Event Catalog Reference](../reference/event-catalog.md)
- [Troubleshooting: Authentication Issues](../troubleshooting/authentication-issues.md)
