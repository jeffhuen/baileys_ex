# Syncd Protocol (10.5a–10.5d) Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the Baileys Syncd (app state sync) pipeline to Elixir — key expansion, LTHash, snapshot/patch encode/decode with MAC verification, sync action mapping, and runtime orchestration.

**Architecture:** Semantic-mirror of Baileys' `chat-utils.ts` and `sync-action-utils.ts`. Pure functions for codec/mapping, existing coordinator/store for runtime. Module decomposition follows Baileys' semantic seams: `Syncd.Keys`, `Syncd.Codec`, `Syncd.ActionMapper`, `Util.LTHash`. Public API stays in `Feature.AppState`.

**Tech Stack:** Elixir/OTP 28, Erlang `:crypto` (HMAC-SHA256/512, AES-256-CBC, SHA-256), HKDF (existing `Crypto.hkdf/4`), hand-written protobuf modules (existing `MessageSupport` pattern).

**Naming convention:** Baileys-close snake_case — `decode_syncd_snapshot`, `encode_syncd_patch`, `process_sync_action`, `expand_app_state_keys`.

---

## Reference Map

| BaileysEx Module | Baileys Source | Functions Ported |
|---|---|---|
| `BaileysEx.Syncd.Keys` | `chat-utils.ts:34-43` | `expand_app_state_keys/1`, `mutation_keys/1` |
| `BaileysEx.Util.LTHash` | `lt-hash.ts` + rust bridge | `new/0`, `subtract_then_add/3` |
| `BaileysEx.Syncd.Codec` | `chat-utils.ts:45-489` | `generate_mac/4`, `generate_snapshot_mac/4`, `generate_patch_mac/5`, `make_lt_hash_generator/1`, `decode_syncd_mutations/5`, `decode_syncd_patch/6`, `decode_syncd_snapshot/5`, `decode_patches/7`, `encode_syncd_patch/4`, `extract_syncd_patches/1`, `chat_modification_to_app_patch/2` |
| `BaileysEx.Syncd.ActionMapper` | `chat-utils.ts:758-974`, `sync-action-utils.ts` | `process_sync_action/4`, `process_contact_action/2`, `emit_sync_action_results/2` |
| `BaileysEx.Protocol.Proto.Syncd` | `WAProto.proto:4953-5001` | Protobuf encode/decode for SyncdSnapshot, SyncdPatch, SyncdMutation, SyncdRecord, SyncdIndex, SyncdValue, SyncdVersion, SyncdMutations, SyncActionData, SyncActionValue (30+ action types), ExternalBlobReference, KeyId |
| `BaileysEx.Feature.AppState` | `chats.ts:465-853` | `resync_app_state/3`, `app_patch/2`, `chat_modify/3` |

## Crypto Operations (exact Baileys parity)

| Function | Algorithm | Input Format | Output |
|---|---|---|---|
| `generate_mac/4` | HMAC-SHA512 | `(op_byte \|\| key_id) \|\| enc_value \|\| (8-byte length)` | First 32 bytes |
| `generate_snapshot_mac/4` | HMAC-SHA256 | `lt_hash \|\| version_64bit_be \|\| name_utf8` | 32 bytes |
| `generate_patch_mac/5` | HMAC-SHA256 | `snapshot_mac \|\| value_macs... \|\| version_64bit_be \|\| name_utf8` | 32 bytes |
| `expand_app_state_keys/1` | HKDF-SHA256 | ikm=keydata, salt=empty, info="WhatsApp Mutation Keys", len=160 | 5 × 32-byte keys |
| Value encrypt | AES-256-CBC | Random 16-byte IV prepended to ciphertext | `IV \|\| ciphertext` |
| Value decrypt | AES-256-CBC | Split first 16 bytes as IV | plaintext |
| Index MAC | HMAC-SHA256 | `JSON.stringify(index)` | 32 bytes |
| LTHash expand | SHA-256 × 4 | `SHA-256(i \|\| valueMac)` for i=0..3, concatenated | 128 bytes |
| LTHash update | uint16 LE add/sub | 64 uint16 values, wrapping arithmetic | 128-byte hash |

## Proto Enum Values

- `SyncdOperation.SET = 0` (proto), `0x01` in MAC input
- `SyncdOperation.REMOVE = 1` (proto), `0x02` in MAC input

## File Structure

### New files
| File | Responsibility | ~Lines |
|---|---|---|
| `lib/baileys_ex/protocol/proto/syncd_messages.ex` | Protobuf encode/decode for all Syncd wire types | ~500 |
| `lib/baileys_ex/syncd/keys.ex` | Key expansion (HKDF → 5 subkeys) | ~60 |
| `lib/baileys_ex/util/lt_hash.ex` | LTHash anti-tampering algorithm | ~80 |
| `lib/baileys_ex/syncd/codec.ex` | MAC gen/verify, encode/decode snapshot/patch/mutations, LTHash generator | ~400 |
| `lib/baileys_ex/syncd/action_mapper.ex` | processSyncAction, processContactAction, 25+ action handlers | ~300 |
| `test/baileys_ex/syncd/keys_test.exs` | Key expansion pinned vectors | ~60 |
| `test/baileys_ex/util/lt_hash_test.exs` | LTHash add/subtract/roundtrip | ~80 |
| `test/baileys_ex/syncd/codec_test.exs` | MAC generation, encode/decode roundtrip, snapshot/patch decode | ~300 |
| `test/baileys_ex/syncd/action_mapper_test.exs` | All 25+ sync action types → event mapping | ~250 |

### Modified files
| File | Changes |
|---|---|
| `lib/baileys_ex/feature/app_state.ex` | Add `resync_app_state/3`, `app_patch/2`, refactor existing patch builder to use `chat_modification_to_app_patch/2` |
| `lib/baileys_ex/connection/store.ex` | Add `app-state-sync-version` and `app-state-sync-key` storage |
| `lib/baileys_ex/connection/coordinator.ex` | Route incoming app state sync notifications to AppState |

---

## Task 1: Protobuf Types + Key Expansion + LTHash (10.5a)

**Files:**
- Create: `lib/baileys_ex/protocol/proto/syncd_messages.ex`
- Create: `lib/baileys_ex/syncd/keys.ex`
- Create: `lib/baileys_ex/util/lt_hash.ex`
- Create: `test/baileys_ex/syncd/keys_test.exs`
- Create: `test/baileys_ex/util/lt_hash_test.exs`

### Proto messages needed

From `WAProto.proto`:
```
KeyId { optional bytes id = 1 }
SyncdIndex { optional bytes blob = 1 }
SyncdValue { optional bytes blob = 1 }
SyncdVersion { optional uint64 version = 1 }
SyncdRecord { optional SyncdIndex index = 1; optional SyncdValue value = 2; optional KeyId keyId = 3 }
SyncdMutation { optional SyncdOperation operation = 1; optional SyncdRecord record = 2; enum SyncdOperation { SET = 0; REMOVE = 1 } }
SyncdMutations { repeated SyncdMutation mutations = 1 }
SyncdPatch { optional SyncdVersion version = 1; repeated SyncdMutation mutations = 2; optional ExternalBlobReference externalMutations = 3; optional bytes snapshotMac = 4; optional bytes patchMac = 5; optional KeyId keyId = 6; optional ExitCode exitCode = 7; optional uint32 deviceIndex = 8; optional bytes clientDebugData = 9 }
SyncdSnapshot { optional SyncdVersion version = 1; repeated SyncdRecord records = 2; optional bytes mac = 3; optional KeyId keyId = 4 }
ExternalBlobReference { optional bytes mediaKey = 1; optional string directPath = 2; optional string handle = 3; optional uint64 fileSizeBytes = 4; optional bytes fileSha256 = 5; optional bytes fileEncSha256 = 6 }
SyncActionData { optional bytes index = 1; optional SyncActionValue value = 2; optional bytes padding = 3; optional int32 version = 4 }
SyncActionValue { optional int64 timestamp = 1; optional StarAction starAction = 2; optional ContactAction contactAction = 3; optional MuteAction muteAction = 4; optional PinAction pinAction = 5; ... (30+ fields) }
```

Note: `SyncActionValue` has 30+ optional action fields. For 10.5a, implement the outer Syncd types (SyncdPatch, SyncdSnapshot, SyncdMutation, SyncdRecord, SyncActionData) and a minimal SyncActionValue that decodes the raw bytes for individual action types. Full SyncActionValue field coverage comes in 10.5c when ActionMapper needs them.

### Steps

- [ ] **Step 1: Write proto encode/decode tests for core Syncd types**

Test that SyncdPatch, SyncdSnapshot, SyncdMutation, SyncdRecord roundtrip correctly. Use hand-constructed binaries matching protobuf wire format.

Run: `mix test test/baileys_ex/protocol/proto/syncd_messages_test.exs`
Expected: FAIL (module doesn't exist)

- [ ] **Step 2: Implement Syncd protobuf modules**

Create `lib/baileys_ex/protocol/proto/syncd_messages.ex` using the existing `MessageSupport` pattern (see `message_messages.ex` for reference). Hand-write encode/decode for: `KeyId`, `SyncdIndex`, `SyncdValue`, `SyncdVersion`, `SyncdRecord`, `SyncdMutation`, `SyncdMutations`, `SyncdPatch`, `SyncdSnapshot`, `ExternalBlobReference`, `SyncActionData`.

For `SyncActionValue`: implement as a struct with all 30+ optional fields, but only encode/decode the fields needed by ActionMapper. Use the existing `MessageSupport.encode_fields/2` and `decode_fields/3` pattern.

Run: `mix test test/baileys_ex/protocol/proto/syncd_messages_test.exs`
Expected: PASS

- [ ] **Step 3: Write key expansion tests with pinned vectors**

Test `expand_app_state_keys/1` with a known 32-byte input. Pin the 5 output keys as literal binaries. Verify HKDF parameters: salt=empty, info="WhatsApp Mutation Keys", length=160.

Run: `mix test test/baileys_ex/syncd/keys_test.exs`
Expected: FAIL (module doesn't exist)

- [ ] **Step 4: Implement Syncd.Keys**

```elixir
defmodule BaileysEx.Syncd.Keys do
  # Ports: chat-utils.ts:34-43 (mutationKeys + expandAppStateKeys)
  alias BaileysEx.Crypto

  @hkdf_info "WhatsApp Mutation Keys"
  @key_length 160  # 5 × 32 bytes

  @type t :: %{
    index_key: <<_::256>>,
    value_encryption_key: <<_::256>>,
    value_mac_key: <<_::256>>,
    snapshot_mac_key: <<_::256>>,
    patch_mac_key: <<_::256>>
  }

  @spec expand_app_state_keys(binary()) :: t()
  def expand_app_state_keys(key_data) when byte_size(key_data) == 32 do
    {:ok, expanded} = Crypto.hkdf(key_data, @hkdf_info, @key_length)
    <<index_key::binary-32, value_encryption_key::binary-32,
      value_mac_key::binary-32, snapshot_mac_key::binary-32,
      patch_mac_key::binary-32>> = expanded
    %{
      index_key: index_key,
      value_encryption_key: value_encryption_key,
      value_mac_key: value_mac_key,
      snapshot_mac_key: snapshot_mac_key,
      patch_mac_key: patch_mac_key
    }
  end

  @spec mutation_keys(binary()) :: t()
  def mutation_keys(key_data), do: expand_app_state_keys(key_data)
end
```

Run: `mix test test/baileys_ex/syncd/keys_test.exs`
Expected: PASS

- [ ] **Step 5: Write LTHash tests**

Test:
- `new/0` returns 128 zero bytes
- `subtract_then_add/3` with known valueMacs produces expected hash
- Adding then subtracting same value returns to original hash (roundtrip)
- Multiple operations accumulate correctly

Run: `mix test test/baileys_ex/util/lt_hash_test.exs`
Expected: FAIL

- [ ] **Step 6: Implement LTHash**

The LTHash anti-tampering algorithm:
1. Expand each 32-byte valueMac to 128 bytes: `SHA-256(0 || mac) || SHA-256(1 || mac) || SHA-256(2 || mac) || SHA-256(3 || mac)`
2. Treat 128-byte state and expansion as arrays of 64 uint16 LE values
3. Subtract sub_buffs, then add add_buffs (wrapping uint16 arithmetic)

```elixir
defmodule BaileysEx.Util.LTHash do
  # Ports: lt-hash.ts (LTHashAntiTampering from whatsapp-rust-bridge)

  @hash_size 128  # bytes
  @spec new() :: <<_::1024>>
  def new, do: <<0::size(@hash_size * 8)>>

  @spec subtract_then_add(binary(), [binary()], [binary()]) :: binary()
  def subtract_then_add(hash, sub_buffs, add_buffs) do
    hash
    |> subtract_all(sub_buffs)
    |> add_all(add_buffs)
  end
end
```

Run: `mix test test/baileys_ex/util/lt_hash_test.exs`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add lib/baileys_ex/protocol/proto/syncd_messages.ex \
        lib/baileys_ex/syncd/keys.ex \
        lib/baileys_ex/util/lt_hash.ex \
        test/baileys_ex/syncd/keys_test.exs \
        test/baileys_ex/util/lt_hash_test.exs \
        test/baileys_ex/protocol/proto/syncd_messages_test.exs
git commit -m "feat(syncd): add protobuf types, key expansion, and LTHash (10.5a)"
```

---

## Task 2: Patch Encode/Decode + MAC Verification (10.5b)

**Files:**
- Create: `lib/baileys_ex/syncd/codec.ex`
- Create: `test/baileys_ex/syncd/codec_test.exs`

### Steps

- [ ] **Step 1: Write MAC generation tests with pinned vectors**

Test all three MAC functions with known inputs, pin the output bytes:
- `generate_mac/4` — HMAC-SHA512 with operation byte + keyId + data + length, truncated to 32 bytes
- `generate_snapshot_mac/4` — HMAC-SHA256 with lthash + version_64be + name_utf8
- `generate_patch_mac/5` — HMAC-SHA256 with snapshot_mac + value_macs + version_64be + name_utf8

Run: `mix test test/baileys_ex/syncd/codec_test.exs`
Expected: FAIL

- [ ] **Step 2: Implement MAC generation functions**

Port exact Baileys MAC input construction:

```elixir
# generate_mac: chat-utils.ts:45-67
def generate_mac(operation, data, key_id, key) do
  op_byte = if operation == :set, do: 0x01, else: 0x02
  key_id_bin = ensure_binary(key_id)
  key_data = <<op_byte, key_id_bin::binary>>
  last = <<0::56, byte_size(key_data)::8>>
  total = key_data <> data <> last
  :crypto.mac(:hmac, :sha512, key, total) |> binary_part(0, 32)
end
```

Run: `mix test test/baileys_ex/syncd/codec_test.exs`
Expected: PASS (MAC tests)

- [ ] **Step 3: Write encode/decode roundtrip tests**

Test `encode_syncd_patch/4`:
- Provide deterministic inputs: key_data, index, sync_action, api_version, operation
- Inject deterministic IV for AES-CBC (via opts)
- Verify output patch structure: patchMac, snapshotMac, keyId, mutations[0].record
- Verify roundtrip: encode then decode recovers original sync_action

Test `decode_syncd_mutations/5`:
- Construct a valid encrypted mutation (AES-CBC encrypt + MAC)
- Decode and verify recovered SyncActionData matches original
- Verify LTHash state updates correctly

Run: `mix test test/baileys_ex/syncd/codec_test.exs`
Expected: FAIL

- [ ] **Step 4: Implement LTHash generator (make_lt_hash_generator)**

Port `chat-utils.ts:77-112`:
```elixir
def make_lt_hash_generator(%{hash: hash, index_value_map: index_value_map}) do
  # Returns {mix_fn, finish_fn} or a struct with mix/finish
  # mix/1 takes %{index_mac:, value_mac:, operation:}
  # finish/0 returns %{hash:, index_value_map:}
end
```

Use an Agent or accumulator pattern — or since this is called synchronously in a pipeline, use a simple reduce with accumulator state.

- [ ] **Step 5: Implement decode_syncd_mutations**

Port `chat-utils.ts:197-270`. For each mutation:
1. Extract operation (SET/REMOVE) and record
2. Fetch decryption key via callback
3. Split value blob: `enc_content = blob[0..-33]`, `value_mac = blob[-32..]`
4. If validate_macs: verify value MAC via `generate_mac/4`
5. AES-256-CBC decrypt: first 16 bytes of enc_content is IV
6. Decode protobuf SyncActionData
7. If validate_macs: verify index MAC via HMAC-SHA256
8. Parse index as JSON array
9. Call on_mutation callback
10. Mix into LTHash generator

- [ ] **Step 6: Implement decode_syncd_patch**

Port `chat-utils.ts:272-304`:
1. If validate_macs: verify patch MAC
2. Call decode_syncd_mutations for all mutations
3. Return updated LTHash state

- [ ] **Step 7: Implement decode_syncd_snapshot**

Port `chat-utils.ts:374-420`:
1. Create fresh LTHash state, set version
2. Decode all records via decode_syncd_mutations
3. If validate_macs: verify snapshot MAC
4. Return state + mutation_map

- [ ] **Step 8: Implement decode_patches (sequence)**

Port `chat-utils.ts:422-489`:
1. For each patch in sequence: update version, decode, verify snapshot MAC chain
2. State accumulates across patches
3. Return final state + mutation_map

- [ ] **Step 9: Implement encode_syncd_patch**

Port `chat-utils.ts:132-195`:
1. Fetch encryption key
2. Encode SyncActionData protobuf
3. Derive 5 keys via mutation_keys
4. AES-256-CBC encrypt with random IV (injectable)
5. Generate value MAC, index MAC
6. Update LTHash
7. Generate snapshot MAC, patch MAC
8. Build SyncdPatch protobuf
9. Return {patch, state}

- [ ] **Step 10: Run full test suite**

Run: `mix format --check-formatted && mix compile --warnings-as-errors && mix test`
Expected: PASS

- [ ] **Step 11: Commit**

```bash
git add lib/baileys_ex/syncd/codec.ex test/baileys_ex/syncd/codec_test.exs
git commit -m "feat(syncd): add codec — MAC gen/verify, encode/decode snapshot/patch (10.5b)"
```

---

## Task 3: Sync Action Mapping (10.5c)

**Files:**
- Create: `lib/baileys_ex/syncd/action_mapper.ex`
- Create: `test/baileys_ex/syncd/action_mapper_test.exs`
- Modify: `lib/baileys_ex/protocol/proto/syncd_messages.ex` (add remaining SyncActionValue fields)

### Sync Action Types (from chat-utils.ts:758-974)

| SyncAction Field | Event Emitted | Index Format |
|---|---|---|
| `mute_action` | `chats_update` | `["mute", jid]` |
| `archive_chat_action` | `chats_update` | `["archive", jid]` |
| `mark_chat_as_read_action` | `chats_update` | `["markChatAsRead", jid]` |
| `delete_message_for_me_action` | `messages_delete` | `["deleteMessageForMe", jid, msgId, fromMe]` |
| `contact_action` | `contacts_upsert` + `lid_mapping_update` | `["contact", jid]` |
| `push_name_setting` | `creds_update` | `["setting_pushName"]` |
| `pin_action` | `chats_update` | `["pin_v1", jid]` |
| `unarchive_chats_setting` | `creds_update` | n/a |
| `star_action` | `messages_update` | `["star", jid, msgId, fromMe, "0"]` |
| `delete_chat_action` | `chats_delete` | `["deleteChat", jid, "1"]` |
| `clear_chat_action` | (no event — handled by chat ops) | `["clearChat", jid, "1", "0"]` |
| `label_edit_action` | `labels_edit` | `["label_edit", id]` |
| `label_association_action` | `labels_association` | `["label_chat", labelId, jid]` or `["label_message", ...]` |
| `locale_setting` | `settings_update` | n/a |
| `time_format_action` | `settings_update` | n/a |
| `pn_for_lid_chat_action` | `lid_mapping_update` | n/a |
| `privacy_setting_relay_all_calls` | `settings_update` | n/a |
| `status_privacy` | `settings_update` | n/a |
| `lock_chat_action` | `chats_lock` | n/a |
| `privacy_setting_disable_link_previews_action` | `settings_update` | n/a |
| `notification_activity_setting_action` | `settings_update` | n/a |
| `lid_contact_action` | `contacts_upsert` | n/a |
| `privacy_setting_channels_personalised_recommendation_action` | `settings_update` | n/a |

### Steps

- [ ] **Step 1: Add remaining SyncActionValue fields to proto module**

Add encode/decode for all action sub-messages: MuteAction, PinAction, StarAction, ContactAction, ArchiveChatAction, MarkChatAsReadAction, DeleteMessageForMeAction, DeleteChatAction, ClearChatAction, LabelEditAction, LabelAssociationAction, PushNameSetting, QuickReplyAction, UnarchiveChatsSetting, LocaleSetting, TimeFormatAction, PnForLidChatAction, LockChatAction, and the privacy setting actions.

- [ ] **Step 2: Write action mapper tests — one test per sync action type**

For each of the 23+ action types, construct a ChatMutation with the appropriate sync_action and index, call `process_sync_action/4`, and verify the emitted event type and payload.

Run: `mix test test/baileys_ex/syncd/action_mapper_test.exs`
Expected: FAIL

- [ ] **Step 3: Implement process_sync_action/4**

Port `chat-utils.ts:758-974`. Pattern match on the SyncActionValue fields. Each branch emits the corresponding event.

- [ ] **Step 4: Implement process_contact_action/2**

Port `sync-action-utils.ts:22-64`. Returns list of `{:contacts_upsert, data}` and optionally `{:lid_mapping_update, data}`.

- [ ] **Step 5: Implement emit_sync_action_results/2**

Port `sync-action-utils.ts:66-74`. Dispatch results to event emitter.

- [ ] **Step 6: Write chat_modification_to_app_patch tests**

Verify all 17 modification types produce correct WAPatchCreate structures matching Baileys `chatModificationToAppPatch`.

- [ ] **Step 7: Move/refactor chat_modification_to_app_patch into Codec**

Port `chat-utils.ts:491-756` — the full `chatModificationToAppPatch` function with all 17 modification types. This replaces the existing `patch_for/3` clauses in `app_state.ex` with the authoritative Baileys implementation. Include message range validation.

- [ ] **Step 8: Run full test suite**

Run: `mix format --check-formatted && mix compile --warnings-as-errors && mix test`
Expected: PASS

- [ ] **Step 9: Commit**

```bash
git add lib/baileys_ex/syncd/action_mapper.ex \
        test/baileys_ex/syncd/action_mapper_test.exs \
        lib/baileys_ex/protocol/proto/syncd_messages.ex
git commit -m "feat(syncd): add action mapper — 23+ sync action types to events (10.5c)"
```

---

## Task 4: Runtime Orchestration (10.5d)

**Files:**
- Modify: `lib/baileys_ex/feature/app_state.ex`
- Modify: `lib/baileys_ex/connection/store.ex`
- Modify: `lib/baileys_ex/connection/coordinator.ex`
- Create: `test/baileys_ex/syncd/runtime_test.exs`

### Steps

- [ ] **Step 1: Extend Store for app-state-sync-version and app-state-sync-key**

Add key type support for:
- `"app-state-sync-version"` — stores `%{version:, hash:, index_value_map:}` per collection
- `"app-state-sync-key"` — stores `%{key_data:}` per keyId

- [ ] **Step 2: Implement resync_app_state/3**

Port `chats.ts:479-632`:
1. Cache key lookups
2. For each collection: get current version, build IQ request
3. Send query, extract patches via `Syncd.Codec.extract_syncd_patches/1`
4. If snapshot: decode via `decode_syncd_snapshot/5`
5. If patches: decode via `decode_patches/7`
6. Persist updated state
7. Retry on failure (max 2 attempts)
8. After all collections: call `process_sync_action/4` for each mutation

- [ ] **Step 3: Implement app_patch/2**

Port `chats.ts:779-853`:
1. Get my app state key ID from creds
2. Serialize patches (mutex equivalent — use a serialized call through coordinator or a dedicated process)
3. Resync before patching
4. Encode patch via `Syncd.Codec.encode_syncd_patch/4`
5. Build and send IQ node
6. Persist updated state
7. If emit_own_events: decode own patch and emit

- [ ] **Step 4: Refactor Feature.AppState public API**

Update `push_patch/5` to call `app_patch/2` when given a connection. Keep `build_patch/4` for pure patch construction. Add `chat_modify/3` as the high-level entry point (calls `chat_modification_to_app_patch/2` then `app_patch/2`).

- [ ] **Step 5: Route incoming app state sync notifications**

In coordinator, handle incoming `notification` nodes with `type="encrypt"` that contain `AppStateSyncKeyShare` messages. Store the keys via Store. Also handle incoming sync patches from other devices.

- [ ] **Step 6: Write runtime integration tests**

Test the full flow with mock socket/store:
- `resync_app_state/3` with mock server response
- `app_patch/2` sends correct IQ and persists state
- Incoming sync notification stores keys and emits events

Run: `mix format --check-formatted && mix compile --warnings-as-errors && mix test`
Expected: PASS

- [ ] **Step 7: Run full delivery gates**

```bash
mix format --check-formatted && \
mix compile --warnings-as-errors && \
mix test && \
mix credo --all && \
mix dialyzer && \
mix docs
```

- [ ] **Step 8: Commit**

```bash
git add lib/baileys_ex/feature/app_state.ex \
        lib/baileys_ex/connection/store.ex \
        lib/baileys_ex/connection/coordinator.ex \
        test/baileys_ex/syncd/runtime_test.exs
git commit -m "feat(syncd): add runtime orchestration — resync, push, incoming sync (10.5d)"
```

- [ ] **Step 9: Update PROGRESS.md**

Mark 10.5a, 10.5b, 10.5c, 10.5d as complete. Update acceptance criteria checkboxes.

---

## Dependencies Between Tasks

```
Task 1 (10.5a): Proto + Keys + LTHash
    ↓
Task 2 (10.5b): Codec (depends on proto, keys, lthash)
    ↓
Task 3 (10.5c): ActionMapper (depends on proto SyncActionValue fields, codec for chat_modification_to_app_patch)
    ↓
Task 4 (10.5d): Runtime (depends on codec + action_mapper + store)
```

Tasks are strictly sequential — each builds on the previous.
