# Troubleshooting: Authentication Issues

## I have to scan a QR code again after every restart

**What you see:**
```
The first run pairs successfully, but the next restart asks for a new QR code.
```

**Why this happens:** The runtime updated credentials in memory, but your application never persisted the `:creds_update` events.

**Fix:**

```elixir
alias BaileysEx.Auth.NativeFilePersistence

{:ok, persisted_auth} =
  NativeFilePersistence.use_native_file_auth_state("tmp/baileys_auth")

unsubscribe =
  BaileysEx.subscribe_raw(connection, fn events ->
    if Map.has_key?(events, :creds_update) do
      {:ok, auth_state} = BaileysEx.auth_state(connection)
      :ok = persisted_auth.save_creds.(auth_state)
    end
  end)
```

Reuse that same auth path on every restart.

If you are intentionally using the Baileys-compatible JSON helper, the same
subscription pattern applies with
`BaileysEx.Auth.FilePersistence.use_multi_file_auth_state/1`.

---

## `request_pairing_code/3` returns `{:error, :not_connected}`

**What you see:**
```elixir
{:error, :not_connected}
```

**Why this happens:** Phone pairing codes can only be requested after the socket is open.

**Fix:**

```elixir
receive do
  {:connection_update, %{connection: :open}} -> :ok
end

{:ok, code} = BaileysEx.request_pairing_code(connection, "15551234567")
```

Use digits only for the phone number.

---

## The session works once, then behaves like a different device

**What you see:**
```
Message state, history sync, or encryption state no longer matches the previous session.
```

**Why this happens:** The auth directory, persistence backend, or Signal store
changed between restarts, so WhatsApp sees a different local device state.

**Fix:**

```elixir
auth_path = Path.expand("tmp/baileys_auth", File.cwd!())
{:ok, persisted_auth} =
  BaileysEx.Auth.NativeFilePersistence.use_native_file_auth_state(auth_path)
```

Keep the same auth path and the same persisted-auth helper configuration for the
lifetime of one linked device.

If you are moving from the compatibility JSON backend to the native backend,
migration is explicit, not automatic. Preserve the current session by migrating
once:

```elixir
{:ok, _summary} =
  BaileysEx.Auth.PersistenceMigration.migrate_compat_json_to_native(
    "tmp/baileys_auth_json",
    "tmp/baileys_auth_native"
  )
```

If you do not need to preserve the current linked session, the simpler path is
to remove the old auth directory, switch to
`BaileysEx.Auth.NativeFilePersistence.use_native_file_auth_state/1`, and pair
again.

---

**See also:**
- [Manage Authentication and Persistence](../guides/authentication-and-persistence.md)
- [First Connection](../getting-started/first-connection.md)
- [Troubleshooting: Encryption Issues](encryption-issues.md)
