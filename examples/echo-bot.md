# Echo Bot Example

This example shows the smallest runnable bot in the repository. It opens a real WhatsApp connection with `BaileysEx.Connection.Transport.MintWebSocket`, persists credentials, and echoes inbound text messages back to the sender.

## Run the example

```bash
mix run examples/echo_bot.exs -- --auth-path tmp/echo_bot_auth
```

On the first run, scan the QR code or use phone pairing. On later runs, the saved credentials in `tmp/echo_bot_auth` are reused.

## What it demonstrates

- loading and saving auth state with `BaileysEx.Auth.FilePersistence`
- starting a real connection with `BaileysEx.connect/2`
- subscribing to `:creds_update` and incoming messages
- replying with `BaileysEx.send_message/4`

## Source

The runnable script lives at [`examples/echo_bot.exs`](echo_bot.exs).

---

**See also:**
- [First Connection](../user_docs/getting-started/first-connection.md)
- [Send Your First Message](../user_docs/getting-started/sending-your-first-message.md)
