# Configuration Reference

This page covers the public connection options for `BaileysEx.connect/2` and every key in `BaileysEx.Connection.Config`.

## `connect/2` options

### `transport`

- **Type:** `{module(), keyword() | map()}`
- **Default:** `{BaileysEx.Connection.Transport.Noop, %{}}`
- **Example:**

```elixir
transport: {BaileysEx.Connection.Transport.MintWebSocket, []}
```

Use this to choose the actual network transport. You must set it for a real WhatsApp session.

### `config`

- **Type:** `BaileysEx.Connection.Config.t()`
- **Default:** `BaileysEx.Connection.Config.new()`
- **Example:**

```elixir
config: BaileysEx.Connection.Config.new(connect_timeout_ms: 30_000)
```

Use this to override runtime timing, browser identity, and sync behavior.

### `signal_store_module`

- **Type:** `module()`
- **Default:** `BaileysEx.Signal.Store.Memory`
- **Example:**

```elixir
signal_store_module: MyApp.BaileysSignalStore
```

Use this when the default in-memory Signal key store is not enough for your runtime.

### `signal_store_opts`

- **Type:** `keyword()`
- **Default:** `[]`
- **Example:**

```elixir
signal_store_opts: [table: :baileys_signal_store]
```

These options are passed directly to your selected Signal store module.

### `on_connection`

- **Type:** `(map() -> term())`
- **Default:** `nil`
- **Example:**

```elixir
on_connection: fn update -> IO.inspect(update, label: "connection") end
```

Receives each `:connection_update` payload.

### `on_qr`

- **Type:** `(String.t() -> term())`
- **Default:** `nil`
- **Example:**

```elixir
on_qr: fn qr -> IO.puts("Scan QR: #{qr}") end
```

Receives QR strings extracted from connection updates.

### `on_message`

- **Type:** `(map() -> term())`
- **Default:** `nil`
- **Example:**

```elixir
on_message: fn message -> IO.inspect(message, label: "incoming") end
```

Receives each message from `:messages_upsert`.

### `on_event`

- **Type:** `(map() -> term())`
- **Default:** `nil`
- **Example:**

```elixir
on_event: fn events -> IO.inspect(events, label: "raw events") end
```

Receives the buffered raw event map before the public facade normalizes it.

### `signal_repository`

- **Type:** `BaileysEx.Signal.Repository.t()`
- **Default:** runtime-managed repository
- **Example:**

```elixir
signal_repository: repository
```

Use this only if you need to inject a prebuilt repository into the coordinator.

### `signal_repository_adapter`

- **Type:** `module()`
- **Default:** runtime default
- **Example:**

```elixir
signal_repository_adapter: MyApp.SignalAdapter
```

Advanced only. This swaps the repository adapter used for end-to-end encryption operations.

### `signal_repository_adapter_state`

- **Type:** `term()`
- **Default:** `%{}`
- **Example:**

```elixir
signal_repository_adapter_state: %{sessions: %{}}
```

Initial adapter state for a custom Signal repository adapter.

### `history_sync_download_fun`

- **Type:** `(map(), map() -> {:ok, binary()} | {:error, term()})`
- **Default:** built-in downloader
- **Example:**

```elixir
history_sync_download_fun: fn notification, context ->
  MyApp.HistorySync.download(notification, context)
end
```

Advanced only. Use this when you need to override history-sync media download.

### `history_sync_inflate_fun`

- **Type:** `(binary() -> {:ok, binary()} | {:error, term()})`
- **Default:** built-in inflater
- **Example:**

```elixir
history_sync_inflate_fun: &MyApp.HistorySync.inflate/1
```

Advanced only. This overrides the history-sync inflate step.

### `get_message_fun`

- **Type:** `(map() -> map() | nil)`
- **Default:** `nil`
- **Example:**

```elixir
get_message_fun: &MyApp.MessageStore.fetch/1
```

Used when the runtime needs to look up a previously sent message, for example when it processes certain interactive updates.

### `handle_encrypt_notification_fun`

- **Type:** `(map() -> term())`
- **Default:** `nil`
- **Example:**

```elixir
handle_encrypt_notification_fun: &MyApp.Notifications.handle_encrypt/1
```

Advanced hook for encryption notification handling.

### `device_notification_fun`

- **Type:** `(map() -> term())`
- **Default:** `nil`
- **Example:**

```elixir
device_notification_fun: &MyApp.Devices.handle_update/1
```

Advanced hook for device list notifications.

### `resync_app_state_fun`

- **Type:** `(String.t() | [atom()] -> term())`
- **Default:** built-in app-state resync
- **Example:**

```elixir
resync_app_state_fun: &MyApp.Syncd.resync/1
```

Advanced only. Override the runtime's app-state resync path.

## `BaileysEx.Connection.Config`

### `ws_url`

- **Type:** `String.t()`
- **Default:** `"wss://web.whatsapp.com/ws/chat"`
- **Example:**

```elixir
BaileysEx.Connection.Config.new(ws_url: "wss://web.whatsapp.com/ws/chat")
```

The WebSocket endpoint for the WhatsApp Web session.

### `keep_alive_interval_ms`

- **Type:** `pos_integer()`
- **Default:** `25_000`
- **Example:**

```elixir
BaileysEx.Connection.Config.new(keep_alive_interval_ms: 15_000)
```

How often the runtime sends keep-alive traffic.

### `default_query_timeout_ms`

- **Type:** `pos_integer()`
- **Default:** `60_000`
- **Example:**

```elixir
BaileysEx.Connection.Config.new(default_query_timeout_ms: 30_000)
```

Default timeout for IQ-style query calls.

### `initial_sync_timeout_ms`

- **Type:** `pos_integer()`
- **Default:** `20_000`
- **Example:**

```elixir
BaileysEx.Connection.Config.new(initial_sync_timeout_ms: 10_000)
```

How long the runtime waits for the initial history and sync burst before flushing buffered events.

### `pairing_qr_initial_timeout_ms`

- **Type:** `pos_integer()`
- **Default:** `60_000`
- **Example:**

```elixir
BaileysEx.Connection.Config.new(pairing_qr_initial_timeout_ms: 45_000)
```

How long a freshly generated QR stays valid before the runtime requests a refresh.

### `pairing_qr_refresh_timeout_ms`

- **Type:** `pos_integer()`
- **Default:** `20_000`
- **Example:**

```elixir
BaileysEx.Connection.Config.new(pairing_qr_refresh_timeout_ms: 15_000)
```

How long refreshed QR codes remain valid.

### `retry_request_delay_ms`

- **Type:** `pos_integer()`
- **Default:** `250`
- **Example:**

```elixir
BaileysEx.Connection.Config.new(retry_request_delay_ms: 500)
```

Delay before a request retry starts.

### `max_msg_retry_count`

- **Type:** `pos_integer()`
- **Default:** `5`
- **Example:**

```elixir
BaileysEx.Connection.Config.new(max_msg_retry_count: 3)
```

Maximum message retry count for retry-driven receive flows.

### `retry_delay_ms`

- **Type:** `pos_integer()`
- **Default:** `2_000`
- **Example:**

```elixir
BaileysEx.Connection.Config.new(retry_delay_ms: 1_000)
```

Base delay between reconnect or retry attempts.

### `max_retries`

- **Type:** `non_neg_integer()`
- **Default:** `5`
- **Example:**

```elixir
BaileysEx.Connection.Config.new(max_retries: 8)
```

Upper bound for reconnect attempts.

### `connect_timeout_ms`

- **Type:** `pos_integer()`
- **Default:** `20_000`
- **Example:**

```elixir
BaileysEx.Connection.Config.new(connect_timeout_ms: 30_000)
```

Connection-establishment timeout for the transport.

### `fire_init_queries`

- **Type:** `boolean()`
- **Default:** `true`
- **Example:**

```elixir
BaileysEx.Connection.Config.new(fire_init_queries: false)
```

Controls whether the runtime sends its initial post-login queries automatically.

### `mark_online_on_connect`

- **Type:** `boolean()`
- **Default:** `true`
- **Example:**

```elixir
BaileysEx.Connection.Config.new(mark_online_on_connect: false)
```

Controls whether the runtime marks the session available as soon as it connects.

### `enable_auto_session_recreation`

- **Type:** `boolean()`
- **Default:** `true`
- **Example:**

```elixir
BaileysEx.Connection.Config.new(enable_auto_session_recreation: false)
```

Enables automatic Signal session recreation when the runtime decides it is required.

### `enable_recent_message_cache`

- **Type:** `boolean()`
- **Default:** `true`
- **Example:**

```elixir
BaileysEx.Connection.Config.new(enable_recent_message_cache: false)
```

Controls the recent-message cache used by the runtime.

### `browser`

- **Type:** `{String.t(), String.t(), String.t()}`
- **Default:** `{"Mac OS", "Chrome", "14.4.1"}`
- **Example:**

```elixir
BaileysEx.Connection.Config.new(browser: {"Linux", "Chrome", "122.0.0"})
```

The platform tuple BaileysEx advertises during login.

### `version`

- **Type:** `[non_neg_integer()]`
- **Default:** `[2, 3000, 1_033_846_690]`
- **Example:**

```elixir
BaileysEx.Connection.Config.new(version: [2, 3000, 1_033_846_690])
```

The WhatsApp Web version tuple sent during login.

### `country_code`

- **Type:** `String.t()`
- **Default:** `"US"`
- **Example:**

```elixir
BaileysEx.Connection.Config.new(country_code: "BR")
```

Country code used in the runtime's platform metadata.

### `sync_full_history`

- **Type:** `boolean()`
- **Default:** `true`
- **Example:**

```elixir
BaileysEx.Connection.Config.new(sync_full_history: false)
```

Controls the history-sync mode the client asks WhatsApp to use.

### `should_sync_history_message`

- **Type:** `(map() -> boolean())`
- **Default:** `&BaileysEx.Connection.Config.default_should_sync_history_message/1`
- **Example:**

```elixir
BaileysEx.Connection.Config.new(
  should_sync_history_message: fn history_message ->
    history_message[:sync_type] != :FULL
  end
)
```

Filters individual history-sync messages after download. Use this only if you already understand your history-sync requirements.

### `print_qr_in_terminal`

- **Type:** `boolean()`
- **Default:** `false`
- **Example:**

```elixir
BaileysEx.Connection.Config.new(print_qr_in_terminal: true)
```

Controls whether QR codes are printed directly in the terminal.
