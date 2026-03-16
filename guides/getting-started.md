# Getting Started

BaileysEx runs a per-connection supervisor that owns the socket, event emitter, runtime store, Signal state, and coordinator.

## 1. Load auth state

```elixir
alias BaileysEx.Auth.FilePersistence

auth_path = "tmp/baileys_auth"
{:ok, auth_state} = FilePersistence.load_credentials(auth_path)
```

`load_credentials/1` creates a fresh `BaileysEx.Auth.State` when no credential file exists yet.

## 2. Connect

```elixir
{:ok, connection} =
  BaileysEx.connect(auth_state,
    on_qr: fn qr -> IO.puts("Scan QR: #{qr}") end,
    on_connection: fn update -> IO.inspect(update, label: "connection") end
  )
```

The callback options are convenience wrappers around the event emitter:

- `:on_qr`
- `:on_connection`
- `:on_message`
- `:on_event`

## 3. Subscribe to events

```elixir
unsubscribe =
  BaileysEx.subscribe(connection, fn
    {:message, message} -> IO.inspect(message, label: "incoming")
    {:connection, update} -> IO.inspect(update, label: "connection")
    {:event, name, payload} -> IO.inspect({name, payload})
    _other -> :ok
  end)
```

Use `subscribe_raw/2` if you want the buffered Baileys-style event maps directly.

## 4. Send a message

```elixir
{:ok, sent} =
  BaileysEx.send_message(connection, "1234567890@s.whatsapp.net", %{text: "hello"})

IO.inspect(sent.id, label: "message_id")
```

## 5. Persist updated credentials

```elixir
alias BaileysEx.Auth.FilePersistence
alias BaileysEx.Auth.State

{:ok, latest_auth_state} = BaileysEx.auth_state(connection)
:ok = FilePersistence.save_credentials(auth_path, struct(State, latest_auth_state))
```

Persist after any `:creds_update` event if you want the connection to survive restarts cleanly.

## 6. Disconnect

```elixir
unsubscribe.()
:ok = BaileysEx.disconnect(connection)
```
