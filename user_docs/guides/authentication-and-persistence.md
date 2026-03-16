# Manage Authentication and Persistence

Use this guide when you need a session that survives restarts, or when you want to swap the default runtime key store for your own implementation.

## Quick start

Load the saved auth state before connecting, then persist updates whenever the runtime emits `:creds_update`.

```elixir
alias BaileysEx.Auth.FilePersistence
alias BaileysEx.Auth.State
alias BaileysEx.Connection.Transport.MintWebSocket

auth_path = "tmp/baileys_auth"
{:ok, auth_state} = FilePersistence.load_credentials(auth_path)

{:ok, connection} =
  BaileysEx.connect(auth_state,
    transport: {MintWebSocket, []},
    on_qr: &IO.puts("Scan QR: #{&1}")
  )

unsubscribe =
  BaileysEx.subscribe_raw(connection, fn events ->
    if Map.has_key?(events, :creds_update) do
      {:ok, latest_auth_state} = BaileysEx.auth_state(connection)
      :ok = FilePersistence.save_credentials(auth_path, struct(State, latest_auth_state))
    end
  end)
```

## Options

These options matter most for auth and runtime persistence:

- `BaileysEx.Auth.FilePersistence` gives you the default multi-file auth storage
- `BaileysEx.auth_state/1` returns the current auth-state snapshot from the running connection
- `signal_store_module:` replaces the default in-memory Signal key store
- `signal_store_opts:` passes options to that Signal store module

→ See [Configuration Reference](../reference/configuration.md#connect2-options) for the connection options that affect persistence.

## Common patterns

### Reuse one auth directory across restarts

```elixir
auth_path = Path.expand("tmp/baileys_auth", File.cwd!())
{:ok, auth_state} = BaileysEx.Auth.FilePersistence.load_credentials(auth_path)
```

The same directory must be used for every restart of the same linked account.

### Replace the default Signal key store

```elixir
{:ok, connection} =
  BaileysEx.connect(auth_state,
    transport: {BaileysEx.Connection.Transport.MintWebSocket, []},
    signal_store_module: MyApp.BaileysSignalStore,
    signal_store_opts: [table: :baileys_signal_store]
  )
```

Your custom module needs to implement the `BaileysEx.Signal.Store` behaviour.

### Build your own auth persistence wrapper

```elixir
defmodule MyApp.BaileysAuth do
  def load!(path) do
    {:ok, state} = BaileysEx.Auth.FilePersistence.load_credentials(path)
    state
  end

  def persist!(connection, path) do
    {:ok, auth_state} = BaileysEx.auth_state(connection)
    :ok = BaileysEx.Auth.FilePersistence.save_credentials(path, struct(BaileysEx.Auth.State, auth_state))
  end
end
```

This keeps the public connection lifecycle simple while you integrate persistence into your own supervision tree.

## Limitations

- The runtime updates auth state in memory automatically, but it does not write files for you. Persist `:creds_update` yourself.
- `BaileysEx.Auth.FilePersistence` covers auth credentials and key datasets on disk. A custom `signal_store_module:` is a separate runtime concern.
- If you change the auth directory or Signal store without migrating the saved data, WhatsApp usually treats the next connection as a new device.

---

**See also:**
- [First Connection](../getting-started/first-connection.md)
- [Configuration Reference](../reference/configuration.md)
- [Troubleshooting: Authentication Issues](../troubleshooting/authentication-issues.md)
