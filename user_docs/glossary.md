# Glossary

Canonical definitions for terms used throughout BaileysEx documentation.

---

**Auth State** — The collection of cryptographic keys and identity data that represents
your connection to WhatsApp. Persisted between sessions so you don't need to re-pair.

**Binary Node** — WhatsApp's wire format for communication. A compact binary encoding
of XML-like structures with a tag, attributes, and content (children or binary data).

**Connection** — An active, authenticated session with WhatsApp servers. Managed by
BaileysEx's supervision tree. One connection = one WhatsApp account.

**Device** — A single client (phone, desktop, web) linked to a WhatsApp account.
WhatsApp's multi-device protocol means each device has its own encryption session.

**Double Ratchet** — The Signal protocol algorithm that generates unique encryption keys
for every message. Provides forward secrecy — past messages can't be decrypted even if
current keys are compromised.

**Event** — A notification emitted by a connection when something happens: message received,
presence changed, group updated, etc. You subscribe to events to react to WhatsApp activity.

**JID** — Jabber ID. The address format WhatsApp uses for users, groups, and broadcasts.
Format: `user@server` (e.g., `5511999887766@s.whatsapp.net` for a user,
`120363001234567890@g.us` for a group).

**LID** — Logical ID. An alternative addressing mode WhatsApp uses internally for
multi-device routing. Mapped to phone numbers (PN) by the protocol.

**Noise Protocol** — The transport encryption layer. Establishes an encrypted tunnel
over WebSocket before any application data is exchanged. Uses Curve25519 key exchange
and AES-256-GCM encryption.

**Pairing** — The process of linking BaileysEx to your WhatsApp account. Done once via
QR code scan or phone number verification code.

**Pre-Key** — A one-time-use public key uploaded to WhatsApp servers. Allows other devices
to establish encrypted sessions with you without being online simultaneously.

**Sender Key** — A shared secret used for group message encryption. One encryption
operation covers all group members, instead of encrypting separately for each device.

**Signal Protocol** — The end-to-end encryption protocol used by WhatsApp. Each message
is encrypted individually per recipient device. BaileysEx implements this in pure Elixir.

**X3DH** — Extended Triple Diffie-Hellman. The Signal protocol's key agreement mechanism
for establishing a shared secret between two devices that may never have communicated before.

**XEdDSA** — A signature scheme that allows Curve25519 keys (used for key exchange) to
also produce Ed25519-compatible signatures. Required because WhatsApp identity keys are
Curve25519 but must sign pre-keys.
