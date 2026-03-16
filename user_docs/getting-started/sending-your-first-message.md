# Send Your First Message

You will finish this page with a text message sent from a live BaileysEx connection.

## Before you begin

- Your connection reaches WhatsApp successfully
- Your session is already paired
- You know the recipient [JID](../glossary.md#jid)
- Your connection was started with `:signal_repository` or `:signal_repository_adapter`

## Steps

### 1. Send a text message

Call `BaileysEx.send_message/4` with a user JID and a content map.

BaileysEx does not attach a default Signal repository adapter during `connect/2`, so
outbound sends only work after you configure one of those connection options.

```elixir
{:ok, sent} =
  BaileysEx.send_message(connection, "15551234567@s.whatsapp.net", %{text: "Hello from Elixir"})
```

The return value includes the generated message id, destination JID, encoded message, and timestamp.

### 2. Subscribe to incoming messages

Use `BaileysEx.subscribe/2` if you want a simple message loop.

```elixir
unsubscribe =
  BaileysEx.subscribe(connection, fn
    {:message, message} -> IO.inspect(message, label: "incoming")
    {:connection, update} -> IO.inspect(update, label: "connection")
    _other -> :ok
  end)
```

This is the simplest way to build bots and automations on top of the public facade.

### 3. Reply to a received message

Use the incoming message key to reply in the same chat.

```elixir
{:message, incoming} = receive do
  event -> event
end

{:ok, _reply} =
  BaileysEx.send_message(connection, incoming.key.remote_jid, %{
    text: "I received your message",
    quoted: incoming
  })
```

Quoted replies use the original message metadata so WhatsApp renders the reply thread correctly.

## Check that it worked

You should see a result like `%{id: "3EB0..."}` from `send_message/4`, and the recipient should receive the message in WhatsApp.

---

**Next steps:**
- [Messages](../guides/messages.md) — send reactions, polls, forwards, and other non-media payloads
- [Media](../guides/media.md) — upload and download images, audio, documents, and stickers
