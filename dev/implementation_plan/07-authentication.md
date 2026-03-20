# Phase 7: Authentication

**Goal:** QR code pairing, phone number pairing, credential persistence, pre-key
upload flow.

**Depends on:** Phase 5 (Signal boundary / key-store contracts), Phase 6 (Connection)
**Blocks:** Phase 8 (Messaging)

**Baileys reference:**
- `src/Utils/auth-utils.ts` — `initAuthCreds`, `makeCacheableSignalKeyStore`, `addTransactionCapability`
- `src/Utils/validate-connection.ts` — `generateLoginNode`, `generateRegistrationNode`, `configureSuccessfulPairing`, `encodeSignedDeviceIdentity`
- `src/Utils/signal.ts` — `createSignalIdentity`, `getPreKeys`, `generateOrGetPreKeys`, `xmppSignedPreKey`, `xmppPreKey`, `parseAndInjectE2ESessions`, `extractDeviceJids`, `getNextPreKeysNode`
- `src/Utils/use-multi-file-auth-state.ts` — file-based persistence reference
- `src/Defaults/index.ts` — `MIN_PREKEY_COUNT=5`, `INITIAL_PREKEY_COUNT=812`, transaction opts

> **Phase 6 note:** the connection-coupled rc.9 QR helpers and `pair-success`
> verification/signing path now live in `Connection.Socket` plus
> `Auth.QR` / `Auth.Pairing`, because Baileys performs that work at the
> socket boundary. Phase 7 still owns the remaining auth surface: the auth
> state struct, persistence backends, phone pairing code flow, and pre-key
> upload / key-store transaction work.
>
> **Phase 15 note:** Phase 7 remains the phase that delivered the swappable
> persistence behaviour and the Baileys-compatible multi-file helper. Later
> persistence architecture work may add a recommended native durable backend
> and simplify the compatibility codec, but that follow-up should not be
> treated as reopening the auth/runtime behaviour accepted here.

---

## Design Decisions

**Persistence as a behaviour.**
Users should be able to store credentials however they want (files, database, etc.).
We provide a default file-based implementation and a behaviour for custom backends.

**Auth state is an Elixir struct.**
Auth credentials are simple key-value data. Keep them in Elixir structs and serialize
them to/from disk. Even if Signal session/state operations are backed by a native
library in Phase 5, the persisted auth envelope and connection-facing data model
should stay ordinary Elixir data.

**v7 auth state must preserve LID-era datasets.**
Baileys v7 treats `lid-mapping`, `device-list`, and `tctoken` as first-class
datasets in the auth/key-store surface. They are not optional extras if we want
current multi-device parity.

---

## Tasks

### 7.1 Auth state struct

File: `lib/baileys_ex/auth/state.ex`

```elixir
defmodule BaileysEx.Auth.State do
  @type t :: %__MODULE__{
    noise_key: %{public: binary(), private: binary()},
    pairing_ephemeral_key: %{public: binary(), private: binary()} | nil,
    signed_identity_key: %{public: binary(), private: binary()},
    signed_pre_key: %{key_pair: map(), key_id: integer(), signature: binary()},
    registration_id: non_neg_integer(),
    adv_secret_key: String.t(),
    next_pre_key_id: non_neg_integer(),
    first_unuploaded_pre_key_id: non_neg_integer(),
    account: map() | nil,
    me: map() | nil,
    signal_identities: [map()],
    platform: String.t() | nil,
    last_account_sync_timestamp: integer() | nil,
    processed_history_messages: [map()],
    account_sync_counter: non_neg_integer(),
    account_settings: %{unarchive_chats: boolean(), default_disappearing_mode: map() | nil},
    registered: boolean(),
    pairing_code: String.t() | nil,
    last_prop_hash: String.t() | nil,
    routing_info: binary() | nil,
    my_app_state_key_id: String.t() | nil,
    additional_data: term() | nil
  }

  defstruct [...]

  def new do
    noise_key = BaileysEx.Signal.Curve.generate_key_pair()
    identity_key = BaileysEx.Signal.Curve.generate_key_pair()
    {:ok, signed_pre_key} = BaileysEx.Signal.Curve.signed_key_pair(identity_key, 1)
    <<registration_id::unsigned-integer-size(16)>> = BaileysEx.Crypto.random_bytes(2)

    %__MODULE__{
      noise_key: noise_key,
      pairing_ephemeral_key: BaileysEx.Signal.Curve.generate_key_pair(),
      signed_identity_key: identity_key,
      signed_pre_key: signed_pre_key,
      registration_id: Bitwise.band(registration_id, 16_383),
      adv_secret_key: BaileysEx.Crypto.random_bytes(32) |> Base.encode64(),
      processed_history_messages: [],
      next_pre_key_id: 1,
      first_unuploaded_pre_key_id: 1,
      account_sync_counter: 0,
      account_settings: %{unarchive_chats: false, default_disappearing_mode: nil},
      registered: false,
      pairing_code: nil,
      last_prop_hash: nil,
      routing_info: nil,
      my_app_state_key_id: nil,
      additional_data: nil
    }
  end
end
```

### 7.2 Persistence behaviour

File: `lib/baileys_ex/auth/persistence.ex`

```elixir
defmodule BaileysEx.Auth.Persistence do
  @callback load_credentials() :: {:ok, Auth.State.t()} | {:error, term()}
  @callback save_credentials(Auth.State.t()) :: :ok | {:error, term()}
  @callback load_keys(type :: atom(), id :: term()) :: {:ok, term()} | {:error, term()}
  @callback save_keys(type :: atom(), id :: term(), data :: term()) :: :ok | {:error, term()}
  @callback delete_keys(type :: atom(), id :: term()) :: :ok | {:error, term()}
end
```

### 7.3 File-based persistence (default)

File: `lib/baileys_ex/auth/file_persistence.ex`

```elixir
defmodule BaileysEx.Auth.FilePersistence do
  @behaviour BaileysEx.Auth.Persistence

  # Missing creds.json initializes fresh credentials, matching
  # Baileys `useMultiFileAuthState`.
  # Each key type/id pair is stored in a separate sanitized JSON file.
  # JSON encoding uses explicit BufferJSON-style binary tagging so the files
  # stay inspectable while round-tripping arbitrary auth/key-store terms.
  # File access is guarded by a per-path mutex; writes use temp-file-then-rename.
end
```

### 7.4 Reuse QR pairing helpers at the auth boundary

Files: `lib/baileys_ex/auth/qr.ex`, `lib/baileys_ex/auth/pairing.ex`

Flow:
1. Phase 6 socket reaches `:authenticating` and emits rc.9 QR updates
2. `Auth.QR` remains the shared payload formatter for `ref,public_key,identity_key,adv_secret`
3. `Auth.QR.generate/2` accepts either raw 32-byte ADV secrets or the persisted base64 string form without double-encoding
4. `Auth.Pairing.configure_successful_pairing/2` remains the `pair-success` verifier/signing helper; the runtime persists the emitted `creds_update` payload around it

```elixir
defmodule BaileysEx.Auth.QR do
  @doc """
  Shared QR payload formatter used by Connection.Socket and auth-facing flows.
  """
  def generate(ref, auth_state) do
    [
      ref,
      Base.encode64(auth_state.noise_key.public),
      Base.encode64(auth_state.signed_identity_key.public),
      auth_state.adv_secret_key
    ]
    |> Enum.join(",")
  end
end
```

### 7.5 Phone number pairing

File: `lib/baileys_ex/auth/phone.ex`

Flow:
1. User calls `Connection.Socket.request_pairing_code/3` while the socket is `:authenticating`
2. `Auth.Phone.build_pairing_request/4` generates or validates the 8-char pairing code, derives the wrapped companion ephemeral key via PBKDF2-SHA256 (131,072 iterations), and builds the `link_code_companion_reg` companion-hello IQ
3. The socket emits `creds_update` with `pairing_code` and `me`, then sends the companion-hello node
4. WhatsApp later sends a `notification/link_code_companion_reg` auth node with the wrapped primary ephemeral key
5. `Auth.Phone.complete_pairing/2` deciphers that payload, derives the new ADV secret, and builds the companion-finish IQ
6. `Connection.Socket` sends the companion-finish node as a query, waits for the server result, and only then emits `creds_update` with `registered: true`

### 7.6 Pre-key upload

Files: `lib/baileys_ex/signal/prekey.ex`, `lib/baileys_ex/connection/socket.ex`, `lib/baileys_ex/connection/supervisor.ex`

Upload pre-keys to WhatsApp server after authentication:
- Check server's pre-key count
- Generate batch of new pre-keys if needed
- Upload via binary node
- Track uploaded key IDs in auth state
- Run the sync inside `Connection.Socket`'s post-success path, before `connection.update(:open)`,
  so the order matches rc.9: `count -> upload_if_required -> passive(active) -> digest -> open`
- Serialize concurrent upload attempts and bound the upload work with the explicit 30s timeout used by Baileys
- Phase 7 currently uses the existing `Signal.Store.Memory` child for runtime pre-key material;
  Phase 7.7 replaces that narrow runtime child with the richer transactional key-store wrapper

### 7.7 Transactional Signal Key Storage (GAP-44)

File: `lib/baileys_ex/auth/key_store.ex`

Baileys wraps Signal key state operations in transactions using `AsyncLocalStorage`,
`p-queue` (concurrency: 1 per key type), and `async-mutex`. This prevents race
conditions and database locks during massive parallel read/write bursts seen in
history sync and group messaging.

Our Elixir approach is a persistence-backed `Signal.Store` implementation:
- ETS read-through cache for hot reads and cached misses
- caller-local transaction context via process dictionary, mirroring the Baileys
  transaction-cache behavior
- per-transaction-key mutexing in the owner process so overlapping history/app-state
  bursts serialize cleanly
- commit retry plus snapshot rollback to restore the previous persisted view if
  a batch write fails
- pre-key deletion safeguards matching Baileys `PreKeyManager`
- runtime injection seam in `Connection.Supervisor` so the connection stack can
  host either the persistent store or the in-memory store

```elixir
defmodule BaileysEx.Auth.KeyStore do
  @behaviour BaileysEx.Signal.Store

  # `start_link/1` accepts a persistence module plus optional context. If the
  # module exports context-aware `load_keys/save_keys/delete_keys` arities
  # (`3/4/3`), the store uses those; otherwise it falls back to the plain
  # `Auth.Persistence` callback arities.
  #
  # Reads:
  #   - hit ETS directly for cached values and cached misses
  #   - load missing ids from persistence and populate ETS
  #
  # Transactions:
  #   - reuse nested transaction contexts
  #   - cache fetched ids in the caller process
  #   - buffer writes until commit
  #   - serialize by transaction key
  #
  # Commits:
  #   - snapshot the previous persisted values for touched ids
  #   - apply writes/deletes
  #   - on failure, restore the previous snapshot and retry
  #
  # Pre-keys:
  #   - outside transactions, only delete ids that actually exist
  #   - inside transactions, only delete ids already present in the transaction cache
end
```

### 7.8 Connection validation (login/registration nodes)

Files: `lib/baileys_ex/auth/connection_validator.ex`,
`lib/baileys_ex/protocol/proto/client_payload_messages.ex`,
`lib/baileys_ex/connection/config.ex`, `lib/baileys_ex/connection/socket.ex`

Constructs login and registration payloads sent after the Noise handshake completes.
These are the first application-level messages exchanged with WhatsApp servers.

```elixir
defmodule BaileysEx.Auth.ConnectionValidator do
  @moduledoc """
  Constructs login and registration payloads sent after Noise handshake.
  """

  # Minimal WAProto coverage for rc.9 handshake payloads now lives in
  # `Protocol.Proto.ClientPayload` and `Protocol.Proto.DeviceProps`.
  #
  # `generate_login_node/2`:
  #   - parses JID user/device into ClientPayload.username/device
  #   - sets passive/pull/lid_db_migrated exactly like rc.9
  #   - builds UserAgent/WebInfo from config.version/country_code/browser
  #
  # `generate_registration_node/2`:
  #   - md5 hashes config.version for devicePairingData.buildHash
  #   - encodes DeviceProps with requireFullSync/historySyncConfig/platformType
  #   - carries registration id, identity key, and signed pre-key bytes
  #
  # `generate_client_payload/2` selects login vs registration from auth_state.me
  # and returns the encoded binary fed into Noise.client_finish/2.
end
```

### 7.9 Pre-key management (advanced)

Files: `lib/baileys_ex/signal/prekey.ex`, `lib/baileys_ex/connection/socket.ex`

Additional pre-key management functions beyond basic upload, covering automatic
replenishment and rotation:

```elixir
# `PreKey.digest_key_bundle/1`:
#   - sends encrypt/get digest
#   - treats a missing digest node as the rc.9 recovery case:
#     upload pre-keys, then return an error
#
# `PreKey.rotate_signed_pre_key/1`:
#   - increments the signed pre-key id
#   - generates a fresh signed pre-key from signed_identity_key
#   - sends encrypt/set rotate<skey>
#   - emits creds_update with the new signed_pre_key
#
# `Connection.Socket` now owns the rc.9 post-auth sequencing:
#   - awaits the passive IQ result before emitting `connection.update(:open)`
#   - runs digest validation after the pre-key upload check
#   - handles low pre-key server notifications without routing them through the wrapper
```

### 7.10 Tests

- [x] Auth state creation with valid crypto keys
- [x] Persistence save/load roundtrip (file-based)
- [x] File persistence binary encoding, sanitized file names, and concurrent write coverage
- [x] QR data generation matches expected format
- [x] Phone pairing PBKDF2 key derivation against test vectors
- [x] Phone pairing companion-hello and companion-finish node coverage
- [x] Pre-key upload node construction
- [x] Connection-socket pre-key upload ordering coverage
- [x] Login payload generation and socket handshake coverage
- [x] Registration payload generation and device-props coverage
- [x] Open-path digest validation coverage
- [x] Signed pre-key rotation coverage
- [x] Explicit pre-key upload timeout coverage
- [x] Transactional key-store persistence, rollback, and cache coverage
- [x] Persistent key-store integration coverage through the connection supervisor

---

## Acceptance Criteria

- [x] New auth state generates valid crypto keys
- [x] File persistence saves and loads credentials correctly
- [x] File persistence serializes binaries safely and guards per-file writes with a mutex
- [x] QR code data format matches WhatsApp expectations
- [x] Phone pairing key derivation matches Baileys output
- [x] Pre-key upload constructs correct binary nodes
- [x] Custom persistence backend can be swapped via behaviour
- [x] Login node constructed correctly for returning users
- [x] Registration node includes device props, history sync config, platform type
- [x] Pair-success HMAC and ADV signature verification passes
- [x] Companion-finish waits for an IQ result before `registered: true` is persisted
- [x] Pre-key upload triggered automatically when server count is low
- [x] Socket delays `connection.update(:open)` until the rc.9 pre-key upload / passive / digest sequence completes
- [x] Signed pre-key rotation works correctly
- [x] Key store transactions serialize concurrent read/write bursts (GAP-44)
- [x] Transaction commits roll back to the previous persisted snapshot on failure (GAP-44)
- [x] Read-through cache prevents redundant persistence lookups during sync
- [x] Key store supports lid-mapping, device-list, identity-key, sender-key-memory, and tctoken datasets

## Files Created/Modified

- `lib/baileys_ex/auth/state.ex`
- `lib/baileys_ex/auth/persistence.ex`
- `lib/baileys_ex/auth/file_persistence.ex`
- `lib/baileys_ex/auth/pairing.ex`
- `lib/baileys_ex/auth/qr.ex`
- `lib/baileys_ex/auth/phone.ex`
- `lib/baileys_ex/auth/connection_validator.ex`
- `lib/baileys_ex/signal/prekey.ex` (extend)
- `lib/baileys_ex/protocol/proto/client_payload_messages.ex`
- `lib/baileys_ex/connection/socket.ex`
- `lib/baileys_ex/connection/config.ex`
- `lib/baileys_ex/connection/coordinator.ex`
- `lib/baileys_ex/connection/supervisor.ex`
- `test/baileys_ex/auth/state_test.exs`
- `test/baileys_ex/auth/file_persistence_test.exs`
- `test/baileys_ex/auth/key_store_test.exs`
- `test/baileys_ex/auth/qr_test.exs`
- `test/baileys_ex/auth/phone_test.exs`
- `test/baileys_ex/auth/connection_validator_test.exs`
- `test/baileys_ex/auth/connection_validator_runtime_test.exs`
- `test/baileys_ex/connection/socket_test.exs`
- `test/baileys_ex/connection/supervisor_test.exs`
- `test/baileys_ex/signal/prekey_test.exs`
- `lib/baileys_ex/auth/key_store.ex`
