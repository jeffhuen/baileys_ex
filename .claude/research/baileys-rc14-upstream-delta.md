# Research: Baileys v7.0.0-rc14 Upstream Delta

**Audited:** 2026-08-26
**Local branch:** `main` at `f8ef661`
**Local parity baseline:** Baileys `v7.0.0-rc13`

## Summary

Baileys `v7.0.0-rc14` was released on July 29, 2026 at commit `7e7b075`. The official `rc13...rc14` comparison contains 8 commits and 14 changed files (92 insertions, 21 deletions), but only three clusters affect BaileysEx behavior: a new WhatsApp Web version triplet, corrected trusted-contact-token wire shapes, and experimental Android companion identification.

This is not a metadata-only reference bump. BaileysEx currently emits the RC13 Web version, emits profile-picture TC tokens as IQ siblings without their timestamp attribute, emits presence TC tokens without their timestamp attribute, and always identifies the client as Web. Those are concrete RC14 parity gaps. The direct-message TC-token shape is a separate upstream path and must retain empty attributes.

## Primary Sources

- [RC14 release](https://github.com/WhiskeySockets/Baileys/releases/tag/v7.0.0-rc14) — release date and tag commit.
- [Official RC13-to-RC14 comparison](https://github.com/WhiskeySockets/Baileys/compare/v7.0.0-rc13...v7.0.0-rc14) — 8 commits and 14 changed files.
- [Profile-picture TC-token fix, PR #2607](https://github.com/WhiskeySockets/Baileys/pull/2607) — confirms the token belongs under `picture` and carries `t`.
- [Android browser support, PR #2201](https://github.com/WhiskeySockets/Baileys/pull/2201) — adds experimental Android companion identification and the `Browsers.android` tuple.
- [WhatsApp Web version update](https://github.com/WhiskeySockets/Baileys/commit/20cc099170a3d62efec6e2316026689f5c5a0d48) — changes the triplet to `[2, 3000, 1043857760]`.

## Exact Upstream Delta

- Web version (`src/Defaults/baileys-version.json`, `src/Defaults/index.ts`, `src/Utils/generics.ts`): the default changes from `[2, 3000, 1035194821]` to `[2, 3000, 1043857760]`. BaileysEx needs the same config/default update.
- Profile-picture TC token (`src/Socket/chats.ts`, `src/Utils/tc-token-utils.ts`): `tctoken` moves from an IQ sibling to a child of `picture`; it carries `attrs.t`; entries without a timestamp are rejected and cleaned up. This is a required wire-shape fix.
- Presence TC token (`src/Socket/chats.ts`, `src/Utils/tc-token-utils.ts`): the shared participant-JID helper now includes stored timestamp `t` on presence-subscribe tokens. This is a required wire-shape fix.
- Android companion (`src/Utils/browser-utils.ts`, `src/Utils/validate-connection.ts`, `src/Socket/socket.ts`, `src/Types/index.ts`): RC14 adds `Browsers.android(version) -> [version, "Android", ""]`, uses UserAgent platform `ANDROID` (`0`), omits `webInfo`, uses DeviceProps `ANDROID_PHONE` (`16`), and logs an experimental warning. BaileysEx needs equivalent config/payload support; helper naming may remain idiomatic Elixir.
- TypeScript build fix (`src/Utils/generics.ts`): a type-only `Long` import has no Protox/Elixir equivalent and is not applicable.
- Release infrastructure (publish workflow, `CHANGELOG.md`, `package.json`): the NPM pin and release metadata are not runtime parity work.
- Upstream tests (`src/__tests__/Socket/chats.test.ts`, `src/__tests__/Utils/tc-token.test.ts`): these lock the corrected token nesting, timestamp, and missing-timestamp behavior and should become deterministic ExUnit regressions.

## Upstream TC-Token Callsite Audit

`buildTcTokenFromJid` has two runtime callsites in RC14:

1. `profilePictureUrl` — eligible non-self PN/LID user queries only. The resulting node is nested under `picture`.
2. `presenceSubscribe` — eligible PN/LID user subscriptions. The resulting node is a direct child of `presence`.

Direct 1:1 message relay does not use that helper. `messages-send.ts` builds its own `tctoken` node with `attrs: {}`. Therefore, a global change that adds `t` to every BaileysEx TC-token node would be incorrect.

The three RC14 wire shapes are:

```text
profile IQ
  picture type=preview|image query=url
    tctoken t=<stored timestamp>

presence subscribe
  tctoken t=<stored timestamp>

direct 1:1 message
  tctoken                    # attrs remain empty
```

## Current BaileysEx Gap Map

- `Connection.Config.version` is `[2, 3000, 1_035_194_821]`; RC14 requires `[2, 3000, 1_043_857_760]`.
- The configuration guide still documents `[2, 3000, 1_033_846_690]`. It was already stale before RC14 and should be corrected in the same pass.
- `Profile.picture_url/4` currently builds `[picture, tctoken]` and the token attrs are empty. RC14 requires `[picture(content: [tctoken(t: ...)])]`.
- The local profile query attempts generic token attachment whenever a signal store is supplied. RC14 (and RC13) only attach for non-self PN/LID users, subject to the upstream profile-token gate, and never for groups, newsletters, or self. This adjacent pre-existing gap is exposed by the same callsite and should be fixed in the same pass.
- `Presence.subscribe/3` emits a token with empty attrs; RC14 requires `"t" => stored_timestamp`.
- Direct message sender currently emits empty token attrs. That matches RC14 and must not regress.
- `TcToken.expired?/2` already treats an unparsable or absent timestamp as expired, and cleanup preserves `sender_timestamp`. Add a focused missing-timestamp assertion rather than redesigning that behavior.
- `ConnectionValidator` always uses Web UserAgent platform `14` and always populates `web_info`. Android requires platform `0` and no `web_info`.
- `Config.device_props_platform_type/1` does not map Android; RC14 requires `ANDROID_PHONE` value `16`.
- There is no Android-specific experimental warning during socket construction.

## Recommended Phase 18 Scope

1. Retarget the authoritative reference copy to the exact `v7.0.0-rc14` tag, then update `AGENTS.md`, `CLAUDE.md`, `README.md`, the overview, agent rules, progress tracker, phase file, and parity matrix from RC13 to RC14.
2. Refactor TC-token construction by callsite:
   - preserve a direct-message builder with empty attrs;
   - expose stored token plus timestamp to query callsites;
   - make presence tokens carry `t`;
   - nest profile tokens under `picture`; and
   - enforce upstream non-self user-JID eligibility.
3. Add Android client identification without introducing a process or dependency:
   - recognize the tuple `{android_version, "Android", ""}`;
   - set UserAgent platform to `0`;
   - omit `web_info`; and
   - map registration DeviceProps to `16`.
4. Update the default Web version to `[2, 3000, 1_043_857_760]` everywhere it is a default or documented default. Keep deliberately pinned historical test vectors unchanged unless the test specifically asserts the current default.
5. Add deterministic ExUnit coverage and parity fixtures for the exact encoded payload/node shapes, then run all 11 delivery gates plus `dev/scripts/run_parity_suite.sh`.

## Focused Verification Matrix

- Config default and public documentation report the RC14 triplet.
- Web login and registration still encode platform `14` and include `web_info`.
- Android login and registration encode platform `0`, omit `web_info`, and registration DeviceProps encode platform type `16`.
- Profile query without a token contains one bare `picture` child.
- Profile query with a token contains one `picture` child whose content is one `tctoken` with a pinned timestamp.
- Self, group, and newsletter profile queries do not attach a TC token.
- Presence subscribe attaches the token with its pinned timestamp.
- Direct-message relay continues to attach the token with empty attrs.
- A token with no timestamp is not emitted and is removed while any `sender_timestamp` dedupe state is retained.
- Current Web behavior and non-Android browser tuples remain unchanged.

## Watch Out For

- Do not solve the timestamp change in generic `TcToken.build_node/3`; that would alter the direct-message stanza, which RC14 leaves unchanged.
- In Protobuf, Android UserAgent platform is numeric zero. Tests must assert the encoded/decoded value explicitly so a default-value omission is not mistaken for an unset field.
- Android detection follows upstream browser tuple element 2, case-insensitively. The upstream helper returns `[version, "Android", ""]`, not `["Android", version, ""]`.
- `web_info` must be absent, not a struct containing `web_sub_platform: 0`.
- Retargeting the copied reference directory and trackers is part of completion; changing only the Elixir defaults would leave the project spec internally contradictory.

## Conclusion

RC14 is a bounded but real parity phase. The clean implementation should touch connection config/payload construction and the existing TC-token/profile/presence modules, while leaving Signal cryptography, media, Syncd, message decoding, and most feature surfaces unchanged.
