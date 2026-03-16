# Glossary

Canonical definitions for terms used throughout BaileysEx documentation.

---

## App State Sync (Syncd)

WhatsApp's cross-device settings sync system. It keeps state such as archived chats,
mute and pin settings, labels, contact updates, and similar metadata consistent across
your linked devices.

## Auth State

The collection of cryptographic keys and identity data that represents your connection
to WhatsApp. Persisted between sessions so you do not need to re-pair.

## Binary Node

WhatsApp's wire format for communication. A compact binary encoding of XML-like
structures with a tag, attributes, and content.

## Connection

An active, authenticated session with WhatsApp servers. Managed by BaileysEx's
supervision tree. One connection maps to one WhatsApp account.

## Device

A single client such as a phone, desktop app, or web session linked to a WhatsApp
account. WhatsApp's multi-device protocol gives each device its own encryption session.

## Double Ratchet

The Signal protocol algorithm that generates unique encryption keys for every message.
This gives you forward secrecy, which means older messages stay protected even if newer
keys are later exposed.

## Event

A notification emitted by a connection when something happens, such as a received
message, a presence change, or a group update. You subscribe to events to react to
WhatsApp activity in your application.

## Community

A WhatsApp container that can organize one or more related groups. BaileysEx exposes
community creation and metadata from the top-level facade and the fuller management
surface through `BaileysEx.Feature.Community`.

## JID

Jabber ID. The address format WhatsApp uses for users, groups, and broadcasts.
Examples: `5511999887766@s.whatsapp.net` for a user and `120363001234567890@g.us`
for a group.

## LID

Logical ID. An alternative addressing mode WhatsApp uses internally for multi-device
routing. The protocol maps LIDs to phone-number-based identities when needed.

## LTHash

The integrity check WhatsApp uses for app state sync. Instead of trusting every patch
blindly, BaileysEx recomputes this rolling hash so it can detect drift or tampering
before applying Syncd updates.

## Noise Protocol

The transport encryption layer. It establishes an encrypted tunnel over WebSocket
before any application data is exchanged.

## Newsletter

WhatsApp's channel-style broadcast surface. In BaileysEx, newsletter operations cover
metadata lookups, follow and unfollow flows, reactions, and administration helpers.

## Pairing

The process of linking BaileysEx to your WhatsApp account. You do this once with a
QR code or phone-number verification code, then reuse the saved auth state.

## Pre-Key

A one-time-use public key uploaded to WhatsApp servers. It lets other devices start
an encrypted session with you even when you are offline.

## Sender Key

A shared secret used for group message encryption. It lets one encrypted send cover
the whole group instead of encrypting separately for every device.

## WAM

WhatsApp Analytics and Metrics. This is WhatsApp's internal event buffer format for
client telemetry. BaileysEx can encode and send WAM buffers when you need Baileys
parity for that path.

## Signal Protocol

The end-to-end encryption protocol used by WhatsApp. Each message is encrypted
individually for the recipient device, and BaileysEx handles that workflow for you.

## X3DH

Extended Triple Diffie-Hellman. The Signal protocol's key agreement mechanism for
establishing a shared secret between two devices that may never have talked before.

## XEdDSA

A signature scheme that lets Curve25519 keys also produce Ed25519-compatible
signatures. WhatsApp uses this because its identity keys must both exchange keys and
sign pre-keys.
