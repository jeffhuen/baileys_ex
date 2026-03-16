# Troubleshooting: Authentication Issues

## I have to scan a QR code again after every restart

**What you see:**
```
The first run pairs successfully, but the next restart asks for a new QR code.
```

**Why this happens:** The runtime updated credentials in memory, but your application never persisted the `:creds_update` events.

**Fix:**

```elixir
alias BaileysEx.Auth.FilePersistence
alias BaileysEx.Auth.State

unsubscribe =
  BaileysEx.subscribe_raw(connection, fn events ->
    if Map.has_key?(events, :creds_update) do
      {:ok, auth_state} = BaileysEx.auth_state(connection)
      :ok = FilePersistence.save_credentials("tmp/baileys_auth", struct(State, auth_state))
    end
  end)
```

Reuse that same auth path on every restart.

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

**Why this happens:** The auth directory or Signal store changed between restarts, so WhatsApp sees a different local device state.

**Fix:**

```elixir
auth_path = Path.expand("tmp/baileys_auth", File.cwd!())
{:ok, auth_state} = BaileysEx.Auth.FilePersistence.load_credentials(auth_path)
```

Keep the same auth path and the same `signal_store_module:` configuration for the lifetime of one linked device.

---

**See also:**
- [Manage Authentication and Persistence](../guides/authentication-and-persistence.md)
- [First Connection](../getting-started/first-connection.md)
- [Troubleshooting: Encryption Issues](encryption-issues.md)
