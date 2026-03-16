# Troubleshooting: App State Sync

## I get `{:error, :app_state_key_not_present}` or `{:error, {:key_not_found, ...}}`

**What you see:**
```elixir
{:error, :app_state_key_not_present}
```

or:

```elixir
{:error, {:key_not_found, "..."}}
```

**Why this happens:** Your runtime has not stored the app-state sync key yet, or the call is using a different signal store than the running connection.

**Fix:**

```elixir
:ok =
  BaileysEx.Feature.AppState.resync_app_state(
    query,
    creds_store,
    [:regular_high],
    signal_store: signal_store,
    event_emitter: event_emitter
  )
```

Retry only after the running connection has finished initial sync and persisted the app-state sync key into the same `signal_store`.

---

## I get `{:error, :invalid_snapshot_mac}` or `{:error, :invalid_patch_mac}`

**What you see:**
```elixir
{:error, :invalid_snapshot_mac}
```

or:

```elixir
{:error, :invalid_patch_mac}
```

**Why this happens:** The local Syncd state no longer matches WhatsApp's state, or the wrong key/version state is being used for verification.

**Fix:**

```elixir
:ok =
  BaileysEx.Feature.AppState.resync_app_state(
    query,
    creds_store,
    [:critical_block, :critical_unblock_low, :regular_high, :regular_low, :regular],
    signal_store: signal_store,
    event_emitter: event_emitter
  )
```

Use the same `signal_store` and credential store as the running connection. A full resync rebuilds the stored app-state version and [LTHash](../glossary.md#lthash) from the server.

---

## The call succeeds, but my app does not receive chat or contact updates

**What you see:**
```
The resync or patch call returns :ok, but no update events reach your process.
```

**Why this happens:** The Syncd runtime emits through the connection's event emitter. If you do not pass the same `event_emitter`, the runtime updates local state but your application never sees the emitted events.

**Fix:**

```elixir
:ok =
  BaileysEx.Feature.AppState.app_patch(
    query,
    creds_store,
    patch,
    signal_store: signal_store,
    event_emitter: event_emitter,
    me: me
  )
```

Pass the same `event_emitter` your connection runtime already uses when you want normal `:chats_update`, `:contacts_upsert`, `:labels_edit`, or settings events.

---

**See also:**
- [Manage App State Sync](../guides/manage-app-state-sync.md) — advanced Syncd workflow and examples
- [Glossary](../glossary.md) — definitions for Syncd and LTHash
