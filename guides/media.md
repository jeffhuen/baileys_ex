# Media

## Download to memory

```elixir
{:ok, binary} = BaileysEx.download_media(image_message)
```

## Download to a file

```elixir
{:ok, path} = BaileysEx.download_media_to_file(image_message, "tmp/photo.jpg")
```

The streamed file path avoids buffering the full payload in memory first.

## Send media

```elixir
{:ok, _sent} =
  BaileysEx.send_message(connection, "1234567890@s.whatsapp.net", %{
    document: {:file, "priv/spec.pdf"},
    file_name: "spec.pdf",
    mimetype: "application/pdf"
  })
```

## Telemetry

Media operations emit:

- `[:baileys_ex, :media, :upload, :start | :stop | :exception]`
- `[:baileys_ex, :media, :download, :start | :stop | :exception]`
