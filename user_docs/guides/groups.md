# Work with Groups and Communities

Use this guide when you need to create groups, inspect group metadata, leave groups, or move into the advanced group and community helper modules.

## Quick start

Create a group from the top-level facade.

```elixir
{:ok, group} =
  BaileysEx.group_create(connection, "Launch Team", [
    "15551234567@s.whatsapp.net",
    "15557654321@s.whatsapp.net"
  ])
```

## Options

The facade methods are intentionally small:

- `BaileysEx.group_create/4` accepts a subject, participant JIDs, and optional builder/query options
- `BaileysEx.group_metadata/3` fetches the current group snapshot
- `BaileysEx.group_leave/2` leaves a group immediately

→ See `BaileysEx.Feature.Group` and `BaileysEx.Feature.Community` for the complete advanced API surface.

## Common patterns

### Fetch group metadata

```elixir
{:ok, metadata} = BaileysEx.group_metadata(connection, "120363001234567890@g.us")
```

### Leave a group

```elixir
:ok = BaileysEx.group_leave(connection, "120363001234567890@g.us")
```

### Create or inspect a community

```elixir
{:ok, community} = BaileysEx.community_create(connection, "Support Hub", "Company-wide support")
{:ok, metadata} = BaileysEx.community_metadata(connection, community.id)
```

### Use advanced participant and invite helpers

When you need participant management, invite codes, subgroup links, or join-approval flows, call the public feature modules directly with the queryable socket:

```elixir
{:ok, queryable} = BaileysEx.queryable(connection)
{:ok, invite_code} = BaileysEx.Feature.Group.invite_code(queryable, "120363001234567890@g.us")
```

## Limitations

- The top-level facade covers the common group lifecycle only. Advanced group and community operations live in `BaileysEx.Feature.Group` and `BaileysEx.Feature.Community`.
- All participant and community APIs expect full WhatsApp JIDs.
- Group and community changes emit runtime events only if you keep the connection event subscriptions active.

---

**See also:**
- [Advanced Features](advanced-features.md) — newsletters, business helpers, communities, app state sync, and WAM
- [Event and Subscription Patterns](events-and-subscriptions.md)
- [Troubleshooting: Connection Issues](../troubleshooting/connection-issues.md)
