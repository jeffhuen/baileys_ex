# First Connection

You will finish this page with a live BaileysEx connection that can pair by QR code or phone pairing code.

## Before you begin

- BaileysEx compiles successfully in your project
- You chose an auth-state directory
- Your machine can reach `web.whatsapp.com`
- You have your phone nearby for pairing

## Steps

### 1. Load or create auth state

For most Elixir apps, load the saved auth state from the durable native backend
and reuse the matching file-backed Signal store options on every connection
attempt.

```elixir
alias BaileysEx.Auth.NativeFilePersistence

auth_path = "tmp/baileys_auth"
{:ok, persisted_auth} = NativeFilePersistence.use_native_file_auth_state(auth_path)
```

If the directory is empty, `use_native_file_auth_state/1` returns a fresh state
for a new pairing flow and the `connect/2` options needed to persist Signal
keys in the same directory.

If you need the Baileys-compatible JSON multi-file layout instead, use
`BaileysEx.Auth.FilePersistence.use_multi_file_auth_state/1` with the same
connection flow.

Switching between those backends later is not automatic. If you move an
existing linked device from compatibility JSON to the native backend, either
migrate the saved auth directory once or re-pair on the native backend.

### 2. Start the connection with a real transport

Use `BaileysEx.connect/2` with `BaileysEx.Connection.Transport.MintWebSocket`.

```elixir
alias BaileysEx.Connection.Transport.MintWebSocket

parent = self()

{:ok, connection} =
  BaileysEx.connect(
    persisted_auth.state,
    Keyword.merge(persisted_auth.connect_opts, [
      transport: {MintWebSocket, []},
      on_qr: fn qr -> IO.puts("Scan QR: #{qr}") end,
      on_connection: fn update -> send(parent, {:connection_update, update}) end
    ])
  )
```

The `:on_qr` callback gives you QR data for a new login. The `:on_connection` callback tells you when the socket opens or closes.

### 3. Persist updated credentials before pairing

Save credentials whenever the connection emits a `:creds_update` event.

```elixir
unsubscribe =
  BaileysEx.subscribe_raw(connection, fn events ->
    if Map.has_key?(events, :creds_update) do
      {:ok, latest_auth_state} = BaileysEx.auth_state(connection)
      :ok = persisted_auth.save_creds.(latest_auth_state)
    end
  end)
```

Attach this subscriber before you scan the QR or request a phone pairing code. Pair success emits the first credential update immediately.

### 4. Pair the session

For QR pairing, scan the QR from WhatsApp on your phone.

For phone pairing, request a code after the connection starts:

```elixir
{:ok, code} = BaileysEx.request_pairing_code(connection, "15551234567")
IO.puts("Enter this code in WhatsApp: #{code}")
```

Use only digits for the phone number. Do not include `+` or spaces.

## Check that it worked

Wait for a connection update like this:

```elixir
receive do
  {:connection_update, %{connection: :open}} -> :ok
end
```

You should also see new credential data written to your auth directory after pairing succeeds.

---

**Next steps:**
- [Send Your First Message](sending-your-first-message.md) — send a real text message through the paired connection
- [Authentication and Persistence](../guides/authentication-and-persistence.md) — wire auth saving and custom key storage cleanly
