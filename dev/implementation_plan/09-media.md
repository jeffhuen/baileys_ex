# Phase 9: Media

**Goal:** Media encryption/decryption, upload to WhatsApp CDN, streaming download,
integration with message builder.

**Depends on:** Phase 2 (Crypto NIF), Phase 8 (Messaging)
**Parallel with:** Phase 10 (Features)

---

## Design Decisions

**Streaming, never buffer entire file in memory.**
Use `Stream` and `Req` streaming for upload/download. Encrypt/decrypt in chunks.
This matches Baileys' approach and handles large media (videos, documents).

**Crypto pipeline in a single NIF call for performance.**
Media encryption involves HKDF expand → AES-CBC encrypt → HMAC. For large files,
doing this per-chunk across the NIF boundary is wasteful. Provide a streaming NIF
that processes chunks without returning to Elixir between steps.

**`Req` for HTTP.**
Modern, composable HTTP client built on Mint/Finch. Supports streaming requests
and responses natively.

---

## Tasks

### 9.1 Media crypto

File: `lib/baileys_ex/media/crypto.ex`

```elixir
defmodule BaileysEx.Media.Crypto do
  @doc """
  Encrypt media for upload using single-pass streaming (GAP-46).

  Streams the input through AES-CBC while simultaneously computing
  sha256_plain, sha256_enc, and MAC — avoiding loading large files into memory.
  Returns %{encrypted: iodata, media_key, file_sha256, file_enc_sha256, file_length}.
  """
  def encrypt(input, media_type) do
    media_key = BaileysEx.Crypto.random_bytes(32)
    %{iv: iv, cipher_key: cipher_key, mac_key: mac_key} =
      BaileysEx.Crypto.expand_media_key(media_key, media_type)

    # Initialize crypto state for single-pass streaming
    crypto_state = :crypto.crypto_init(:aes_256_cbc, cipher_key, iv, encrypt: true)
    plain_hash_state = :crypto.hash_init(:sha256)
    enc_hash_state = :crypto.hash_init(:sha256)
    mac_state = :crypto.mac_init(:hmac, :sha256, mac_key)

    # Include IV in MAC computation
    mac_state = :crypto.mac_update(mac_state, iv)

    # Stream chunks through all operations simultaneously
    {encrypted_chunks, file_length, plain_hash_state, enc_hash_state, mac_state} =
      input
      |> to_stream()
      |> Enum.reduce({[], 0, plain_hash_state, enc_hash_state, mac_state},
        fn chunk, {acc, len, ph, eh, ms} ->
          # Hash plaintext
          ph = :crypto.hash_update(ph, chunk)
          # Encrypt
          encrypted = :crypto.crypto_update(crypto_state, chunk)
          # Hash + MAC ciphertext
          eh = :crypto.hash_update(eh, encrypted)
          ms = :crypto.mac_update(ms, encrypted)
          {[encrypted | acc], len + byte_size(chunk), ph, eh, ms}
        end)

    # Finalize: PKCS7 padding
    final_block = :crypto.crypto_final(crypto_state)
    enc_hash_state = :crypto.hash_update(enc_hash_state, final_block)
    mac_state = :crypto.mac_update(mac_state, final_block)

    encrypted_data = IO.iodata_to_binary(Enum.reverse([final_block | encrypted_chunks]))
    mac = :crypto.mac_final(mac_state) |> binary_part(0, 10)
    enc_with_mac = encrypted_data <> mac

    %{
      encrypted: enc_with_mac,
      media_key: media_key,
      file_sha256: :crypto.hash_final(plain_hash_state),
      file_enc_sha256: :crypto.hash_update(enc_hash_state, mac) |> :crypto.hash_final(),
      file_length: file_length
    }
  end

  defp to_stream(binary) when is_binary(binary) do
    # Chunk binary into 64KB pieces for streaming
    Stream.unfold(binary, fn
      <<>> -> nil
      <<chunk::binary-size(65_536), rest::binary>> -> {chunk, rest}
      remaining -> {remaining, <<>>}
    end)
  end

  defp to_stream(%File.Stream{} = stream), do: stream
  defp to_stream(stream) when is_function(stream) or is_struct(stream, Stream), do: stream

  @doc "Decrypt downloaded media"
  def decrypt(encrypted_data, media_key, media_type) do
    %{iv: iv, cipher_key: cipher_key, mac_key: mac_key} =
      BaileysEx.Crypto.expand_media_key(media_key, media_type)

    # Split ciphertext and MAC
    mac_size = 10
    ciphertext_size = byte_size(encrypted_data) - mac_size
    <<ciphertext::binary-size(ciphertext_size), mac::binary-size(mac_size)>> = encrypted_data

    # Verify MAC
    computed_mac = compute_mac(iv, ciphertext, mac_key)
    unless binary_part(computed_mac, 0, 10) == mac do
      {:error, :mac_mismatch}
    end

    # Decrypt
    BaileysEx.Crypto.aes_cbc_decrypt(cipher_key, iv, ciphertext)
  end

  defp compute_mac(iv, ciphertext, mac_key) do
    BaileysEx.Crypto.hmac_sha256(mac_key, iv <> ciphertext)
  end
end
```

### 9.2 Media upload

File: `lib/baileys_ex/media/upload.ex`

```elixir
defmodule BaileysEx.Media.Upload do
  @doc "Upload encrypted media to WhatsApp CDN"
  def upload(conn, encrypted_data, media_type, opts \\ []) do
    # 1. Request upload URL from WhatsApp server
    {:ok, upload_info} = request_upload_url(conn, media_type, byte_size(encrypted_data))

    # 2. Upload via HTTP POST
    {:ok, response} = Req.post(upload_info.url,
      body: encrypted_data,
      headers: upload_headers(upload_info)
    )

    # 3. Parse response for direct_path and media URL
    {:ok, parse_upload_response(response)}
  end

  defp request_upload_url(conn, media_type, file_size) do
    node = build_media_upload_node(media_type, file_size)
    Connection.Socket.send_node_and_wait(conn, node)
  end
end
```

### 9.3 Media download

File: `lib/baileys_ex/media/download.ex`

```elixir
defmodule BaileysEx.Media.Download do
  @doc "Download and decrypt media from a received message"
  def download(media_message, opts \\ []) do
    url = media_url(media_message)
    media_key = media_message.media_key
    media_type = media_type_from_message(media_message)

    with {:ok, encrypted_data} <- fetch_media(url),
         {:ok, decrypted} <- Media.Crypto.decrypt(encrypted_data, media_key, media_type) do
      {:ok, decrypted}
    end
  end

  @doc "Download media to a file path (streaming)"
  def download_to_file(media_message, path, opts \\ []) do
    url = media_url(media_message)

    Req.get(url,
      into: File.stream!(path, [:write]),
      # Decrypt after download completes
      decode_body: false
    )
    # Then decrypt the file in place or to a new path
  end

  defp fetch_media(url) do
    case Req.get(url) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:http_error, status}}
      {:error, reason} -> {:error, reason}
    end
  end
end
```

### 9.4 Media types

File: `lib/baileys_ex/media/types.ex`

```elixir
defmodule BaileysEx.Media.Types do
  @media_types %{
    image: %{mime_prefix: "image/", hkdf_info: "WhatsApp Image Keys", proto_field: :image_message},
    video: %{mime_prefix: "video/", hkdf_info: "WhatsApp Video Keys", proto_field: :video_message},
    audio: %{mime_prefix: "audio/", hkdf_info: "WhatsApp Audio Keys", proto_field: :audio_message},
    document: %{mime_prefix: "application/", hkdf_info: "WhatsApp Document Keys", proto_field: :document_message},
    sticker: %{mime_prefix: "image/webp", hkdf_info: "WhatsApp Image Keys", proto_field: :sticker_message}
  }

  def get(type), do: Map.fetch!(@media_types, type)
  def from_mime(mime), do: ...
end
```

### 9.5 Thumbnail and waveform generation

File: `lib/baileys_ex/media/thumbnail.ex`

Thumbnail and audio waveform generation for media messages. These are optional
but expected for a complete WhatsApp experience.

```elixir
defmodule BaileysEx.Media.Thumbnail do
  @moduledoc """
  Generate thumbnails for images/videos and waveforms for audio.
  Uses optional dependencies — gracefully degrades if not available.
  """

  @doc "Generate JPEG thumbnail from image (default 32x32)"
  def image_thumbnail(image_data, opts \\ []) do
    # Options: width (default 32), height (default 32)
    # Uses `image` hex package if available, otherwise returns nil
  end

  @doc "Generate thumbnail from video frame"
  def video_thumbnail(video_path, opts \\ []) do
    # Uses System.cmd("ffmpeg", ...) if available
    # Extracts frame at opts[:time] || "00:00:01"
  end

  @doc "Generate audio waveform visualization (64 samples)"
  def audio_waveform(audio_data) do
    # Decode audio, sample 64 points for visualization
    # Returns list of 64 integers (0-100 amplitude values)
  end

  @doc "Extract image dimensions from binary data"
  def image_dimensions(image_data) do
    # Parse JPEG/PNG/WebP header for width/height
    # Returns {width, height} or nil
  end
end
```

### 9.5a Media Re-upload Flow (GAP-47)

File: `lib/baileys_ex/media/retry.ex`

When media download returns HTTP 404/410 (expired), the client sends a
`mediaretry` notification encrypted with HKDF-derived keys. The server
responds with a `messages.media-update` event containing refreshed media.

```elixir
defmodule BaileysEx.Media.Retry do
  @moduledoc """
  Media re-upload request flow for expired media.
  Reference: Baileys messages-media.ts L637-679
  """

  @doc "Request media re-upload for an expired message"
  def request_reupload(conn, message_key, opts \\ []) do
    # 1. Generate retry receipt with HKDF keys
    media_key = BaileysEx.Crypto.random_bytes(32)
    expanded = BaileysEx.Crypto.hkdf_expand(media_key, "messages_media_retry", 80)
    <<iv::binary-16, cipher_key::binary-32, mac_key::binary-32>> = expanded

    # 2. Encrypt retry request
    retry_data = Proto.ServerErrorReceipt.encode(%Proto.ServerErrorReceipt{
      stanza_id: message_key.id
    })
    encrypted = BaileysEx.Crypto.aes_cbc_encrypt(cipher_key, iv, retry_data)

    # 3. Send via IQ
    node = %BinaryNode{
      tag: "iq",
      attrs: %{
        "to" => message_key.remote_jid,
        "type" => "set",
        "xmlns" => "urn:xmpp:whatsapp:m"
      },
      content: [
        %BinaryNode{
          tag: "media_retry",
          attrs: %{
            "id" => message_key.id,
            "participant" => message_key.participant
          },
          content: encrypted
        }
      ]
    }
    Connection.Socket.send_node(conn, node)
  end
end
```

### 9.6 Media connection and retry

File: extends `lib/baileys_ex/media/upload.ex`

```elixir
  @doc "Refresh media connection credentials (cached, force-refreshable)"
  def refresh_media_conn(conn, force \\ false) do
    # IQ: xmlns='w:m', type='set', content: <media_conn/>
    # Cache auth tokens, refresh on expiry or force
  end

  @doc "Retry media upload for failed messages"
  def update_media_message(conn, message) do
    # Re-encrypt and re-upload media
    # Update message with new URL/directPath
    # Emit :messages_media_update event
  end
```

### 9.7 Integrate with message builder

Extend `Message.Builder` to handle media messages:

```elixir
def build(%{image: {:file, path}, caption: caption}, conn) do
  file_data = File.read!(path)
  mime = MIME.type(Path.extname(path))

  encrypted = Media.Crypto.encrypt(file_data, :image)
  {:ok, upload_result} = Media.Upload.upload(conn, encrypted.encrypted, :image)

  %Proto.Message{
    image_message: %Proto.ImageMessage{
      url: upload_result.url,
      direct_path: upload_result.direct_path,
      media_key: encrypted.media_key,
      file_sha256: encrypted.file_sha256,
      file_enc_sha256: encrypted.file_enc_sha256,
      file_length: byte_size(file_data),
      mimetype: mime,
      caption: caption
    }
  }
end
```

### 9.8 Tests

- Media encrypt/decrypt roundtrip for each media type
- HKDF key expansion matches Baileys test vectors
- MAC verification catches tampered data
- Upload node construction
- Download with mock HTTP server
- Integration: encrypt → upload → download → decrypt roundtrip

---

## Acceptance Criteria

- [ ] Media encrypt/decrypt roundtrip for all types
- [ ] MAC verification works (pass and fail cases)
- [ ] Upload constructs correct HTTP request
- [ ] Download handles streaming
- [ ] Message builder integrates media handling
- [ ] Cross-validation with Baileys-encrypted media
- [ ] Image thumbnails generated when `image` package available
- [ ] Video thumbnails via ffmpeg when available
- [ ] Audio waveform computed (64 samples)
- [ ] Media connection refreshed and cached
- [ ] Media upload retry works for failed messages
- [ ] Media encryption uses single-pass streaming for large files (GAP-46)
- [ ] Media re-upload request sent for expired media (GAP-47)

## Files Created/Modified

- `lib/baileys_ex/media/crypto.ex`
- `lib/baileys_ex/media/upload.ex`
- `lib/baileys_ex/media/download.ex`
- `lib/baileys_ex/media/types.ex`
- `lib/baileys_ex/message/builder.ex` (extend)
- `test/baileys_ex/media/crypto_test.exs`
- `test/baileys_ex/media/upload_test.exs`
- `test/baileys_ex/media/download_test.exs`
- `lib/baileys_ex/media/thumbnail.ex`
- `lib/baileys_ex/media/retry.ex`
