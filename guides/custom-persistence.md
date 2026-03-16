# Custom Persistence

BaileysEx keeps runtime state in process-local stores, but you can persist auth updates wherever you want.

## Auth persistence behaviour

The built-in file persistence module implements:

```elixir
@behaviour BaileysEx.Auth.Persistence
```

Implement the same callbacks if you want S3, Postgres, or another custom store:

- `load_credentials/0`
- `save_credentials/1`
- `load_keys/2`
- `save_keys/3`
- `delete_keys/2`

## Saving runtime auth state

The public facade exposes the current auth snapshot:

```elixir
{:ok, auth_state} = BaileysEx.auth_state(connection)
```

Persist it after `:creds_update`:

```elixir
unsubscribe =
  BaileysEx.subscribe_raw(connection, fn events ->
    if Map.has_key?(events, :creds_update) do
      {:ok, auth_state} = BaileysEx.auth_state(connection)
      persist_somewhere(auth_state)
    end
  end)
```

## Signal store access

When you need direct access to the wrapped Signal store:

```elixir
{:ok, signal_store} = BaileysEx.signal_store(connection)
```

That handle can be passed into lower-level feature functions that accept `:signal_store` options.
