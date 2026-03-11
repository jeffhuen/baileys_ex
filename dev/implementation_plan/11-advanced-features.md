# Phase 11: Advanced Features

**Goal:** Business operations, newsletters, communities, call handling.

**Depends on:** Phase 10 (Features)
**Blocks:** Phase 12 (Polish)

**Baileys reference:**
- `src/Socket/business.ts` — 9 functions (catalog, products, orders, cover photo)
- `src/Socket/newsletter.ts` — 19 functions (mixed WMex/IQ/message transport)
- `src/Socket/communities.ts` — 24 functions (mirrors groups.ts structure)
- `src/Socket/messages-recv.ts` — `handleCall` (call event handling)
- `src/Socket/chats.ts` — `createCallLink` (call link creation)
- `src/Utils/business.ts` — node builders/parsers for catalog/product/order data

Community functions are structurally identical to group functions (same IQ patterns,
different namespace). Newsletter uses WMex GraphQL for most operations. Both are
mostly mechanical porting once the connection transport layer works.

---

## Tasks

### 11.1 Business operations

File: `lib/baileys_ex/feature/business.ex`

```elixir
defmodule BaileysEx.Feature.Business do
  # `get_business_profile/2` lives in Phase 10 because Baileys exposes it from
  # chats.ts, not business.ts.

  # --- Profile update ---
  def update_business_profile(conn, profile_data), do: ...
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

Newsletter operations use mixed transports in the Baileys reference:

- Most metadata/update/admin calls use WMex (`src/Socket/mex.ts`)
- `fetch_messages/4` and `subscribe_updates/2` use `xmlns: "newsletter"` IQ queries
- `react_message/4` uses a direct `message` stanza with `type="reaction"`

The Elixir plan should keep one public feature module, but the wire format must
match the correct transport for each operation.

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
  # Must handle both a community JID and a subgroup JID, matching Baileys' auto-detection

  # --- Participants ---
  def participants_update(conn, community_jid, jids, action), do: ...
  # action: :add | :remove | :promote | :demote
  # remove must include the linked_groups cascade flag like Baileys communities.ts
  def request_participants_list(conn, community_jid), do: ...
  def request_participants_update(conn, community_jid, jids, action), do: ...
  # action: :approve | :reject

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
  # join approval uses a `membership_approval_mode` node with `community_join`

  # --- Metadata ---
  def metadata(conn, community_jid), do: ...
  def fetch_all_participating(conn), do: ...
end
```

Wire a community dirty-update handler from Phase 6 `dirty_update` events so
`type="communities"` refetches participating communities, emits `groups.update`,
and cleans the `groups` bucket the same way rc.9 does in `communities.ts`.

Reference: `dev/reference/Baileys-master/src/Socket/communities.ts`

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

  @doc "Create a persistent call link (Baileys createCallLink/3)"
  def create_call_link(conn, type, opts \\ []) when type in [:audio, :video] do
    event = Keyword.get(opts, :event)
    timeout_ms = Keyword.get(opts, :timeout_ms)

    node = %BinaryNode{
      tag: "call",
      attrs: %{"to" => "@call"},
      content: [
        %BinaryNode{
          tag: "link_create",
          attrs: %{"media" => to_string(type)},
          content:
            if event do
              [%BinaryNode{tag: "event", attrs: %{"start_time" => to_string(event.start_time)}}]
            end
        }
      ]
    }

    with {:ok, response} <- Connection.Socket.query(conn, node, timeout_ms) do
      {:ok, extract_link_create_token(response)}
    end
  end
end
```

### 11.5 Tests

- Business update/catalog/order node construction and response parsing
- Newsletter CRUD node construction
- Community operations
- Call offer/reject node handling

---

## Acceptance Criteria

- [ ] Newsletter: all exported newsletter operations construct correct WMex/IQ/message nodes
- [ ] Community: all exported community operations construct correct IQ nodes
- [ ] Community: subgroup linking/unlinking works
- [ ] Community: fetch_linked_groups returns correct structure
- [ ] Community dirty updates refetch participating communities, emit `groups.update`, and clean the `groups` bucket
- [ ] Business: profile update with hours/website arrays
- [ ] Business: cover photo upload via media upload pipeline
- [ ] Business: product CRUD operations
- [ ] Business: order-details query uses the `fb:thrift_iq` namespace from Baileys
- [ ] Call: reject constructs correct call node
- [ ] Call events emitted correctly
- [ ] All node formats match Baileys reference
- [ ] Call link creation uses `call/link_create` and returns token for audio/video with optional event (GAP-36)

## Files Created/Modified

- `lib/baileys_ex/feature/business.ex`
- `lib/baileys_ex/feature/newsletter.ex`
- `lib/baileys_ex/feature/community.ex`
- `lib/baileys_ex/feature/call.ex`
- `test/baileys_ex/feature/business_test.exs`
- `test/baileys_ex/feature/newsletter_test.exs`
- `test/baileys_ex/feature/community_test.exs`
- `test/baileys_ex/feature/call_test.exs`
