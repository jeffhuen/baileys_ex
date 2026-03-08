# Phase 7: Authentication

**Goal:** QR code pairing, phone number pairing, credential persistence, pre-key
upload flow.

**Depends on:** Phase 5 (Signal / libsignal native layer), Phase 6 (Connection)
**Blocks:** Phase 8 (Messaging)

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
    adv_secret_key: binary(),
    next_pre_key_id: non_neg_integer(),
    first_unuploaded_pre_key_id: non_neg_integer(),
    server_has_pre_keys: boolean(),
    account: map() | nil,
    me: JID.t() | nil,
    signal_identities: [map()],
    platform: String.t() | nil,
    last_account_sync_timestamp: integer() | nil,
    my_app_state_key_id: String.t() | nil
  }

  defstruct [...]

  def new do
    noise_key = BaileysEx.Crypto.generate_key_pair()
    identity_key = BaileysEx.Crypto.generate_key_pair()
    signed_pre_key = BaileysEx.Crypto.signed_key_pair(identity_key)
    registration_id = :rand.uniform(16380) + 1

    %__MODULE__{
      noise_key: noise_key,
      signed_identity_key: identity_key,
      signed_pre_key: %{key_pair: signed_pre_key, key_id: 1, signature: signed_pre_key.signature},
      registration_id: registration_id,
      adv_secret_key: BaileysEx.Crypto.random_bytes(32),
      next_pre_key_id: 1,
      first_unuploaded_pre_key_id: 1,
      server_has_pre_keys: false
    }
  end
end
```

### 7.2 Persistence behaviour

File: `lib/baileys_ex/auth/persistence.ex`

```elixir
defmodule BaileysEx.Auth.Persistence do
  @callback load_credentials() :: {:ok, Auth.State.t()} | {:error, :not_found}
  @callback save_credentials(Auth.State.t()) :: :ok | {:error, term()}
  @callback load_keys(type :: atom(), id :: term()) :: {:ok, binary()} | {:error, :not_found}
  @callback save_keys(type :: atom(), id :: term(), data :: binary()) :: :ok
  @callback delete_keys(type :: atom(), id :: term()) :: :ok
end
```

### 7.3 File-based persistence (default)

File: `lib/baileys_ex/auth/file_persistence.ex`

```elixir
defmodule BaileysEx.Auth.FilePersistence do
  @behaviour BaileysEx.Auth.Persistence

  # Stores each key type in a separate file within a directory
  # Uses :erlang.term_to_binary / :erlang.binary_to_term for serialization
  # Atomic writes via write-to-temp-then-rename pattern
end
```

### 7.4 QR code pairing

File: `lib/baileys_ex/auth/qr.ex`

Flow:
1. Connection reaches `:authenticating` state
2. Server sends QR challenge data
3. Generate QR payload: `ref,public_key,identity_key,adv_secret`
4. Emit `:qr` event with payload (and optionally render to terminal)
5. Wait for server confirmation
6. On success: extract credentials, transition to `:connected`

```elixir
defmodule BaileysEx.Auth.QR do
  def generate_qr_data(ref, auth_state) do
    [
      ref,
      Base.encode64(auth_state.noise_key.public),
      Base.encode64(auth_state.signed_identity_key.public),
      Base.encode64(auth_state.adv_secret_key)
    ]
    |> Enum.join(",")
  end

  def handle_qr_event(data, auth_state, event_emitter) do
    qr_data = generate_qr_data(data.ref, auth_state)
    EventEmitter.emit(event_emitter, {:qr, qr_data})
  end
end
```

### 7.5 Phone number pairing

File: `lib/baileys_ex/auth/phone.ex`

Flow:
1. User calls `BaileysEx.request_pairing_code(conn, phone_number)`
2. Generate pairing ephemeral key pair
3. Send pairing request node to server
4. Server returns pairing code
5. User enters code in WhatsApp mobile
6. Key derivation via PBKDF2 (131,072 iterations)
7. Complete pairing

### 7.6 Pre-key upload

File: `lib/baileys_ex/signal/prekey.ex` (extend from Phase 5)

Upload pre-keys to WhatsApp server after authentication:
- Check server's pre-key count
- Generate batch of new pre-keys if needed
- Upload via binary node
- Track uploaded key IDs in auth state

### 7.7 Transactional Signal Key Storage (GAP-44)

File: `lib/baileys_ex/auth/key_store.ex`

Baileys wraps Signal key state operations in transactions using `AsyncLocalStorage`,
`p-queue` (concurrency: 1 per key type), and `async-mutex`. This prevents race
conditions and database locks during massive parallel read/write bursts seen in
history sync and group messaging.

Our Elixir approach: GenServer per key type that serializes writes and caches
reads within a transaction window. Uses `Ecto.Multi` or similar for atomic
commits when backed by a database.

```elixir
defmodule BaileysEx.Auth.KeyStore do
  @moduledoc """
  Transactional Signal key storage. Wraps the persistence behaviour with
  caching and serialized writes to prevent race conditions during heavy
  sync operations (history sync, group message bursts).

  Each key type (session, pre-key, sender-key, etc.) gets its own serialized
  queue to prevent cross-type contention while maintaining per-type ordering.
  """

  use GenServer

  @key_types [:session, :pre_key, :signed_pre_key, :sender_key, :sender_key_memory,
              :app_state_sync_key, :app_state_sync_version, :tctoken]

  defstruct [
    :persistence_module,  # User's Auth.Persistence implementation
    :cache,               # ETS table for read-through cache
    :pending_writes,      # Accumulated writes within current transaction
    :in_transaction?      # Whether we're inside a transaction
  ]

  @doc "Start a transaction: caches reads, batches writes"
  def transaction(store, fun) do
    GenServer.call(store, {:transaction, fun}, :infinity)
  end

  @doc "Read within transaction (cache-first)"
  def get(store, type, ids) when type in @key_types do
    GenServer.call(store, {:get, type, ids})
  end

  @doc "Write within transaction (buffered until commit)"
  def set(store, type, data) when type in @key_types do
    GenServer.call(store, {:set, type, data})
  end

  # GenServer callbacks serialize all operations per-store.
  # During transaction:
  #   - Reads check pending_writes first, then cache, then persistence
  #   - Writes accumulate in pending_writes
  #   - On commit: flush all pending_writes to persistence atomically
  #   - On rollback: discard pending_writes, clear cache entries
  #
  # For database-backed persistence, commit uses Ecto.Multi for atomicity.
  # For file-backed persistence, commit writes sequentially with fsync.
  #
  # Retry logic: on "database is locked" errors, retry with exponential
  # backoff (matching Baileys' commitWithRetry behavior).
end
```

### 7.8 Connection validation (login/registration nodes)

File: `lib/baileys_ex/auth/connection_validator.ex`

Constructs login and registration payloads sent after the Noise handshake completes.
These are the first application-level messages exchanged with WhatsApp servers.

```elixir
defmodule BaileysEx.Auth.ConnectionValidator do
  @moduledoc """
  Constructs login and registration payloads sent after Noise handshake.
  """

  @doc "Build login payload for returning users (have credentials)"
  def generate_login_node(me_jid, config) do
    # ClientPayload protobuf with:
    # - username (user part of JID)
    # - device (device ID)
    # - passive: true (for login)
    # - user_agent: browser info + platform type + app version
    # - web_info: web_sub_platform
  end

  @doc "Build registration payload for new devices"
  def generate_registration_node(creds, config) do
    # ClientPayload with:
    # - reg_data: registration ID, identity key, signed pre-key, device props
    # - passive: false
    # - device_pairing_data: app version config
    # - user_agent: platform type mapping
    # - history sync config: storage quota, inline payloads, chunk tuning
  end

  @doc "Process pair-success response: verify HMAC + ADV signatures, create reply"
  def configure_successful_pairing(stanza, creds) do
    # Parse pair-success binary node
    # Verify account signature (ADV)
    # Verify device signature
    # Construct reply node
    # Return updated credentials
  end
end
```

### 7.9 Pre-key management (advanced)

File: `lib/baileys_ex/signal/prekey.ex` (extend)

Additional pre-key management functions beyond basic upload, covering automatic
replenishment and rotation:

```elixir
# Additional pre-key management functions (in BaileysEx.Signal.PreKey or new module):

@doc "Check server pre-key count and upload if needed"
def upload_if_required(conn) do
  # Query server for remaining pre-key count
  # If below threshold, generate and upload batch
  # Minimum interval between uploads to prevent spam
end

@doc "Rotate signed pre-key"
def rotate_signed_pre_key(conn) do
  # Generate new signed pre-key
  # Upload to server via IQ xmlns='encrypt'
  # Emit :creds_update event
end

@doc "Send key bundle digest"
def digest_key_bundle(conn) do
  # IQ xmlns='encrypt' with digest of current key bundle
end
```

### 7.10 Tests

- Auth state creation with valid crypto keys
- Persistence save/load roundtrip (file-based)
- QR data generation matches expected format
- Pre-key upload node construction
- Phone pairing PBKDF2 key derivation against test vectors

---

## Acceptance Criteria

- [ ] New auth state generates valid crypto keys
- [ ] File persistence saves and loads credentials correctly
- [ ] QR code data format matches WhatsApp expectations
- [ ] Phone pairing key derivation matches Baileys output
- [ ] Pre-key upload constructs correct binary nodes
- [ ] Custom persistence backend can be swapped via behaviour
- [ ] Login node constructed correctly for returning users
- [ ] Registration node includes device props, history sync config, platform type
- [ ] Pair-success HMAC and ADV signature verification passes
- [ ] Pre-key upload triggered automatically when server count is low
- [ ] Signed pre-key rotation works correctly
- [ ] Key store transactions serialize concurrent read/write bursts (GAP-44)
- [ ] Transaction commits are atomic (Ecto.Multi for DB, sequential for files)
- [ ] Read-through cache prevents redundant persistence lookups during sync

## Files Created/Modified

- `lib/baileys_ex/auth/state.ex`
- `lib/baileys_ex/auth/persistence.ex`
- `lib/baileys_ex/auth/file_persistence.ex`
- `lib/baileys_ex/auth/qr.ex`
- `lib/baileys_ex/auth/phone.ex`
- `lib/baileys_ex/signal/prekey.ex` (extend)
- `test/baileys_ex/auth/state_test.exs`
- `test/baileys_ex/auth/file_persistence_test.exs`
- `test/baileys_ex/auth/qr_test.exs`
- `lib/baileys_ex/auth/connection_validator.ex`
- `lib/baileys_ex/auth/key_store.ex`
