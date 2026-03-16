# Sending Messages

## Text messages

```elixir
{:ok, sent} =
  BaileysEx.send_message(connection, "1234567890@s.whatsapp.net", %{text: "Hello"})
```

The result includes:

- `id`
- `jid`
- `message`
- `timestamp`

## Media messages

BaileysEx uses the same media preparation pipeline as the lower-level message builder.

```elixir
{:ok, sent} =
  BaileysEx.send_message(connection, "1234567890@s.whatsapp.net", %{
    image: {:file, "priv/example.jpg"},
    caption: "An image"
  })
```

## Status broadcast

```elixir
{:ok, sent} = BaileysEx.send_status(connection, %{text: "status update"})
```

## JIDs

`send_message/4` accepts either:

- a JID string such as `"1234567890@s.whatsapp.net"`
- a `%BaileysEx.JID{}` struct

Invalid JID input returns `{:error, :invalid_jid}`.

## Runtime note

Use the public facade for sending. It routes through the connection coordinator so Signal repository state stays synchronized after each relay.
