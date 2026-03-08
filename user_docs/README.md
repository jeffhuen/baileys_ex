# User Documentation

> **For Claude:** Follow these rules when writing or updating any file in `user_docs/`.
> These standards are mandatory and enforced by the documentation delivery gate.

This is the user-facing documentation for BaileysEx. Every page here is written for
**Elixir developers** who want to integrate WhatsApp messaging into their applications.
They know Elixir and OTP at a working level. They don't know WhatsApp's internal
protocols and shouldn't need to.

Separate internal documentation (architecture, implementation plans) lives in `dev/`
and is never published.

---

## Who You Are Writing For

Before writing a single word, hold this picture in mind:

**The reader is someone who:**
- Wants to add WhatsApp messaging to their Elixir application
- Knows Elixir, Mix, and basic OTP (supervisors, GenServers)
- Has added Hex dependencies before and read HexDocs
- Will not read the WhatsApp protocol spec — they want the library to handle it
- Will quit if "hello world" (send a text message) takes more than 15 minutes
- Has never heard of Signal protocol, Noise handshake, or WABinary encoding

**The reader is not:**
- A protocol engineer debugging the Signal implementation
- Someone who will read `dev/implementation_plan/` phase files
- Someone who needs to understand Montgomery-Edwards key conversion
- Someone extending BaileysEx internals (that's what `@moduledoc` is for)

**The test:** Read your page out loud. If it sounds like a protocol specification,
rewrite it. If it sounds like an Elixir library guide (think Ecto, Phoenix, Oban docs),
it passes.

---

## Tone and Language

### Write for developers who don't know WhatsApp internals

| Instead of... | Write... |
|---|---|
| "The Noise XX handshake derives transport keys via HKDF" | "BaileysEx handles the encrypted connection automatically" |
| "Messages are encrypted per-device using the Signal Double Ratchet" | "Each message is end-to-end encrypted — BaileysEx handles this for you" |
| "Construct a BinaryNode with tag 'message' and attrs..." | "Use `BaileysEx.send_message/3` to send a text message" |
| "The `:gen_statem` transitions through four states" | "The connection manages reconnection automatically" |

### Specific rules

- **Second person:** "You can send..." not "Developers can send..."
- **Active voice:** "Call `send_message/3`" not "`send_message/3` should be called"
- **Present tense:** "This sends the message" not "This will send the message"
- **Short sentences:** One idea per sentence. If you need a semicolon, split it.
- **Concrete:** Show the exact code. Show what the return value looks like. Don't describe it abstractly.
- **No hedging:** "Call `BaileysEx.connect/2`" not "You might want to try calling `BaileysEx.connect/2`"
- **No protocol jargon without a link:** First use of a WhatsApp-specific term links to the glossary.
- **No internal names:** Don't mention `Connection.Socket`, `Signal.SessionCipher`, or `Protocol.BinaryNode` in guides. Users interact with the public API.
- **No future tense for existing features:** If it's not built, it doesn't appear in user docs.

---

## Documentation Architecture

Every page belongs in exactly one category:

```
user_docs/
├── README.md              ← You are here (standards + index)
├── glossary.md            ← Plain-language definitions of WhatsApp terms
├── getting-started/       ← Zero to working: install → pair → send message
├── guides/                ← Task-oriented: "How do I send media?"
├── reference/             ← Look up a specific option, event, or type
└── troubleshooting/       ← Fix a specific problem
```

### When to use each category

| Category | Purpose | Reader's question |
|---|---|---|
| **Getting Started** | Zero to working | "How do I set this up for the first time?" |
| **Guides** | Accomplish a task | "How do I send images?" / "How do I manage groups?" |
| **Reference** | Look something up | "What events can I subscribe to?" |
| **Troubleshooting** | Fix something broken | "Why does my connection keep dropping?" |

**Never mix categories.** A getting-started page that becomes a reference dump confuses
first-time readers. A reference page that buries setup instructions is impossible to
search. If content genuinely spans categories, split it and cross-link.

---

## Anti-Patterns

These are hard rules. Each one represents a common documentation failure:

### 1. No protocol internals

**Bad:** "BaileysEx uses a ResourceArc wrapping the `snow` crate's HandshakeState
to perform the Noise XX pattern handshake with Curve25519 ECDH..."

**Good:** "BaileysEx establishes an encrypted connection to WhatsApp automatically
when you call `BaileysEx.connect/2`."

**Rule:** Protocol details belong in `@moduledoc` (Layer 1) or `dev/docs/` (Layer 3).
User guides explain *what you can do*, not *how the protocol works*.

### 2. No content duplication

**Bad:** Explaining connection options in the getting-started guide, the authentication
guide, and the configuration reference.

**Good:** Explain once in Reference. Link from everywhere else:
"See [Configuration Reference](reference/configuration.md#connection-options) for all options."

**Rule:** One canonical home per concept. Everything else links to it.

### 3. No orphaned pages

**Bad:** A page exists in `guides/` but isn't in the README index and isn't linked from anywhere.

**Good:** Every page is in the README index AND linked from at least one related page.

**Rule:** When you create a page, add it to the Page Index below and add "See also"
links from related pages.

### 4. No missing navigation

**Bad:** A page ends after explaining a feature. The reader doesn't know what to do next.

**Good:** Every page ends with a "Next steps" or "See also" section.

**Rule:** Every page must end with at least one forward link.

### 5. No walls of config

**Bad:** A 30-line options keyword list dropped in the middle of a guide with no explanation.

**Good:** Show the minimum working call first (2–3 options). Link to Reference for the
full option list.

**Rule:** Guides show minimal examples. Reference pages show complete option lists.
Never mix the two.

### 6. No roadmap in user docs

**Bad:** "In a future version, you'll be able to send polls and events."

**Good:** Describe only what exists today. Roadmap lives in `dev/`.

**Rule:** If it isn't built, it doesn't exist in user docs.

### 7. No inconsistent structure

**Bad:** The messages guide is 800 lines covering every detail. The groups guide is 50 lines.
Readers can't predict what to expect.

**Good:** Every page in a category follows the same template.

**Rule:** Use the templates below. Every page in a category looks the same.

### 8. No buried troubleshooting

**Bad:** Troubleshooting tips scattered throughout five different guide pages.

**Good:** All troubleshooting lives in `troubleshooting/`. Guides say:
"If this fails, see [Troubleshooting: Connection](../troubleshooting/connection-issues.md)."

**Rule:** Never put troubleshooting inline in a guide.

---

## Page Templates

Copy these exactly. Do not improvise the structure.

### Getting Started Page

````markdown
# <What you'll accomplish — e.g., "Send Your First Message">

<One sentence: what the user will have working by the end.>

## Before you begin

- <Concrete prerequisite — e.g., "Elixir 1.19+ installed">
- <Another prerequisite>

## Steps

### 1. <Action verb + noun — e.g., "Add BaileysEx to your project">

<2–3 sentences explaining what to do.>

```elixir
<exact code to write or command to run>
```

You should see: `<exact expected output>`

### 2. <Next step>

...

## Check that it worked

<Concrete verification step — not "it should work." Give an exact thing to do
and what to see.>

---

**Next steps:**
- [Link to next page](path) — one sentence on why to go there
````

### Guide Page

````markdown
# <Task — e.g., "Send Media Messages">

<One paragraph: what this covers, when you'd use it, what it enables.>

## Quick start

<Minimum code to get it working. No options, no variations — just the thing
that works.>

```elixir
<minimal working example>
```

## Options

<Only the options relevant to this task, in plain language. Link to Reference
for the full list.>

→ See [Configuration: <section>](../reference/configuration.md#section) for all options.

## Common patterns

<Task-oriented sections: "Send an image," "Send a document," "Send with a caption">

## Limitations

<What this feature doesn't do. Be honest — prevents users from wasting time
on the impossible.>

---

**See also:**
- [Related guide](path)
- [Troubleshooting: <area>](../troubleshooting/area.md)
````

### Reference Page

````markdown
# <Subject> Reference

<One sentence: what this page covers.>

## <Section heading>

### `<option or type name>`

- **Type:** `atom | String.t() | keyword()`
- **Default:** `<value>` *(or "required")*
- **Example:**

```elixir
<shortest working example>
```

<1–2 sentences: what it does. When would a developer change it?>

...
````

### Troubleshooting Page

````markdown
# Troubleshooting: <Area>

## <Problem in plain language — the words the user would search for>

**What you see:**
```
<exact error message or behavior>
```

**Why this happens:** <One sentence>

**Fix:**

```elixir
<exact code change or command>
```

---

## <Next problem>

...
````

---

## Glossary Standards

`user_docs/glossary.md` defines all WhatsApp and BaileysEx terms in plain language.
These definitions are the ground truth — `@moduledoc` may add technical depth but
must not contradict them.

**When to add a term:** Any WhatsApp concept a typical Elixir developer wouldn't know —
JID, Signal protocol, Noise handshake, Sender Keys, pre-keys, LID, pairing, etc.
Define it before using it in a guide.

**How to write a definition:** Plain language. One to three sentences. Focus on what
the reader needs to know, not how it's implemented.

**Good:**
> **JID** — Jabber ID. The address format WhatsApp uses for users and groups.
> Format: `5511999887766@s.whatsapp.net` for a user, `120363001234@g.us` for a group.

**Bad:**
> **JID** — A `BaileysEx.Protocol.JID` struct parsed by `JID.parse/1` containing
> user, server, and device fields with LID/PN addressing modes.

---

## Page Index

> Update this table whenever you add a page. A page not listed here is effectively invisible.

### Getting Started

| Page | Description |
|---|---|
| *(Phase 12)* | Installation, first connection, first message |

### Guides

| Page | Description |
|---|---|
| *(Phase 12)* | Messages, media, groups, presence, events, auth, advanced |

### Reference

| Page | Description |
|---|---|
| *(Phase 12)* | Configuration, events catalog, message types |

### Troubleshooting

| Page | Description |
|---|---|
| *(Phase 12)* | Connection issues, authentication, encryption |

---

## Relationship to Other Documentation

| Layer | Location | Audience | Their question |
|---|---|---|---|
| User docs | **`user_docs/`** (here) | Elixir developers using BaileysEx | How do I use this library? |
| Code reference | **ExDoc** (`mix docs`) | Developers reading source / extending | How does this function work? |
| Architecture | **`dev/implementation_plan/`** | Contributors and agents | Why was this built this way? |

Never duplicate content across layers. Each fact has exactly one canonical home.
