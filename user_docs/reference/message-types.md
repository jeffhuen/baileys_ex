# Message Types Reference

This page lists the content maps the public facade accepts for `BaileysEx.send_message/4`, plus the download helpers for inbound media.

## Text and reply content

### `%{text: binary()}`

- **Type:** `map()`
- **Default:** required for plain text
- **Example:**

```elixir
%{text: "Hello from Elixir"}
```

Sends a plain text message. Add `quoted:` or `mentions:` when you need reply context.

### `quoted: message`

- **Type:** `map()`
- **Default:** optional
- **Example:**

```elixir
%{text: "Replying", quoted: incoming}
```

Adds WhatsApp reply context from a previously received or sent message.

### `mentions: [jid]`

- **Type:** `list()`
- **Default:** `[]`
- **Example:**

```elixir
%{text: "Hi @team", mentions: ["15551234567@s.whatsapp.net"]}
```

Adds mentioned JIDs to a text message.

### `link_preview: %{...}`

- **Type:** `map()`
- **Default:** optional
- **Example:**

```elixir
%{
  text: "https://example.com",
  link_preview: %{title: "Example", description: "Preview body"}
}
```

Supplies preview metadata explicitly instead of relying on automatic detection.

## Media content

### `%{image: {:file, path} | {:binary, binary} | path}`

- **Type:** `map()`
- **Default:** optional
- **Example:**

```elixir
%{image: {:file, "priv/photos/launch.jpg"}, caption: "Launch"}
```

Sends an image. Common companion keys are `caption:` and `mimetype:`.

### `%{video: ...}`

- **Type:** `map()`
- **Default:** optional
- **Example:**

```elixir
%{video: {:file, "priv/video/demo.mp4"}, caption: "Demo", gif_playback: true}
```

Sends a video or GIF-style looping video.

### `%{audio: ...}`

- **Type:** `map()`
- **Default:** optional
- **Example:**

```elixir
%{audio: {:file, "priv/audio/note.ogg"}, ptt: true, mimetype: "audio/ogg"}
```

Sends audio. Add `ptt: true` for voice-note behavior.

### `%{document: ...}`

- **Type:** `map()`
- **Default:** optional
- **Example:**

```elixir
%{
  document: {:file, "priv/spec.pdf"},
  file_name: "spec.pdf",
  mimetype: "application/pdf",
  caption: "Current API spec"
}
```

Sends a document. `file_name:` controls the visible file name.

### `%{sticker: ...}`

- **Type:** `map()`
- **Default:** optional
- **Example:**

```elixir
%{sticker: {:file, "priv/stickers/launch.webp"}, is_animated: false}
```

Sends a sticker. The default mimetype is `image/webp`.

### Media input forms

- **Type:** `{:file, String.t()} | {:binary, binary()} | String.t()`
- **Default:** path strings must exist on disk
- **Example:**

```elixir
%{image: {:binary, File.read!("priv/photos/launch.jpg")}}
```

BaileysEx accepts a tagged file path, raw binary, or a direct file-system path string.

## Reactions, polls, and controls

### `%{react: %{key: key, text: emoji}}`

- **Type:** `map()`
- **Default:** optional
- **Example:**

```elixir
%{react: %{key: incoming.key, text: "🔥"}}
```

Reacts to an existing message.

### `%{poll: %{name: binary(), values: [binary()]}}`

- **Type:** `map()`
- **Default:** optional
- **Example:**

```elixir
%{poll: %{name: "Lunch?", values: ["Yes", "No"], selectable_count: 1}}
```

Creates a poll. `selectable_count:` controls how many answers can be selected.

### `%{delete: key}`

- **Type:** `map()`
- **Default:** optional
- **Example:**

```elixir
%{delete: incoming.key}
```

Revokes a previously sent message.

### `%{forward: message}`

- **Type:** `map()`
- **Default:** optional
- **Example:**

```elixir
%{forward: original_message}
```

Forwards an existing message.

### `%{disappearing_messages_in_chat: boolean() | integer()}`

- **Type:** `map()`
- **Default:** optional
- **Example:**

```elixir
%{disappearing_messages_in_chat: true}
```

Updates disappearing-message settings for the chat.

### `%{pin: %{key: key, type: :pin | :unpin, time: seconds}}`

- **Type:** `map()`
- **Default:** optional
- **Example:**

```elixir
%{pin: %{key: incoming.key, type: :pin, time: 86_400}}
```

Pins or unpins a message for the chat.

## Contacts, location, events, and replies

### `%{contacts: %{display_name: binary(), contacts: [contact]}}`

- **Type:** `map()`
- **Default:** optional
- **Example:**

```elixir
%{
  contacts: %{
    display_name: "Support",
    contacts: [%{display_name: "Support", vcard: "BEGIN:VCARD\nEND:VCARD"}]
  }
}
```

Sends one contact or a contact array.

### `%{location: %{latitude: float(), longitude: float()}}`

- **Type:** `map()`
- **Default:** optional
- **Example:**

```elixir
%{location: %{latitude: 37.78, longitude: -122.41, name: "HQ"}}
```

Sends a static location.

### `%{live_location: %{latitude: float(), longitude: float()}}`

- **Type:** `map()`
- **Default:** optional
- **Example:**

```elixir
%{live_location: %{latitude: 37.78, longitude: -122.41, sequence_number: 1}}
```

Sends a live-location payload.

### `%{group_invite: %{group_jid: jid, invite_code: binary()}}`

- **Type:** `map()`
- **Default:** optional
- **Example:**

```elixir
%{
  group_invite: %{
    group_jid: "120363001234567890@g.us",
    invite_code: "ABCD1234",
    group_name: "Launch Team"
  }
}
```

Sends a group invite message.

### `%{product: %{...}}`

- **Type:** `map()`
- **Default:** optional
- **Example:**

```elixir
%{
  product: %{
    product_id: "sku-1",
    title: "Sticker Pack",
    currency_code: "USD",
    price_amount_1000: 2_500_000,
    business_owner_jid: "15550001111@s.whatsapp.net"
  }
}
```

Sends a product share card.

### `%{button_reply: %{display_text: binary(), id: binary()}}`

- **Type:** `map()`
- **Default:** optional
- **Example:**

```elixir
%{button_reply: %{display_text: "Yes", id: "confirm"}}
```

Builds a reply payload for button-based interactions.

### `%{list_reply: %{title: binary(), row_id: binary()}}`

- **Type:** `map()`
- **Default:** optional
- **Example:**

```elixir
%{list_reply: %{title: "Standard", row_id: "standard"}}
```

Builds a reply payload for list-based interactions.

### `%{share_phone_number: true}` and `%{request_phone_number: true}`

- **Type:** `map()`
- **Default:** optional
- **Example:**

```elixir
%{request_phone_number: true}
```

Use these to request a phone number or share your own number.

### `%{event: %{name: binary(), start_time: DateTime.t() | integer()}}`

- **Type:** `map()`
- **Default:** optional
- **Example:**

```elixir
%{
  event: %{
    name: "Launch review",
    description: "Final check-in",
    start_time: DateTime.utc_now()
  }
}
```

Builds an event message, optionally with an embedded location.

### `%{edit: key, text: binary()}`

- **Type:** `map()`
- **Default:** optional
- **Example:**

```elixir
%{
  edit: %{id: "3EB0OLD", remote_jid: "15551234567@s.whatsapp.net", from_me: true},
  text: "Updated text"
}
```

Edits an existing text message.

### `%{view_once: true, ...}`

- **Type:** `map()`
- **Default:** optional
- **Example:**

```elixir
%{view_once: true, image: {:file, "priv/photos/launch.jpg"}}
```

Wraps the inner content in a view-once container.

## Inbound media download helpers

### `BaileysEx.download_media/2`

- **Type:** `map() -> {:ok, binary()} | {:error, term()}`
- **Default:** downloads to memory
- **Example:**

```elixir
{:ok, binary} = BaileysEx.download_media(image_message)
```

Use this when the media is small enough to keep in memory.

### `BaileysEx.download_media_to_file/3`

- **Type:** `map(), Path.t() -> {:ok, Path.t()} | {:error, term()}`
- **Default:** streams directly to disk
- **Example:**

```elixir
{:ok, path} = BaileysEx.download_media_to_file(image_message, "tmp/photo.jpg")
```

Use this when you want lower memory usage or a file on disk.
