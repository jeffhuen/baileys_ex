# Send and Download Media

Use this guide when you need to upload or download images, video, audio, documents, or stickers.

## Quick start

Send a file by passing a media field to `BaileysEx.send_message/4`.

All outbound send examples on this page assume the connection was started with
`connect/2` with the default Signal credentials in auth state, or override the
repository explicitly with `:signal_repository` or `:signal_repository_adapter`.

```elixir
{:ok, _sent} =
  BaileysEx.send_message(connection, "15551234567@s.whatsapp.net", %{
    image: {:file, "priv/photos/launch.jpg"},
    caption: "Launch photo"
  })
```

## Options

These keys are the ones you will use most often:

- `caption:` add text to images, video, and documents
- `mimetype:` override MIME detection when the file extension is not enough
- `file_name:` set the visible document name
- `ptt:` mark audio as a voice note
- `gif_playback:` send a video as a GIF-style looping clip

→ See [Message Types Reference](../reference/message-types.md#media-content) for the complete media payload shapes.

## Common patterns

### Send a document

```elixir
{:ok, _sent} =
  BaileysEx.send_message(connection, "15551234567@s.whatsapp.net", %{
    document: {:file, "priv/spec.pdf"},
    file_name: "spec.pdf",
    mimetype: "application/pdf",
    caption: "Current API spec"
  })
```

### Send a voice note

```elixir
{:ok, _sent} =
  BaileysEx.send_message(connection, "15551234567@s.whatsapp.net", %{
    audio: {:file, "priv/audio/note.ogg"},
    ptt: true,
    mimetype: "audio/ogg"
  })
```

### Download media into memory

```elixir
{:ok, binary} = BaileysEx.download_media(image_message)
```

### Download media directly to disk

```elixir
{:ok, path} = BaileysEx.download_media_to_file(image_message, "tmp/photo.jpg")
```

The file-based download path keeps memory use lower for larger payloads.

### Refresh stale media URLs before download

If a media message has an expired `url` or `direct_path`, ask the paired device to
refresh it first:

```elixir
{:ok, refreshed} = BaileysEx.update_media_message(connection, incoming)
{:ok, binary} = BaileysEx.download_media(refreshed.message.image_message)
```

On success, BaileysEx also emits a `messages_update` event with the refreshed
message payload, matching Baileys' observable behavior.

## Limitations

- Media sending requires a live connection because BaileysEx uploads encrypted blobs before it relays the message.
- Media sending also requires the default Signal credentials in auth state, or an explicit `:signal_repository` / `:signal_repository_adapter` override.
- `download_media/2` and `download_media_to_file/3` need a valid media message with `url` or `direct_path` and a `media_key`.
- `update_media_message/3` requires the original `WebMessageInfo` for the media message, not only the nested media struct.
- Thumbnail generation depends on the available thumbnail helpers for the selected media type.

---

**See also:**
- [Send Messages](messages.md) — combine media with quoted replies and other message features
- [Message Types Reference](../reference/message-types.md)
- [Troubleshooting: Connection Issues](../troubleshooting/connection-issues.md)
