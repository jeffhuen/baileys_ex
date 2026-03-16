# Use Advanced Features

Use this guide when you need surface area beyond text messages and basic groups: [communities](../glossary.md#community), newsletters, business helpers, [app state sync](../glossary.md#app-state-sync-syncd), or [WAM](../glossary.md#wam) buffers.

## Quick start

Fetch newsletter metadata from the top-level facade:

```elixir
{:ok, metadata} =
  BaileysEx.newsletter_metadata(connection, :jid, "120363400000000000@newsletter")
```

## Options

The public facade covers the common entry points:

- communities: `BaileysEx.community_create/4` and `BaileysEx.community_metadata/3`
- newsletters: `BaileysEx.newsletter_metadata/4`, `newsletter_follow/3`, and `newsletter_unfollow/3`
- business: `BaileysEx.business_catalog/2` and `update_business_profile/3`
- WAM: `BaileysEx.WAM` plus `BaileysEx.send_wam_buffer/2`

When you need the full surface, call the feature modules directly with `BaileysEx.queryable/1`.

→ See [Configuration Reference](../reference/configuration.md#connect2-options) if you need runtime hooks such as custom history sync helpers.

## Common patterns

### Create and inspect a community

```elixir
{:ok, community} =
  BaileysEx.community_create(connection, "Support Hub", "Company-wide support")

{:ok, metadata} = BaileysEx.community_metadata(connection, community.id)
```

### Follow a newsletter

```elixir
{:ok, _result} =
  BaileysEx.newsletter_follow(connection, "120363400000000000@newsletter")
```

### Update business profile data

```elixir
{:ok, _node} =
  BaileysEx.update_business_profile(connection, %{
    description: "Open weekdays",
    email: "support@example.com"
  })
```

### Build and send a WAM buffer

```elixir
wam =
  BaileysEx.WAM.new()
  |> BaileysEx.WAM.put_event(:WebcFingerprint, [{"sessionId", "demo"}])

{:ok, _node} = BaileysEx.send_wam_buffer(connection, wam)
```

### Drop down to the full feature module

```elixir
{:ok, queryable} = BaileysEx.queryable(connection)
{:ok, linked} = BaileysEx.Feature.Community.fetch_linked_groups(queryable, "120363001234567890@g.us")
```

## Limitations

- The top-level facade only exposes the most common advanced helpers. Full community, newsletter, business, and app-state operations live in their public feature modules.
- App-state sync is an advanced surface that assumes you reuse the running connection's credential store, Signal store, and event emitter.
- WAM encoding exists for Baileys parity. It is not a general analytics system for your application.

---

**See also:**
- [Work with Groups and Communities](groups.md)
- [Manage App State Sync](manage-app-state-sync.md)
- [Troubleshooting: App State Sync](../troubleshooting/app-state-sync-issues.md)
