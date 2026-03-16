# Groups and Communities

## Groups

Create a group:

```elixir
{:ok, metadata} =
  BaileysEx.group_create(connection, "Team Chat", [
    "15551234567@s.whatsapp.net",
    "15557654321@s.whatsapp.net"
  ])
```

Fetch metadata:

```elixir
{:ok, metadata} = BaileysEx.group_metadata(connection, "120363001234567890@g.us")
```

Leave a group:

```elixir
:ok = BaileysEx.group_leave(connection, "120363001234567890@g.us")
```

## Communities

Create a community:

```elixir
{:ok, metadata} =
  BaileysEx.community_create(connection, "Engineering", "Internal engineering community")
```

Fetch community metadata:

```elixir
{:ok, metadata} = BaileysEx.community_metadata(connection, "120363001234567890@g.us")
```

## Presence helpers

```elixir
:ok = BaileysEx.send_presence_update(connection, :available)
:ok = BaileysEx.presence_subscribe(connection, "15551234567@s.whatsapp.net")
```
