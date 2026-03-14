# Phase 10: Features

**Goal:** Group management, chat operations, presence, privacy settings, app state sync.

**Depends on:** Phase 8 (Messaging)
**Parallel with:** Phase 9 (Media)
**Blocks:** Phase 11 (Advanced Features)

**Baileys reference:** `src/Socket/chats.ts` (40+ functions), `src/Socket/groups.ts` (20 functions),
`src/Utils/chat-utils.ts` (Syncd protocol), `src/Utils/lt-hash.ts`, `src/Utils/sync-action-utils.ts`

---

## Design Decisions

**Feature modules are stateless functions.**
Each feature module constructs binary nodes, sends them through the connection socket,
and parses responses. No dedicated processes — these are just organized function
namespaces that operate on the connection.

**App state sync is the most complex feature here.**
The Syncd protocol uses LTHash, versioned patches, and CRC verification. It is split
into 4 sub-tasks (10.5a–10.5d) to manage complexity. The key reference files are:
- `src/Utils/chat-utils.ts` — `expandAppStateKeys`, `decodeSyncdPatch`, `decodeSyncdSnapshot`, `encodeSyncdMutations`, `processSyncdPatches`, `processAppStateSyncMessage`, `ChatMutationMap`, `makeLtHashGenerator`
- `src/Utils/sync-action-utils.ts` — `processContactAction`, `emitSyncActionResults`

**First step for each task:** open the corresponding Baileys source file, list every
exported function, and verify it has a home in this plan. The plan is the skeleton —
the Baileys source is the spec for filling in the details.

**Current status:** `10.1`, `10.1a`, `10.2`, `10.3`, `10.3a`, and `10.3b` are
complete. The Phase 10 runtime now has the core group/query
surface, the initial app-state patch layer, Baileys-style presence handling, and
the bot-directory query surface. `BaileysEx.Feature.Group` covers the main
`groups.ts` IQ/query helpers, metadata extraction, invite v3/v4 operations, v4
invite invalidation plus synthetic `GROUP_PARTICIPANT_ADD` side effects when
callback hooks are provided, and the relay-backed `GROUP_MEMBER_LABEL_CHANGE`
path with `member_tag` meta nodes, participating-group fetch, and coordinator-
driven dirty-group refetch + clean behavior. `BaileysEx.Feature.PhoneValidation`
implements `on_whatsapp/3` through the USync contact protocol, supports
deterministic `sid` injection for tests, and returns only confirmed contacts.
`BaileysEx.Feature.Chat` and the initial `BaileysEx.Feature.AppState` module now
build Baileys-aligned chat-modification patches with timestamps nested inside
`sync_action` and validated last-message ranges. `BaileysEx.Feature.Presence`
covers availability/chatstate sends, presence subscribe, incoming presence parsing,
and coordinator event emission. `BaileysEx.Feature.TcToken` covers direct-message
relay attachment, presence-subscribe attachment, privacy-token fetch/storage, and
notification handling. `BaileysEx.Feature.Profile.picture_url/4` now covers the
Baileys profile-picture URL query with TC-token attachment and response parsing.
`BaileysEx.Feature.BotDirectory` mirrors `getBotListV2`. Full Syncd
encode/encrypt/send behavior remains the responsibility of `10.5a`-`10.5d`.

---

## Tasks

### 10.1 Group management

File: `lib/baileys_ex/feature/group.ex`

```elixir
defmodule BaileysEx.Feature.Group do
  @doc "Create a new group"
  def create(conn, subject, participants) do
    key = generate_message_id_v2()

    node = %BinaryNode{
      tag: "iq",
      attrs: %{"type" => "set", "xmlns" => "w:g2", "to" => "@g.us"},
      content: [
        %BinaryNode{tag: "create", attrs: %{"subject" => subject, "key" => key}, content:
          Enum.map(participants, &participant_node/1)
        }
      ]
    }
    Connection.Socket.query(conn, node)
  end

  def update_subject(conn, group_jid, subject), do: ...
  def update_description(conn, group_jid, description), do: ...
  def leave(conn, group_jid), do: ...
  def add_participants(conn, group_jid, jids), do: ...
  def remove_participants(conn, group_jid, jids), do: ...
  def promote_participants(conn, group_jid, jids), do: ...
  def demote_participants(conn, group_jid, jids), do: ...
  def invite_code(conn, group_jid), do: ...
  def revoke_invite(conn, group_jid), do: ...
  def accept_invite(conn, code), do: ...
  def get_metadata(conn, group_jid), do: ...
  def fetch_all_participating(conn), do: ...
  def toggle_ephemeral(conn, group_jid, expiration), do: ...
  def get_invite_info(conn, code), do: ...
  def setting_update(conn, group_jid, setting) when setting in [:announcement, :not_announcement, :locked, :unlocked], do: ...
  def member_add_mode(conn, group_jid, mode) when mode in [:admin_add, :all_member_add], do: ...
  def join_approval_mode(conn, group_jid, mode) when mode in [:on, :off], do: ...
  def request_participants_list(conn, group_jid), do: ...
  def request_participants_update(conn, group_jid, jids, action) when action in [:approve, :reject], do: ...
  def accept_invite_v4(conn, key, invite_message, opts \\ []), do: ...
  def revoke_invite_v4(conn, group_jid, invited_jid), do: ...

  @doc "Set custom label/tag on a group member"
  def update_member_label(conn, group_jid, member_label) do
    # Relays ProtocolMessage.GROUP_MEMBER_LABEL_CHANGE
    # with meta node: tag_reason='user_update', appdata='member_tag'
  end

  defp participant_node(jid) do
    %BinaryNode{tag: "participant", attrs: %{"jid" => JID.to_string(jid)}}
  end
end
```

Include `fetch_all_participating/1` plus a dirty-update handler fed from Phase 6
`dirty_update` events so `type="groups"` refetches participating groups, emits
`groups.update`, and cleans the `groups` dirty bucket just like `groups.ts`.

### 10.1a Phone number validation

File: `lib/baileys_ex/feature/phone_validation.ex`

```elixir
defmodule BaileysEx.Feature.PhoneValidation do
  @moduledoc "Check if phone numbers are registered on WhatsApp."

  @doc "Check one or more phone numbers. Returns [{exists?, jid}]"
  def on_whatsapp(conn, phone_numbers, opts \\ []) when is_list(phone_numbers) do
    query = USync.build_query([:contact], phone_numbers, context: :interactive)
    sid = Keyword.get(opts, :sid, Integer.to_string(System.unique_integer([:positive])))
    {:ok, node} = USync.to_node(query, sid)
    {:ok, response} = Connection.Socket.query(conn, node)
    USync.parse_response(response, :contact)
    # Returns [%{exists: true, jid: "1234@s.whatsapp.net"}, ...]
    # v7 note: this is PN/contact discovery, not a source of truth for LIDs
  end
end
```

### 10.2 Chat operations

File: `lib/baileys_ex/feature/chat.ex`

```elixir
defmodule BaileysEx.Feature.Chat do
  @moduledoc """
  Chat-level operations. All use app state sync patches (Syncd protocol)
  via AppState.push_patch/5. Maps 1:1 to Baileys chatModify types.
  """

  @doc "Archive or unarchive a chat. Requires last_messages for sync."
  def archive(conn, jid, archive?, last_messages) do
    chat_modify(conn, jid, :archive, %{archive: archive?, last_messages: last_messages})
  end

  @doc "Mute a chat. duration = unix timestamp of unmute, or nil to unmute."
  def mute(conn, jid, duration), do: chat_modify(conn, jid, :mute, duration)

  @doc "Pin or unpin a chat."
  def pin(conn, jid, pin?), do: chat_modify(conn, jid, :pin, pin?)

  @doc "Star or unstar messages in a chat."
  def star(conn, jid, messages, star?) when is_list(messages) do
    # messages: [%{id: "msg_id", from_me: true/false}]
    chat_modify(conn, jid, :star, %{messages: messages, star: star?})
  end

  @doc "Delete a chat. Requires last_messages for sync."
  def delete(conn, jid, last_messages) do
    chat_modify(conn, jid, :delete, %{last_messages: last_messages})
  end

  @doc "Clear chat history."
  def clear(conn, jid, last_messages) do
    chat_modify(conn, jid, :clear, %{last_messages: last_messages})
  end

  @doc "Mark chat as read or unread."
  def mark_read(conn, jid, read?, last_messages) do
    chat_modify(conn, jid, :mark_read, %{read: read?, last_messages: last_messages})
  end

  @doc "Delete a specific message for me."
  def delete_message_for_me(conn, jid, message_key, timestamp, delete_media? \\ false) do
    chat_modify(conn, jid, :delete_for_me, %{
      key: message_key,
      timestamp: timestamp,
      delete_media: delete_media?
    })
  end

  defp chat_modify(conn, jid, action, value) do
    AppState.push_patch(conn, action, jid, value)
  end
end
```

### 10.3 Presence

File: `lib/baileys_ex/feature/presence.ex`

```elixir
defmodule BaileysEx.Feature.Presence do
  @type presence :: :available | :unavailable | :composing | :recording | :paused

  def send_presence(conn, presence) do
    node = %BinaryNode{
      tag: "presence",
      attrs: %{"type" => to_string(presence)}
    }
    Connection.Socket.send_node(conn, node)
  end

  def subscribe(conn, jid) do
    node = %BinaryNode{
      tag: "presence",
      attrs: %{"type" => "subscribe", "to" => JID.to_string(jid)}
    }
    Connection.Socket.send_node(conn, node)
  end

  def handle_presence_update(%BinaryNode{tag: "presence"} = node, conn) do
    presence = parse_presence(node)
    EventEmitter.emit(conn, {:presence_update, presence})
  end
end
```

### 10.3a Trusted Contact Tokens (GAP-23)

File: `lib/baileys_ex/feature/tc_token.ex`

Trusted Contact tokens are fetched from the key store and appended to presence
subscribe and profile picture queries. They also feed the direct 1:1 message
relay path in Phase 8. They enable privacy-aware access to profile data and
privacy-sensitive message sends.

```elixir
defmodule BaileysEx.Feature.TcToken do
  @moduledoc """
  Trusted Contact token management. Tokens are stored in the key store
  and attached to presence/profile queries for privacy-aware access.
  """

  @doc "Build TC token child node for a JID (for appending to IQ queries)"
  def build_tc_token_node(conn, jid) do
    case Store.get_key(conn, :tctoken, jid) do
      {:ok, %{token: token}} ->
        %BinaryNode{tag: "tctoken", attrs: %{}, content: token}
      _ ->
        nil
    end
  end

  @doc "Fetch privacy tokens for JIDs from server"
  def get_privacy_tokens(conn, jids) when is_list(jids) do
    timestamp = System.os_time(:second) |> Integer.to_string()

    node = %BinaryNode{
      tag: "iq",
      attrs: %{"to" => "s.whatsapp.net", "type" => "set", "xmlns" => "privacy"},
      content: [
        %BinaryNode{tag: "tokens", attrs: %{}, content:
          Enum.map(jids, fn jid ->
            %BinaryNode{tag: "token", attrs: %{
              "jid" => JID.to_string(jid),
              "t" => timestamp,
              "type" => "trusted_contact"
            }}
          end)
        }
      ]
    }
    Connection.Socket.query(conn, node)
  end

  @doc "Handle privacy_token notification: store received tokens"
  def handle_notification(%BinaryNode{} = node, conn) do
    # Extract trusted_contact tokens from node children
    # Store via Store.set_key(conn, :tctoken, %{jid => %{token: token, timestamp: ts}})
  end
end
```

### 10.3b Bot Directory (GAP-37)

```elixir
# In BaileysEx.Feature module or a utility module:

@doc "Fetch WhatsApp bot directory (AI bots, business bots)"
def get_bot_list(conn) do
  node = %BinaryNode{
    tag: "iq",
    attrs: %{"to" => "s.whatsapp.net", "type" => "get", "xmlns" => "bot"},
    content: [
      %BinaryNode{tag: "list", attrs: %{"v" => "2"}}
    ]
  }

  with {:ok, response} <- Connection.Socket.query(conn, node) do
    bots = parse_bot_list(response)
    {:ok, bots}
    # Returns [%{jid: jid, persona_id: id}]
  end
end
```

Reference: `dev/reference/Baileys-master/src/Socket/chats.ts` L211-244

### 10.4 Privacy settings

File: `lib/baileys_ex/feature/privacy.ex`

All privacy functions use an internal `privacy_query/3` helper that builds IQ nodes
with `xmlns: "privacy"`.

```elixir
defmodule BaileysEx.Feature.Privacy do
  @moduledoc """
  Privacy settings management. Maps 1:1 to Baileys chats.ts privacy functions.
  """

  # --- Fetch all settings ---

  @doc "Fetch all privacy settings from server"
  def fetch_settings(conn, force \\ false) do
    # IQ: xmlns=privacy, type=get
    # Returns map: %{"last" => "contacts", "online" => "all", ...}
  end

  # --- Individual privacy setting updates ---
  # Each maps to a privacy category name sent in the IQ node

  @doc "Who can see your last seen. Values: :all | :contacts | :contact_blacklist | :none"
  def update_last_seen(conn, value), do: privacy_query(conn, "last", value)

  @doc "Online status visibility. Values: :all | :match_last_seen"
  def update_online(conn, value), do: privacy_query(conn, "online", value)

  @doc "Profile picture visibility. Values: :all | :contacts | :contact_blacklist | :none"
  def update_profile_picture(conn, value), do: privacy_query(conn, "profile", value)

  @doc "Status/stories visibility. Values: :all | :contacts | :contact_blacklist | :none"
  def update_status(conn, value), do: privacy_query(conn, "status", value)

  @doc "Read receipts. Values: :all | :none"
  def update_read_receipts(conn, value), do: privacy_query(conn, "readreceipts", value)

  @doc "Who can add you to group calls. Values: :all | :known"
  def update_call_add(conn, value), do: privacy_query(conn, "calladd", value)

  @doc "Who can message you. Values: :all | :contacts"
  def update_messages(conn, value), do: privacy_query(conn, "messages", value)

  @doc "Who can add you to groups. Values: :all | :contacts | :contact_blacklist"
  def update_group_add(conn, value), do: privacy_query(conn, "groupadd", value)

  @doc "Disable server-side link preview generation (Baileys updateDisableLinkPreviewsPrivacy/1)"
  def update_disable_link_previews_privacy(conn, disabled?), do: ...

  @doc "Elixir-friendly alias for update_disable_link_previews_privacy/2"
  def update_link_previews(conn, disabled?), do: update_disable_link_previews_privacy(conn, disabled?)

  # --- Default disappearing mode ---

  @doc "Set default disappearing message duration (seconds, 0 = disabled)"
  def update_default_disappearing_mode(conn, duration) do
    # IQ: xmlns=disappearing_mode, type=set
    # Content: <disappearing_mode duration="86400"/>
  end

  @doc "Fetch disappearing duration for JIDs (USync query)"
  def fetch_disappearing_duration(conn, jids) when is_list(jids), do: ...

  # --- Block list ---

  @doc "Fetch all blocked JIDs"
  def fetch_blocklist(conn) do
    # IQ: xmlns=blocklist, type=get
    # Returns list of JID strings
  end

  @doc "Block or unblock a user"
  def update_block_status(conn, jid, action) when action in [:block, :unblock] do
    # IQ: xmlns=blocklist, type=set
    # Content: <item action="block" jid="..."/>
  end

  # --- Internal ---

  defp privacy_query(conn, category, value) do
    node = %BinaryNode{
      tag: "iq",
      attrs: %{"xmlns" => "privacy", "to" => "s.whatsapp.net", "type" => "set"},
      content: [
        %BinaryNode{tag: "privacy", attrs: %{}, content: [
          %BinaryNode{tag: "category", attrs: %{"name" => category, "value" => to_string(value)}}
        ]}
      ]
    }
    Connection.Socket.query(conn, node)
  end
end
```

### 10.5 App state sync (Syncd)

File: `lib/baileys_ex/feature/app_state.ex`

The Syncd protocol is the most complex feature in this phase. It handles cross-device
state synchronization for mute/pin/star/archive/labels/contacts/settings.

**Baileys reference:** `src/Utils/chat-utils.ts` (all exported functions),
`src/Utils/sync-action-utils.ts`, `src/Socket/chats.ts` (`appPatch`, `resyncAppState`,
`chatModify`).

This task is split into 4 sub-tasks to manage complexity:

#### 10.5a Syncd key expansion + snapshot decode

- `expandAppStateKeys(keydata)` — extract {indexKey, valueEncryptionKey, valueMacKey, snapshotMacKey, patchMacKey} from raw key material
- `decodeAppStateSyncKey(key)` — decode a sync key from protobuf
- `decodeSyncdSnapshot(snapshot, keys)` — decode full app state snapshot, verify MACs
- 5 collection names: `critical_block`, `critical_unblock_low`, `regular_high`, `regular_low`, `regular`

#### 10.5b Syncd patch encode/decode + MAC verification

- `decodeSyncdMutation(mutation)` — decode a single mutation
- `decodeSyncdPatch(patch, keyId, keys)` — decode + verify patch MAC
- `encodeSyncdMutations(mutations, keys)` — encode outbound mutations with MAC
- `generateMac(operation, data, keyId, key)` — HMAC-SHA512(opByte | keyId | data | length[8])

#### 10.5c ChatMutationMap + process patches → emit events

- `ChatMutationMap` — mapping sync action types to chat/contact/label/setting modifications
  covering: pin, mute, archive, star, clear, delete, contact, label, quick reply, settings,
  disappearing mode, link preview privacy, push name, locale, etc.
- `processSyncdPatches(patches, keyId, keys, ...)` — apply mutations, verify LTHash, emit events
- `processContactAction(action, id)` — parse contact action, emit contacts.upsert + lid-mapping.update
- `emitSyncActionResults(ev, results)` — dispatch consolidated results to event emitter

#### 10.5d Full resync + push patch flow

- `processAppStateSyncMessage(message, ...)` — main entry point for incoming app state sync
- `initial_sync(conn)` — fetch snapshots for all 5 collections, apply, verify, emit
- `resyncAppState(conn, collections)` — full resync from server for specified collections
- `push_patch(conn, action, jid, value)` — construct patch, encode, encrypt, send, update local LTHash

```elixir
defmodule BaileysEx.Feature.AppState do
  @collections [:critical_block, :critical_unblock_low, :regular_high, :regular_low, :regular]

  def initial_sync(conn) do
    # Fetch snapshots for all collections
    # Apply patches to local state
    # Verify with LTHash
    # Emit consolidated sync-action results such as:
    #   :contacts_upsert
    #   :lid_mapping_update
    #   :labels_edit / :labels_association
    #   :settings_update
    #   :chats_lock
  end

  def push_patch(conn, action, jid, value) do
    # Construct patch for the appropriate collection
    # Encode, encrypt, send
    # Update local LTHash
  end

  def resync(conn, collections \\ @collections) do
    # Full resync from server for specified collections
    # Re-fetch snapshots, re-apply, re-verify LTHash
  end

  def process_sync_notification(conn, node) do
    # Incoming sync patches from other devices
    # Decrypt, apply, verify LTHash, emit events
    # Uses a pure sync-action mapper similar to Baileys sync-action-utils.ts
  end
end
```

### 10.6 LTHash utility

File: `lib/baileys_ex/util/lt_hash.ex`

```elixir
defmodule BaileysEx.Util.LTHash do
  @doc "Linked Truncated Hash for app state verification"
  def new(hash_size), do: ...
  def add(lt_hash, key, value), do: ...
  def remove(lt_hash, key, value), do: ...
  def verify(lt_hash, expected), do: ...
end
```

### 10.7 Profile management

File: `lib/baileys_ex/feature/profile.ex`

```elixir
defmodule BaileysEx.Feature.Profile do
  @moduledoc """
  Profile management functions. Maps 1:1 to Baileys chats.ts profile functions.
  """

  @doc "Update profile picture (own or group)"
  def update_picture(conn, jid, image_data, dimensions \\ nil) do
    # IQ: xmlns=w:profile:picture, type=set
    # Content: <picture type="image">{binary}</picture>
    # jid param controls: own profile vs group picture
  end

  @doc "Remove profile picture (own or group)"
  def remove_picture(conn, jid) do
    # IQ: xmlns=w:profile:picture, type=set (no content)
  end

  @doc "Get profile picture URL"
  def picture_url(conn, jid, type \\ :preview) when type in [:preview, :image] do
    # IQ: xmlns=w:profile:picture, type=get
    # Content: <picture type="preview|image" query="url"/>
    # Returns {:ok, url} | {:error, :not_found}
  end

  @doc "Update display name (app state sync: pushNameSetting)"
  def update_name(conn, name) do
    AppState.push_patch(conn, :push_name_setting, "", name)
  end

  @doc "Update status text"
  def update_status(conn, status) do
    # IQ: xmlns=status, type=set
    # Content: <status>{utf8 binary}</status>
  end

  @doc "Fetch status text for one or more JIDs (USync query)"
  def fetch_status(conn, jids) when is_list(jids) do
    # USync: protocol=status, mode=query, context=interactive
    # Returns [%{jid: jid, status: text, set_at: datetime}]
  end

  @doc "Get business profile for a JID"
  def get_business_profile(conn, jid) do
    # IQ: xmlns=w:biz, type=get
    # Content: <business_profile v="244"><profile jid="..."/></business_profile>
    # Returns %{address, description, website, email, category, business_hours}
  end
end
```

### 10.8 Label management

File: `lib/baileys_ex/feature/label.ex`

```elixir
defmodule BaileysEx.Feature.Label do
  @moduledoc """
  Label CRUD and association with chats/messages.
  All operations go through app state sync patches.
  """

  @doc "Create or edit a label"
  def add_or_edit(conn, %{id: _, name: _} = label) do
    # App state patch: addLabel
    # Fields: id, name, color (0-19), deleted, predefined_id
    AppState.push_patch(conn, :add_label, "", label)
  end

  @doc "Assign a label to a chat"
  def add_to_chat(conn, jid, label_id) do
    AppState.push_patch(conn, :add_chat_label, jid, %{label_id: label_id})
  end

  @doc "Remove a label from a chat"
  def remove_from_chat(conn, jid, label_id) do
    AppState.push_patch(conn, :remove_chat_label, jid, %{label_id: label_id})
  end

  @doc "Assign a label to a specific message"
  def add_to_message(conn, jid, message_id, label_id) do
    AppState.push_patch(conn, :add_message_label, jid, %{
      message_id: message_id,
      label_id: label_id
    })
  end

  @doc "Remove a label from a specific message"
  def remove_from_message(conn, jid, message_id, label_id) do
    AppState.push_patch(conn, :remove_message_label, jid, %{
      message_id: message_id,
      label_id: label_id
    })
  end
end
```

### 10.9 Contact management

File: `lib/baileys_ex/feature/contact.ex`

```elixir
defmodule BaileysEx.Feature.Contact do
  @moduledoc """
  Contact CRUD via app state sync.
  """

  @doc "Add or edit a contact (syncs across devices)"
  def add_or_edit(conn, jid, %{} = contact_action) do
    # contact_action: %{display_name: "...", first_name: "...", ...}
    AppState.push_patch(conn, :contact, jid, contact_action)
  end

  @doc "Remove a contact"
  def remove(conn, jid) do
    AppState.push_patch(conn, :contact, jid, nil)
  end
end
```

### 10.10 Quick replies

File: `lib/baileys_ex/feature/quick_reply.ex`

```elixir
defmodule BaileysEx.Feature.QuickReply do
  @moduledoc "Quick reply management via app state sync."

  @doc "Create or edit a quick reply"
  def add_or_edit(conn, %{shortcut: _, message: _} = quick_reply) do
    AppState.push_patch(conn, :quick_reply, "", quick_reply)
  end

  @doc "Remove a quick reply by timestamp"
  def remove(conn, timestamp) do
    AppState.push_patch(conn, :quick_reply, "", %{timestamp: timestamp, deleted: true})
  end
end
```

### 10.11 Tests

**Group tests** (`test/baileys_ex/feature/group_test.exs`):
- Group CRUD node construction matches Baileys format
- Participant add/remove/promote/demote nodes
- Invite code get/revoke/accept nodes
- Ephemeral toggle node

**Presence tests** (`test/baileys_ex/feature/presence_test.exs`):
- Presence node construction (available, unavailable)
- Chatstate node construction (composing, recording, paused)
- Presence subscribe node
- Presence update parsing

**Privacy tests** (`test/baileys_ex/feature/privacy_test.exs`):
- Each privacy category produces correct IQ node
- Fetch settings parses response correctly
- Block/unblock IQ construction
- Fetch blocklist response parsing
- Default disappearing mode IQ construction

**Profile tests** (`test/baileys_ex/feature/profile_test.exs`):
- Update picture IQ with binary content
- Remove picture IQ (empty content)
- Picture URL query and response parsing
- Update status IQ construction
- Fetch status USync query construction
- Business profile query and response parsing

**App state tests** (`test/baileys_ex/feature/app_state_test.exs`):
- App state sync patch encoding
- LTHash add/remove/verify
- Chat modify constructs correct patches
- Label patches (add/edit/assign/remove)
- Contact patches (add/edit/remove)
- Quick reply patches

---

## Acceptance Criteria

- [x] Group operations construct correct binary nodes
- [x] Presence updates send and receive correctly
- [x] Chat operations integrate with app state sync
- [ ] **Privacy: all 8 categories** query and update via IQ nodes
- [ ] **Privacy: default disappearing mode** set/fetch
- [ ] **Privacy: block list** fetch/block/unblock
- [ ] App state sync initial fetch works
- [ ] LTHash verification matches Baileys
- [ ] Sync actions emit contacts, LID mappings, labels, settings, and chat-lock updates correctly
- [ ] **Profile: update/remove picture** constructs correct IQ
- [x] **Profile: picture URL** query and response parsing
- [ ] **Profile: update name** via app state sync
- [ ] **Profile: update status text** via IQ
- [ ] **Profile: fetch status** via USync query
- [ ] **Profile: business profile** query and response parsing
- [ ] **Labels: CRUD** via app state patches
- [ ] **Labels: chat/message association** via app state patches
- [ ] **Contacts: add/edit/remove** via app state patches
- [ ] **Quick replies: add/edit/remove** via app state patches
- [x] `on_whatsapp` validates phone numbers via USync contact protocol
- [x] Group setting update (announcement/locked toggles) constructs correct IQ
- [x] Group member add mode and join approval mode supported
- [x] Pending join request list and approve/reject operations work
- [x] V4 invite accept and revoke operations work
- [x] Group dirty updates refetch participating groups, emit `groups.update`, and clean the `groups` bucket
- [x] TC tokens built and attached to presence/profile queries (GAP-23)
- [x] Privacy token notifications stored correctly (GAP-23)
- [x] Bot directory fetched via IQ query (GAP-37)
- [x] Link preview privacy toggle maps to Baileys `updateDisableLinkPreviewsPrivacy/1`
- [x] Group member label update constructs correct protocol message (GAP-39)

## Files Created/Modified

- `lib/baileys_ex/feature/group.ex`
- `lib/baileys_ex/feature/chat.ex`
- `lib/baileys_ex/feature/bot_directory.ex`
- `lib/baileys_ex/feature/presence.ex`
- `lib/baileys_ex/feature/privacy.ex`
- `lib/baileys_ex/feature/profile.ex`
- `lib/baileys_ex/feature/label.ex`
- `lib/baileys_ex/feature/contact.ex`
- `lib/baileys_ex/feature/quick_reply.ex`
- `lib/baileys_ex/feature/app_state.ex`
- `lib/baileys_ex/util/lt_hash.ex`
- `test/baileys_ex/feature/group_test.exs`
- `test/baileys_ex/feature/chat_test.exs`
- `test/baileys_ex/feature/bot_directory_test.exs`
- `test/baileys_ex/feature/phone_validation_test.exs`
- `test/baileys_ex/feature/presence_test.exs`
- `test/baileys_ex/feature/tc_token_test.exs`
- `test/baileys_ex/feature/privacy_test.exs`
- `test/baileys_ex/feature/profile_test.exs`
- `test/baileys_ex/feature/app_state_test.exs`
- `test/baileys_ex/util/lt_hash_test.exs`
- `lib/baileys_ex/feature/phone_validation.ex`
- `lib/baileys_ex/feature/tc_token.ex`
