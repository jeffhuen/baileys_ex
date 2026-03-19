# Live Validation Checklist

Use dedicated internal test accounts only.

## 1. Pairing

- [ ] `BAILEYS_EX_PARITY_MODE=qr`: start from a clean auth dir and complete QR pairing
- [ ] `BAILEYS_EX_PARITY_MODE=phone_code`: request a pairing code and complete phone-code pairing
- [ ] After pairing, confirm the runtime emits `connection: :open`

## 2. Restart Path

- [ ] Complete the QR scan restart path
- [ ] Confirm the post-auth reconnect reaches `connection: :open`
- [ ] Confirm the first post-auth server responses are processed in wire order

## 3. Direct Messaging

- [ ] Send one plain text message to `BAILEYS_EX_PARITY_TEST_JID`
- [ ] Confirm the receiving account gets the message
- [ ] Reply from the receiving account and confirm the local runtime ingests it

## 4. Media

- [ ] Send one supported media type to `BAILEYS_EX_PARITY_TEST_JID`
- [ ] Confirm upload, receipt, and receive/decrypt behavior on the other side

## 5. App State

- [ ] Change one chat-level state (mute, archive, or pin)
- [ ] Confirm the expected sync/app-state update is observed

## 6. Group Or Community

- [ ] If `BAILEYS_EX_PARITY_GROUP_JID` is set, perform one group/community sanity action
- [ ] Confirm the expected event/update is emitted

## 7. Cleanup

- [ ] Capture any mismatch with exact timestamps, nodes, events, and absolute file paths
- [ ] Do not leave live-account credentials in the repo
