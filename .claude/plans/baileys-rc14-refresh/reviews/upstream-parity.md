# Upstream parity review

## Verdict

No concrete correctness findings.

## Scope reviewed

- Official `v7.0.0-rc13...v7.0.0-rc14` runtime delta.
- Both runtime callers of `buildTcTokenFromJid`.
- Separate direct message-relay TC-token construction.
- Profile token eligibility, nesting, and self PN/LID handling.
- Android browser detection, login/registration payloads, and warning.
- Default version and registration hash behavior.

## Evidence

- `mix compile --warnings-as-errors` passed.
- Focused reviewer suite: 132 passed, with 5 parity-tagged tests excluded by
  the default test filter.
