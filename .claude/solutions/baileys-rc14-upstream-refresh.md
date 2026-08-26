# Baileys rc14 upstream refresh

## Problem

Baileys v7.0.0-rc14 introduced a bounded runtime delta over rc13: a new default
WhatsApp Web version, timestamped query-side trusted-contact tokens with corrected
profile-picture nesting, and experimental Android companion identification.
BaileysEx still matched rc13 and its query-token API shared assumptions with the
separate direct message-relay token path.

## Source-backed resolution

- Refreshed the ignored upstream reference and verified all 196 upstream-tracked
  files byte-for-byte against tag commit `7e7b075`.
- Updated the default version to `[2, 3000, 1_043_857_760]` and the derived
  registration hash vector.
- Kept two explicit TC-token constructions:
  - query-side tokens include `attrs: %{"t" => to_string(timestamp)}`;
  - direct message-relay tokens retain empty attrs.
- Nested profile query tokens under `picture` and applied the upstream default-on
  AB gate, PN/LID-only eligibility, and self PN/LID exclusions.
- Limited presence query tokens to PN/LID users and used the timestamped query
  shape.
- Matched rc14 Android selection from browser tuple element two, including
  case-insensitive substring detection, UserAgent platform `ANDROID`, omitted
  `webInfo`, DeviceProps `ANDROID_PHONE`, and the experimental warning.
- Routed the public profile facade through the live runtime so self identity,
  server props, and the Signal store reach the profile helper together.

## Parity pattern

Do not hand-construct new upstream expectations inside the reference runner. For
TC-token parity, the runner uses rc14's real `buildTcTokenFromJid` with a
deterministic in-memory key-store seam, then passes its output to the real profile
picture-content helper. This prevents Elixir and a duplicated TypeScript fixture
from agreeing on the same mistake.

## Compatibility cleanup

Elixir 1.20 requires pins for already-bound variables used in bitstring sizes and
identifies several redundant clauses more precisely than 1.19. The minimal cleanup
pins those sizes and removes only compiler-proven unreachable/redundant branches.
The native Noise resource test also uses `spawn_monitor/1` so monitoring is atomic
and cannot report `:noproc` when the worker exits before a separate monitor call.

## Verification

- Formatting and `git diff --check`: passed.
- Compilation with warnings as errors: passed.
- Credo strict: no issues.
- Dialyzer: zero errors, skips, or unnecessary skips.
- Full ExUnit suite: 956 passed, including 13 properties; 20 parity-tagged tests
  excluded by the default filter.
- JS-to-Elixir parity suite: 20 passed.
- ExDoc and Hex package builds: passed.
- Three independent reviews: upstream parity and Elixir design clean; all
  scope/completeness findings resolved.

## Reusable cautions

- Audit every upstream helper caller before changing a generic builder.
- Treat query-side and relay-side nodes as separate wire contracts even when they
  share the same tag name.
- Compare tracked reference files rather than claiming a parity working directory
  has no generated dependencies or build output.
- Attach process monitors atomically in lifecycle tests.
