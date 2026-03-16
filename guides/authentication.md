# Authentication

BaileysEx follows Baileys' auth model: load an auth state, connect, pair, then persist updates.

## File-based persistence

The default path uses the same multi-file approach as Baileys' `useMultiFileAuthState`.

```elixir
alias BaileysEx.Auth.FilePersistence

auth_path = "tmp/baileys_auth"

{:ok, auth_state} = FilePersistence.load_credentials(auth_path)
{:ok, connection} = BaileysEx.connect(auth_state)
```

Persist updates after `:creds_update`:

```elixir
alias BaileysEx.Auth.FilePersistence
alias BaileysEx.Auth.State

{:ok, latest_auth_state} = BaileysEx.auth_state(connection)
:ok = FilePersistence.save_credentials(auth_path, struct(State, latest_auth_state))
```

## QR pairing

Listen to `:on_qr` or the `{:connection, %{qr: qr}}` event from `subscribe/2`.

```elixir
{:ok, connection} =
  BaileysEx.connect(auth_state, on_qr: fn qr -> IO.puts("Scan QR: #{qr}") end)
```

## Phone-number pairing

```elixir
{:ok, code} = BaileysEx.request_pairing_code(connection, "15551234567")
IO.puts("Pairing code: #{code}")
```

This uses the active socket session, so call it after the connection runtime has started.

## Inspecting runtime state

For advanced flows:

- `BaileysEx.auth_state/1` returns the current auth snapshot from the runtime store
- `BaileysEx.signal_store/1` returns the wrapped Signal store
- `BaileysEx.subscribe_raw/2` exposes raw `:creds_update` payloads
