# Send Messages

Use this guide when you want to send anything that is not primarily a media upload: text, quoted replies, reactions, polls, forwards, and control messages.

## Quick start

Send a plain text message with `BaileysEx.send_message/4`.

```elixir
{:ok, _sent} =
  BaileysEx.send_message(connection, "15551234567@s.whatsapp.net", %{text: "Hello from BaileysEx"})
```

## Options

These options matter most for everyday message sending:

- `quoted:` reply to a previous message in the same chat
- `mentions:` mention one or more user JIDs in a text message
- `link_preview:` supply preview metadata yourself for a URL
- `message_id_fun:` override message-id generation when you need deterministic ids in tests

→ See [Message Types Reference](../reference/message-types.md) for the complete payload catalog.

## Common patterns

### Send a quoted reply

```elixir
{:ok, _sent} =
  BaileysEx.send_message(connection, incoming.key.remote_jid, %{
    text: "Replying to your message",
    quoted: incoming
  })
```

### Edit a previously sent text message

```elixir
{:ok, _sent} =
  BaileysEx.send_message(connection, "15551234567@s.whatsapp.net", %{
    edit: %{id: "3EB0OLD", remote_jid: "15551234567@s.whatsapp.net", from_me: true},
    text: "Updated text"
  })
```

### React to a message

```elixir
{:ok, _sent} =
  BaileysEx.send_message(connection, incoming.key.remote_jid, %{
    react: %{key: incoming.key, text: "👍"}
  })
```

### Create a poll

```elixir
{:ok, _sent} =
  BaileysEx.send_message(connection, "15551234567@s.whatsapp.net", %{
    poll: %{name: "Lunch?", values: ["Yes", "No"], selectable_count: 1}
  })
```

### Forward or revoke a message

```elixir
{:ok, _forwarded} =
  BaileysEx.send_message(connection, "15551234567@s.whatsapp.net", %{forward: original_message})

{:ok, _revoked} =
  BaileysEx.send_message(connection, "15551234567@s.whatsapp.net", %{delete: original_message.key})
```

## Limitations

- The public facade sends message payloads that `BaileysEx.Message.Builder` supports today. It does not add a second abstraction layer over the builder.
- Outbound interactive templates are not covered by the top-level facade. The currently supported reply payloads are listed in the message-types reference.
- If you pass an invalid JID, `BaileysEx.send_message/4` returns `{:error, :invalid_jid}`.

---

**See also:**
- [Media](media.md) — send uploaded files and download inbound media
- [Event and Subscription Patterns](events-and-subscriptions.md) — react to incoming messages cleanly
- [Troubleshooting: Encryption Issues](../troubleshooting/encryption-issues.md)
