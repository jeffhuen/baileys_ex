# Manage Authentication and Persistence

Use this guide when you need a session that survives restarts, or when you want to swap the default runtime key store for your own implementation.

## Choose a backend

- `BaileysEx.Auth.NativeFilePersistence.use_native_file_auth_state/1` is the
  recommended durable backend for Elixir-first applications.
- `BaileysEx.Auth.FilePersistence.use_multi_file_auth_state/1` keeps the
  Baileys-compatible JSON multi-file layout when you need that helper contract.
  Treat it as a compatibility bridge for migrations off a Baileys JS sidecar,
  not as the long-term default for Elixir apps.
- Custom SQL/NoSQL backends remain supported through
  `BaileysEx.Auth.Persistence` and a matching `BaileysEx.Signal.Store`
  implementation.

## Quick start

For most Elixir apps, load the durable native auth state before connecting,
wire in the built-in file-backed Signal store, then persist updates whenever
the runtime emits `:creds_update`.

```elixir
alias BaileysEx.Auth.NativeFilePersistence
alias BaileysEx.Connection.Transport.MintWebSocket

auth_path = "tmp/baileys_auth"
{:ok, persisted_auth} = NativeFilePersistence.use_native_file_auth_state(auth_path)

{:ok, connection} =
  BaileysEx.connect(
    persisted_auth.state,
    Keyword.merge(persisted_auth.connect_opts, [
      transport: {MintWebSocket, []},
      on_qr: &IO.puts("Scan QR: #{&1}")
    ])
  )

unsubscribe =
  BaileysEx.subscribe_raw(connection, fn events ->
    if Map.has_key?(events, :creds_update) do
      {:ok, latest_auth_state} = BaileysEx.auth_state(connection)
      :ok = persisted_auth.save_creds.(latest_auth_state)
    end
  end)
```

## Options

These options matter most for auth and runtime persistence:

- `BaileysEx.Auth.NativeFilePersistence.use_native_file_auth_state/1` gives you the recommended durable built-in file storage
- `BaileysEx.Auth.FilePersistence.use_multi_file_auth_state/1` mirrors Baileys' JSON helper path and returns the matching `connect/2` options for the built-in file-backed Signal store
- `BaileysEx.auth_state/1` returns the current auth-state snapshot from the running connection
- `signal_store_module:` replaces the default in-memory Signal key store when you are not using the built-in multi-file helper
- `signal_store_opts:` passes options to that Signal store module

→ See [Configuration Reference](../reference/configuration.md#connect2-options) for the connection options that affect persistence.

## Common patterns

### Reuse one auth directory across restarts

```elixir
auth_path = Path.expand("tmp/baileys_auth", File.cwd!())
{:ok, persisted_auth} =
  BaileysEx.Auth.NativeFilePersistence.use_native_file_auth_state(auth_path)
```

The same directory must be used for every restart of the same linked account.

### Keep the Baileys-compatible JSON helper

```elixir
auth_path = Path.expand("tmp/baileys_auth_json", File.cwd!())
{:ok, persisted_auth} = BaileysEx.Auth.FilePersistence.use_multi_file_auth_state(auth_path)
```

Use this helper when you need the Baileys-shaped JSON file layout on disk, for
example during compatibility testing or when mirroring an existing Baileys
multi-file auth directory. It exists to bridge migrations off Baileys JS
sidecars; new Elixir-first deployments should start on the native backend.

### Switch from compatibility JSON to the native backend

Backend switching is explicit. `connect/2` and the built-in helpers do not
migrate saved auth state automatically.

If you want to preserve the current linked session, migrate once into a new
native directory:

```elixir
source_path = Path.expand("tmp/baileys_auth_json", File.cwd!())
target_path = Path.expand("tmp/baileys_auth_native", File.cwd!())

{:ok, _summary} =
  BaileysEx.Auth.PersistenceMigration.migrate_compat_json_to_native(
    source_path,
    target_path
  )

{:ok, persisted_auth} =
  BaileysEx.Auth.NativeFilePersistence.use_native_file_auth_state(target_path)
```

If you do not need to preserve the current linked session, the simpler path is:

1. Log out or stop using the old auth directory.
2. Switch your app to `NativeFilePersistence.use_native_file_auth_state/1`.
3. Pair again and keep using that same native directory afterward.

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
That includes the explicit transaction-store contract introduced in Phase 16:
`transaction/3` must pass a transaction-scoped handle into the callback, and
transactional reads/writes must use that handle.

### Build your own auth persistence wrapper

```elixir
defmodule MyApp.BaileysAuth do
  alias BaileysEx.Auth.NativeFilePersistence

  def load!(path) do
    {:ok, state} = NativeFilePersistence.load_credentials(path)
    state
  end

  def persist!(connection, path) do
    {:ok, auth_state} = BaileysEx.auth_state(connection)
    :ok =
      NativeFilePersistence.save_credentials(
        path,
        struct(BaileysEx.Auth.State, auth_state)
      )
  end
end
```

This keeps the public connection lifecycle simple while you integrate persistence into your own supervision tree.

For fully custom SQL/NoSQL storage, keep the same `connect/2` lifecycle and
replace the built-in helper with your own `BaileysEx.Auth.Persistence` backend
plus a `signal_store_module` that reads and writes through it.

## Limitations

- The runtime updates auth state in memory automatically, but it does not write files for you. Persist `:creds_update` yourself.
- Both built-in helpers wire the built-in file-backed Signal store for you, but custom stores still need explicit `signal_store_module:` / `signal_store_opts:` overrides.
- If you change the auth directory, switch backends, or swap the Signal store without migrating the saved data, WhatsApp usually treats the next connection as a new device.
- Backend migration is explicit, not automatic. Preserve the current session with `BaileysEx.Auth.PersistenceMigration`, or re-pair on the new backend.

---

**See also:**
- [First Connection](../getting-started/first-connection.md)
- [Configuration Reference](../reference/configuration.md)
- [Troubleshooting: Authentication Issues](../troubleshooting/authentication-issues.md)
