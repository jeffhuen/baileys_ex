defmodule BaileysEx do
  @moduledoc """
  Public facade for the BaileysEx connection runtime and major feature surfaces.

  ## Quick Start

      alias BaileysEx.Auth.FilePersistence
      alias BaileysEx.Connection.Transport.MintWebSocket

      {:ok, persisted_auth} = FilePersistence.use_multi_file_auth_state("tmp/baileys_auth")
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

  Advanced callers can obtain the raw socket transport tuple via `queryable/1`
  and pass it directly to the lower-level feature modules.

  Outbound `send_message/4` and `send_status/3` use the built-in production Signal
  adapter by default when the auth state includes `signed_identity_key`,
  `signed_pre_key`, and `registration_id`. Use `:signal_repository` or
  `:signal_repository_adapter` only when you need to override that default.
  """

  alias BaileysEx.Connection.Supervisor, as: ConnectionSupervisor
  alias BaileysEx.Connection.Version, as: ConnectionVersion
  alias BaileysEx.Feature.Business
  alias BaileysEx.Feature.Community
  alias BaileysEx.Feature.Group
  alias BaileysEx.Feature.Newsletter
  alias BaileysEx.Feature.Presence
  alias BaileysEx.Feature.Privacy
  alias BaileysEx.Feature.Profile
  alias BaileysEx.JID
  alias BaileysEx.Media.Download
  alias BaileysEx.Protocol.JID, as: JIDUtil
  alias BaileysEx.Signal.Store
  alias BaileysEx.WAM.BinaryInfo, as: WAMBinaryInfo

  @type connection :: GenServer.server()
  @type unsubscribe_fun :: (-> :ok)

  @doc """
  Start a connection runtime and optionally attach convenience callbacks.

  Pass a real `:transport` such as `{BaileysEx.Connection.Transport.MintWebSocket, []}`
  when you want an actual WhatsApp connection. Without it, the default transport
  returns `{:error, :transport_not_configured}`.

  Use `BaileysEx.Auth.FilePersistence.use_multi_file_auth_state/1` when you want the
  Baileys-style multi-file setup that pairs persisted credentials with the built-in
  file-backed Signal store.

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
  @spec signal_store(connection()) :: {:ok, Store.t()} | {:error, :signal_store_not_available}
  def signal_store(connection) do
    case ConnectionSupervisor.signal_store(connection) do
      %Store{} = store -> {:ok, store}
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
      Presence.send_update(queryable, type, to_jid, opts)
    end)
  end

  @doc "Subscribe to a contact or group presence feed."
  @spec presence_subscribe(connection(), String.t(), keyword()) :: :ok | {:error, term()}
  def presence_subscribe(connection, jid, opts \\ []) when is_binary(jid) and is_list(opts) do
    with_queryable(connection, fn queryable ->
      Presence.subscribe(queryable, jid, maybe_put_signal_store(opts, connection))
    end)
  end

  @doc "Download media into memory."
  @spec download_media(map(), keyword()) :: {:ok, binary()} | {:error, term()}
  def download_media(message, opts \\ []), do: Download.download(message, opts)

  @doc "Download media directly to a file path."
  @spec download_media_to_file(map(), Path.t(), keyword()) :: {:ok, Path.t()} | {:error, term()}
  def download_media_to_file(message, path, opts \\ []),
    do: Download.download_to_file(message, path, opts)

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

  @doc "Fetch privacy settings."
  @spec privacy_settings(connection(), keyword()) :: {:ok, map()} | {:error, term()}
  def privacy_settings(connection, opts \\ []) when is_list(opts) do
    with_queryable(connection, fn queryable -> Privacy.fetch_settings(queryable, true, opts) end)
  end

  @doc "Fetch a business catalog."
  @spec business_catalog(connection(), keyword()) :: {:ok, map()} | {:error, term()}
  def business_catalog(connection, opts \\ []) when is_list(opts) do
    with_queryable(connection, fn queryable -> Business.get_catalog(queryable, opts) end)
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
    events
    |> ordered_public_events()
    |> Enum.each(&handler.(&1))
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

  defp maybe_put_signal_store(opts, connection) do
    case signal_store(connection) do
      {:ok, store} -> Keyword.put_new(opts, :signal_store, store)
      {:error, _reason} -> opts
    end
  end

  defp normalize_jid(%JID{} = jid), do: {:ok, jid}

  defp normalize_jid(jid) when is_binary(jid) do
    case JIDUtil.parse(jid) do
      %JID{} = parsed -> {:ok, parsed}
      _ -> {:error, :invalid_jid}
    end
  end

  defp normalize_jid(_jid), do: {:error, :invalid_jid}
end
