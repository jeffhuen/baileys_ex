# Scope and completeness review

## Verdict

Three documentation/parity-quality findings were identified and resolved.

## Resolved findings

1. The reference runner manually constructed timestamped TC-token nodes. It now
   invokes rc14's real `buildTcTokenFromJid` helper with a deterministic in-memory
   key-store seam; the profile path also invokes the real picture-content helper.
2. Phase 18 and `PROGRESS.md` omitted several changed files. Both inventories now
   include the RC14 surfaces and the behavior-preserving compiler/test cleanups.
3. The reference acceptance criterion claimed the whole ignored working tree was
   pristine. It now states the verified contract precisely: all 196
   upstream-tracked files match rc14 byte-for-byte, while generated dependency and
   build outputs are excluded.

## Clean checks

- Current authority docs target rc14; remaining rc13 references are historical.
- `git diff --check` is clean.
- Package allowlisting excludes internal plans, references, tools, and tests.
- `.claude/settings.json` remains unmodified and unstaged.
