# Phase 9: Media

**Goal:** Media encryption/decryption, upload to WhatsApp CDN, streaming download,
integration with message builder.

**Depends on:** Phase 2 (Crypto), Phase 8 (Messaging)
**Parallel with:** Phase 10 (Features)

**Baileys reference:**
- `src/Utils/messages-media.ts` — `getMediaKeys`, `encryptedStream`, `downloadContentFromMessage`, `downloadEncryptedContent`, `getRawMediaUploadData`, `getWAUploadToServer`, `encryptMediaRetryRequest`, `decryptMediaRetryData`, `getAudioDuration`, `getAudioWaveform`, `extractImageThumb`, `generateThumbnail`, `generateProfilePicture`, `hkdfInfoKey`
- `src/Defaults/index.ts` — `MEDIA_PATH_MAP` (10 media type → CDN path mappings), `MEDIA_HKDF_KEY_MAPPING` (19 media type → HKDF info string mappings)

---

## Design Decisions

**Streaming, never buffer entire file in memory.**
Use `Stream` and `Req` streaming for upload/download. Encrypt/decrypt in chunks.
This matches Baileys' approach and handles large media (videos, documents).

**Single-pass streaming in Elixir/OTP first.**
Media encryption still involves HKDF expand → AES-CBC encrypt → HMAC, but the
current architecture should keep that streaming pipeline in Elixir/`:crypto`
unless profiling proves a native boundary is necessary. The goal is one pass
over the data, not a gratuitous media-specific NIF.

**`Req` for HTTP.**
Modern, composable HTTP client built on Mint/Finch. Supports streaming requests
and responses natively.

## Current Branch Status

Phase 9 is now complete on `phase-09-media`.

The completed media runtime now covers the full Phase 9 scope:
- WAProto media message structs now include the core upload/download metadata
  fields used by rc.9 (`url`, `direct_path`, `media_key`, hashes, length, and
  type-specific fields like thumbnails/waveform/background color).
- `BaileysEx.Media.Types` now mirrors the current Baileys media-path and HKDF
  mapping tables.
- `BaileysEx.Media.Crypto` implements single-pass encrypt-to-tempfile and media
  decrypt with MAC verification.
- `BaileysEx.Media.Upload` implements `w:m` `media_conn` lookup and CDN upload.
- `BaileysEx.Media.Download` implements media URL resolution, streaming decrypt
  to a file, and Baileys-style aligned ranged downloads.
- `BaileysEx.Media.Thumbnail` provides image/video thumbnails, sticker
  dimensions, and 64-sample push-to-talk waveforms with explicit missing-tool
  errors.
- `BaileysEx.Media.Retry` implements the rc.9 expired-media re-upload flow:
  `server-error` receipt construction, encrypted retry payloads, retry
  notification decoding, and decrypted media-update application.
- `BaileysEx.Media.Upload` now caches `media_conn` in the connection store,
  force-refreshes on invalid responses, and retries across upload hosts instead
  of collapsing on the first failure.
- `BaileysEx.Media.MessageBuilder` now handles sender-side media preparation
  before `BaileysEx.Message.Builder`: encrypt, upload, derive thumbnails or
  waveforms, and populate the media proto metadata expected by the relay path.
- The phase now includes committed Baileys rc.9 media cross-validation fixtures
  in `test/fixtures/media/baileys_v7.json`.

The streamed download path intentionally mirrors Baileys rc.9 by decrypting
aligned AES-CBC chunks without validating the trailing 10-byte media MAC. Full
payload verification remains available through `BaileysEx.Media.Crypto.decrypt/3`.

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
    Connection.Socket.query(conn, node)
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
runtime features, but the public API reports missing tooling explicitly instead
of silently returning `nil`.

```elixir
defmodule BaileysEx.Media.Thumbnail do
  @moduledoc """
  Generate thumbnails for images/videos and waveforms for audio.
  Uses optional runtime tooling and returns explicit dependency errors when
  tooling is unavailable.
  """

  @doc "Generate JPEG thumbnail from image data (default width 32)"
  def image_thumbnail(image_data, opts \\ []) do
    # Uses the optional `Image` package when available
    # Returns %{jpeg_thumbnail, width, height} on success
    # Returns {:error, {:missing_dependency, :image}} when unavailable
  end

  @doc "Generate thumbnail from video frame"
  def video_thumbnail(video_path, opts \\ []) do
    # Uses ffmpeg when available
    # Extracts frame at opts[:time] || "00:00:01"
    # Returns {:error, {:missing_dependency, :ffmpeg}} when unavailable
  end

  @doc "Generate audio waveform visualization (64 samples as a binary)"
  def audio_waveform(audio_data) do
    # Uses ffmpeg to decode mono PCM and normalizes to 64 0..100 samples
  end

  @doc "Extract image dimensions from binary data"
  def image_dimensions(image_data) do
    # Parses JPEG/PNG/WebP headers for width/height
  end
end
```

### 9.5a Media Re-upload Flow (GAP-47)

File: `lib/baileys_ex/media/retry.ex`

When media download returns HTTP 404/410 (expired), the client sends a
Baileys-style `server-error` receipt with an encrypted retry payload. The
paired device responds through a `mediaretry` notification that becomes a
`messages_media_update` event and can be decrypted back into a refreshed
`direct_path`.

```elixir
defmodule BaileysEx.Media.Retry do
  @doc "Build or send the rc.9 `server-error` receipt requesting re-upload"
  def request_reupload(socket, message_key, media_key, opts \\ []) do
    # Derive the retry key using `WhatsApp Media Retry Notification`
    # Encrypt a `ServerErrorReceipt` protobuf with AES-256-GCM (AAD = stanza id)
    # Emit a receipt node containing <encrypt><enc_p/><enc_iv/></encrypt> and <rmr/>
    # via `BaileysEx.Connection.Socket.send_node/2`
  end

  @doc "Decode a mediaretry notification into the event payload emitted upstream"
  def decode_notification_event(node) do
    # Extract the `rmr` message key and either `encrypt` bytes or `error` attrs
  end

  @doc "Decrypt and apply the refreshed direct path to a media message"
  def apply_media_update(message, media_key, event) do
    # Decrypt `MediaRetryNotification`, require `SUCCESS`, then replace
    # `direct_path` and `url` on the relevant media proto struct
  end
end
```

### 9.6 Media connection and retry

File: extends `lib/baileys_ex/media/upload.ex`

```elixir
  @doc "Refresh media connection credentials (cached, force-refreshable)"
  def refresh_media_conn(queryable, opts \\ []) do
    # Query `xmlns='w:m'` for `<media_conn/>`
    # Reuse a cached store-backed record until TTL expiry unless `force: true`
    # Persist refreshed records under `:media_conn`
  end

  @doc "Upload encrypted media with host retry and invalid-response refresh"
  def upload(queryable, encrypted_path, media_type, opts \\ []) do
    # Try each returned upload host in order
    # Force-refresh `media_conn` if a successful response omits both `url` and
    # `direct_path`, then continue with the remaining hosts
  end
```

### 9.7 Integrate with message builder

The media pipeline now lives one layer earlier than the original draft:
`BaileysEx.Media.MessageBuilder` prepares sender-side media before the existing
message builder constructs the proto structs.

```elixir
def send(context, jid, content, opts \\ []) when is_map(content) do
  media_opts =
    opts
    |> Keyword.put_new_lazy(:media_queryable, fn -> context[:query_fun] || context[:socket] end)
    |> Keyword.put_new(:store_ref, context[:store_ref])

  with {:ok, prepared_content} <- BaileysEx.Media.MessageBuilder.prepare(content, media_opts),
       %Proto.Message{} = proto_message <- BaileysEx.Message.Builder.build(prepared_content, opts) do
    send_proto(context, jid, proto_message, opts)
  end
end
```

### 9.8 Tests

- Media encrypt/decrypt roundtrip for each media type
- HKDF key expansion matches Baileys test vectors
- MAC verification catches tampered data
- Upload node construction
- Download with mock HTTP server and aligned range requests
- Integration: encrypt → upload → download → decrypt roundtrip
- Committed cross-validation against a Baileys rc.9 media fixture generated from
  the local reference algorithm and bridge-backed HKDF expansion

---

## Acceptance Criteria

- [x] Media encrypt/decrypt roundtrip for all core media message types
- [x] MAC verification works (pass and fail cases)
- [x] Upload constructs correct HTTP request
- [x] Download handles streaming
- [x] Message builder integrates media handling
- [x] Cross-validation with Baileys-encrypted media
- [x] Image thumbnails generated when `image` package available
- [x] Video thumbnails via ffmpeg when available
- [x] Audio waveform computed (64 samples)
- [x] Media connection refreshed and cached
- [x] Media upload retry works for failed messages
- [x] Media encryption uses single-pass streaming for large files (GAP-46)
- [x] Media re-upload request sent for expired media (GAP-47)

## Files Created/Modified

- `lib/baileys_ex/media/crypto.ex`
- `lib/baileys_ex/media/upload.ex`
- `lib/baileys_ex/media/download.ex`
- `lib/baileys_ex/media/types.ex`
- `lib/baileys_ex/media/thumbnail.ex`
- `lib/baileys_ex/media/message_builder.ex`
- `lib/baileys_ex/media/retry.ex`
- `lib/baileys_ex/message/builder.ex` (extend)
- `lib/baileys_ex/message/notification_handler.ex` (extend)
- `lib/baileys_ex/message/sender.ex` (extend)
- `lib/baileys_ex/protocol/proto/media_retry_messages.ex`
- `test/baileys_ex/media/crypto_test.exs`
- `test/baileys_ex/media/cross_validation_test.exs`
- `test/baileys_ex/media/upload_test.exs`
- `test/baileys_ex/media/download_test.exs`
- `test/baileys_ex/media/types_test.exs`
- `test/baileys_ex/media/thumbnail_test.exs`
- `test/baileys_ex/media/message_builder_test.exs`
- `test/baileys_ex/media/retry_test.exs`
- `test/fixtures/media/baileys_v7.json`
