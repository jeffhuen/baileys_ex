# Troubleshooting: Encryption Issues

## `send_message/4` returns `{:error, :signal_repository_not_ready}`

**What you see:**
```elixir
{:error, :signal_repository_not_ready}
```

**Why this happens:** The connection was started without `:signal_repository` or
`:signal_repository_adapter`, so the runtime has no Signal repository for outbound
end-to-end encryption.

**Fix:**

Start `BaileysEx.connect/2` with either a prebuilt `signal_repository:` or a
`signal_repository_adapter:` plus `signal_repository_adapter_state:`. BaileysEx
does not attach a default adapter during connection startup.

---

## `send_message/4` returns `{:error, :invalid_jid}`

**What you see:**
```elixir
{:error, :invalid_jid}
```

**Why this happens:** The destination is not a valid WhatsApp [JID](../glossary.md#jid).

**Fix:**

```elixir
{:ok, _sent} =
  BaileysEx.send_message(connection, "15551234567@s.whatsapp.net", %{text: "Hello"})
```

User chats use `@s.whatsapp.net`, groups use `@g.us`, and newsletters use `@newsletter`.

---

## A lower-level Signal call returns `{:error, :invalid_signal_address}`

**What you see:**
```elixir
{:error, :invalid_signal_address}
```

**Why this happens:** The JID cannot be converted into a valid per-device Signal address.

**Fix:**

```elixir
{:ok, queryable} = BaileysEx.queryable(connection)
```

Use the public connection and message helpers unless you specifically need the lower-level Signal repository surface. If you do use it directly, pass full WhatsApp user JIDs instead of group JIDs or malformed addresses.

---

## A receive or decrypt path returns `{:error, :invalid_ciphertext}`

**What you see:**
```elixir
{:error, :invalid_ciphertext}
```

**Why this happens:** The local session state no longer matches WhatsApp's encryption state, or the restored auth and Signal data are from different sessions.

**Fix:**

```elixir
alias BaileysEx.Auth.FilePersistence

auth_path = Path.expand("tmp/baileys_auth", File.cwd!())
{:ok, auth_state} = FilePersistence.load_credentials(auth_path)
```

Make sure the same auth directory and Signal store are reused together. If the saved state is already corrupted or mixed between sessions, remove it and pair again.

---

## Media download fails with `{:error, :missing_media_key}` or `{:error, :missing_media_url}`

**What you see:**
```elixir
{:error, :missing_media_key}
```

or:

```elixir
{:error, :missing_media_url}
```

**Why this happens:** The message does not contain the encrypted media metadata required for download.

**Fix:**

```elixir
{:ok, path} = BaileysEx.download_media_to_file(image_message, "tmp/photo.jpg")
```

Only pass actual media messages that include a `media_key` and either `url` or `direct_path`.

---

**See also:**
- [Send and Download Media](../guides/media.md)
- [Manage Authentication and Persistence](../guides/authentication-and-persistence.md)
- [Troubleshooting: Connection Issues](connection-issues.md)
