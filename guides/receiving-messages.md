# Receiving Messages

## Friendly event stream

```elixir
unsubscribe =
  BaileysEx.subscribe(connection, fn
    {:message, message} -> IO.inspect(message, label: "incoming")
    {:connection, update} -> IO.inspect(update, label: "connection")
    {:event, name, payload} -> IO.inspect({name, payload})
    _other -> :ok
  end)
```

`subscribe/2` flattens common events into stable tuples:

- `{:message, message}`
- `{:connection, update}`
- `{:presence, update}`
- `{:call, payload}`

Everything else is passed through as `{:event, name, payload}`.

## Raw event stream

```elixir
unsubscribe =
  BaileysEx.subscribe_raw(connection, fn events ->
    IO.inspect(events, label: "raw_events")
  end)
```

Raw subscription mirrors the buffered event maps emitted by the internal runtime.

## Common inbound message fields

Incoming messages follow the normalized Baileys shape:

- `message.key.remote_jid`
- `message.key.from_me`
- `message.message`
- `message.message_timestamp`

## Cleanup

```elixir
unsubscribe.()
```
