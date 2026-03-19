# Manual Live Validation

This harness is internal-only and manual by design. It exists so contributors
can validate end-to-end WhatsApp behavior with dedicated internal test accounts
without turning live-account checks into a public delivery gate.

## Scope

The live checklist covers:

- QR pairing
- phone-code pairing
- connect and `connection: :open`
- reconnect after `restart_required`
- one text send/receive roundtrip
- one media send/receive roundtrip
- one app-state sync sanity check
- one group/community sanity path

## Required Environment

- `BAILEYS_EX_PARITY_MODE`
  - `qr` or `phone_code`
- `BAILEYS_EX_PARITY_AUTH_DIR`
  - local auth-state directory to use for the live run
- `BAILEYS_EX_PARITY_TEST_JID`
  - direct-chat JID for the second internal test account

## Optional Environment

- `BAILEYS_EX_PARITY_TEST_PHONE`
  - required when `BAILEYS_EX_PARITY_MODE=phone_code`
- `BAILEYS_EX_PARITY_GROUP_JID`
  - group/community JID for the manual group sanity path

## Entry Point

```bash
mix run dev/scripts/run_live_validation.exs
```

The script is intentionally conservative. It validates environment, prints the
active checklist, and shows the exact manual scenarios to run. It is not part
of CI and should not be exposed in public docs.
