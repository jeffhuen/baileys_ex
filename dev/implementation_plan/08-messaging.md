# Phase 8: Messaging Core

**Goal:** Full message send/receive pipeline with Signal encryption, device discovery,
receipt handling, and retry logic.

**Depends on:** Phase 5 (Signal), Phase 6 (Connection), Phase 7 (Auth)
**Blocks:** Phase 9 (Media), Phase 10 (Features)

---

## Design Decisions

**Send pipeline as a function chain, not a process.**
Message sending is a request-response operation: construct → encrypt → encode → send → await ACK.
No persistent state needed beyond what the connection socket already holds. Use
`Task.Supervisor.async_nolink` for concurrent sends.

**Receive pipeline dispatches from the socket.**
The `:gen_statem` socket receives WABinary nodes. Message nodes are pattern-matched
and dispatched to the receiver module, which decrypts, parses, and emits events.

**Device discovery cached in ETS.**
Before encrypting for a recipient, we need their device list. Cache in the connection
Store's ETS table. Refresh on cache miss or session error.

**Message retry via process mailbox, not separate process.**
Retry state (message ID → retry count + encrypted content) stored in the connection
Store. Timer-based retry triggers re-read from Store and re-send. No dedicated
retry process needed.

---

## Tasks

### 8.1 Message builder

File: `lib/baileys_ex/message/builder.ex`

Construct protobuf `WAProto.Message` from user-friendly input. Every message type
Baileys supports must have an explicit `build/1` clause — no hidden "other" bucket.

```elixir
defmodule BaileysEx.Message.Builder do
  @moduledoc """
  Constructs WAProto.Message structs from user-friendly input maps.
  Each message type has an explicit build clause.
  """

  # --- Text ---

  def build(%{text: text} = content) do
    if Map.has_key?(content, :quoted) or Map.has_key?(content, :mentions) or
       Map.has_key?(content, :edit) or Map.has_key?(content, :link_preview) do
      %Proto.Message{
        extended_text_message: %Proto.ExtendedTextMessage{
          text: text,
          context_info: build_context_info(content),
          matched_text: get_in(content, [:link_preview, :matched_text]),
          canonical_url: get_in(content, [:link_preview, :canonical_url]),
          title: get_in(content, [:link_preview, :title]),
          description: get_in(content, [:link_preview, :description]),
          background_argb: content[:background_color],
          font: content[:font]
        }
      }
    else
      %Proto.Message{conversation: text}
    end
  end

  # --- Media (placeholders — fully built in Phase 9) ---

  def build(%{image: _} = content) do
    %Proto.Message{
      image_message: %Proto.ImageMessage{
        caption: content[:caption],
        context_info: build_context_info(content)
      }
    }
  end

  def build(%{video: _} = content) do
    if content[:ptv] do
      %Proto.Message{ptv_message: %Proto.VideoMessage{
        caption: content[:caption],
        gif_playback: content[:gif_playback] || false,
        context_info: build_context_info(content)
      }}
    else
      %Proto.Message{video_message: %Proto.VideoMessage{
        caption: content[:caption],
        gif_playback: content[:gif_playback] || false,
        context_info: build_context_info(content)
      }}
    end
  end

  def build(%{audio: _} = content) do
    %Proto.Message{
      audio_message: %Proto.AudioMessage{
        ptt: content[:ptt] || false,
        seconds: content[:seconds],
        context_info: build_context_info(content)
      }
    }
  end

  def build(%{document: _} = content) do
    %Proto.Message{
      document_message: %Proto.DocumentMessage{
        mimetype: content[:mimetype] || "application/octet-stream",
        file_name: content[:file_name] || "file",
        caption: content[:caption],
        context_info: build_context_info(content)
      }
    }
  end

  def build(%{sticker: _} = content) do
    %Proto.Message{
      sticker_message: %Proto.StickerMessage{
        is_animated: content[:is_animated] || false,
        context_info: build_context_info(content)
      }
    }
  end

  # --- Reactions ---

  def build(%{react: %{key: key, text: emoji}}) do
    %Proto.Message{
      reaction_message: %Proto.ReactionMessage{
        key: build_message_key(key),
        text: emoji,
        sender_timestamp_ms: System.os_time(:millisecond)
      }
    }
  end

  # --- Polls ---

  def build(%{poll: %{name: name, values: values} = poll}) do
    selectable_count = Map.get(poll, :selectable_count, 0)
    message_secret = :crypto.strong_rand_bytes(32)

    poll_msg = %Proto.PollCreationMessage{
      name: name,
      options: Enum.map(values, &%Proto.PollCreationMessage.Option{option_name: &1}),
      selectable_options_count: selectable_count
    }

    # V1: multi-select, V2: announcement group, V3: single-select
    msg_field = cond do
      poll[:to_announcement_group] -> :poll_creation_message_v2
      selectable_count == 1 -> :poll_creation_message_v3
      true -> :poll_creation_message
    end

    %Proto.Message{
      msg_field => poll_msg,
      message_context_info: %Proto.MessageContextInfo{
        message_secret: message_secret
      }
    }
  end

  # --- Contacts / vCards ---

  def build(%{contacts: %{display_name: display_name, contacts: [single]}})
      when is_map(single) do
    %Proto.Message{
      contact_message: %Proto.ContactMessage{
        display_name: single[:display_name] || display_name,
        vcard: single.vcard
      }
    }
  end

  def build(%{contacts: %{display_name: display_name, contacts: contacts}})
      when is_list(contacts) and length(contacts) > 1 do
    %Proto.Message{
      contacts_array_message: %Proto.ContactsArrayMessage{
        display_name: display_name,
        contacts: Enum.map(contacts, fn c ->
          %Proto.ContactMessage{
            display_name: c[:display_name],
            vcard: c.vcard
          }
        end)
      }
    }
  end

  # --- Location ---

  def build(%{location: loc}) when not is_nil(loc) do
    %Proto.Message{
      location_message: %Proto.LocationMessage{
        degrees_latitude: loc.latitude,
        degrees_longitude: loc.longitude,
        name: loc[:name],
        address: loc[:address],
        url: loc[:url],
        accuracy_in_meters: loc[:accuracy]
      }
    }
  end

  def build(%{live_location: loc}) when not is_nil(loc) do
    %Proto.Message{
      live_location_message: %Proto.LiveLocationMessage{
        degrees_latitude: loc.latitude,
        degrees_longitude: loc.longitude,
        accuracy_in_meters: loc[:accuracy],
        speed_in_mps: loc[:speed],
        degrees_clockwise_from_magnetic_north: loc[:heading],
        sequence_number: loc[:sequence_number]
      }
    }
  end

  # --- Message Deletion (Revoke / "Delete for Everyone") ---

  def build(%{delete: key}) do
    %Proto.Message{
      protocol_message: %Proto.ProtocolMessage{
        key: build_message_key(key),
        type: :REVOKE
      }
    }
  end

  # --- Message Editing ---

  def build(%{edit: key, text: new_text}) do
    %Proto.Message{
      protocol_message: %Proto.ProtocolMessage{
        key: build_message_key(key),
        type: :MESSAGE_EDIT,
        edited_message: %Proto.Message{
          conversation: new_text
        },
        timestamp_ms: System.os_time(:millisecond)
      }
    }
  end

  # --- Disappearing Messages ---

  def build(%{disappearing_messages_in_chat: expiration}) do
    exp = if is_boolean(expiration) and expiration, do: 86_400, else: expiration

    %Proto.Message{
      protocol_message: %Proto.ProtocolMessage{
        type: :EPHEMERAL_SETTING,
        ephemeral_expiration: exp || 0
      }
    }
  end

  # --- Pin in Chat ---

  def build(%{pin: %{key: key, type: type, time: duration}}) do
    %Proto.Message{
      pin_in_chat_message: %Proto.PinInChatMessage{
        key: build_message_key(key),
        type: if(type == :pin, do: :PIN_FOR_ALL, else: :UNPIN_FOR_ALL),
        sender_timestamp_ms: System.os_time(:millisecond)
      },
      message_context_info: %Proto.MessageContextInfo{
        message_add_on_duration_in_secs: duration
      }
    }
  end

  # --- Group Invite ---

  def build(%{group_invite: %{group_jid: gjid, invite_code: code} = inv}) do
    %Proto.Message{
      group_invite_message: %Proto.GroupInviteMessage{
        group_jid: JID.to_string(gjid),
        invite_code: code,
        invite_expiration: inv[:invite_expiration],
        group_name: inv[:group_name],
        caption: inv[:caption],
        jpeg_thumbnail: inv[:jpeg_thumbnail]
      }
    }
  end

  # --- Forward ---

  def build(%{forward: original_message, force: force?}) do
    content = normalize_message_content(original_message.message)
    context = get_or_create_context_info(content)
    forwarding_score = (context[:forwarding_score] || 0) + 1

    put_context_info(content, %Proto.ContextInfo{
      is_forwarded: true,
      forwarding_score: forwarding_score
    })
  end

  # --- Events ---

  def build(%{event: %{name: name} = event}) do
    message_secret = :crypto.strong_rand_bytes(32)

    %Proto.Message{
      event_message: %Proto.EventMessage{
        name: name,
        description: event[:description],
        start_time: event[:start_time] && DateTime.to_unix(event[:start_time]),
        is_canceled: event[:is_cancelled] || false,
        extra_guests_allowed: event[:extra_guests_allowed] || false,
        location: event[:location] && build(%{location: event[:location]}).location_message
      },
      message_context_info: %Proto.MessageContextInfo{
        message_secret: message_secret
      }
    }
  end

  # --- Product ---

  def build(%{product: %{product_image: _, title: _} = prod}) do
    %Proto.Message{
      product_message: %Proto.ProductMessage{
        product: %Proto.ProductMessage.ProductSnapshot{
          product_id: prod[:product_id],
          title: prod.title,
          description: prod[:description],
          currency_code: prod[:currency_code],
          price_amount_1000: prod[:price_amount_1000],
          url: prod[:url]
        },
        business_owner_jid: prod[:business_owner_jid],
        body: prod[:body],
        footer: prod[:footer]
      }
    }
  end

  # --- Button / List Replies (parsing inbound; users send these as responses) ---

  def build(%{button_reply: %{display_text: text, id: id, type: :template}}) do
    %Proto.Message{
      template_button_reply_message: %Proto.TemplateButtonReplyMessage{
        selected_display_text: text,
        selected_id: id
      }
    }
  end

  def build(%{button_reply: %{display_text: text, id: id}}) do
    %Proto.Message{
      buttons_response_message: %Proto.ButtonsResponseMessage{
        selected_display_text: text,
        selected_button_id: id,
        type: :DISPLAY_TEXT
      }
    }
  end

  def build(%{list_reply: %{title: title, row_id: row_id}}) do
    %Proto.Message{
      list_response_message: %Proto.ListResponseMessage{
        title: title,
        single_select_reply: %Proto.ListResponseMessage.SingleSelectReply{
          selected_row_id: row_id
        }
      }
    }
  end

  # --- Share Phone Number ---

  def build(%{share_phone_number: true, key: key}) do
    %Proto.Message{
      protocol_message: %Proto.ProtocolMessage{
        key: build_message_key(key),
        type: :SHARE_PHONE_NUMBER
      }
    }
  end

  def build(%{request_phone_number: true}) do
    %Proto.Message{
      request_phone_number_message: %Proto.RequestPhoneNumberMessage{}
    }
  end

  # --- View Once wrapper (applied to any message) ---

  def build(%{view_once: true} = content) do
    inner = build(Map.delete(content, :view_once))
    %Proto.Message{
      view_once_message: %Proto.FutureProofMessage{message: inner}
    }
  end

  # --- Helpers ---

  defp build_context_info(content) do
    %Proto.ContextInfo{
      stanza_id: get_in(content, [:quoted, :key, :id]),
      participant: get_in(content, [:quoted, :key, :participant]),
      quoted_message: get_in(content, [:quoted, :message]),
      mentioned_jid: content[:mentions] || [],
      expiration: content[:ephemeral_expiration],
      is_forwarded: content[:is_forwarded] || false,
      forwarding_score: content[:forwarding_score]
    }
  end

  defp build_message_key(%{id: id, remote_jid: jid} = key) do
    %Proto.MessageKey{
      id: id,
      remote_jid: JID.to_string(jid),
      from_me: key[:from_me] || false,
      participant: key[:participant] && JID.to_string(key[:participant])
    }
  end
end
```

**Inbound-only message types (parsed by Receiver, not built by Builder):**

These types are received from WhatsApp but cannot be sent by regular users. The
Receiver must parse them correctly:

| Proto Type | Description |
|------------|-------------|
| `ButtonsMessage` | Interactive buttons (header + body + button array) |
| `ListMessage` | List picker (sections with rows) |
| `TemplateMessage` | HSM templates from WhatsApp Business |
| `InteractiveMessage` | Native flows, carousels, shop storefronts |
| `InteractiveResponseMessage` | Responses to interactive messages |
| `PollUpdateMessage` | Vote on a poll (encrypted payload) |
| `PollResultSnapshotMessage` | Aggregated poll results |
| `EncReactionMessage` | Encrypted reaction (for groups with privacy) |
| `EncEventResponseMessage` | Encrypted event RSVP |
| `AIRichResponseMessage` | AI bot structured responses |

File: `lib/baileys_ex/message/parser.ex`

```elixir
defmodule BaileysEx.Message.Parser do
  @moduledoc """
  Parses inbound WAProto.Message content into normalized structs.
  Handles unwrapping ephemeral, viewOnce, and template wrappers.
  """

  @doc "Extract the actual message content type from a wrapped message"
  def normalize_content(%Proto.Message{ephemeral_message: %{message: inner}})
      when not is_nil(inner), do: normalize_content(inner)
  def normalize_content(%Proto.Message{view_once_message: %{message: inner}})
      when not is_nil(inner), do: normalize_content(inner)
  def normalize_content(%Proto.Message{view_once_message_v2: %{message: inner}})
      when not is_nil(inner), do: normalize_content(inner)
  def normalize_content(%Proto.Message{} = msg), do: msg

  @doc "Detect the content type key from a message"
  def get_content_type(%Proto.Message{} = msg) do
    # Returns atom like :image_message, :reaction_message, etc.
    # Skips :sender_key_distribution_message (internal Signal)
    msg
    |> Map.from_struct()
    |> Enum.find(fn {k, v} -> v != nil and k not in [:sender_key_distribution_message] end)
    |> case do
      {key, _} -> key
      nil -> nil
    end
  end
end
```

### 8.2 Message sender

File: `lib/baileys_ex/message/sender.ex`

The full send pipeline:

```elixir
defmodule BaileysEx.Message.Sender do
  @status_broadcast "status@broadcast"

  @doc "Send a message to a JID. Returns {:ok, sent_message} or {:error, reason}."
  def send(conn, jid, content, opts \\ []) do
    with {:ok, proto_message} <- Builder.build(content),
         {:ok, message_id} <- generate_message_id(),
         proto_message <- maybe_wrap_ephemeral(proto_message, conn, jid),
         {:ok, devices} <- discover_devices(conn, jid, opts),
         {:ok, encrypted_nodes} <- encrypt_for_devices(conn, jid, proto_message, devices),
         :ok <- relay_message(conn, jid, message_id, encrypted_nodes, opts) do
      {:ok, %{id: message_id, jid: jid, message: proto_message, timestamp: now()}}
    end
  end

  @doc "Send to status/stories. Wraps send/4 with status@broadcast JID."
  def send_status(conn, content, opts \\ []) do
    # status_jid_list in opts controls who sees the status
    send(conn, @status_broadcast, content, opts)
  end

  defp discover_devices(conn, jid) do
    # Check Store ETS cache first
    # If miss, send usync query node, await response
    # Cache result
  end

  defp encrypt_for_devices(conn, jid, message, devices) do
    store = Store.get_signal_store(conn)
    encoded = Proto.Message.encode(message)

    devices
    |> Task.async_stream(fn device ->
      address = {JID.to_signal_address(jid), device}
      BaileysEx.Signal.SessionCipher.encrypt(store, address, encoded)
    end, max_concurrency: 10, ordered: false)
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, {:ok, encrypted}}, {:ok, acc} -> {:cont, {:ok, [encrypted | acc]}}
      {:ok, {:error, reason}}, _ -> {:halt, {:error, reason}}
    end)
  end

  defp relay_message(conn, jid, message_id, encrypted_nodes, opts) do
    node = build_relay_node(jid, message_id, encrypted_nodes, opts)
    Connection.Socket.send_node(conn, node)
  end

  # --- Message ID Generation (matches Baileys format) ---

  defp generate_message_id(me_jid) do
    # Format: "3EB0" + 36 hex chars (timestamp + random)
    ts = System.os_time(:millisecond)
    random = :crypto.strong_rand_bytes(16)
    {:ok, "3EB0" <> Base.encode16(<<ts::64>> <> random, case: :upper) |> binary_part(0, 36)}
  end

  # --- Participant Hash V2 ---

  defp participant_hash(participant_jids) do
    sorted = Enum.sort(participant_jids)
    hash = :crypto.hash(:sha256, Enum.join(sorted, ""))
    "2:" <> (Base.encode64(binary_part(hash, 0, 6), padding: false))
  end

  # --- Device Sent Message (DSM) ---
  # When sending 1:1, own devices get a deviceSentMessage wrapper
  # so multi-device stays in sync.

  defp wrap_dsm(message, destination_jid) do
    %Proto.Message{
      device_sent_message: %Proto.DeviceSentMessage{
        destination_jid: JID.to_string(destination_jid),
        message: message
      },
      message_context_info: message.message_context_info
    }
  end

  # --- Group Send: Sender Key Distribution ---
  # For group messages:
  # 1. Check sender key memory → which devices already have the key
  # 2. New devices get SenderKeyDistributionMessage in pkmsg nodes
  # 3. Main message encrypted with group sender key (skmsg)
  # 4. Update sender key memory

  defp encrypt_for_group(conn, group_jid, message, devices) do
    store = Store.get_signal_store(conn)
    sender_key_memory = Store.get_sender_key_memory(conn, group_jid)

    # Determine which devices need SKD
    {known_devices, new_devices} = split_known_devices(devices, sender_key_memory)

    # Encrypt main message with group sender key
    {:ok, group_ciphertext, skd_message} =
      BaileysEx.Signal.GroupCipher.encrypt(store, group_jid, Proto.Message.encode(message))

    # For new devices: encrypt SKD individually
    skd_nodes = encrypt_skd_for_devices(store, new_devices, skd_message)

    # Update sender key memory
    Store.update_sender_key_memory(conn, group_jid, devices)

    {:ok, %{group_ciphertext: group_ciphertext, skd_nodes: skd_nodes, type: :skmsg}}
  end

  # --- Reporting Tokens (GAP-32) ---
  # 28+ message types require a reporting token for abuse reporting.
  # Token is generated from encoded message + messageContextInfo.messageSecret
  # and attached as a child node to the message stanza.

  @reporting_token_types [
    :image_message, :video_message, :audio_message, :document_message,
    :sticker_message, :contact_message, :contacts_array_message,
    :location_message, :live_location_message, :event_message,
    :poll_creation_message, :poll_creation_message_v2, :poll_creation_message_v3,
    :ptv_message, :group_invite_message, :product_message,
    # ... and more
  ]

  defp maybe_attach_reporting_token(stanza_children, message, content_type) do
    if content_type in @reporting_token_types do
      token = generate_reporting_token(message)
      [%BinaryNode{tag: "report", attrs: %{"token" => token}} | stanza_children]
    else
      stanza_children
    end
  end

  defp generate_reporting_token(message) do
    encoded = Proto.Message.encode(message)
    secret = get_in(message, [:message_context_info, :message_secret]) || <<>>
    :crypto.hash(:sha256, encoded <> secret)
    |> binary_part(0, 16)
    |> Base.encode64()
  end
end
```

### 8.3 Message receiver

File: `lib/baileys_ex/message/receiver.ex`

Processes incoming message nodes from the socket:

```elixir
defmodule BaileysEx.Message.Receiver do
  @doc "Process an incoming message binary node"
  def process_node(%BinaryNode{tag: "message"} = node, conn) do
    with {:ok, sender} <- extract_sender(node),
         {:ok, msg_type, ciphertext} <- extract_encrypted_content(node),
         {:ok, plaintext} <- decrypt_message(conn, sender, msg_type, ciphertext),
         {:ok, proto_message} <- Proto.Message.decode(plaintext) do
      message = build_received_message(node, sender, proto_message)
      EventEmitter.emit(conn, {:message, message})
      send_receipt(conn, node, :delivered)
      {:ok, message}
    else
      {:error, :no_session} ->
        # Request retry with pre-key
        handle_retry(conn, node)
      {:error, reason} ->
        Logger.warning("Failed to process message: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def process_node(%BinaryNode{tag: "notification"} = node, conn) do
    # Handle notification types: group updates, presence, etc.
    handle_notification(node, conn)
  end

  defp decrypt_message(conn, sender, msg_type, ciphertext) do
    store = Store.get_signal_store(conn)
    address = {JID.to_signal_address(sender.jid), sender.device}
    BaileysEx.Signal.SessionCipher.decrypt(store, address, msg_type, ciphertext)
  end
end
```

### 8.3a Offline node processor (GAP-05)

Baileys uses `makeOfflineNodeProcessor()` to queue offline messages, calls,
receipts, and notifications. The Elixir port should preserve the behavior but
use a BEAM-friendly implementation:

- Maintain a FIFO queue of `{:message | :call | :receipt | :notification, node}`.
- Drain at most 10 nodes per pass, then yield by rescheduling the next drain
  with `Process.send_after(self(), :drain_offline_queue, 0)` or `handle_continue/2`.
- Keep the queue inside the receiver/socket owner process so ordering is stable
  and backpressure is explicit.
- Wrap offline drain windows with event buffering; flush only when the queue and
  sync-state conditions allow it.

This is the BEAM equivalent of Baileys' `setImmediate()` batching and avoids
long scheduler monopolization during large history sync bursts.

### 8.3b Envelope decode and protocol-message side effects

Files:
- `lib/baileys_ex/message/decode.ex`
- `lib/baileys_ex/message/receiver.ex`

Mirror the responsibilities split across Baileys `Utils/decode-wa-message.ts`
and `Utils/process-message.ts`:

- Decode envelope addressing context: `addressing_mode`, `participant_lid`,
  `participant_pn`, recipient alternates, newsletter `server_id`, and
  `remote_jid_alt` / `participant_alt` fields on the produced message key.
- If `addressing_mode` is absent, fall back the same way Baileys v7 does by
  inferring from the sender/server shape instead of discarding the alternate
  addressing information.
- Resolve the actual decryption JID through the LID mapping store before session
  decryption. When the envelope reveals a new PN<->LID pair, persist it and
  opportunistically migrate sessions.
- Treat the LID side as canonical when both PN and LID are available; PN is the
  compatibility/migration path.
- Keep WhatsApp NACK reason codes near the decode/decrypt path so parse and
  decryption failures map to the correct ack error.
- Handle `ProtocolMessage` side effects in the core receiver path:
  - history sync notifications
  - app-state sync key share injection
  - peer-data operation request responses
  - revoke / ephemeral setting / message edit
  - group member label change
  - LID migration mapping sync

### 8.4 Receipt handling

File: `lib/baileys_ex/message/receipt.ex`

```elixir
defmodule BaileysEx.Message.Receipt do
  def send_receipt(conn, message_node, type) do
    # type: :delivered | :read | :played
    node = build_receipt_node(message_node, type)
    Connection.Socket.send_node(conn, node)
  end

  def process_receipt(%BinaryNode{tag: "receipt"} = node, conn) do
    receipt = parse_receipt(node)
    EventEmitter.emit(conn, {:receipt, receipt})
  end
end
```

### 8.5 Retry logic

File: `lib/baileys_ex/message/retry.ex`

```elixir
defmodule BaileysEx.Message.Retry do
  @moduledoc """
  Sophisticated message retry management. Handles retry reason codes,
  MAC error detection, session recreation, recent-message replay, and
  scheduled phone requests. Mirrors Baileys' MessageRetryManager behavior.
  """

  @max_retries 5
  @session_recreate_cooldown_ms 3_600_000  # 1 hour
  @phone_request_delay_ms 3_000
  @recent_message_cache_ttl_ms 300_000     # 5 minutes
  @recent_message_cache_size 512
  @mac_error_codes [4, 7]

  # v7 tightened retry/session recreation loops to recover missing sessions,
  # pre-key failures, and history gaps without spinning forever. Mirror the
  # manager semantics, not older ad-hoc retry snippets.

  # Gate recent-message replay behind Connection.Config.enable_recent_message_cache
  # to mirror Baileys' enableRecentMessageCache behavior.

  # Retry reason codes (matching Baileys RetryReason enum)
  @retry_reasons [
    :unknown_error, :signal_error_no_session, :signal_error_invalid_key,
    :signal_error_bad_mac, :signal_error_duplicate_message,
    :signal_error_invalid_cipher, :signal_error_stale_key,
    :decryption_error, :serialization_error, :no_sender_key,
    :sender_key_error, :pre_key_error, :plaintext_error, :unknown
  ]

  @doc "Handle a retry request from recipient"
  def handle_retry_receipt(conn, node) do
    retry_count = parse_retry_count(node)
    error_code = parse_error_code(node)
    message_id = node.attrs["id"]

    cond do
      retry_count > @max_retries ->
        {:error, :max_retries_exceeded}

      mac_error?(error_code) ->
        # MAC errors: recreate session immediately (if cooldown elapsed)
        maybe_recreate_session(conn, node)
        resend_message(conn, message_id)

      true ->
        resend_message(conn, message_id)
    end
  end

  @doc "Send retry request when we can't decrypt an incoming message"
  def send_retry_request(conn, original_node, opts \\ []) do
    retry_count = get_retry_count(original_node.attrs["id"])
    force_keys = opts[:force_include_keys] || retry_count > 1

    # If recent-message caching is enabled, schedule a delayed phone request for
    # retry_count <= 2. The manager keeps the callback debounced per message ID.
    node = build_retry_receipt(original_node, retry_count, force_keys)
    Connection.Socket.send_node(conn, node)
    increment_retry_count(original_node.attrs["id"])
  end

  @doc "Request placeholder resend for unavailable messages via PDO"
  def request_placeholder_resend(conn, message_key, msg_data \\ nil) do
    # Cache-checked (1 hour TTL to prevent duplicates)
    # 2-second delay before request
    # 8-second timeout for phone offline detection
    # Uses BaileysEx.Message.PeerData.send_request/3 under the hood
  end

  @doc "Store a recently sent plaintext/ciphertext envelope for resend"
  def add_recent_message(conn, message_id, message) do
    # Bounded cache: 512 entries, 5 minute TTL, disabled unless config opts in
  end

  @doc "Look up a cached recent message before falling back to persistence"
  def get_recent_message(conn, message_id) do
    # Returns nil when recent-message cache is disabled or entry expired
  end

  defp mac_error?(code) when code in @mac_error_codes, do: true
  defp mac_error?(_), do: false

  defp maybe_recreate_session(conn, node) do
    sender = extract_sender_jid(node)
    last_recreate = Store.get_session_recreate_time(conn, sender)
    now = System.monotonic_time(:millisecond)

    if is_nil(last_recreate) or (now - last_recreate) > @session_recreate_cooldown_ms do
      Store.delete_session(conn, sender)
      Store.set_session_recreate_time(conn, sender, now)
      :ok
    else
      :cooldown_active
    end
  end

  defp parse_retry_count(node) do
    node
    |> BinaryNode.child("retry")
    |> BinaryNode.attr("count")
    |> String.to_integer()
  end

  defp parse_error_code(node) do
    case BinaryNode.child(node, "error") do
      nil -> nil
      error -> error |> BinaryNode.attr("code") |> String.to_integer()
    end
  end
end
```

### 8.5a Peer Data Operations (PDO)

File: `lib/baileys_ex/message/peer_data.ex`

Baileys uses `sendPeerDataOperationMessage()` to send protocol messages to the
primary device. This is shared infrastructure for on-demand history sync,
placeholder resend, and future phone-only flows.

```elixir
defmodule BaileysEx.Message.PeerData do
  @moduledoc """
  Shared transport for peer data operation requests. Sends a protocol message to
  the authenticated primary JID with `category=peer`, `push_priority=high_force`,
  and a `meta appdata=default` child node.
  """

  def send_request(conn, pdo_message, opts \\ []) do
    # Wrap pdo_message in ProtocolMessage.PEER_DATA_OPERATION_REQUEST_MESSAGE
    # Relay to normalized self JID
    # Return generated message/request ID
  end

  @doc "User-facing on-demand history fetch (Baileys fetchMessageHistory/4)"
  def fetch_message_history(conn, count, oldest_msg_key, oldest_msg_timestamp) do
    # Build HISTORY_SYNC_ON_DEMAND request and send via send_request/3
  end
end
```

Keep PDO as its own small module rather than hiding it inside sender/receiver code.
That keeps `request_placeholder_resend/3`, history sync, and future peer-only
operations on a single transport path.

### 8.6 Device discovery

File: `lib/baileys_ex/signal/device.ex`

```elixir
defmodule BaileysEx.Signal.Device do
  @doc "Get device list for a JID, with caching"
  def get_devices(conn, jid) do
    case Store.get_devices(conn, jid) do
      {:ok, devices} -> {:ok, devices}
      {:error, :not_found} -> fetch_devices(conn, jid)
    end
  end

  defp fetch_devices(conn, jid) do
    node = build_usync_query(jid)
    {:ok, response} = Connection.Socket.send_node_and_wait(conn, node)
    devices = parse_device_list(response)
    Store.save_devices(conn, jid, devices)
    {:ok, devices}
  end
end
```

### 8.7 Bad ACK handling (GAP-40)

Handles error acknowledgements from the server. When the server responds with
an ack containing an error code, the message status must be updated to ERROR.

```elixir
# In the Receiver module or as a separate handler:

@doc "Handle server ack with error code"
def handle_bad_ack(%BinaryNode{tag: "ack", attrs: %{"class" => "message", "error" => error_code}} = node, conn) do
  message_id = node.attrs["id"]
  from_jid = node.attrs["from"]
  participant = node.attrs["participant"]

  EventEmitter.emit(conn, {:messages_update, [%{
    key: %{
      remote_jid: from_jid,
      id: message_id,
      from_me: true,
      participant: participant
    },
    update: %{
      status: :ERROR,
      message_stub_parameters: [error_code]
    }
  }]})
end
```

Reference: `dev/reference/Baileys-master/src/Socket/messages-recv.ts` L1453-1498

### 8.7a Verified Name Certificates (GAP-35)

Parse verified business name certificates from received messages. These appear
in `verifiedBizName` fields and contain signed business identity data.

```elixir
# In BaileysEx.Message.Normalizer or a dedicated module:

@doc "Extract verified business name from message if present"
def extract_verified_name(message) do
  case message.verified_biz_name do
    nil -> nil
    cert_binary ->
      # Decode VerifiedNameCertificate protobuf
      # Extract: verified_name, serial_number, issuer_serial
      # Verify signature against known WhatsApp business CA key
      # Return %{name: "Business Name", verified: true/false}
      with {:ok, cert} <- Proto.VerifiedNameCertificate.decode(cert_binary),
           {:ok, details} <- Proto.VerifiedNameCertificate.Details.decode(cert.details) do
        %{
          name: details.verified_name,
          serial: details.serial,
          issuer: details.issuer_serial,
          verified: verify_biz_cert_signature(cert)
        }
      else
        _ -> nil
      end
  end
end
```

Reference: `dev/reference/Baileys-master/src/Utils/validate-connection.ts`

### 8.8 Notification handler

File: `lib/baileys_ex/message/notification_handler.ex`

Processes all notification types from the server. Each notification type
has specific parsing and event emission logic.

```elixir
defmodule BaileysEx.Message.NotificationHandler do
  @moduledoc """
  Processes all notification types from the server. Each notification type
  has specific parsing and event emission logic.
  """

  @doc "Route notification to appropriate handler"
  def process(%BinaryNode{tag: "notification", attrs: %{"type" => type}} = node, conn) do
    case type do
      "w:gp2"       -> handle_group_notification(node, conn)
      "encrypt"     -> handle_encrypt_notification(node, conn)
      "devices"     -> handle_device_notification(node, conn)
      "picture"     -> handle_picture_notification(node, conn)
      "account_sync" -> handle_account_sync(node, conn)
      "server_sync" -> handle_server_sync(node, conn)
      "mediaretry"  -> handle_media_retry(node, conn)
      "newsletter"  -> handle_newsletter_notification(node, conn)
      "mex"         -> handle_mex_notification(node, conn)
      "link_code_companion_reg" -> handle_link_code(node, conn)
      "privacy_token" -> handle_privacy_token(node, conn)
      _ -> Logger.debug("Unhandled notification type: #{type}")
    end
  end

  # Group notifications produce messageStubType values:
  @group_stub_types [
    :create, :ephemeral, :not_ephemeral, :modify, :promote, :demote,
    :remove, :add, :leave, :subject, :description, :announcement,
    :not_announcement, :locked, :unlocked, :invite, :member_add_mode,
    :membership_approval_mode, :created_membership_requests,
    :revoked_membership_requests
  ]

  defp handle_group_notification(node, conn) do
    # Parse child nodes to determine stub type
    # Emit :groups_upsert / :groups_update / :chats_upsert events
    # Generate synthetic message with stub type
  end

  defp handle_encrypt_notification(node, conn) do
    # Identity key changes → session refresh
    # Pre-key count updates → upload if needed
  end

  defp handle_picture_notification(node, conn) do
    # Profile picture changes → emit :contacts_update with img_url: :changed | :removed
  end

  defp handle_account_sync(node, conn) do
    # Disappearing mode changes, blocklist updates → emit :blocklist_update
  end

  defp handle_media_retry(node, conn) do
    # Decode media retry → emit :messages_media_update
  end
end
```

### 8.9 History sync

File: `lib/baileys_ex/message/history_sync.ex`

Downloads and processes history sync notifications. Handles initial
bootstrap, recent messages, full sync, push names, and on-demand fetch.

```elixir
defmodule BaileysEx.Message.HistorySync do
  @moduledoc """
  Downloads and processes history sync notifications. Handles initial
  bootstrap, recent messages, full sync, push names, and on-demand fetch.
  """

  @sync_types [:initial_bootstrap, :push_name, :recent, :full, :on_demand]

  @doc "Download, decompress, and process history sync notification"
  def process(history_sync_msg, conn) do
    with {:ok, compressed} <- download_blob(history_sync_msg),
         {:ok, decompressed} <- decompress(compressed),
         {:ok, history} <- Proto.HistorySyncNotification.decode(decompressed) do
      process_by_type(history, conn)
    end
  end

  defp process_by_type(%{sync_type: :INITIAL_BOOTSTRAP} = hist, conn) do
    # Extract messages, contacts, chats from conversations
    # Extract LID↔PN mappings from conversations (GAP-45)
    # Primary: use explicit phoneNumberToLidMappings array
    # Fallback 1: use chat.pnJid field
    # Fallback 2: iterate outgoing messages' userReceipt arrays to extract
    #   recipient phone numbers when explicit mappings are missing.
    #   This hack is mandatory for multi-device decryption routing.
    extract_pn_lid_mappings(hist.conversations, conn)
    # Emit :messages_upsert (type: :append), :chats_upsert, :contacts_upsert
  end

  defp process_by_type(%{sync_type: :PUSH_NAME} = hist, conn) do
    # Extract push name updates
    # Emit :contacts_upsert with push names
  end

  defp process_by_type(%{sync_type: :RECENT} = hist, conn) do
    # Extract recent messages
    # Emit :messages_upsert (type: :append)
  end

  defp process_by_type(%{sync_type: :FULL} = hist, conn) do
    # Full history — extract all conversations
    # Emit :messages_upsert, :chats_upsert, :contacts_upsert
  end

  defp process_by_type(%{sync_type: :ON_DEMAND} = hist, conn) do
    # On-demand history fetch result
    # Emit :messages_upsert (type: :append)
  end

  @doc "Fetch message history on demand via Peer Data Operation"
  def fetch_message_history(conn, count, oldest_msg_key, oldest_msg_timestamp) do
    # Build HISTORY_SYNC_ON_DEMAND request
    # Send via BaileysEx.Message.PeerData.send_request/3
  end

  # --- PN-LID Fallback Recovery (GAP-45) ---

  defp extract_pn_lid_mappings(conversations, conn) do
    Enum.each(conversations, fn conv ->
      cond do
        # Primary: explicit mapping array
        conv.phone_number_to_lid_mappings != [] ->
          Enum.each(conv.phone_number_to_lid_mappings, fn mapping ->
            Store.save_lid_pn_mapping(conn, mapping.lid_jid, mapping.pn_jid)
          end)

        # Fallback 1: chat has pnJid
        conv.pn_jid != nil ->
          Store.save_lid_pn_mapping(conn, conv.id, conv.pn_jid)

        # Fallback 2: extract from outgoing message userReceipt arrays
        true ->
          extract_pn_from_messages(conv.messages, conn)
      end
    end)
  end

  defp extract_pn_from_messages(messages, conn) do
    Enum.each(messages, fn msg ->
      if msg.key.from_me do
        Enum.each(msg.user_receipt || [], fn receipt ->
          if JID.is_user?(receipt.user_jid) do
            Store.save_lid_pn_mapping(conn, msg.key.remote_jid, receipt.user_jid)
          end
        end)
      end
    end)
  end
end
```

### 8.10 Identity change handler

File: `lib/baileys_ex/message/identity_change_handler.ex`

Handles identity key change notifications. Filters companion devices,
skips self-primary and offline notifications, debounces, triggers
session refresh.

```elixir
defmodule BaileysEx.Message.IdentityChangeHandler do
  @moduledoc """
  Handles identity key change notifications. Filters companion devices,
  skips self-primary and offline notifications, debounces, triggers
  session refresh.
  """

  def handle(node, conn) do
    # Filter: skip non-zero companion devices, self-primary, offline
    # Debounce with ETS-based cache
    # Validate existing session before refresh
    # Trigger session assertion if needed
  end
end
```

### 8.10a Addressing and decryption helpers

File: `lib/baileys_ex/message/decode.ex`

This module owns the wire-facing helper logic from Baileys
`Utils/decode-wa-message.ts`:

- extract envelope addressing context and preserve alt-address fields
- choose the correct decryption JID for PN/LID conversations
- expose retry/NACK reason constants for parse/decrypt failures
- store envelope-derived PN<->LID mappings and trigger session migration when
  new mappings are learned from message stanzas

### 8.11 Message normalization

File: `lib/baileys_ex/message/normalizer.ex`

Post-processing for received messages. Normalizes JIDs, processes
reactions/polls, handles LID/PN users.

```elixir
defmodule BaileysEx.Message.Normalizer do
  @moduledoc """
  Post-processing for received messages. Normalizes JIDs, processes
  reactions/polls, handles LID/PN users.
  """

  def normalize(message, me_jid, me_lid) do
    message
    |> normalize_jids(me_jid, me_lid)
    |> process_reaction_if_present()
    |> process_poll_if_present()
    |> process_event_response_if_present()
  end

  defp normalize_jids(message, me_jid, me_lid) do
    # Replace LID JIDs with phone number JIDs where possible
    # Normalize sender/participant JIDs
  end

  defp process_reaction_if_present(message) do
    # Extract reaction key, normalize JIDs in reaction target
  end

  defp process_poll_if_present(message) do
    # Decrypt poll vote if present, aggregate results
  end

  defp process_event_response_if_present(message) do
    # Decrypt event response payloads when the referenced event message secret
    # is available, then update the source event's response list.
  end
end
```

### 8.12 Tests

**Builder tests** (`test/baileys_ex/message/builder_test.exs`):
- Text message → `conversation` field
- Text with quote/mentions → `extended_text_message` with `context_info`
- Text with link preview → `extended_text_message` with preview fields
- Reaction → `reaction_message` with key + emoji + timestamp
- Poll (multi-select) → `poll_creation_message` with options and secret
- Poll (single-select) → `poll_creation_message_v3`
- Single contact → `contact_message` with vCard
- Multiple contacts → `contacts_array_message`
- Static location → `location_message` with lat/lng
- Live location → `live_location_message`
- Message deletion → `protocol_message` with type `:REVOKE`
- Message editing → `protocol_message` with type `:MESSAGE_EDIT`
- Disappearing messages → `protocol_message` with `:EPHEMERAL_SETTING`
- Pin in chat → `pin_in_chat_message` with duration
- Group invite → `group_invite_message` with code and JID
- Forward → preserves content, increments `forwarding_score`
- Event → `event_message` with name, times, secret
- Product → `product_message` with snapshot
- Button reply → `buttons_response_message` / `template_button_reply_message`
- List reply → `list_response_message` with selected row
- View once → wraps inner message in `view_once_message`
- Media placeholders (image/video/audio/document/sticker) → correct proto types

**Parser tests** (`test/baileys_ex/message/parser_test.exs`):
- Unwraps ephemeral wrapper
- Unwraps viewOnce wrapper (v1 and v2)
- Detects content type for all message types
- Handles nested wrappers (ephemeral + viewOnce)

**Pipeline tests**:
- Send pipeline constructs correct relay nodes
- Receiver decrypts and parses messages correctly (mock Signal)
- Receipt nodes match expected format
- Retry logic respects max retry count
- Device discovery caches results
- Status broadcast sends to `status@broadcast` with `status_jid_list`
- End-to-end: build → encrypt → decrypt → parse roundtrip

---

## Acceptance Criteria

- [ ] Text message send/receive pipeline works end-to-end (with mock server)
- [ ] Signal encryption/decryption integrated into pipeline
- [ ] Device discovery queries and caches device lists
- [ ] Receipts (delivered, read, played) sent correctly
- [ ] Retry logic handles failed decryption
- [ ] **Builder covers ALL message types explicitly** (no catch-all clause)
- [ ] Events emitted for received messages
- [ ] Reactions send and receive correctly
- [ ] Polls create with message secret, correct version selection (V1/V2/V3)
- [ ] Contacts: single → `contactMessage`, multiple → `contactsArrayMessage`
- [ ] Location and live location produce correct proto
- [ ] Message delete (revoke) constructs correct `protocolMessage`
- [ ] Message edit constructs correct `protocolMessage` with `:MESSAGE_EDIT`
- [ ] Disappearing messages toggle via `protocolMessage` with `:EPHEMERAL_SETTING`
- [ ] Pin/unpin in chat with duration
- [ ] Forward increments `forwarding_score` and sets `is_forwarded`
- [ ] Status/stories send to `status@broadcast` with viewer list
- [ ] Parser correctly unwraps ephemeral/viewOnce/template wrappers
- [ ] Parser detects content type for all known message types
- [ ] Inbound interactive messages (buttons, lists, templates) parsed without crash
- [ ] Notification handler processes all 11 notification types
- [ ] Group notifications produce correct stub types (20+ types)
- [ ] History sync downloads, decompresses, and processes correctly
- [ ] History sync emits correct events by sync type
- [ ] DSM wrapper sent to own devices for 1:1 messages
- [ ] Group messages distribute SKD to new devices
- [ ] Sender key memory tracked and updated per group
- [ ] Message ID format matches Baileys (3EB0 + timestamp + random)
- [ ] Participant hash V2 computed and sent as phash attribute
- [ ] Retry manager handles 14 reason codes with proper session recreation
- [ ] MAC errors trigger immediate session recreation (with 1-hour cooldown)
- [ ] Recent-message cache and scheduled phone requests match MessageRetryManager semantics when enabled
- [ ] Identity change notifications trigger session refresh
- [ ] Placeholder resend requests sent via PDO with deduplication
- [ ] Peer Data Operation requests are sent to self with `category=peer` and `meta appdata=default`
- [ ] ProtocolMessage side effects cover history sync, app-state key share, PDO responses, label-change, edit/revoke, and LID migration mapping sync
- [ ] Decode path preserves alt addressing fields and uses LID mapping for decryption routing
- [ ] Received messages normalized (JIDs, reactions, polls, LID/PN)
- [ ] Received event responses decrypt and update the source event message when the message secret is available
- [ ] Reporting tokens attached to applicable message types (GAP-32)
- [ ] Bad ACK errors emit messages.update with ERROR status (GAP-40)
- [ ] History sync extracts PN-LID mappings with fallback recovery (GAP-45)
- [ ] Offline node processor drains FIFO batches of 10 without long scheduler monopolization

## Files Created/Modified

- `lib/baileys_ex/message/builder.ex`
- `lib/baileys_ex/message/parser.ex`
- `lib/baileys_ex/message/sender.ex`
- `lib/baileys_ex/message/receiver.ex`
- `lib/baileys_ex/message/decode.ex`
- `lib/baileys_ex/message/receipt.ex`
- `lib/baileys_ex/message/retry.ex`
- `lib/baileys_ex/message/peer_data.ex`
- `lib/baileys_ex/signal/device.ex`
- `test/baileys_ex/message/builder_test.exs`
- `test/baileys_ex/message/parser_test.exs`
- `test/baileys_ex/message/sender_test.exs`
- `test/baileys_ex/message/receiver_test.exs`
- `test/baileys_ex/message/decode_test.exs`
- `test/baileys_ex/message/receipt_test.exs`
- `test/baileys_ex/message/peer_data_test.exs`
- `lib/baileys_ex/message/notification_handler.ex`
- `lib/baileys_ex/message/history_sync.ex`
- `lib/baileys_ex/message/identity_change_handler.ex`
- `lib/baileys_ex/message/normalizer.ex`
- `test/baileys_ex/message/notification_handler_test.exs`
- `test/baileys_ex/message/history_sync_test.exs`
