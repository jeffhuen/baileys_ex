# Manage App State Sync

Use this guide when you need to drive WhatsApp's [app state sync](../glossary.md#app-state-sync-syncd) flow yourself. Most applications let the connection runtime do this automatically during initial history sync and when WhatsApp asks the client to resync cross-device state.

## Before you begin

- Use an authenticated connection that has already received its app-state sync keys.
- Reuse the same `query`, credential store, signal store, and event emitter from that running connection.

## Quick start

If you already have access to the query callback and stores from your connection runtime, you can force a resync of one or more collections with `BaileysEx.Feature.AppState.resync_app_state/4`.

```elixir
# `query`, `creds_store`, `signal_store`, and `event_emitter`
# come from your running connection runtime.

:ok =
  BaileysEx.Feature.AppState.resync_app_state(
    query,
    creds_store,
    [:regular_high, :regular_low],
    signal_store: signal_store,
    event_emitter: event_emitter,
    me: %{id: "15550001111@s.whatsapp.net", name: "Example"}
  )
```

This fetches the latest patches, verifies them against WhatsApp's [LTHash](../glossary.md#lthash), updates the stored Syncd version state, and emits the same chat, contact, label, and settings events the runtime uses.

## Options

These options matter most when you call the Syncd surface directly:

- `:signal_store` — stores app-state sync keys and collection version state. Use the same signal store your running connection uses.
- `:event_emitter` — receives emitted `:chats_update`, `:contacts_upsert`, `:settings_update`, and related Syncd events.
- `:me` — current account metadata used for events such as push-name updates.
- `:is_initial_sync` — marks the run as the first sync after history bootstrap so conditional chat updates behave like Baileys.

See the ExDoc page for `BaileysEx.Feature.AppState` for the full function-level reference.

## Common patterns

### Force a full resync of all collections

Use all five Baileys collections when you need to rebuild local app-state state from the server:

```elixir
:ok =
  BaileysEx.Feature.AppState.resync_app_state(
    query,
    creds_store,
    [:critical_block, :critical_unblock_low, :regular_high, :regular_low, :regular],
    signal_store: signal_store,
    event_emitter: event_emitter,
    me: me
  )
```

### Send one app-state patch

`app_patch/4` encodes the outgoing patch, sends it to WhatsApp, updates the stored collection version, and can emit the local event side effects for your own process:

```elixir
patch = %{
  type: :regular_high,
  index: ["mute", "15551234567@s.whatsapp.net"],
  sync_action: %BaileysEx.Protocol.Proto.Syncd.SyncActionValue{
    timestamp: 1_710_000_000,
    mute_action: %BaileysEx.Protocol.Proto.Syncd.MuteAction{
      muted: true,
      mute_end_timestamp: 1_710_086_400
    }
  },
  api_version: 2,
  operation: :set
}

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

### Build a patch without sending it

Use `build_patch/4` when you want the Baileys-compatible patch shape but a different transport path:

```elixir
patch =
  BaileysEx.Feature.AppState.build_patch(
    :pin,
    "15551234567@s.whatsapp.net",
    true,
    timestamp: 1_710_000_000
  )
```

## Limitations

- This is an advanced surface. It assumes you already have the same query callback, credential store, signal store, and event emitter your connection runtime uses.
- Collection sync keys must already be available in the signal store. If the runtime has not received the app-state key share yet, resync and patch calls return an error.
- Higher-level chat patch helpers can build Baileys-compatible patches, but they do not replace the runtime's automatic Syncd orchestration.

---

**See also:**
- [Glossary](../glossary.md) — terms used by the Syncd surface
- [Troubleshooting: App State Sync](../troubleshooting/app-state-sync-issues.md) — fix the most common runtime and verification failures
- `BaileysEx.Feature.AppState` — function-by-function API reference in ExDoc
