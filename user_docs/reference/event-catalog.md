# Event Catalog Reference

This page lists the normalized events from `BaileysEx.subscribe/2` and the raw event keys from `BaileysEx.subscribe_raw/2`.

## Normalized `subscribe/2` events

### `{:connection, update}`

- **Type:** `{:connection, map()}`
- **Default:** emitted when `:connection_update` exists
- **Example:**

```elixir
{:connection, %{connection: :open}}
```

Use this for connection lifecycle updates, QR data, and disconnect metadata.

### `{:message, message}`

- **Type:** `{:message, map()}`
- **Default:** emitted once per entry in `:messages_upsert.messages`
- **Example:**

```elixir
{:message, %{key: %{remote_jid: "15551234567@s.whatsapp.net"}}}
```

Use this for bot and automation message handling.

### `{:presence, update}`

- **Type:** `{:presence, map()}`
- **Default:** emitted when `:presence_update` exists
- **Example:**

```elixir
{:presence, %{id: "15551234567@s.whatsapp.net", presences: %{}}}
```

Use this for contact and group presence updates.

### `{:call, payload}`

- **Type:** `{:call, map() | list() | term()}`
- **Default:** emitted when `:call` exists
- **Example:**

```elixir
{:call, %{status: :offer}}
```

Use this when you want call offer, accept, reject, or terminate events.

### `{:event, name, payload}`

- **Type:** `{:event, atom(), term()}`
- **Default:** emitted for every other raw event
- **Example:**

```elixir
{:event, :groups_update, [%{id: "120363001234567890@g.us"}]}
```

Use this for everything the public facade does not normalize directly.

## Raw `subscribe_raw/2` events

Each raw delivery is a map with one or more of these keys.

### Connection and auth

#### `:connection_update`

- **Type:** `map()`
- **Default:** emitted by the runtime during connect, pair, reconnect, and close flows
- **Example:**

```elixir
%{connection_update: %{connection: :open}}
```

Connection lifecycle, QR data, and disconnect details.

#### `:creds_update`

- **Type:** `map()`
- **Default:** emitted whenever the runtime updates auth credentials
- **Example:**

```elixir
%{creds_update: %{me: %{name: "Example"}}}
```

Persist this if you want your session to survive restarts.

#### `:socket_node`

- **Type:** `BaileysEx.BinaryNode.t() | map()`
- **Default:** emitted for selected low-level socket traffic
- **Example:**

```elixir
%{socket_node: node}
```

Useful for advanced debugging.

### Chats and contacts

#### `:chats_upsert`

- **Type:** `list()`
- **Default:** emitted for new chats
- **Example:**

```elixir
%{chats_upsert: [%{id: "15551234567@s.whatsapp.net"}]}
```

#### `:chats_update`

- **Type:** `list()`
- **Default:** emitted for chat state changes
- **Example:**

```elixir
%{chats_update: [%{id: "15551234567@s.whatsapp.net", archived: true}]}
```

#### `:chats_delete`

- **Type:** `list()`
- **Default:** emitted when chats are removed
- **Example:**

```elixir
%{chats_delete: ["15551234567@s.whatsapp.net"]}
```

#### `:chats_lock`

- **Type:** `term()`
- **Default:** emitted for chat lock updates
- **Example:**

```elixir
%{chats_lock: payload}
```

#### `:contacts_upsert`

- **Type:** `list()`
- **Default:** emitted for new or full contact inserts
- **Example:**

```elixir
%{contacts_upsert: [%{id: "15551234567@s.whatsapp.net"}]}
```

#### `:contacts_update`

- **Type:** `list()`
- **Default:** emitted for contact changes
- **Example:**

```elixir
%{contacts_update: [%{id: "15551234567@s.whatsapp.net", notify: "Jeff"}]}
```

#### `:blocklist_set`

- **Type:** `list()`
- **Default:** emitted when the runtime receives the full blocklist
- **Example:**

```elixir
%{blocklist_set: ["15551234567@s.whatsapp.net"]}
```

#### `:blocklist_update`

- **Type:** `list()`
- **Default:** emitted for incremental blocklist updates
- **Example:**

```elixir
%{blocklist_update: [%{jid: "15551234567@s.whatsapp.net", action: :block}]}
```

### Messages and media

#### `:messages_upsert`

- **Type:** `%{type: atom() | String.t(), messages: list()}`
- **Default:** emitted when messages arrive or are inserted from history sync
- **Example:**

```elixir
%{messages_upsert: %{type: :notify, messages: [%{key: %{id: "ABC"}}]}}
```

#### `:messages_update`

- **Type:** `list()`
- **Default:** emitted for message edits and status updates
- **Example:**

```elixir
%{messages_update: [%{key: %{id: "ABC"}}]}
```

#### `:messages_delete`

- **Type:** `list()`
- **Default:** emitted when messages are revoked or removed
- **Example:**

```elixir
%{messages_delete: [%{key: %{id: "ABC"}}]}
```

#### `:messages_reaction`

- **Type:** `list()`
- **Default:** emitted for reaction updates
- **Example:**

```elixir
%{messages_reaction: [%{key: %{id: "ABC"}, reaction: "🔥"}]}
```

#### `:messages_media_update`

- **Type:** `list()`
- **Default:** emitted for media retry and download updates
- **Example:**

```elixir
%{messages_media_update: [%{key: %{id: "ABC"}}]}
```

#### `:message_receipt_update`

- **Type:** `list()`
- **Default:** emitted for delivery and read receipts
- **Example:**

```elixir
%{message_receipt_update: [%{key: %{id: "ABC"}}]}
```

#### `:messaging_history_set`

- **Type:** `map()`
- **Default:** emitted when a history-sync batch is applied
- **Example:**

```elixir
%{messaging_history_set: %{messages: []}}
```

### Groups, communities, labels, and settings

#### `:groups_upsert`

- **Type:** `list()`
- **Default:** emitted when groups are inserted
- **Example:**

```elixir
%{groups_upsert: [%{id: "120363001234567890@g.us"}]}
```

#### `:groups_update`

- **Type:** `list()`
- **Default:** emitted for group and community metadata changes
- **Example:**

```elixir
%{groups_update: [%{id: "120363001234567890@g.us", subject: "Launch Team"}]}
```

#### `:group_participants_update`

- **Type:** `list() | map()`
- **Default:** emitted for participant add, remove, promote, or demote updates
- **Example:**

```elixir
%{group_participants_update: [%{id: "120363001234567890@g.us"}]}
```

#### `:group_join_request`

- **Type:** `map() | list()`
- **Default:** emitted for join-approval updates
- **Example:**

```elixir
%{group_join_request: %{id: "120363001234567890@g.us"}}
```

#### `:group_member_tag_update`

- **Type:** `list() | map()`
- **Default:** emitted for member-tag updates
- **Example:**

```elixir
%{group_member_tag_update: [%{id: "120363001234567890@g.us"}]}
```

#### `:labels_edit`

- **Type:** `list()`
- **Default:** emitted for label create, update, and delete actions
- **Example:**

```elixir
%{labels_edit: [%{id: "1", name: "Important"}]}
```

#### `:labels_association`

- **Type:** `list()`
- **Default:** emitted when labels are associated with chats or messages
- **Example:**

```elixir
%{labels_association: [%{label_id: "1"}]}
```

#### `:settings_update`

- **Type:** `map() | list()`
- **Default:** emitted for app settings updates
- **Example:**

```elixir
%{settings_update: %{unarchive_chats: true}}
```

#### `:dirty_update`

- **Type:** `map()`
- **Default:** emitted when WhatsApp asks the client to refetch a dataset
- **Example:**

```elixir
%{dirty_update: %{type: "groups"}}
```

#### `:lid_mapping_update`

- **Type:** `list() | map()`
- **Default:** emitted when LID mappings change
- **Example:**

```elixir
%{lid_mapping_update: [%{pn: "15551234567", lid: "123@lid"}]}
```

### Presence, calls, and newsletters

#### `:presence_update`

- **Type:** `map()`
- **Default:** emitted for presence and chatstate updates
- **Example:**

```elixir
%{presence_update: %{id: "15551234567@s.whatsapp.net", presences: %{}}}
```

#### `:call`

- **Type:** `map() | list()`
- **Default:** emitted for call offers and terminal call states
- **Example:**

```elixir
%{call: %{status: :offer}}
```

#### `:newsletter_participants_update`

- **Type:** `map() | list()`
- **Default:** emitted for newsletter participant changes
- **Example:**

```elixir
%{newsletter_participants_update: %{jid: "120363400000000000@newsletter"}}
```

#### `:newsletter_reaction`

- **Type:** `map() | list()`
- **Default:** emitted for newsletter reaction updates
- **Example:**

```elixir
%{newsletter_reaction: %{jid: "120363400000000000@newsletter"}}
```

#### `:newsletter_settings_update`

- **Type:** `map() | list()`
- **Default:** emitted for newsletter settings changes
- **Example:**

```elixir
%{newsletter_settings_update: %{jid: "120363400000000000@newsletter"}}
```

#### `:newsletter_view`

- **Type:** `map() | list()`
- **Default:** emitted for newsletter view and metadata updates
- **Example:**

```elixir
%{newsletter_view: %{jid: "120363400000000000@newsletter"}}
```
