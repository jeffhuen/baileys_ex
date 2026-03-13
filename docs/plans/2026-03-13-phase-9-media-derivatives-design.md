# Phase 9 Media Derivatives Design

Date: 2026-03-13
Branch: `phase-09-media`
Scope: Phase 9 Task `9.5` thumbnail and waveform generation

## Context

Baileys rc.9 derives three media-side artifacts in `messages-media.ts`:

- image thumbnails via an optional image processing library
- video thumbnails via `ffmpeg`
- audio waveforms from decoded audio samples

The Elixir port already has media crypto, upload, download, and media types in
place. The next honest slice is the derivative-generation layer that later
message-builder work can consume.

## Approaches

### 1. Dynamic dependency adapters

Use a plain-function `BaileysEx.Media.Thumbnail` module with:

- dynamic `Image` integration for image thumbnails
- `ffmpeg` execution for video thumbnails
- `ffmpeg` PCM extraction plus Elixir normalization for audio waveforms

Missing runtime support returns explicit `{:error, {:missing_dependency, dep}}`
per call.

Trade-offs:

- matches Baileys' optional-runtime posture
- avoids boot-time crashes and avoids adding new processes
- keeps the library operable in environments where media derivation is not installed
- requires explicit docs/tests around the optional runtime surface

Recommendation: yes

### 2. Mandatory boot-time dependencies

Require `Image`/libvips and `ffmpeg` for the application to be considered
supported, and fail hard as soon as the app boots if they are missing.

Trade-offs:

- simpler mental model for deploys
- worse operator ergonomics
- unnecessary failure scope: an app that never sends media should not fail at boot

Recommendation: no

### 3. Reimplement everything in pure Elixir

Write image resize, video frame extraction, and audio decode logic directly or
behind new NIFs.

Trade-offs:

- maximal control
- completely unnecessary scope expansion
- deviates from the "wrap battle-tested tooling" strategy already used in the project

Recommendation: no

## Chosen Design

Implement `BaileysEx.Media.Thumbnail` as a plain-function utility module with
four public functions:

- `image_thumbnail/2`
- `video_thumbnail/2`
- `audio_waveform/2`
- `image_dimensions/1`

The public API returns explicit `{:ok, value}` / `{:error, reason}` tuples.

### Image thumbnails

- Accept a formatted image binary or a file path.
- Detect dimensions in pure Elixir for JPEG/PNG/WebP.
- If `Image` is not loaded, return `{:error, {:missing_dependency, :image}}`.
- If `Image` is loaded, use `Image.from_binary/1` or `Image.thumbnail/3` and
  `Image.write(..., :memory, suffix: ".jpg")` to produce a JPEG thumbnail.
- Return the JPEG thumbnail plus the original image dimensions.

### Video thumbnails

- Accept a video file path.
- Require `ffmpeg` via `System.find_executable/1`.
- Execute `ffmpeg` to seek to a configurable timestamp, scale to a configurable
  maximum edge, and write a JPEG frame to stdout.
- Return the JPEG thumbnail bytes.

### Audio waveforms

- Accept an audio file path.
- Require `ffmpeg`.
- Use `ffmpeg` to decode the audio into mono PCM samples streamed to stdout.
- In Elixir, split the PCM sample stream into 64 buckets, average absolute
  amplitude per bucket, normalize to the largest bucket, and return a 64-byte
  waveform binary with values `0..100`.

### Image dimensions

- Parse dimensions directly from JPEG, PNG, and WebP binary headers.
- Support both binaries and file paths.
- Return `{:error, :unsupported_image_format}` for unsupported formats.

## Error handling

- Missing image library: `{:error, {:missing_dependency, :image}}`
- Missing ffmpeg: `{:error, {:missing_dependency, :ffmpeg}}`
- Unsupported image format: `{:error, :unsupported_image_format}`
- Failed external command: `{:error, {:command_failed, command, status, stderr}}`

## Testing

Tests will follow TDD:

- image dimension parsing for JPEG/PNG/WebP fixtures
- image thumbnail success via injected image adapter
- image thumbnail missing dependency path
- video thumbnail success via injected command runner
- video thumbnail missing dependency path
- audio waveform normalization to 64 samples via injected PCM output
- explicit missing-dependency and command-failure cases

## Plan impact

No phase reordering change.

The Phase 9 implementation plan should be updated to reflect:

- `9.5` uses explicit per-call dependency errors instead of boot-time failure
- audio waveform generation is implemented via `ffmpeg` + Elixir normalization
- `image_dimensions/1` returns explicit error tuples instead of `nil`
