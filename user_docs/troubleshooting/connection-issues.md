# Troubleshooting: Connection Issues

## `BaileysEx.connect/2` returns `{:error, :transport_not_configured}`

**What you see:**
```elixir
{:error, :transport_not_configured}
```

**Why this happens:** `BaileysEx.connect/2` does not open a real network connection unless you pass an explicit transport.

**Fix:**

```elixir
{:ok, connection} =
  BaileysEx.connect(auth_state,
    transport: {BaileysEx.Connection.Transport.MintWebSocket, []}
  )
```

---

## `request_pairing_code/3`, `send_message/4`, or other runtime calls return `{:error, :not_connected}`

**What you see:**
```elixir
{:error, :not_connected}
```

**Why this happens:** The socket is not open yet, or the previous session has already closed.

**Fix:**

```elixir
receive do
  {:connection_update, %{connection: :open}} -> :ok
end
```

Wait for the open connection update before you request a pairing code or send a message.

---

## A query returns `{:error, :timeout}`

**What you see:**
```elixir
{:error, :timeout}
```

**Why this happens:** The runtime did not receive a response before the configured query timeout expired.

**Fix:**

```elixir
config = BaileysEx.Connection.Config.new(default_query_timeout_ms: 120_000)

{:ok, connection} =
  BaileysEx.connect(auth_state,
    transport: {BaileysEx.Connection.Transport.MintWebSocket, []},
    config: config
  )
```

Increase the timeout only after you confirm the transport and session are otherwise healthy.

---

## The connection opens, then closes again during startup

**What you see:**
```
The runtime reaches the QR or opening stage, then closes and reconnects.
```

**Why this happens:** The auth state is stale, the network path is unstable, or the previous linked session was replaced.

**Fix:**

```elixir
unsubscribe =
  BaileysEx.subscribe(connection, fn
    {:connection, update} -> IO.inspect(update, label: "connection")
    _other -> :ok
  end)
```

Inspect the connection updates first. If the session was replaced or logged out, remove the stale auth directory and pair again.

---

**See also:**
- [First Connection](../getting-started/first-connection.md)
- [Configuration Reference](../reference/configuration.md)
- [Troubleshooting: Authentication Issues](authentication-issues.md)
