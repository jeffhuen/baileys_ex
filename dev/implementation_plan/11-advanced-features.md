# Phase 11: Advanced Features

**Goal:** Business profiles, newsletters, communities, call handling.

**Depends on:** Phase 10 (Features)
**Blocks:** Phase 12 (Polish)

---

## Tasks

### 11.1 Business profiles

File: `lib/baileys_ex/feature/business.ex`

```elixir
defmodule BaileysEx.Feature.Business do
  # --- Profile ---
  def get_profile(conn, jid), do: ...
  def update_profile(conn, profile_data), do: ...
  # profile_data: %{address, email, description, websites: [], hours: %{timezone, days: [%{day, mode, open_time, close_time}]}}

  # --- Cover Photo ---
  def update_cover_photo(conn, photo), do: ...
  def remove_cover_photo(conn, cover_id), do: ...

  # --- Catalog ---
  def get_catalog(conn, opts \\ []), do: ...  # opts: jid, limit, cursor
  def get_collections(conn, jid \\ nil, limit \\ 51), do: ...

  # --- Products ---
  def product_create(conn, product), do: ...
  def product_update(conn, product_id, updates), do: ...
  def product_delete(conn, product_ids) when is_list(product_ids), do: ...

  # --- Orders ---
  def get_order_details(conn, order_id, token), do: ...
end
```

Reference: `dev/reference/Baileys-master/src/Socket/business.ts`

### 11.2 Newsletters

File: `lib/baileys_ex/feature/newsletter.ex`

Newsletter operations use a "WMex" (WhatsApp MEX) query format that is different
from standard IQ queries. WMex queries are JSON-based and sent via a specific
binary node structure rather than the typical XML-like IQ format.

```elixir
defmodule BaileysEx.Feature.Newsletter do
  # --- CRUD ---
  def create(conn, name, description), do: ...
  def delete(conn, newsletter_jid), do: ...
  def update(conn, newsletter_jid, updates), do: ...

  # --- Metadata ---
  def metadata(conn, type, key) when type in [:invite, :jid], do: ...
  def subscribers(conn, newsletter_jid), do: ...
  def admin_count(conn, newsletter_jid), do: ...

  # --- Subscription ---
  def follow(conn, newsletter_jid), do: ...
  def unfollow(conn, newsletter_jid), do: ...
  def mute(conn, newsletter_jid), do: ...
  def unmute(conn, newsletter_jid), do: ...
  def subscribe_updates(conn, newsletter_jid), do: ...

  # --- Content ---
  def fetch_messages(conn, newsletter_jid, count, opts \\ []), do: ...
  def react_message(conn, newsletter_jid, server_id, reaction \\ nil), do: ...

  # --- Profile ---
  def update_name(conn, newsletter_jid, name), do: ...
  def update_description(conn, newsletter_jid, description), do: ...
  def update_picture(conn, newsletter_jid, content), do: ...
  def remove_picture(conn, newsletter_jid), do: ...

  # --- Admin ---
  def change_owner(conn, newsletter_jid, new_owner_jid), do: ...
  def demote(conn, newsletter_jid, user_jid), do: ...
end
```

Reference: `dev/reference/Baileys-master/src/Socket/newsletter.ts`

### 11.3 Communities

File: `lib/baileys_ex/feature/community.ex`

Communities mirror group operations but with additional features for managing
subgroups, linked groups, and community-wide settings.

```elixir
defmodule BaileysEx.Feature.Community do
  # --- CRUD ---
  def create(conn, subject, description), do: ...
  def leave(conn, community_jid), do: ...
  def update_subject(conn, community_jid, subject), do: ...
  def update_description(conn, community_jid, description), do: ...

  # --- Subgroup management ---
  def create_group(conn, subject, participants, parent_community_jid), do: ...
  def link_group(conn, group_jid, parent_community_jid), do: ...
  def unlink_group(conn, group_jid, parent_community_jid), do: ...
  def fetch_linked_groups(conn, community_jid), do: ...

  # --- Participants ---
  def participants_update(conn, community_jid, jids, action), do: ...
  def request_participants_list(conn, community_jid), do: ...
  def request_participants_update(conn, community_jid, jids, action), do: ...

  # --- Invites ---
  def invite_code(conn, community_jid), do: ...
  def revoke_invite(conn, community_jid), do: ...
  def accept_invite(conn, code), do: ...
  def get_invite_info(conn, code), do: ...
  def accept_invite_v4(conn, key, invite_message), do: ...
  def revoke_invite_v4(conn, community_jid, invited_jid), do: ...

  # --- Settings ---
  def toggle_ephemeral(conn, community_jid, expiration), do: ...
  def setting_update(conn, community_jid, setting), do: ...
  def member_add_mode(conn, community_jid, mode), do: ...
  def join_approval_mode(conn, community_jid, mode), do: ...

  # --- Metadata ---
  def metadata(conn, community_jid), do: ...
  def fetch_all_participating(conn), do: ...
end
```

Reference: `dev/reference/Baileys-master/src/Socket/community.ts`

### 11.4 Call handling

File: `lib/baileys_ex/feature/call.ex`

```elixir
defmodule BaileysEx.Feature.Call do
  def handle_call_offer(conn, node) do
    call_info = parse_call_offer(node)
    EventEmitter.emit(conn, {:call, :offer, call_info})
  end

  def reject_call(conn, call_id, caller_jid) do
    node = build_call_reject_node(call_id, caller_jid)
    Connection.Socket.send_node(conn, node)
  end

  @doc "Create a persistent call link (GAP-36)"
  def create_call_link(conn, type, event \\ nil) when type in [:audio, :video] do
    # IQ: xmlns='call', to='@call', type='set'
    # Content: <call> with type and optional scheduled event
    # Returns {:ok, token_string}
    attrs = %{"type" => to_string(type)}
    content = if event do
      [%BinaryNode{tag: "event", attrs: %{"start_time" => to_string(event.start_time)}}]
    else
      nil
    end

    node = %BinaryNode{
      tag: "iq",
      attrs: %{"to" => "@call", "type" => "set", "xmlns" => "call"},
      content: [%BinaryNode{tag: "call", attrs: attrs, content: content}]
    }

    with {:ok, response} <- Connection.Socket.send_node_and_wait(conn, node) do
      {:ok, extract_call_link_token(response)}
    end
  end
end
```

### 11.5 Tests

- Business profile query/response parsing
- Newsletter CRUD node construction
- Community operations
- Call offer/reject node handling

---

## Acceptance Criteria

- [ ] Newsletter: all 19 functions construct correct WMex/IQ nodes
- [ ] Community: all 23 functions construct correct IQ nodes
- [ ] Community: subgroup linking/unlinking works
- [ ] Community: fetch_linked_groups returns correct structure
- [ ] Business: profile update with hours/website arrays
- [ ] Business: cover photo upload via media upload pipeline
- [ ] Business: product CRUD operations
- [ ] Call: reject constructs correct call node
- [ ] Call events emitted correctly
- [ ] All node formats match Baileys reference
- [ ] Call link creation returns token for audio/video with optional event (GAP-36)

## Files Created/Modified

- `lib/baileys_ex/feature/business.ex`
- `lib/baileys_ex/feature/newsletter.ex`
- `lib/baileys_ex/feature/community.ex`
- `lib/baileys_ex/feature/call.ex`
- `test/baileys_ex/feature/business_test.exs`
- `test/baileys_ex/feature/newsletter_test.exs`
- `test/baileys_ex/feature/community_test.exs`
- `test/baileys_ex/feature/call_test.exs`
