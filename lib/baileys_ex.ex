defmodule BaileysEx do
  @moduledoc """
  Public facade for the BaileysEx connection runtime and major feature surfaces.

  ## Quick Start

      alias BaileysEx.Auth.NativeFilePersistence
      alias BaileysEx.Connection.Transport.MintWebSocket

      {:ok, persisted_auth} =
        NativeFilePersistence.use_native_file_auth_state("tmp/baileys_auth")
      parent = self()

      {:ok, connection} =
        BaileysEx.connect(
          persisted_auth.state,
          Keyword.merge(persisted_auth.connect_opts, [
            transport: {MintWebSocket, []},
            on_qr: fn qr -> IO.puts("Scan QR: \#{qr}") end,
            on_connection: fn update ->
              IO.inspect({:connection, update})
              send(parent, {:connection_update, update})
            end
          ])
        )

      _creds_unsubscribe =
        BaileysEx.subscribe_raw(connection, fn events ->
          if Map.has_key?(events, :creds_update) do
            {:ok, latest_auth_state} = BaileysEx.auth_state(connection)
            :ok = persisted_auth.save_creds.(latest_auth_state)
          end
        end)

      receive do
        {:connection_update, %{connection: :open}} -> :ok
      after
        30_000 -> raise "connection did not open"
      end

      unsubscribe =
        BaileysEx.subscribe(connection, fn
          {:message, message} -> IO.inspect(message, label: "incoming")
          {:connection, update} -> IO.inspect(update, label: "connection")
          _other -> :ok
        end)

      unsubscribe.()
      :ok = BaileysEx.disconnect(connection)

  ## Persistence Backends

  Use `BaileysEx.Auth.NativeFilePersistence.use_native_file_auth_state/1` for the
  recommended durable file-backed setup in Elixir-first apps.

  Use `BaileysEx.Auth.FilePersistence.use_multi_file_auth_state/1` when you need
  the Baileys-compatible JSON multi-file auth layout and helper semantics.

  Custom SQL/NoSQL backends remain supported through
  `BaileysEx.Auth.Persistence`, `BaileysEx.Auth.KeyStore`, and a matching
  `signal_store_module`.

  Advanced callers can obtain the raw socket transport tuple via `queryable/1`
  and pass it directly to the lower-level feature modules.

  Outbound `send_message/4` and `send_status/3` use the built-in production Signal
  adapter by default when the auth state includes `signed_identity_key`,
  `signed_pre_key`, and `registration_id`. Use `:signal_repository` or
  `:signal_repository_adapter` only when you need to override that default.
  """

  alias BaileysEx.Connection.EventEmitter
  alias BaileysEx.Connection.Store, as: RuntimeStore
  alias BaileysEx.Connection.Supervisor, as: ConnectionSupervisor
  alias BaileysEx.Connection.Version, as: ConnectionVersion
  alias BaileysEx.Feature.AppState
  alias BaileysEx.Feature.Business
  alias BaileysEx.Feature.Call
  alias BaileysEx.Feature.Community
  alias BaileysEx.Feature.Group
  alias BaileysEx.Feature.Newsletter
  alias BaileysEx.Feature.PhoneValidation
  alias BaileysEx.Feature.Presence
  alias BaileysEx.Feature.Privacy
  alias BaileysEx.Feature.Profile
  alias BaileysEx.JID
  alias BaileysEx.Media.Download
  alias BaileysEx.Media.Retry, as: MediaRetry
  alias BaileysEx.Message.Receipt
  alias BaileysEx.Protocol.JID, as: JIDUtil
  alias BaileysEx.Protocol.Proto.WebMessageInfo
  alias BaileysEx.Signal.Store, as: SignalStore
  alias BaileysEx.WAM.BinaryInfo, as: WAMBinaryInfo

  @type connection :: GenServer.server()
  @type unsubscribe_fun :: (-> :ok)

  @typedoc """
  Opaque WAProto `WebMessageInfo` struct accepted by media download and retry helpers.
  """
  @type web_message_info :: struct()

  @doc """
  Start a connection runtime and optionally attach convenience callbacks.

  Pass a real `:transport` such as `{BaileysEx.Connection.Transport.MintWebSocket, []}`
  when you want an actual WhatsApp connection. Without it, the default transport
  returns `{:error, :transport_not_configured}`.

  Use `BaileysEx.Auth.NativeFilePersistence.use_native_file_auth_state/1` for the
  recommended durable built-in file setup.

  Use `BaileysEx.Auth.FilePersistence.use_multi_file_auth_state/1` when you want the
  Baileys-compatible JSON multi-file helper instead.

  Custom persistence backends remain supported through `BaileysEx.Auth.Persistence`
  plus a compatible `signal_store_module`.

  Supported callback options:
  - `:on_connection` receives each `connection_update` payload
  - `:on_qr` receives QR strings extracted from `connection_update`
  - `:on_message` receives each message from `messages_upsert`
  - `:on_event` receives the raw buffered event map

  These convenience callbacks stay attached for the lifetime of the connection runtime.
  Use `subscribe/2` or `subscribe_raw/2` when you need an explicit unsubscribe handle.
  """
  @spec connect(term(), keyword()) :: {:ok, pid()} | {:error, term()}
  def connect(auth_state, opts \\ []) when is_list(opts) do
    {callback_opts, connection_opts} =
      Keyword.split(opts, [:on_connection, :on_event, :on_message, :on_qr])

    auth_state
    |> ConnectionSupervisor.start_connection(
      maybe_put_initial_event_subscribers(connection_opts, callback_opts)
    )
  end

  @doc "Stop a running connection runtime."
  @spec disconnect(connection()) :: :ok | {:error, term()}
  def disconnect(connection), do: ConnectionSupervisor.stop_connection(connection)

  @doc "Return the underlying socket transport tuple used by feature modules."
  @spec queryable(connection()) :: {:ok, {module(), pid()}} | {:error, :socket_not_available}
  def queryable(connection) do
    case ConnectionSupervisor.queryable(connection) do
      {module, pid} -> {:ok, {module, pid}}
      nil -> {:error, :socket_not_available}
    end
  end

  @doc "Return the connection event emitter pid."
  @spec event_emitter(connection()) :: {:ok, pid()} | {:error, :event_emitter_not_available}
  def event_emitter(connection) do
    case ConnectionSupervisor.event_emitter(connection) do
      pid when is_pid(pid) -> {:ok, pid}
      _ -> {:error, :event_emitter_not_available}
    end
  end

  @doc "Return the wrapped Signal store for the connection when present."
  @spec signal_store(connection()) ::
          {:ok, SignalStore.t()} | {:error, :signal_store_not_available}
  def signal_store(connection) do
    case ConnectionSupervisor.signal_store(connection) do
      %SignalStore{} = store -> {:ok, store}
      _ -> {:error, :signal_store_not_available}
    end
  end

  @doc """
  Return the current auth state snapshot from the connection store.

  `creds_update` events are mirrored into the store before public subscribers run,
  so callers can safely read `auth_state/1` from inside those callbacks.
  """
  @spec auth_state(connection()) :: {:ok, map()} | {:error, :store_not_available}
  def auth_state(connection) do
    case ConnectionSupervisor.store(connection) do
      pid when is_pid(pid) ->
        store_ref = BaileysEx.Connection.Store.wrap(pid)
        {:ok, BaileysEx.Connection.Store.get(store_ref, :auth_state, %{})}

      _ ->
        {:error, :store_not_available}
    end
  end

  @doc "Subscribe to raw buffered event maps."
  @spec subscribe_raw(connection(), (map() -> term())) ::
          unsubscribe_fun() | {:error, :event_emitter_not_available}
  def subscribe_raw(connection, handler) when is_function(handler, 1) do
    ConnectionSupervisor.subscribe(connection, handler)
  end

  @doc """
  Subscribe to friendly high-level events.

  The handler receives:
  - `{:connection, update}` for connection lifecycle updates
  - `{:message, message}` for each incoming message
  - `{:presence, update}` for presence updates
  - `{:call, payload}` for call events
  - `{:event, name, payload}` for all other event payloads
  """
  @spec subscribe(connection(), (tuple() -> term())) ::
          unsubscribe_fun() | {:error, :event_emitter_not_available}
  def subscribe(connection, handler) when is_function(handler, 1) do
    subscribe_raw(connection, fn events -> dispatch_public_events(events, handler) end)
  end

  @doc "Request a phone-number pairing code from the active socket."
  @spec request_pairing_code(connection(), binary(), keyword()) ::
          {:ok, binary()} | {:error, term()}
  def request_pairing_code(connection, phone_number, opts \\ [])
      when is_binary(phone_number) and is_list(opts) do
    ConnectionSupervisor.request_pairing_code(connection, phone_number, opts)
  end

  @doc """
  Send a message to a WhatsApp JID through the coordinator-managed runtime.

  By default, `connect/2` builds the production Signal adapter when the auth state
  includes `signed_identity_key`, `signed_pre_key`, and `registration_id`. Use
  `:signal_repository` or `:signal_repository_adapter` only to override it.
  """
  @spec send_message(connection(), String.t() | JID.t(), map() | struct(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def send_message(connection, jid, content, opts \\ []) when is_list(opts) do
    with {:ok, parsed_jid} <- normalize_jid(jid) do
      ConnectionSupervisor.send_message(connection, parsed_jid, content, opts)
    end
  end

  @doc """
  Send a status update through the `status@broadcast` fanout path.

  By default, `connect/2` builds the production Signal adapter when the auth state
  includes `signed_identity_key`, `signed_pre_key`, and `registration_id`. Use
  `:signal_repository` or `:signal_repository_adapter` only to override it.
  """
  @spec send_status(connection(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def send_status(connection, content, opts \\ []) when is_map(content) and is_list(opts) do
    ConnectionSupervisor.send_status(connection, content, opts)
  end

  @doc "Send a WAM analytics buffer or `BaileysEx.WAM.BinaryInfo` through the active socket."
  @spec send_wam_buffer(connection(), binary() | WAMBinaryInfo.t()) ::
          {:ok, BaileysEx.BinaryNode.t()} | {:error, term()}
  def send_wam_buffer(connection, %WAMBinaryInfo{} = binary_info) do
    binary_info
    |> BaileysEx.WAM.encode()
    |> then(&ConnectionSupervisor.send_wam_buffer(connection, &1))
  end

  def send_wam_buffer(connection, wam_buffer) when is_binary(wam_buffer) do
    ConnectionSupervisor.send_wam_buffer(connection, wam_buffer)
  end

  @doc "Fetch the latest version published by Baileys' current `Defaults/index.ts`."
  @spec fetch_latest_baileys_version(keyword()) :: map()
  def fetch_latest_baileys_version(opts \\ []),
    do: ConnectionVersion.fetch_latest_baileys_version(opts)

  @doc "Fetch the latest WhatsApp Web client revision from `web.whatsapp.com/sw.js`."
  @spec fetch_latest_wa_web_version(keyword()) :: map()
  def fetch_latest_wa_web_version(opts \\ []),
    do: ConnectionVersion.fetch_latest_wa_web_version(opts)

  @doc "Send an availability or chatstate update."
  @spec send_presence_update(connection(), Presence.presence(), String.t() | nil, keyword()) ::
          :ok | {:error, term()}
  def send_presence_update(connection, type, to_jid \\ nil, opts \\ []) when is_list(opts) do
    with_queryable(connection, fn queryable ->
      Presence.send_update(queryable, type, to_jid, maybe_put_presence_identity(opts, connection))
    end)
  end

  @doc "Subscribe to a contact or group presence feed."
  @spec presence_subscribe(connection(), String.t(), keyword()) :: :ok | {:error, term()}
  def presence_subscribe(connection, jid, opts \\ []) when is_binary(jid) and is_list(opts) do
    with_queryable(connection, fn queryable ->
      Presence.subscribe(queryable, jid, maybe_put_signal_store(opts, connection))
    end)
  end

  @doc "Archive or unarchive a chat via the app-state patch path."
  @spec archive_chat(connection(), String.t(), boolean(), list(), keyword()) ::
          :ok | {:error, term()}
  def archive_chat(connection, jid, archive?, last_messages, opts \\ [])
      when is_binary(jid) and is_list(last_messages) and is_list(opts) do
    with_app_state_runtime(
      connection,
      :archive,
      jid,
      %{archive: archive?, last_messages: last_messages},
      opts
    )
  end

  @doc "Mute a chat until the given Unix timestamp, or pass `nil` to unmute."
  @spec mute_chat(connection(), String.t(), integer() | nil, keyword()) :: :ok | {:error, term()}
  def mute_chat(connection, jid, duration, opts \\ [])
      when is_binary(jid) and is_list(opts) do
    with_app_state_runtime(connection, :mute, jid, duration, opts)
  end

  @doc "Pin or unpin a chat."
  @spec pin_chat(connection(), String.t(), boolean(), keyword()) :: :ok | {:error, term()}
  def pin_chat(connection, jid, pin?, opts \\ [])
      when is_binary(jid) and is_list(opts) do
    with_app_state_runtime(connection, :pin, jid, pin?, opts)
  end

  @doc "Star or unstar one or more messages in a chat."
  @spec star_messages(connection(), String.t(), [map()], boolean(), keyword()) ::
          :ok | {:error, term()}
  def star_messages(connection, jid, messages, star?, opts \\ [])
      when is_binary(jid) and is_list(messages) and is_list(opts) do
    with_app_state_runtime(connection, :star, jid, %{messages: messages, star: star?}, opts)
  end

  @doc "Mark a chat read or unread."
  @spec mark_chat_read(connection(), String.t(), boolean(), list(), keyword()) ::
          :ok | {:error, term()}
  def mark_chat_read(connection, jid, read?, last_messages, opts \\ [])
      when is_binary(jid) and is_list(last_messages) and is_list(opts) do
    with_app_state_runtime(
      connection,
      :mark_read,
      jid,
      %{read: read?, last_messages: last_messages},
      opts
    )
  end

  @doc "Clear a chat history via app-state sync."
  @spec clear_chat(connection(), String.t(), list(), keyword()) :: :ok | {:error, term()}
  def clear_chat(connection, jid, last_messages, opts \\ [])
      when is_binary(jid) and is_list(last_messages) and is_list(opts) do
    with_app_state_runtime(connection, :clear, jid, %{last_messages: last_messages}, opts)
  end

  @doc "Delete a chat via app-state sync."
  @spec delete_chat(connection(), String.t(), list(), keyword()) :: :ok | {:error, term()}
  def delete_chat(connection, jid, last_messages, opts \\ [])
      when is_binary(jid) and is_list(last_messages) and is_list(opts) do
    with_app_state_runtime(connection, :delete, jid, %{last_messages: last_messages}, opts)
  end

  @doc "Delete a specific message for the current device."
  @spec delete_message_for_me(connection(), String.t(), map(), integer(), boolean(), keyword()) ::
          :ok | {:error, term()}
  def delete_message_for_me(
        connection,
        jid,
        message_key,
        timestamp,
        delete_media? \\ false,
        opts \\ []
      )
      when is_binary(jid) and is_map(message_key) and is_integer(timestamp) and is_list(opts) do
    with_app_state_runtime(
      connection,
      :delete_for_me,
      jid,
      %{key: message_key, timestamp: timestamp, delete_media: delete_media?},
      opts
    )
  end

  @doc "Send read receipts for the provided message keys using current privacy settings."
  @spec read_messages(connection(), [map()], keyword()) :: :ok | {:error, term()}
  def read_messages(connection, keys, opts \\ []) when is_list(keys) and is_list(opts) do
    with_runtime(connection, opts, fn queryable, runtime_opts ->
      with {:ok, settings} <- Privacy.fetch_settings(queryable, false, runtime_opts) do
        Receipt.read_messages(
          runtime_send_node_fun(queryable),
          keys,
          normalize_privacy_settings(settings),
          opts
        )
      end
    end)
  end

  @doc "Update the app-state privacy toggle that disables server-side link previews."
  @spec update_link_previews_privacy(connection(), boolean(), keyword()) ::
          :ok | {:error, term()}
  def update_link_previews_privacy(connection, disabled?, opts \\ []) when is_list(opts) do
    with_app_state_runtime(connection, :disable_link_previews, "", disabled?, opts)
  end

  @doc "Check which phone numbers are registered on WhatsApp."
  @spec on_whatsapp(connection(), [String.t()], keyword()) ::
          {:ok, [%{exists: boolean(), jid: String.t()}]} | {:error, term()}
  def on_whatsapp(connection, phone_numbers, opts \\ [])
      when is_list(phone_numbers) and is_list(opts) do
    with_runtime(connection, opts, fn queryable, runtime_opts ->
      PhoneValidation.on_whatsapp(queryable, phone_numbers, runtime_opts)
    end)
  end

  @doc "Download media into memory."
  @spec download_media(map(), keyword()) :: {:ok, binary()} | {:error, term()}
  def download_media(message, opts \\ []), do: Download.download(message, opts)

  @doc "Download media directly to a file path."
  @spec download_media_to_file(map(), Path.t(), keyword()) :: {:ok, Path.t()} | {:error, term()}
  def download_media_to_file(message, path, opts \\ []),
    do: Download.download_to_file(message, path, opts)

  @doc """
  Request media re-upload and return the updated message with refreshed URLs.

  Sends a retry request, waits for the matching `messages_media_update` event,
  decrypts the response, and applies the refreshed `directPath`/`url`.

  ## Options

    * `:timeout` — milliseconds to wait for the media update event (default 10_000)

  """
  @spec update_media_message(connection(), web_message_info(), keyword()) ::
          {:ok, web_message_info()} | {:error, term()}
  def update_media_message(connection, %WebMessageInfo{} = message, opts \\ [])
      when is_list(opts) do
    with {:ok, queryable} <- queryable(connection),
         {:ok, emitter} <- event_emitter(connection),
         {:ok, auth} <- auth_state(connection) do
      me_id = get_in(auth, [:me, :id]) || get_in(auth, [:me_id])

      if is_binary(me_id) do
        {_mod, socket} = queryable

        MediaRetry.update_media_message(
          socket,
          emitter,
          message,
          Keyword.put(opts, :me_id, me_id)
        )
      else
        {:error, :me_id_not_available}
      end
    end
  end

  @doc "Fetch a profile picture URL."
  @spec profile_picture_url(connection(), String.t(), Profile.picture_type(), keyword()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def profile_picture_url(connection, jid, type \\ :preview, opts \\ [])
      when is_binary(jid) and is_list(opts) do
    with_queryable(connection, fn queryable ->
      Profile.picture_url(queryable, jid, type, maybe_put_signal_store(opts, connection))
    end)
  end

  @doc "Update the account status text."
  @spec update_profile_status(connection(), String.t(), keyword()) ::
          {:ok, BaileysEx.BinaryNode.t()} | {:error, term()}
  def update_profile_status(connection, status, opts \\ [])
      when is_binary(status) and is_list(opts) do
    with_queryable(connection, fn queryable -> Profile.update_status(queryable, status, opts) end)
  end

  @doc "Fetch profile status text for one or more JIDs."
  @spec fetch_status(connection(), [String.t()], keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_status(connection, jids, opts \\ []) when is_list(jids) and is_list(opts) do
    with_runtime(connection, opts, fn queryable, runtime_opts ->
      Profile.fetch_status(queryable, jids, runtime_opts)
    end)
  end

  @doc "Fetch the business profile for a WhatsApp JID."
  @spec business_profile(connection(), String.t(), keyword()) ::
          {:ok, map() | nil} | {:error, term()}
  def business_profile(connection, jid, opts \\ [])
      when is_binary(jid) and is_list(opts) do
    with_runtime(connection, opts, fn queryable, runtime_opts ->
      Profile.get_business_profile(queryable, jid, runtime_opts)
    end)
  end

  @doc "Update the current account push name via app-state sync."
  @spec update_profile_name(connection(), String.t(), keyword()) :: :ok | {:error, term()}
  def update_profile_name(connection, name, opts \\ [])
      when is_binary(name) and is_list(opts) do
    with_app_state_runtime(connection, :push_name_setting, "", name, opts)
  end

  @doc "Update the profile picture for yourself or a group."
  @spec update_profile_picture(connection(), String.t(), term(), map() | nil, keyword()) ::
          {:ok, BaileysEx.BinaryNode.t()} | {:error, term()}
  def update_profile_picture(connection, jid, image_data, dimensions \\ nil, opts \\ [])
      when is_binary(jid) and is_list(opts) do
    with_runtime(connection, opts, fn queryable, runtime_opts ->
      Profile.update_picture(queryable, jid, image_data, dimensions, runtime_opts)
    end)
  end

  @doc "Remove the profile picture for yourself or a group."
  @spec remove_profile_picture(connection(), String.t(), keyword()) ::
          {:ok, BaileysEx.BinaryNode.t()} | {:error, term()}
  def remove_profile_picture(connection, jid, opts \\ [])
      when is_binary(jid) and is_list(opts) do
    with_runtime(connection, opts, fn queryable, runtime_opts ->
      Profile.remove_picture(queryable, jid, runtime_opts)
    end)
  end

  @doc "Reject an inbound call."
  @spec reject_call(connection(), String.t(), String.t(), keyword()) ::
          {:ok, BaileysEx.BinaryNode.t()} | {:error, term()}
  def reject_call(connection, call_id, caller_jid, opts \\ [])
      when is_binary(call_id) and is_binary(caller_jid) and is_list(opts) do
    with_runtime(connection, opts, fn queryable, runtime_opts ->
      Call.reject_call(queryable, call_id, caller_jid, runtime_opts)
    end)
  end

  @doc "Create an audio or video call link."
  @spec create_call_link(connection(), :audio | :video, map() | nil, keyword()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def create_call_link(connection, type, event \\ nil, opts \\ [])
      when type in [:audio, :video] and (is_map(event) or is_nil(event)) and is_list(opts) do
    merged_opts =
      if is_nil(event) do
        opts
      else
        Keyword.put_new(opts, :event, event)
      end

    with_runtime(connection, merged_opts, fn queryable, runtime_opts ->
      Call.create_call_link(queryable, type, runtime_opts)
    end)
  end

  @doc "Create a group."
  @spec group_create(connection(), String.t(), [String.t()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def group_create(connection, subject, participants, opts \\ [])
      when is_binary(subject) and is_list(participants) and is_list(opts) do
    with_queryable(connection, fn queryable ->
      Group.create(queryable, subject, participants, opts)
    end)
  end

  @doc "Fetch group metadata."
  @spec group_metadata(connection(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def group_metadata(connection, group_jid, opts \\ [])
      when is_binary(group_jid) and is_list(opts) do
    with_queryable(connection, fn queryable -> Group.get_metadata(queryable, group_jid, opts) end)
  end

  @doc "Leave a group."
  @spec group_leave(connection(), String.t()) :: :ok | {:error, term()}
  def group_leave(connection, group_jid) when is_binary(group_jid) do
    with_queryable(connection, fn queryable -> Group.leave(queryable, group_jid) end)
  end

  @doc "Add, remove, promote, or demote group participants."
  @spec group_participants_update(
          connection(),
          String.t(),
          [String.t()],
          :add | :remove | :promote | :demote,
          keyword()
        ) :: {:ok, [map()]} | {:error, term()}
  def group_participants_update(connection, group_jid, jids, action, opts \\ [])
      when is_binary(group_jid) and is_list(jids) and
             action in [:add, :remove, :promote, :demote] and is_list(opts) do
    with_queryable(connection, fn queryable ->
      case action do
        :add -> Group.add_participants(queryable, group_jid, jids)
        :remove -> Group.remove_participants(queryable, group_jid, jids)
        :promote -> Group.promote_participants(queryable, group_jid, jids)
        :demote -> Group.demote_participants(queryable, group_jid, jids)
      end
    end)
  end

  @doc "Update a group subject."
  @spec group_update_subject(connection(), String.t(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def group_update_subject(connection, group_jid, subject, opts \\ [])
      when is_binary(group_jid) and is_binary(subject) and is_list(opts) do
    with_queryable(connection, fn queryable ->
      Group.update_subject(queryable, group_jid, subject)
    end)
  end

  @doc "Update or clear a group description."
  @spec group_update_description(connection(), String.t(), String.t() | nil, keyword()) ::
          :ok | {:error, term()}
  def group_update_description(connection, group_jid, description, opts \\ [])
      when is_binary(group_jid) and is_list(opts) do
    with_queryable(connection, fn queryable ->
      Group.update_description(queryable, group_jid, description, opts)
    end)
  end

  @doc "Update a group announcement or locked setting."
  @spec group_setting_update(
          connection(),
          String.t(),
          :announcement | :not_announcement | :locked | :unlocked,
          keyword()
        ) :: :ok | {:error, term()}
  def group_setting_update(connection, group_jid, setting, opts \\ [])
      when is_binary(group_jid) and
             setting in [:announcement, :not_announcement, :locked, :unlocked] and
             is_list(opts) do
    with_queryable(connection, fn queryable ->
      Group.setting_update(queryable, group_jid, setting)
    end)
  end

  @doc "Fetch the current group invite code."
  @spec group_invite_code(connection(), String.t(), keyword()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def group_invite_code(connection, group_jid, opts \\ [])
      when is_binary(group_jid) and is_list(opts) do
    with_queryable(connection, fn queryable -> Group.invite_code(queryable, group_jid) end)
  end

  @doc "Revoke the current group invite code and return the new one."
  @spec group_revoke_invite(connection(), String.t(), keyword()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def group_revoke_invite(connection, group_jid, opts \\ [])
      when is_binary(group_jid) and is_list(opts) do
    with_queryable(connection, fn queryable -> Group.revoke_invite(queryable, group_jid) end)
  end

  @doc "Accept a legacy group invite code."
  @spec group_accept_invite(connection(), String.t(), keyword()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def group_accept_invite(connection, code, opts \\ [])
      when is_binary(code) and is_list(opts) do
    with_queryable(connection, fn queryable -> Group.accept_invite(queryable, code) end)
  end

  @doc "Fetch group invite metadata without joining."
  @spec group_get_invite_info(connection(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def group_get_invite_info(connection, code, opts \\ [])
      when is_binary(code) and is_list(opts) do
    with_queryable(connection, fn queryable -> Group.get_invite_info(queryable, code) end)
  end

  @doc "Accept a v4 group invite."
  @spec group_accept_invite_v4(connection(), String.t() | map(), map(), keyword()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def group_accept_invite_v4(connection, key, invite_message, opts \\ []) when is_list(opts) do
    with_runtime(connection, opts, fn queryable, runtime_opts ->
      Group.accept_invite_v4(queryable, key, invite_message, runtime_opts)
    end)
  end

  @doc "Revoke a v4 group invite for a specific invited user."
  @spec group_revoke_invite_v4(connection(), String.t(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def group_revoke_invite_v4(connection, group_jid, invited_jid, opts \\ [])
      when is_binary(group_jid) and is_binary(invited_jid) and is_list(opts) do
    with_queryable(connection, fn queryable ->
      Group.revoke_invite_v4(queryable, group_jid, invited_jid)
    end)
  end

  @doc "Fetch the pending join-request list for a group."
  @spec group_request_participants_list(connection(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def group_request_participants_list(connection, group_jid, opts \\ [])
      when is_binary(group_jid) and is_list(opts) do
    with_queryable(connection, fn queryable ->
      Group.request_participants_list(queryable, group_jid)
    end)
  end

  @doc "Approve or reject pending group join requests."
  @spec group_request_participants_update(
          connection(),
          String.t(),
          [String.t()],
          :approve | :reject,
          keyword()
        ) :: {:ok, [map()]} | {:error, term()}
  def group_request_participants_update(connection, group_jid, jids, action, opts \\ [])
      when is_binary(group_jid) and is_list(jids) and action in [:approve, :reject] and
             is_list(opts) do
    with_queryable(connection, fn queryable ->
      Group.request_participants_update(queryable, group_jid, jids, action)
    end)
  end

  @doc "Fetch all participating groups."
  @spec group_fetch_all_participating(connection(), keyword()) ::
          {:ok, %{String.t() => map()}} | {:error, term()}
  def group_fetch_all_participating(connection, opts \\ []) when is_list(opts) do
    with_runtime(connection, opts, fn queryable, runtime_opts ->
      Group.fetch_all_participating(queryable, runtime_opts)
    end)
  end

  @doc "Enable or disable disappearing messages for a group."
  @spec group_toggle_ephemeral(connection(), String.t(), non_neg_integer(), keyword()) ::
          :ok | {:error, term()}
  def group_toggle_ephemeral(connection, group_jid, expiration, opts \\ [])
      when is_binary(group_jid) and is_integer(expiration) and expiration >= 0 and is_list(opts) do
    with_queryable(connection, fn queryable ->
      Group.toggle_ephemeral(queryable, group_jid, expiration)
    end)
  end

  @doc "Switch whether only admins or all members can add participants."
  @spec group_member_add_mode(connection(), String.t(), :admin_add | :all_member_add, keyword()) ::
          :ok | {:error, term()}
  def group_member_add_mode(connection, group_jid, mode, opts \\ [])
      when is_binary(group_jid) and mode in [:admin_add, :all_member_add] and is_list(opts) do
    with_queryable(connection, fn queryable ->
      Group.member_add_mode(queryable, group_jid, mode)
    end)
  end

  @doc "Toggle join-approval mode for a group."
  @spec group_join_approval_mode(connection(), String.t(), :on | :off, keyword()) ::
          :ok | {:error, term()}
  def group_join_approval_mode(connection, group_jid, mode, opts \\ [])
      when is_binary(group_jid) and mode in [:on, :off] and is_list(opts) do
    with_queryable(connection, fn queryable ->
      Group.join_approval_mode(queryable, group_jid, mode)
    end)
  end

  @doc "Create a community."
  @spec community_create(connection(), String.t(), String.t() | nil, keyword()) ::
          {:ok, map()} | {:error, term()}
  def community_create(connection, subject, description \\ nil, opts \\ [])
      when is_binary(subject) and (is_binary(description) or is_nil(description)) and
             is_list(opts) do
    with_queryable(connection, fn queryable ->
      Community.create(queryable, subject, description, opts)
    end)
  end

  @doc "Fetch community metadata."
  @spec community_metadata(connection(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def community_metadata(connection, community_jid, opts \\ [])
      when is_binary(community_jid) and is_list(opts) do
    with_queryable(connection, fn queryable ->
      Community.metadata(queryable, community_jid, opts)
    end)
  end

  @doc "Create a linked subgroup inside a community."
  @spec community_create_group(connection(), String.t(), [String.t()], String.t(), keyword()) ::
          {:ok, map() | nil} | {:error, term()}
  def community_create_group(connection, subject, participants, parent_community_jid, opts \\ [])
      when is_binary(subject) and is_list(participants) and is_binary(parent_community_jid) and
             is_list(opts) do
    with_queryable(connection, fn queryable ->
      Community.create_group(queryable, subject, participants, parent_community_jid, opts)
    end)
  end

  @doc "Leave a community."
  @spec community_leave(connection(), String.t(), keyword()) :: :ok | {:error, term()}
  def community_leave(connection, community_jid, opts \\ [])
      when is_binary(community_jid) and is_list(opts) do
    with_queryable(connection, fn queryable -> Community.leave(queryable, community_jid) end)
  end

  @doc "Update a community subject."
  @spec community_update_subject(connection(), String.t(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def community_update_subject(connection, community_jid, subject, opts \\ [])
      when is_binary(community_jid) and is_binary(subject) and is_list(opts) do
    with_queryable(connection, fn queryable ->
      Community.update_subject(queryable, community_jid, subject)
    end)
  end

  @doc "Update or clear a community description."
  @spec community_update_description(connection(), String.t(), String.t() | nil, keyword()) ::
          :ok | {:error, term()}
  def community_update_description(connection, community_jid, description, opts \\ [])
      when is_binary(community_jid) and is_list(opts) do
    with_queryable(connection, fn queryable ->
      Community.update_description(queryable, community_jid, description, opts)
    end)
  end

  @doc "Link an existing subgroup into a community."
  @spec community_link_group(connection(), String.t(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def community_link_group(connection, group_jid, parent_community_jid, opts \\ [])
      when is_binary(group_jid) and is_binary(parent_community_jid) and is_list(opts) do
    with_queryable(connection, fn queryable ->
      Community.link_group(queryable, group_jid, parent_community_jid)
    end)
  end

  @doc "Unlink a subgroup from a community."
  @spec community_unlink_group(connection(), String.t(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def community_unlink_group(connection, group_jid, parent_community_jid, opts \\ [])
      when is_binary(group_jid) and is_binary(parent_community_jid) and is_list(opts) do
    with_queryable(connection, fn queryable ->
      Community.unlink_group(queryable, group_jid, parent_community_jid)
    end)
  end

  @doc "Fetch linked groups for a community or subgroup."
  @spec community_fetch_linked_groups(connection(), String.t(), keyword()) ::
          {:ok, %{community_jid: String.t(), is_community: boolean(), linked_groups: [map()]}}
          | {:error, term()}
  def community_fetch_linked_groups(connection, jid, opts \\ [])
      when is_binary(jid) and is_list(opts) do
    with_queryable(connection, fn queryable -> Community.fetch_linked_groups(queryable, jid) end)
  end

  @doc "Add, remove, promote, or demote community participants."
  @spec community_participants_update(
          connection(),
          String.t(),
          [String.t()],
          :add | :remove | :promote | :demote,
          keyword()
        ) :: {:ok, [map()]} | {:error, term()}
  def community_participants_update(connection, community_jid, jids, action, opts \\ [])
      when is_binary(community_jid) and is_list(jids) and
             action in [:add, :remove, :promote, :demote] and is_list(opts) do
    with_queryable(connection, fn queryable ->
      Community.participants_update(queryable, community_jid, jids, action)
    end)
  end

  @doc "Fetch the pending membership-approval request list for a community."
  @spec community_request_participants_list(connection(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def community_request_participants_list(connection, community_jid, opts \\ [])
      when is_binary(community_jid) and is_list(opts) do
    with_queryable(connection, fn queryable ->
      Community.request_participants_list(queryable, community_jid)
    end)
  end

  @doc "Approve or reject pending community membership requests."
  @spec community_request_participants_update(
          connection(),
          String.t(),
          [String.t()],
          :approve | :reject,
          keyword()
        ) :: {:ok, [map()]} | {:error, term()}
  def community_request_participants_update(connection, community_jid, jids, action, opts \\ [])
      when is_binary(community_jid) and is_list(jids) and action in [:approve, :reject] and
             is_list(opts) do
    with_queryable(connection, fn queryable ->
      Community.request_participants_update(queryable, community_jid, jids, action)
    end)
  end

  @doc "Fetch the current community invite code."
  @spec community_invite_code(connection(), String.t(), keyword()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def community_invite_code(connection, community_jid, opts \\ [])
      when is_binary(community_jid) and is_list(opts) do
    with_queryable(connection, fn queryable -> Community.invite_code(queryable, community_jid) end)
  end

  @doc "Revoke the current community invite code and return the new one."
  @spec community_revoke_invite(connection(), String.t(), keyword()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def community_revoke_invite(connection, community_jid, opts \\ [])
      when is_binary(community_jid) and is_list(opts) do
    with_queryable(connection, fn queryable ->
      Community.revoke_invite(queryable, community_jid)
    end)
  end

  @doc "Accept a legacy community invite code."
  @spec community_accept_invite(connection(), String.t(), keyword()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def community_accept_invite(connection, code, opts \\ [])
      when is_binary(code) and is_list(opts) do
    with_queryable(connection, fn queryable -> Community.accept_invite(queryable, code) end)
  end

  @doc "Fetch community invite metadata without joining."
  @spec community_get_invite_info(connection(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def community_get_invite_info(connection, code, opts \\ [])
      when is_binary(code) and is_list(opts) do
    with_queryable(connection, fn queryable -> Community.get_invite_info(queryable, code) end)
  end

  @doc "Accept a v4 community invite."
  @spec community_accept_invite_v4(connection(), String.t() | map(), map(), keyword()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def community_accept_invite_v4(connection, key, invite_message, opts \\ [])
      when is_list(opts) do
    with_runtime(connection, opts, fn queryable, runtime_opts ->
      Community.accept_invite_v4(queryable, key, invite_message, runtime_opts)
    end)
  end

  @doc "Revoke a v4 community invite for a specific invited user."
  @spec community_revoke_invite_v4(connection(), String.t(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def community_revoke_invite_v4(connection, community_jid, invited_jid, opts \\ [])
      when is_binary(community_jid) and is_binary(invited_jid) and is_list(opts) do
    with_queryable(connection, fn queryable ->
      Community.revoke_invite_v4(queryable, community_jid, invited_jid)
    end)
  end

  @doc "Enable or disable disappearing messages for a community."
  @spec community_toggle_ephemeral(connection(), String.t(), non_neg_integer(), keyword()) ::
          :ok | {:error, term()}
  def community_toggle_ephemeral(connection, community_jid, expiration, opts \\ [])
      when is_binary(community_jid) and is_integer(expiration) and expiration >= 0 and
             is_list(opts) do
    with_queryable(connection, fn queryable ->
      Community.toggle_ephemeral(queryable, community_jid, expiration)
    end)
  end

  @doc "Update a community announcement or locked setting."
  @spec community_setting_update(
          connection(),
          String.t(),
          :announcement | :not_announcement | :locked | :unlocked,
          keyword()
        ) :: :ok | {:error, term()}
  def community_setting_update(connection, community_jid, setting, opts \\ [])
      when is_binary(community_jid) and
             setting in [:announcement, :not_announcement, :locked, :unlocked] and
             is_list(opts) do
    with_queryable(connection, fn queryable ->
      Community.setting_update(queryable, community_jid, setting)
    end)
  end

  @doc "Switch whether only admins or all members can add participants to a community."
  @spec community_member_add_mode(
          connection(),
          String.t(),
          :admin_add | :all_member_add,
          keyword()
        ) :: :ok | {:error, term()}
  def community_member_add_mode(connection, community_jid, mode, opts \\ [])
      when is_binary(community_jid) and mode in [:admin_add, :all_member_add] and is_list(opts) do
    with_queryable(connection, fn queryable ->
      Community.member_add_mode(queryable, community_jid, mode)
    end)
  end

  @doc "Toggle join-approval mode for a community."
  @spec community_join_approval_mode(connection(), String.t(), :on | :off, keyword()) ::
          :ok | {:error, term()}
  def community_join_approval_mode(connection, community_jid, mode, opts \\ [])
      when is_binary(community_jid) and mode in [:on, :off] and is_list(opts) do
    with_queryable(connection, fn queryable ->
      Community.join_approval_mode(queryable, community_jid, mode)
    end)
  end

  @doc "Fetch all participating communities."
  @spec community_fetch_all_participating(connection(), keyword()) ::
          {:ok, %{String.t() => map()}} | {:error, term()}
  def community_fetch_all_participating(connection, opts \\ []) when is_list(opts) do
    with_runtime(connection, opts, fn queryable, runtime_opts ->
      Community.fetch_all_participating(queryable, runtime_opts)
    end)
  end

  @doc "Fetch privacy settings."
  @spec privacy_settings(connection(), keyword()) :: {:ok, map()} | {:error, term()}
  def privacy_settings(connection, opts \\ []) when is_list(opts) do
    with_runtime(connection, opts, fn queryable, runtime_opts ->
      Privacy.fetch_settings(queryable, true, runtime_opts)
    end)
  end

  @doc "Fetch the account blocklist."
  @spec fetch_blocklist(connection(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def fetch_blocklist(connection, opts \\ []) when is_list(opts) do
    with_runtime(connection, opts, fn queryable, runtime_opts ->
      Privacy.fetch_blocklist(queryable, runtime_opts)
    end)
  end

  @doc "Block or unblock a user."
  @spec update_block_status(connection(), String.t(), :block | :unblock, keyword()) ::
          {:ok, BaileysEx.BinaryNode.t()} | {:error, term()}
  def update_block_status(connection, jid, action, opts \\ [])
      when is_binary(jid) and action in [:block, :unblock] and is_list(opts) do
    with_runtime(connection, opts, fn queryable, runtime_opts ->
      Privacy.update_block_status(queryable, jid, action, runtime_opts)
    end)
  end

  @doc "Update last-seen privacy."
  @spec update_last_seen_privacy(connection(), atom() | String.t(), keyword()) ::
          {:ok, BaileysEx.BinaryNode.t()} | {:error, term()}
  def update_last_seen_privacy(connection, value, opts \\ []) when is_list(opts) do
    with_runtime(connection, opts, fn queryable, runtime_opts ->
      Privacy.update_last_seen(queryable, value, runtime_opts)
    end)
  end

  @doc "Update online-visibility privacy."
  @spec update_online_privacy(connection(), atom() | String.t(), keyword()) ::
          {:ok, BaileysEx.BinaryNode.t()} | {:error, term()}
  def update_online_privacy(connection, value, opts \\ []) when is_list(opts) do
    with_runtime(connection, opts, fn queryable, runtime_opts ->
      Privacy.update_online(queryable, value, runtime_opts)
    end)
  end

  @doc "Update profile-picture privacy."
  @spec update_profile_picture_privacy(connection(), atom() | String.t(), keyword()) ::
          {:ok, BaileysEx.BinaryNode.t()} | {:error, term()}
  def update_profile_picture_privacy(connection, value, opts \\ []) when is_list(opts) do
    with_runtime(connection, opts, fn queryable, runtime_opts ->
      Privacy.update_profile_picture(queryable, value, runtime_opts)
    end)
  end

  @doc "Update status/story privacy."
  @spec update_status_privacy(connection(), atom() | String.t(), keyword()) ::
          {:ok, BaileysEx.BinaryNode.t()} | {:error, term()}
  def update_status_privacy(connection, value, opts \\ []) when is_list(opts) do
    with_runtime(connection, opts, fn queryable, runtime_opts ->
      Privacy.update_status(queryable, value, runtime_opts)
    end)
  end

  @doc "Update read-receipt privacy."
  @spec update_read_receipts_privacy(connection(), atom() | String.t(), keyword()) ::
          {:ok, BaileysEx.BinaryNode.t()} | {:error, term()}
  def update_read_receipts_privacy(connection, value, opts \\ []) when is_list(opts) do
    with_runtime(connection, opts, fn queryable, runtime_opts ->
      Privacy.update_read_receipts(queryable, value, runtime_opts)
    end)
  end

  @doc "Update group-add privacy."
  @spec update_groups_add_privacy(connection(), atom() | String.t(), keyword()) ::
          {:ok, BaileysEx.BinaryNode.t()} | {:error, term()}
  def update_groups_add_privacy(connection, value, opts \\ []) when is_list(opts) do
    with_runtime(connection, opts, fn queryable, runtime_opts ->
      Privacy.update_group_add(queryable, value, runtime_opts)
    end)
  end

  @doc "Set the default disappearing-message duration in seconds."
  @spec update_default_disappearing_mode(connection(), non_neg_integer(), keyword()) ::
          {:ok, BaileysEx.BinaryNode.t()} | {:error, term()}
  def update_default_disappearing_mode(connection, duration, opts \\ [])
      when is_integer(duration) and duration >= 0 and is_list(opts) do
    with_runtime(connection, opts, fn queryable, runtime_opts ->
      Privacy.update_default_disappearing_mode(queryable, duration, runtime_opts)
    end)
  end

  @doc "Update call-add privacy."
  @spec update_call_privacy(connection(), atom() | String.t(), keyword()) ::
          {:ok, BaileysEx.BinaryNode.t()} | {:error, term()}
  def update_call_privacy(connection, value, opts \\ []) when is_list(opts) do
    with_runtime(connection, opts, fn queryable, runtime_opts ->
      Privacy.update_call_add(queryable, value, runtime_opts)
    end)
  end

  @doc "Update who can message you."
  @spec update_messages_privacy(connection(), atom() | String.t(), keyword()) ::
          {:ok, BaileysEx.BinaryNode.t()} | {:error, term()}
  def update_messages_privacy(connection, value, opts \\ []) when is_list(opts) do
    with_runtime(connection, opts, fn queryable, runtime_opts ->
      Privacy.update_messages(queryable, value, runtime_opts)
    end)
  end

  @doc "Fetch a business catalog."
  @spec business_catalog(connection(), keyword()) :: {:ok, map()} | {:error, term()}
  def business_catalog(connection, opts \\ []) when is_list(opts) do
    with_runtime(connection, opts, fn queryable, runtime_opts ->
      Business.get_catalog(queryable, runtime_opts)
    end)
  end

  @doc "Update the business profile payload."
  @spec update_business_profile(connection(), map(), keyword()) ::
          {:ok, BaileysEx.BinaryNode.t()} | {:error, term()}
  def update_business_profile(connection, profile_data, opts \\ [])
      when is_map(profile_data) and is_list(opts) do
    with_queryable(connection, fn queryable ->
      Business.update_business_profile(queryable, profile_data, opts)
    end)
  end

  @doc "Upload and set the business cover photo."
  @spec update_business_cover_photo(connection(), term(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def update_business_cover_photo(connection, photo, opts \\ []) when is_list(opts) do
    with_runtime(connection, opts, fn queryable, runtime_opts ->
      Business.update_cover_photo(queryable, photo, runtime_opts)
    end)
  end

  @doc "Remove the business cover photo."
  @spec remove_business_cover_photo(connection(), String.t(), keyword()) ::
          {:ok, BaileysEx.BinaryNode.t()} | {:error, term()}
  def remove_business_cover_photo(connection, cover_id, opts \\ [])
      when is_binary(cover_id) and is_list(opts) do
    with_runtime(connection, opts, fn queryable, runtime_opts ->
      Business.remove_cover_photo(queryable, cover_id, runtime_opts)
    end)
  end

  @doc "Fetch business catalog collections."
  @spec business_collections(connection(), String.t() | nil, pos_integer(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def business_collections(connection, jid \\ nil, limit \\ 51, opts \\ [])
      when (is_binary(jid) or is_nil(jid)) and is_integer(limit) and limit > 0 and is_list(opts) do
    with_runtime(connection, opts, fn queryable, runtime_opts ->
      Business.get_collections(queryable, jid, limit, runtime_opts)
    end)
  end

  @doc "Create a business product."
  @spec business_product_create(connection(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def business_product_create(connection, product, opts \\ [])
      when is_map(product) and is_list(opts) do
    with_runtime(connection, opts, fn queryable, runtime_opts ->
      Business.product_create(queryable, product, runtime_opts)
    end)
  end

  @doc "Update a business product."
  @spec business_product_update(connection(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def business_product_update(connection, product_id, updates, opts \\ [])
      when is_binary(product_id) and is_map(updates) and is_list(opts) do
    with_runtime(connection, opts, fn queryable, runtime_opts ->
      Business.product_update(queryable, product_id, updates, runtime_opts)
    end)
  end

  @doc "Delete one or more business products."
  @spec business_product_delete(connection(), [String.t()], keyword()) ::
          {:ok, %{deleted: non_neg_integer()}} | {:error, term()}
  def business_product_delete(connection, product_ids, opts \\ [])
      when is_list(product_ids) and is_list(opts) do
    with_runtime(connection, opts, fn queryable, runtime_opts ->
      Business.product_delete(queryable, product_ids, runtime_opts)
    end)
  end

  @doc "Fetch business order details."
  @spec business_order_details(connection(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def business_order_details(connection, order_id, token, opts \\ [])
      when is_binary(order_id) and is_binary(token) and is_list(opts) do
    with_runtime(connection, opts, fn queryable, runtime_opts ->
      Business.get_order_details(queryable, order_id, token, runtime_opts)
    end)
  end

  @doc "Fetch newsletter metadata by `:jid` or `:invite` key."
  @spec newsletter_metadata(connection(), :invite | :jid, String.t(), keyword()) ::
          {:ok, map() | nil} | {:error, term()}
  def newsletter_metadata(connection, type, key, opts \\ [])
      when type in [:invite, :jid] and is_binary(key) and is_list(opts) do
    with_queryable(connection, fn queryable -> Newsletter.metadata(queryable, type, key, opts) end)
  end

  @doc "Follow a newsletter."
  @spec newsletter_follow(connection(), String.t(), keyword()) ::
          {:ok, BaileysEx.BinaryNode.t()} | {:error, term()}
  def newsletter_follow(connection, newsletter_jid, opts \\ [])
      when is_binary(newsletter_jid) and is_list(opts) do
    with_queryable(connection, fn queryable ->
      Newsletter.follow(queryable, newsletter_jid, opts)
    end)
  end

  @doc "Unfollow a newsletter."
  @spec newsletter_unfollow(connection(), String.t(), keyword()) ::
          {:ok, BaileysEx.BinaryNode.t()} | {:error, term()}
  def newsletter_unfollow(connection, newsletter_jid, opts \\ [])
      when is_binary(newsletter_jid) and is_list(opts) do
    with_queryable(connection, fn queryable ->
      Newsletter.unfollow(queryable, newsletter_jid, opts)
    end)
  end

  @doc "Create a newsletter."
  @spec newsletter_create(connection(), String.t(), String.t() | nil, keyword()) ::
          {:ok, map()} | {:error, term()}
  def newsletter_create(connection, name, description \\ nil, opts \\ [])
      when is_binary(name) and (is_binary(description) or is_nil(description)) and is_list(opts) do
    with_runtime(connection, opts, fn queryable, runtime_opts ->
      Newsletter.create(queryable, name, description, runtime_opts)
    end)
  end

  @doc "Delete a newsletter."
  @spec newsletter_delete(connection(), String.t(), keyword()) :: :ok | {:error, term()}
  def newsletter_delete(connection, newsletter_jid, opts \\ [])
      when is_binary(newsletter_jid) and is_list(opts) do
    with_runtime(connection, opts, fn queryable, runtime_opts ->
      Newsletter.delete(queryable, newsletter_jid, runtime_opts)
    end)
  end

  @doc "Update newsletter metadata."
  @spec newsletter_update(connection(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def newsletter_update(connection, newsletter_jid, updates, opts \\ [])
      when is_binary(newsletter_jid) and is_map(updates) and is_list(opts) do
    with_runtime(connection, opts, fn queryable, runtime_opts ->
      Newsletter.update(queryable, newsletter_jid, updates, runtime_opts)
    end)
  end

  @doc "Fetch newsletter subscriber counts."
  @spec newsletter_subscribers(connection(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def newsletter_subscribers(connection, newsletter_jid, opts \\ [])
      when is_binary(newsletter_jid) and is_list(opts) do
    with_runtime(connection, opts, fn queryable, runtime_opts ->
      Newsletter.subscribers(queryable, newsletter_jid, runtime_opts)
    end)
  end

  @doc "Fetch newsletter admin count."
  @spec newsletter_admin_count(connection(), String.t(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def newsletter_admin_count(connection, newsletter_jid, opts \\ [])
      when is_binary(newsletter_jid) and is_list(opts) do
    with_runtime(connection, opts, fn queryable, runtime_opts ->
      Newsletter.admin_count(queryable, newsletter_jid, runtime_opts)
    end)
  end

  @doc "Mute a newsletter."
  @spec newsletter_mute(connection(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def newsletter_mute(connection, newsletter_jid, opts \\ [])
      when is_binary(newsletter_jid) and is_list(opts) do
    with_runtime(connection, opts, fn queryable, runtime_opts ->
      Newsletter.mute(queryable, newsletter_jid, runtime_opts)
    end)
  end

  @doc "Unmute a newsletter."
  @spec newsletter_unmute(connection(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def newsletter_unmute(connection, newsletter_jid, opts \\ [])
      when is_binary(newsletter_jid) and is_list(opts) do
    with_runtime(connection, opts, fn queryable, runtime_opts ->
      Newsletter.unmute(queryable, newsletter_jid, runtime_opts)
    end)
  end

  @doc "Subscribe to live newsletter updates."
  @spec newsletter_subscribe_updates(connection(), String.t(), keyword()) ::
          {:ok, %{duration: String.t()} | nil} | {:error, term()}
  def newsletter_subscribe_updates(connection, newsletter_jid, opts \\ [])
      when is_binary(newsletter_jid) and is_list(opts) do
    with_runtime(connection, opts, fn queryable, runtime_opts ->
      Newsletter.subscribe_updates(queryable, newsletter_jid, runtime_opts)
    end)
  end

  @doc "Fetch newsletter message history."
  @spec newsletter_fetch_messages(connection(), String.t(), pos_integer(), keyword()) ::
          {:ok, BaileysEx.BinaryNode.t()} | {:error, term()}
  def newsletter_fetch_messages(connection, newsletter_jid, count, opts \\ [])
      when is_binary(newsletter_jid) and is_integer(count) and count > 0 and is_list(opts) do
    with_runtime(connection, opts, fn queryable, runtime_opts ->
      Newsletter.fetch_messages(queryable, newsletter_jid, count, runtime_opts)
    end)
  end

  @doc "React to a newsletter message or remove an existing reaction."
  @spec newsletter_react_message(
          connection(),
          String.t(),
          String.t(),
          String.t() | nil,
          keyword()
        ) :: :ok | {:error, term()}
  def newsletter_react_message(connection, newsletter_jid, server_id, reaction \\ nil, opts \\ [])
      when is_binary(newsletter_jid) and is_binary(server_id) and is_list(opts) do
    with_runtime(connection, opts, fn queryable, runtime_opts ->
      Newsletter.react_message(queryable, newsletter_jid, server_id, reaction, runtime_opts)
    end)
  end

  @doc "Update the newsletter name."
  @spec newsletter_update_name(connection(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def newsletter_update_name(connection, newsletter_jid, name, opts \\ [])
      when is_binary(newsletter_jid) and is_binary(name) and is_list(opts) do
    with_runtime(connection, opts, fn queryable, runtime_opts ->
      Newsletter.update_name(queryable, newsletter_jid, name, runtime_opts)
    end)
  end

  @doc "Update the newsletter description."
  @spec newsletter_update_description(connection(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def newsletter_update_description(connection, newsletter_jid, description, opts \\ [])
      when is_binary(newsletter_jid) and is_binary(description) and is_list(opts) do
    with_runtime(connection, opts, fn queryable, runtime_opts ->
      Newsletter.update_description(queryable, newsletter_jid, description, runtime_opts)
    end)
  end

  @doc "Update the newsletter picture."
  @spec newsletter_update_picture(connection(), String.t(), term(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def newsletter_update_picture(connection, newsletter_jid, content, opts \\ [])
      when is_binary(newsletter_jid) and is_list(opts) do
    with_runtime(connection, opts, fn queryable, runtime_opts ->
      Newsletter.update_picture(queryable, newsletter_jid, content, runtime_opts)
    end)
  end

  @doc "Remove the newsletter picture."
  @spec newsletter_remove_picture(connection(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def newsletter_remove_picture(connection, newsletter_jid, opts \\ [])
      when is_binary(newsletter_jid) and is_list(opts) do
    with_runtime(connection, opts, fn queryable, runtime_opts ->
      Newsletter.remove_picture(queryable, newsletter_jid, runtime_opts)
    end)
  end

  @doc "Change the newsletter owner."
  @spec newsletter_change_owner(connection(), String.t(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def newsletter_change_owner(connection, newsletter_jid, new_owner_jid, opts \\ [])
      when is_binary(newsletter_jid) and is_binary(new_owner_jid) and is_list(opts) do
    with_runtime(connection, opts, fn queryable, runtime_opts ->
      Newsletter.change_owner(queryable, newsletter_jid, new_owner_jid, runtime_opts)
    end)
  end

  @doc "Demote a newsletter admin."
  @spec newsletter_demote(connection(), String.t(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def newsletter_demote(connection, newsletter_jid, user_jid, opts \\ [])
      when is_binary(newsletter_jid) and is_binary(user_jid) and is_list(opts) do
    with_runtime(connection, opts, fn queryable, runtime_opts ->
      Newsletter.demote(queryable, newsletter_jid, user_jid, runtime_opts)
    end)
  end

  defp maybe_put_initial_event_subscribers(connection_opts, callback_opts) do
    if callback_handlers?(callback_opts) do
      handler = fn events -> dispatch_callback_events(events, callback_opts) end
      Keyword.update(connection_opts, :initial_event_subscribers, [handler], &[handler | &1])
    else
      connection_opts
    end
  end

  defp callback_handlers?(callback_opts) when is_list(callback_opts) do
    Enum.any?(callback_opts, fn {_key, callback} -> is_function(callback, 1) end)
  end

  defp dispatch_callback_events(events, callback_opts) do
    maybe_emit_callback(callback_opts[:on_event], events)
    maybe_dispatch_connection_callback(events, callback_opts)
    maybe_dispatch_message_callback(events, callback_opts[:on_message])
  end

  defp maybe_dispatch_connection_callback(events, callback_opts) do
    case events[:connection_update] do
      %{} = update ->
        maybe_emit_callback(callback_opts[:on_connection], update)
        maybe_emit_callback(callback_opts[:on_qr], Map.get(update, :qr))

      _ ->
        :ok
    end
  end

  defp maybe_dispatch_message_callback(events, callback) do
    case get_in(events, [:messages_upsert, :messages]) do
      messages when is_list(messages) and is_function(callback, 1) ->
        Enum.each(messages, callback)

      _ ->
        :ok
    end
  end

  defp maybe_emit_callback(callback, payload) when is_function(callback, 1) do
    if is_binary(payload) or is_map(payload) do
      callback.(payload)
    else
      :ok
    end
  end

  defp maybe_emit_callback(_callback, _payload), do: :ok

  defp dispatch_public_events(events, handler) do
    require Logger

    try do
      events
      |> ordered_public_events()
      |> Enum.each(&handler.(&1))
    rescue
      error ->
        Logger.error(
          "[BaileysEx] dispatch_public_events crashed: #{Exception.message(error)}\n" <>
            "  events keys: #{inspect(Map.keys(events))}\n" <>
            "  #{Exception.format_stacktrace(__STACKTRACE__)}"
        )
    end
  end

  defp ordered_public_events(events) when is_map(events) do
    connection_events =
      case events[:connection_update] do
        %{} = update -> [{:connection, update}]
        _ -> []
      end

    message_events =
      case get_in(events, [:messages_upsert, :messages]) do
        messages when is_list(messages) -> Enum.map(messages, &{:message, &1})
        _ -> []
      end

    presence_events =
      case events[:presence_update] do
        %{} = update -> [{:presence, update}]
        _ -> []
      end

    call_events =
      case events[:call] do
        nil -> []
        payload -> [{:call, payload}]
      end

    generic_events =
      events
      |> Enum.reject(fn {key, _value} ->
        key in [:call, :connection_update, :messages_upsert, :presence_update]
      end)
      |> Enum.sort_by(fn {key, _value} -> Atom.to_string(key) end)
      |> Enum.map(fn {key, value} -> {:event, key, value} end)

    connection_events ++ message_events ++ presence_events ++ call_events ++ generic_events
  end

  defp with_queryable(connection, fun) when is_function(fun, 1) do
    with {:ok, queryable} <- queryable(connection) do
      fun.(queryable)
    end
  end

  defp with_runtime(connection, opts, fun) when is_list(opts) and is_function(fun, 2) do
    with {:ok, queryable} <- queryable(connection) do
      fun.(queryable, build_runtime_opts(connection, opts))
    end
  end

  defp with_app_state_runtime(connection, action, jid, value, opts)
       when is_atom(action) and is_binary(jid) and is_list(opts) do
    with {:ok, queryable} <- queryable(connection),
         {:ok, store_ref} <- runtime_store_ref(connection) do
      AppState.chat_modify(
        queryable,
        store_ref,
        action,
        jid,
        value,
        build_runtime_opts(connection, opts, store_ref)
      )
    end
  end

  defp maybe_put_signal_store(opts, connection) do
    case runtime_signal_store(connection) do
      %SignalStore{} = store -> Keyword.put_new(opts, :signal_store, store)
      nil -> opts
    end
  end

  defp build_runtime_opts(connection, opts, store_ref \\ nil) when is_list(opts) do
    event_emitter = runtime_event_emitter(connection)
    me = runtime_me(connection, store_ref)

    []
    |> maybe_put_keyword(:store, store_ref || runtime_store_ref_value(connection))
    |> maybe_put_keyword(:creds_store, store_ref || runtime_store_ref_value(connection))
    |> maybe_put_keyword(:signal_store, runtime_signal_store(connection))
    |> maybe_put_keyword(:event_emitter, event_emitter)
    |> maybe_put_keyword(:me, me)
    |> maybe_put_keyword(:message_update_fun, runtime_message_update_fun(event_emitter))
    |> maybe_put_keyword(:upsert_message_fun, runtime_upsert_message_fun(event_emitter))
    |> Keyword.merge(opts)
  end

  defp runtime_store_ref(connection) do
    case ConnectionSupervisor.store(connection) do
      pid when is_pid(pid) -> {:ok, RuntimeStore.wrap(pid)}
      _ -> {:error, :store_not_available}
    end
  end

  defp runtime_store_ref_value(connection) do
    case runtime_store_ref(connection) do
      {:ok, store_ref} -> store_ref
      {:error, _reason} -> nil
    end
  end

  defp runtime_signal_store(connection) do
    case signal_store(connection) do
      {:ok, store} -> store
      {:error, _reason} -> nil
    end
  end

  defp runtime_event_emitter(connection) do
    case event_emitter(connection) do
      {:ok, pid} -> pid
      {:error, _reason} -> nil
    end
  end

  defp runtime_me(connection, %RuntimeStore.Ref{} = store_ref) do
    store_ref
    |> RuntimeStore.get(:creds, %{})
    |> extract_me()
    |> case do
      nil -> runtime_me(connection, nil)
      me -> me
    end
  end

  defp runtime_me(connection, _store_ref) do
    case auth_state(connection) do
      {:ok, auth_state} -> extract_me(auth_state)
      {:error, _reason} -> nil
    end
  end

  defp runtime_message_update_fun(nil), do: nil

  defp runtime_message_update_fun(event_emitter) do
    fn payload -> EventEmitter.emit(event_emitter, :messages_update, payload) end
  end

  defp runtime_upsert_message_fun(nil), do: nil

  defp runtime_upsert_message_fun(event_emitter) do
    fn message ->
      EventEmitter.emit(event_emitter, :messages_upsert, %{type: :notify, messages: [message]})
    end
  end

  defp runtime_send_node_fun({module, server}) when is_atom(module) do
    fn node -> module.send_node(server, node) end
  end

  defp normalize_privacy_settings(settings) when is_map(settings) do
    Map.put(
      settings,
      :readreceipts,
      Map.get(settings, :readreceipts) || Map.get(settings, "readreceipts")
    )
  end

  defp maybe_put_presence_identity(opts, connection) do
    me = runtime_me(connection, runtime_store_ref_value(connection))

    opts
    |> Keyword.put_new(:me_id, nested_id(me))
    |> Keyword.put_new(:me_lid, nested_lid(me))
  end

  defp nested_id(%{me: %{id: id}}) when is_binary(id), do: id
  defp nested_id(%{me: %{"id" => id}}) when is_binary(id), do: id
  defp nested_id(%{"me" => %{id: id}}) when is_binary(id), do: id
  defp nested_id(%{"me" => %{"id" => id}}) when is_binary(id), do: id
  defp nested_id(%{id: id}) when is_binary(id), do: id
  defp nested_id(%{"id" => id}) when is_binary(id), do: id
  defp nested_id(_auth_state), do: nil

  defp nested_lid(%{me: %{lid: lid}}) when is_binary(lid), do: lid
  defp nested_lid(%{me: %{"lid" => lid}}) when is_binary(lid), do: lid
  defp nested_lid(%{"me" => %{lid: lid}}) when is_binary(lid), do: lid
  defp nested_lid(%{"me" => %{"lid" => lid}}) when is_binary(lid), do: lid
  defp nested_lid(%{lid: lid}) when is_binary(lid), do: lid
  defp nested_lid(%{"lid" => lid}) when is_binary(lid), do: lid
  defp nested_lid(_auth_state), do: nil

  defp extract_me(%{me: %{} = me}), do: me
  defp extract_me(%{"me" => %{} = me}), do: me
  defp extract_me(%{creds: %{me: %{} = me}}), do: me
  defp extract_me(%{creds: %{"me" => %{} = me}}), do: me
  defp extract_me(%{"creds" => %{me: %{} = me}}), do: me
  defp extract_me(%{"creds" => %{"me" => %{} = me}}), do: me
  defp extract_me(_auth_state), do: nil

  defp maybe_put_keyword(opts, _key, nil), do: opts
  defp maybe_put_keyword(opts, key, value), do: Keyword.put_new(opts, key, value)

  defp normalize_jid(%JID{} = jid), do: {:ok, jid}

  defp normalize_jid(jid) when is_binary(jid) do
    case JIDUtil.parse(jid) do
      %JID{} = parsed -> {:ok, parsed}
      _ -> {:error, :invalid_jid}
    end
  end

  defp normalize_jid(_jid), do: {:error, :invalid_jid}
end
