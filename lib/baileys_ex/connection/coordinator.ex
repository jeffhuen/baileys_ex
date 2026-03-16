defmodule BaileysEx.Connection.Coordinator do
  @moduledoc """
  Runtime wrapper around the raw connection socket.

  This process owns wrapper concerns that Baileys keeps outside `makeSocket`:
  initial connect/reconnect policy, init queries, dirty-bit handling, and
  persisting emitted credential updates.
  """

  use GenServer

  require Logger

  alias BaileysEx.Auth.State, as: AuthState
  alias BaileysEx.BinaryNode
  alias BaileysEx.Connection.EventEmitter
  alias BaileysEx.Connection.Socket
  alias BaileysEx.Connection.Store
  alias BaileysEx.Feature.AppState
  alias BaileysEx.Feature.Call
  alias BaileysEx.Feature.Community
  alias BaileysEx.Feature.Group
  alias BaileysEx.Feature.Presence
  alias BaileysEx.Feature.Privacy
  alias BaileysEx.Message.IdentityChangeHandler
  alias BaileysEx.Message.NotificationHandler
  alias BaileysEx.Message.Receipt
  alias BaileysEx.Message.Receiver
  alias BaileysEx.Message.Sender
  alias BaileysEx.Protocol.BinaryNode, as: BinaryNodeUtil
  alias BaileysEx.Protocol.Proto.ADVSignedDeviceIdentity
  alias BaileysEx.Signal.LIDMappingStore
  alias BaileysEx.Signal.Adapter.Signal, as: DefaultSignalAdapter
  alias BaileysEx.Signal.Repository
  alias BaileysEx.Signal.Session
  alias BaileysEx.Signal.Store, as: SignalStore
  alias BaileysEx.Signal.Store.Memory, as: SignalStoreMemory
  alias BaileysEx.Telemetry

  @s_whatsapp_net "s.whatsapp.net"
  @device_identity_account_keys %{
    :details => :details,
    :account_signature_key => :account_signature_key,
    :account_signature => :account_signature,
    :device_signature => :device_signature,
    "details" => :details,
    "account_signature_key" => :account_signature_key,
    "account_signature" => :account_signature,
    "device_signature" => :device_signature
  }

  defmodule State do
    @moduledoc false

    @enforce_keys [
      :config,
      :event_emitter,
      :socket_module,
      :store,
      :supervisor,
      :task_supervisor,
      :signal_store
    ]
    defstruct [
      :config,
      :event_emitter,
      :socket_module,
      :store,
      :signal_store,
      :signal_repository,
      :store_ref,
      :supervisor,
      :task_supervisor,
      :unsubscribe,
      :history_sync_download_fun,
      :history_sync_inflate_fun,
      :get_message_fun,
      :handle_encrypt_notification_fun,
      :device_notification_fun,
      :resync_app_state_fun,
      :reconnect_timer,
      :initial_sync_timer,
      :app_state_sync_ref,
      event_buffer_seed: %{},
      identity_change_cache: %{},
      sync_state: :connecting
    ]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    genserver_opts =
      case Keyword.fetch(opts, :name) do
        {:ok, name} -> [name: name]
        :error -> []
      end

    GenServer.start_link(__MODULE__, opts, genserver_opts)
  end

  @doc "Send a message through the coordinator-owned runtime state."
  @spec send_message(GenServer.server(), BaileysEx.JID.t(), map() | struct(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def send_message(server, jid, content, opts \\ []) when is_list(opts) do
    GenServer.call(server, {:send_message, jid, content, opts}, :infinity)
  end

  @doc "Send a status message through the coordinator-owned runtime state."
  @spec send_status(GenServer.server(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def send_status(server, content, opts \\ []) when is_map(content) and is_list(opts) do
    GenServer.call(server, {:send_status, content, opts}, :infinity)
  end

  @impl true
  def init(opts) do
    state = %State{
      config: Keyword.fetch!(opts, :config),
      event_emitter: Keyword.fetch!(opts, :event_emitter),
      socket_module: Keyword.get(opts, :socket_module, Socket),
      store: Keyword.fetch!(opts, :store),
      signal_store: Keyword.fetch!(opts, :signal_store),
      signal_repository: Keyword.get(opts, :signal_repository),
      supervisor: Keyword.fetch!(opts, :supervisor),
      task_supervisor: Keyword.fetch!(opts, :task_supervisor),
      history_sync_download_fun: Keyword.get(opts, :history_sync_download_fun),
      history_sync_inflate_fun: Keyword.get(opts, :history_sync_inflate_fun),
      get_message_fun: Keyword.get(opts, :get_message_fun),
      handle_encrypt_notification_fun: Keyword.get(opts, :handle_encrypt_notification_fun),
      device_notification_fun: Keyword.get(opts, :device_notification_fun),
      resync_app_state_fun: Keyword.get(opts, :resync_app_state_fun)
    }

    coordinator_pid = self()

    unsubscribe =
      EventEmitter.tap(state.event_emitter, &Kernel.send(coordinator_pid, {:events, &1}))

    wrapped_signal_store = wrap_signal_store(state.signal_store)
    store_ref = Store.wrap(state.store)

    state =
      state
      |> Map.put(:unsubscribe, unsubscribe)
      |> Map.put(:store_ref, store_ref)
      |> Map.put(:signal_store, wrapped_signal_store)
      |> Map.put(
        :signal_repository,
        build_signal_repository(
          state.signal_repository,
          Keyword.get(opts, :signal_repository_adapter),
          Keyword.get(opts, :signal_repository_adapter_state, %{}),
          wrapped_signal_store,
          store_ref
        )
      )
      |> Map.put(:reconnect_timer, nil)

    {:ok, state, {:continue, :connect_socket}}
  end

  @impl true
  def handle_continue(:connect_socket, %State{} = state) do
    {:noreply, connect_socket(state)}
  end

  @impl true
  def handle_call(
        {:send_message, jid, content, opts},
        _from,
        %State{signal_repository: %Repository{} = repository} = state
      ) do
    case Sender.send(sender_context(state, repository), jid, content, opts) do
      {:ok, result, %{signal_repository: %Repository{} = updated_repository}} ->
        {:reply, {:ok, result}, %{state | signal_repository: updated_repository}}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(
        {:send_status, content, opts},
        _from,
        %State{signal_repository: %Repository{} = repository} = state
      ) do
    case Sender.send_status(sender_context(state, repository), content, opts) do
      {:ok, result, %{signal_repository: %Repository{} = updated_repository}} ->
        {:reply, {:ok, result}, %{state | signal_repository: updated_repository}}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:send_message, _jid, _content, _opts}, _from, %State{} = state) do
    {:reply, {:error, :signal_repository_not_ready}, state}
  end

  def handle_call({:send_status, _content, _opts}, _from, %State{} = state) do
    {:reply, {:error, :signal_repository_not_ready}, state}
  end

  def handle_call(request, _from, %State{} = state) do
    Logger.warning("unsupported coordinator request: #{inspect(request)}")
    {:reply, {:error, :unsupported_request}, state}
  end

  @impl true
  def handle_info({:events, events}, %State{} = state) when is_map(events) do
    previous_creds = Store.get(state.store_ref, :creds, %{})

    state =
      state
      |> handle_socket_node(events)
      |> persist_creds_update(events)
      |> persist_lid_mapping_update(events)
      |> maybe_seed_event_buffer(events)
      |> maybe_send_push_name_presence_update(previous_creds, events)
      |> handle_connection_update(events)
      |> handle_sync_event(events)
      |> maybe_start_initial_app_state_sync(events)
      |> handle_dirty_update(events)

    {:noreply, state}
  end

  def handle_info(:reconnect_socket, %State{} = state) do
    {:noreply, connect_socket(%{state | reconnect_timer: nil})}
  end

  def handle_info(:initial_sync_timeout, %State{sync_state: :awaiting_initial_sync} = state) do
    _ = EventEmitter.flush(state.event_emitter)
    {:noreply, %{state | initial_sync_timer: nil, sync_state: :online}}
  end

  def handle_info(:initial_sync_timeout, %State{} = state) do
    {:noreply, %{state | initial_sync_timer: nil}}
  end

  def handle_info(:complete_initial_sync, %State{sync_state: :syncing} = state) do
    _ = EventEmitter.flush(state.event_emitter)
    {:noreply, %{state | sync_state: :online}}
  end

  def handle_info(:complete_initial_sync, %State{app_state_sync_ref: ref} = state)
      when not is_nil(ref) do
    {:noreply, state}
  end

  def handle_info(:complete_initial_sync, %State{} = state) do
    {:noreply, state}
  end

  def handle_info(
        {:app_state_sync_complete, ref, result},
        %State{app_state_sync_ref: ref} = state
      ) do
    state = %{state | app_state_sync_ref: nil}

    case result do
      :ok ->
        increment_account_sync_counter(state)

      {:error, reason} ->
        Logger.warning("initial app state sync failed: #{inspect(reason)}")
    end

    _ = Process.send_after(self(), :complete_initial_sync, 25)
    {:noreply, state}
  end

  def handle_info({:app_state_sync_complete, _ref, _result}, %State{} = state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %State{unsubscribe: unsubscribe}) when is_function(unsubscribe, 0) do
    unsubscribe.()
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp handle_socket_node(
         %State{signal_repository: %Repository{} = repository} = state,
         %{socket_node: %{node: %BinaryNode{tag: "message"} = node}}
       ) do
    case Receiver.process_node(node, receiver_context(state, repository)) do
      {:ok, _message, %{signal_repository: %Repository{} = updated_repository}} ->
        %{state | signal_repository: updated_repository}

      _ ->
        state
    end
  end

  defp handle_socket_node(%State{} = state, %{
         socket_node: %{node: %BinaryNode{tag: "call"} = node}
       }) do
    case Call.handle_node(node,
           event_emitter: state.event_emitter,
           store_ref: state.store_ref,
           send_node_fun: receipt_sender_fun(state)
         ) do
      {:ok, _call} ->
        state

      {:error, reason} ->
        Logger.warning("failed to handle call node: #{inspect(reason)}")
        state
    end
  end

  defp handle_socket_node(%State{} = state, %{
         socket_node: %{node: %BinaryNode{tag: "receipt"} = node}
       }) do
    :ok = Receipt.process_receipt(node, state.event_emitter)
    state
  end

  defp handle_socket_node(%State{} = state, %{
         socket_node: %{node: %BinaryNode{tag: "ack"} = node}
       }) do
    :ok = Receiver.handle_bad_ack(node, state.event_emitter)
    state
  end

  defp handle_socket_node(
         %State{} = state,
         %{
           socket_node: %{
             node: %BinaryNode{tag: "notification", attrs: %{"type" => "encrypt"}} = node
           }
         }
       ) do
    state = maybe_handle_identity_change(state, node)
    :ok = NotificationHandler.process_node(node, notification_context(state))
    state
  end

  defp handle_socket_node(
         %State{} = state,
         %{socket_node: %{node: %BinaryNode{tag: tag} = node}}
       )
       when tag in ["presence", "chatstate"] do
    _ = Presence.handle_update(node, event_emitter: state.event_emitter)
    state
  end

  defp handle_socket_node(
         %State{} = state,
         %{socket_node: %{node: %BinaryNode{tag: "notification"} = node}}
       ) do
    :ok = NotificationHandler.process_node(node, notification_context(state))
    state
  end

  defp handle_socket_node(%State{} = state, _events), do: state

  defp persist_creds_update(%State{} = state, %{creds_update: creds_update})
       when is_map(creds_update) do
    :ok = Store.merge_creds(state.store, creds_update)
    state
  end

  defp persist_creds_update(%State{} = state, _events), do: state

  defp persist_lid_mapping_update(
         %State{signal_store: %SignalStore{} = signal_store} = state,
         %{lid_mapping_update: %{lid: lid, pn: pn}}
       )
       when is_binary(lid) and is_binary(pn) do
    :ok = LIDMappingStore.store_lid_pn_mappings(signal_store, [%{lid: lid, pn: pn}])
    state
  end

  defp persist_lid_mapping_update(%State{} = state, _events), do: state

  defp handle_connection_update(%State{} = state, %{connection_update: %{connection: :open}}) do
    state
    |> cancel_reconnect()
    |> maybe_execute_init_queries()
    |> maybe_send_presence_update()
  end

  defp handle_connection_update(
         %State{} = state,
         %{connection_update: %{connection: :close, last_disconnect: %{reason: reason}}}
       ) do
    if reconnectable_reason?(reason) do
      schedule_reconnect(state, reason)
    else
      cancel_reconnect(state)
    end
  end

  defp handle_connection_update(
         %State{sync_state: :connecting} = state,
         %{connection_update: %{received_pending_notifications: true}}
       ) do
    :ok = EventEmitter.buffer(state.event_emitter)

    if should_sync_history_message?(state.config, %{sync_type: :RECENT}) do
      timer =
        Process.send_after(self(), :initial_sync_timeout, state.config.initial_sync_timeout_ms)

      %{
        cancel_initial_sync_timer(state)
        | initial_sync_timer: timer,
          sync_state: :awaiting_initial_sync
      }
    else
      _ = EventEmitter.flush(state.event_emitter)
      %{cancel_initial_sync_timer(state) | initial_sync_timer: nil, sync_state: :online}
    end
  end

  defp handle_connection_update(%State{} = state, %{connection_update: %{connection: :close}}) do
    state
    |> cancel_initial_sync_timer()
    |> Map.put(:sync_state, :connecting)
  end

  defp handle_connection_update(%State{} = state, _events), do: state

  defp handle_sync_event(
         %State{sync_state: :awaiting_initial_sync} = state,
         %{messaging_history_set: _history}
       ) do
    _ = Process.send_after(self(), :complete_initial_sync, 25)

    state
    |> cancel_initial_sync_timer()
    |> Map.put(:sync_state, :syncing)
  end

  defp handle_sync_event(%State{} = state, _events), do: state

  defp handle_dirty_update(
         %State{} = state,
         %{dirty_update: %{type: "account_sync"} = dirty_update}
       ) do
    previous_timestamp = Store.get(state.store_ref, :last_account_sync_timestamp)

    if previous_timestamp do
      send_clean_dirty_bits(state, "account_sync", previous_timestamp)
    end

    case Map.get(dirty_update, :timestamp) do
      timestamp when is_integer(timestamp) ->
        :ok = Store.put(state.store, :last_account_sync_timestamp, timestamp)
        :ok = Store.merge_creds(state.store, %{last_account_sync_timestamp: timestamp})

        :ok =
          EventEmitter.emit(state.event_emitter, :creds_update, %{
            last_account_sync_timestamp: timestamp
          })

        state

      _ ->
        state
    end
  end

  defp handle_dirty_update(%State{} = state, %{dirty_update: %{type: type}})
       when type in ["groups", "communities"] do
    case fetch_socket_pid(state) do
      {:ok, socket_pid} ->
        dirty_handler =
          case type do
            "communities" -> Community
            _ -> Group
          end

        _ =
          dirty_handler.handle_dirty_update({state.socket_module, socket_pid}, %{type: type},
            event_emitter: state.event_emitter,
            sendable: {state.socket_module, socket_pid}
          )

      :error ->
        send_clean_dirty_bits(state, "groups")
    end

    state
  end

  defp handle_dirty_update(%State{} = state, _events), do: state

  defp schedule_reconnect(%State{reconnect_timer: nil} = state, reason) do
    Telemetry.execute(
      [:connection, :reconnect],
      %{count: 1},
      %{reason: reason, retry_delay_ms: state.config.retry_delay_ms}
    )

    timer = Process.send_after(self(), :reconnect_socket, state.config.retry_delay_ms)
    %{state | reconnect_timer: timer}
  end

  defp schedule_reconnect(%State{} = state, _reason), do: state

  defp cancel_reconnect(%State{reconnect_timer: nil} = state), do: state

  defp cancel_reconnect(%State{reconnect_timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | reconnect_timer: nil}
  end

  defp cancel_initial_sync_timer(%State{initial_sync_timer: nil} = state), do: state

  defp cancel_initial_sync_timer(%State{initial_sync_timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | initial_sync_timer: nil}
  end

  defp reconnectable_reason?(:logged_out), do: false
  defp reconnectable_reason?(_reason), do: true

  defp should_sync_history_message?(%{should_sync_history_message: fun}, history_message)
       when is_function(fun, 1) do
    !!fun.(history_message)
  end

  defp should_sync_history_message?(_config, _history_message), do: true

  defp maybe_execute_init_queries(%State{config: %{fire_init_queries: false}} = state), do: state

  defp maybe_execute_init_queries(%State{} = state) do
    _ =
      Task.Supervisor.start_child(state.task_supervisor, fn ->
        state
        |> init_query_work()
        |> Task.async_stream(fn fun -> fun.() end,
          ordered: false,
          max_concurrency: 3,
          timeout: state.config.default_query_timeout_ms
        )
        |> Stream.run()
      end)

    state
  end

  defp maybe_send_presence_update(%State{config: %{mark_online_on_connect: mark_online}} = state) do
    case fetch_socket_pid(state) do
      {:ok, socket_pid} ->
        _ =
          state.socket_module.send_presence_update(
            socket_pid,
            if(mark_online, do: :available, else: :unavailable)
          )

        state

      :error ->
        state
    end
  end

  defp init_query_work(%State{} = state) do
    [
      fn -> fetch_props(state) end,
      fn -> fetch_blocklist(state) end,
      fn -> fetch_privacy_settings(state) end
    ]
  end

  defp fetch_props(%State{} = state) do
    props_hash =
      state.store_ref
      |> Store.get(:creds, %{})
      |> Map.get(:last_prop_hash, "")

    node = %BinaryNode{
      tag: "iq",
      attrs: %{"to" => @s_whatsapp_net, "xmlns" => "w", "type" => "get"},
      content: [
        %BinaryNode{
          tag: "props",
          attrs: %{"protocol" => "2", "hash" => props_hash},
          content: nil
        }
      ]
    }

    with {:ok, socket_pid} <- fetch_socket_pid(state),
         {:ok, response} <-
           state.socket_module.query(socket_pid, node, state.config.default_query_timeout_ms) do
      props_node = BinaryNodeUtil.child(response, "props")
      props = reduce_children_to_dictionary(props_node, "prop")

      :ok = Store.put(state.store, :props, props)

      case props_node && props_node.attrs["hash"] do
        hash when is_binary(hash) and hash != "" ->
          :ok = Store.merge_creds(state.store, %{last_prop_hash: hash})
          :ok = EventEmitter.emit(state.event_emitter, :creds_update, %{last_prop_hash: hash})

        _ ->
          :ok
      end

      :ok = EventEmitter.emit(state.event_emitter, :settings_update, %{props: props})
      :ok
    else
      _ -> :ok
    end
  end

  defp fetch_blocklist(%State{} = state) do
    with {:ok, socket_pid} <- fetch_socket_pid(state),
         {:ok, blocklist} <-
           Privacy.fetch_blocklist({state.socket_module, socket_pid},
             store: state.store,
             query_timeout: state.config.default_query_timeout_ms
           ) do
      :ok = EventEmitter.emit(state.event_emitter, :blocklist_set, %{blocklist: blocklist})
      :ok
    else
      _ -> :ok
    end
  end

  defp fetch_privacy_settings(%State{} = state) do
    with {:ok, socket_pid} <- fetch_socket_pid(state),
         {:ok, privacy_settings} <-
           Privacy.fetch_settings({state.socket_module, socket_pid}, true,
             store: state.store,
             query_timeout: state.config.default_query_timeout_ms
           ) do
      :ok = EventEmitter.emit(state.event_emitter, :settings_update, %{privacy: privacy_settings})
      :ok
    else
      _ -> :ok
    end
  end

  defp reduce_children_to_dictionary(node, child_tag) do
    node
    |> BinaryNodeUtil.children(child_tag)
    |> Enum.reduce(%{}, fn child, acc ->
      case {child.attrs["name"], child.attrs["value"]} do
        {name, value} when is_binary(name) and is_binary(value) -> Map.put(acc, name, value)
        _ -> acc
      end
    end)
  end

  defp maybe_send_push_name_presence_update(
         %State{} = state,
         previous_creds,
         %{creds_update: %{me: me_update}}
       )
       when is_map(previous_creds) and is_map(me_update) do
    previous_name = nested_name(previous_creds)
    next_name = nested_name(%{me: me_update})

    if is_binary(next_name) and next_name != "" and next_name != previous_name do
      node = %BinaryNode{tag: "presence", attrs: %{"name" => next_name}, content: nil}

      case fetch_socket_pid(state) do
        {:ok, socket_pid} -> _ = state.socket_module.send_node(socket_pid, node)
        :error -> :ok
      end
    end

    state
  end

  defp maybe_send_push_name_presence_update(%State{} = state, _previous_creds, _events), do: state

  defp send_clean_dirty_bits(%State{} = state, type, from_timestamp \\ nil)
       when is_binary(type) do
    attrs =
      %{"type" => type}
      |> maybe_put_timestamp(from_timestamp)

    node = %BinaryNode{
      tag: "iq",
      attrs: %{"to" => @s_whatsapp_net, "type" => "set", "xmlns" => "urn:xmpp:whatsapp:dirty"},
      content: [%BinaryNode{tag: "clean", attrs: attrs, content: nil}]
    }

    case fetch_socket_pid(state) do
      {:ok, socket_pid} -> _ = state.socket_module.send_node(socket_pid, node)
      :error -> :ok
    end
  end

  defp maybe_put_timestamp(attrs, nil), do: attrs

  defp maybe_put_timestamp(attrs, timestamp),
    do: Map.put(attrs, "timestamp", to_string(timestamp))

  defp connect_socket(%State{} = state) do
    case fetch_socket_pid(state) do
      {:ok, socket_pid} ->
        case state.socket_module.connect(socket_pid) do
          :ok -> state
          {:error, {:invalid_state, _state_name}} -> state
        end

      :error ->
        state
    end
  end

  defp fetch_socket_pid(%State{} = state) do
    case socket_pid(state.supervisor, state.socket_module) do
      nil -> :error
      socket_pid -> {:ok, socket_pid}
    end
  end

  defp socket_pid(supervisor, socket_module) do
    supervisor
    |> Elixir.Supervisor.which_children()
    |> Enum.find_value(fn
      {^socket_module, pid, _type, _modules} when is_pid(pid) -> pid
      _ -> nil
    end)
  end

  defp wrap_signal_store(nil), do: nil
  defp wrap_signal_store(%SignalStore{} = signal_store), do: signal_store

  defp wrap_signal_store({module, server}) when is_atom(module) do
    pid = GenServer.whereis(server)

    if is_pid(pid) and function_exported?(module, :wrap, 1) do
      %SignalStore{module: module, ref: module.wrap(pid)}
    else
      nil
    end
  end

  defp wrap_signal_store(server) do
    wrap_signal_store({SignalStoreMemory, server})
  end

  defp build_signal_repository(
         %Repository{} = repository,
         _adapter,
         _adapter_state,
         _signal_store,
         _store_ref
       ),
       do: repository

  defp build_signal_repository(
         nil,
         adapter,
         adapter_state,
         %SignalStore{} = signal_store,
         _store_ref
       )
       when is_atom(adapter) and not is_nil(adapter) do
    Repository.new(
      adapter: adapter,
      adapter_state: adapter_state,
      store: signal_store,
      pn_to_lid_lookup: lid_lookup_fun(signal_store)
    )
  end

  defp build_signal_repository(
         nil,
         nil,
         _adapter_state,
         %SignalStore{} = signal_store,
         %Store.Ref{} = store_ref
       ) do
    case build_default_signal_adapter_state(store_ref, signal_store) do
      {:ok, adapter_state} ->
        Repository.new(
          adapter: DefaultSignalAdapter,
          adapter_state: adapter_state,
          store: signal_store,
          pn_to_lid_lookup: lid_lookup_fun(signal_store)
        )

      :error ->
        nil
    end
  end

  defp build_signal_repository(repository, _adapter, _adapter_state, _signal_store, _store_ref),
    do: repository

  defp build_default_signal_adapter_state(%Store.Ref{} = store_ref, %SignalStore{} = signal_store) do
    auth_state = Store.get(store_ref, :auth_state, %{})
    identity_key_pair = AuthState.get(auth_state, :signed_identity_key)
    signed_pre_key = AuthState.get(auth_state, :signed_pre_key)
    registration_id = AuthState.get(auth_state, :registration_id)

    if valid_identity_key_pair?(identity_key_pair) and valid_signed_pre_key?(signed_pre_key) and
         is_integer(registration_id) and registration_id >= 0 do
      {:ok,
       DefaultSignalAdapter.new(
         store: signal_store,
         identity_key_pair: identity_key_pair,
         registration_id: registration_id,
         signed_pre_key: signed_pre_key
       )}
    else
      :error
    end
  end

  defp valid_identity_key_pair?(%{public: public, private: private})
       when is_binary(public) and is_binary(private),
       do: true

  defp valid_identity_key_pair?(_identity_key_pair), do: false

  defp valid_signed_pre_key?(%{key_id: key_id, key_pair: key_pair, signature: signature})
       when is_integer(key_id) and key_id >= 0 and is_binary(signature),
       do: valid_identity_key_pair?(key_pair)

  defp valid_signed_pre_key?(_signed_pre_key), do: false

  defp receiver_context(%State{} = state, %Repository{} = repository) do
    creds = Store.get(state.store_ref, :creds, %{})

    %{
      signal_repository: repository,
      event_emitter: state.event_emitter,
      me_id: nested_id(creds),
      me_lid: nested_lid(creds),
      store_ref: state.store_ref,
      signal_store: state.signal_store
    }
    |> maybe_put_callback(:send_receipt_fun, receipt_sender_fun(state))
    |> maybe_put_callback(:history_sync_download_fun, state.history_sync_download_fun)
    |> maybe_put_callback(:inflate_fun, state.history_sync_inflate_fun)
    |> maybe_put_callback(:get_message_fun, state.get_message_fun)
  end

  defp sender_context(%State{} = state, %Repository{} = repository) do
    creds = Store.get(state.store_ref, :creds, %{})

    %{
      signal_repository: repository,
      signal_store: state.signal_store,
      me_id: nested_id(creds),
      me_lid: nested_lid(creds)
    }
    |> maybe_put(:device_identity, encoded_device_identity(creds))
    |> maybe_put_callback(:query_fun, sender_query_fun(state))
    |> maybe_put_callback(:send_node_fun, receipt_sender_fun(state))
  end

  defp notification_context(%State{} = state) do
    resync_app_state_fun = state.resync_app_state_fun || built_in_resync_app_state_fun(state)

    %{event_emitter: state.event_emitter}
    |> maybe_put_callback(:store_privacy_token_fun, privacy_token_store_fun(state.signal_store))
    |> maybe_put_callback(:handle_encrypt_notification_fun, state.handle_encrypt_notification_fun)
    |> maybe_put_callback(:device_notification_fun, state.device_notification_fun)
    |> maybe_put_callback(:resync_app_state_fun, resync_app_state_fun)
  end

  defp receipt_sender_fun(%State{} = state) do
    case fetch_socket_pid(state) do
      {:ok, socket_pid} -> fn node -> state.socket_module.send_node(socket_pid, node) end
      :error -> nil
    end
  end

  defp sender_query_fun(%State{} = state) do
    case fetch_socket_pid(state) do
      {:ok, socket_pid} ->
        fn node ->
          state.socket_module.query(socket_pid, node, state.config.default_query_timeout_ms)
        end

      :error ->
        nil
    end
  end

  defp maybe_handle_identity_change(
         %State{signal_repository: %Repository{}} = state,
         %BinaryNode{} = node
       ) do
    if node.attrs["from"] == @s_whatsapp_net do
      state
    else
      creds = Store.get(state.store_ref, :creds, %{})

      context = %{
        signal_repository: state.signal_repository,
        me_id: nested_id(creds),
        me_lid: nested_lid(creds),
        assert_sessions_fun: fn ctx, jids, force? ->
          assert_sessions(state, ctx, jids, force?)
        end
      }

      case IdentityChangeHandler.handle(node, context, state.identity_change_cache) do
        {:ok, _result, %{signal_repository: %Repository{} = repo}, cache} ->
          %{state | signal_repository: repo, identity_change_cache: cache}

        {:ok, _result, _context, cache} ->
          %{state | identity_change_cache: cache}
      end
    end
  end

  defp maybe_handle_identity_change(%State{} = state, _node), do: state

  defp assert_sessions(
         %State{} = state,
         %{signal_repository: %Repository{} = repository},
         jids,
         force?
       ) do
    case fetch_socket_pid(state) do
      {:ok, socket_pid} ->
        Session.assert_sessions(
          %{
            signal_repository: repository,
            query_fun: fn node ->
              state.socket_module.query(socket_pid, node, state.config.default_query_timeout_ms)
            end
          },
          jids,
          force: force?
        )

      :error ->
        {:error, :socket_not_available}
    end
  end

  defp privacy_token_store_fun(%SignalStore{} = signal_store) do
    fn jid, token, timestamp ->
      SignalStore.set(signal_store, %{tctoken: %{jid => %{token: token, timestamp: timestamp}}})
    end
  end

  defp privacy_token_store_fun(_signal_store), do: nil

  defp lid_lookup_fun(%SignalStore{} = signal_store) do
    fn pn ->
      case SignalStore.get(signal_store, :"lid-mapping", [pn]) do
        %{^pn => lid} when is_binary(lid) -> lid
        _ -> nil
      end
    end
  end

  defp built_in_resync_app_state_fun(%State{} = state) do
    fn name ->
      with {:ok, collections} <- normalize_patch_names([name]) do
        run_app_state_resync(state, collections, initial_sync: false)
      end
    end
  end

  defp maybe_seed_event_buffer(
         %State{} = state,
         %{messaging_history_set: %{chats: chats}}
       )
       when is_list(chats) do
    seed_event_buffer_chats(state, :history_sets, chats)
  end

  defp maybe_seed_event_buffer(%State{} = state, %{chats_upsert: chats}) when is_list(chats) do
    seed_event_buffer_chats(state, :chat_upserts, chats)
  end

  defp maybe_seed_event_buffer(%State{} = state, _events), do: state

  defp seed_event_buffer_chats(%State{} = state, bucket, chats) do
    chats_by_id =
      Enum.reduce(chats, %{}, fn chat, acc ->
        case chat_id(chat) do
          id when is_binary(id) -> Map.put(acc, id, chat)
          _ -> acc
        end
      end)

    if map_size(chats_by_id) == 0 do
      state
    else
      seed = merge_event_buffer_seed(state.event_buffer_seed, bucket, chats_by_id)
      :ok = EventEmitter.seed(state.event_emitter, seed)
      %{state | event_buffer_seed: seed}
    end
  end

  defp merge_event_buffer_seed(seed, :history_sets, chats_by_id) do
    history_chats =
      seed
      |> get_in([:historySets, :chats])
      |> Kernel.||(%{})
      |> Map.merge(chats_by_id)

    seed
    |> Map.put(:historySets, %{chats: history_chats})
    |> Map.put(:history_sets, %{chats: history_chats})
  end

  defp merge_event_buffer_seed(seed, :chat_upserts, chats_by_id) do
    chat_upserts =
      seed
      |> Map.get(:chatUpserts, %{})
      |> Map.merge(chats_by_id)

    seed
    |> Map.put(:chatUpserts, chat_upserts)
    |> Map.put(:chat_upserts, chat_upserts)
  end

  defp maybe_start_initial_app_state_sync(
         %State{sync_state: :syncing, app_state_sync_ref: nil} = state,
         %{messaging_history_set: _history}
       ) do
    maybe_launch_initial_app_state_sync(state)
  end

  defp maybe_start_initial_app_state_sync(
         %State{sync_state: :syncing, app_state_sync_ref: nil} = state,
         %{creds_update: %{my_app_state_key_id: key_id}}
       )
       when is_binary(key_id) and key_id != "" do
    maybe_launch_initial_app_state_sync(state)
  end

  defp maybe_start_initial_app_state_sync(%State{} = state, _events), do: state

  defp maybe_launch_initial_app_state_sync(%State{} = state) do
    case current_app_state_key_id(state) do
      key_id when is_binary(key_id) and key_id != "" ->
        launch_initial_app_state_sync(state)

      _ ->
        state
    end
  end

  defp launch_initial_app_state_sync(%State{} = state) do
    case fetch_socket_pid(state) do
      {:ok, socket_pid} ->
        ref = make_ref()
        coordinator_pid = self()
        me = current_me(state)
        collections = BaileysEx.Syncd.Codec.patch_names()

        {:ok, _pid} =
          Task.Supervisor.start_child(state.task_supervisor, fn ->
            result =
              try do
                run_app_state_resync(
                  state,
                  collections,
                  initial_sync: true,
                  socket_pid: socket_pid,
                  me: me
                )
              rescue
                exception ->
                  {:error, exception}
              catch
                kind, reason ->
                  {:error, {kind, reason}}
              end

            Kernel.send(
              coordinator_pid,
              {:app_state_sync_complete, ref, normalize_sync_result(result)}
            )
          end)

        %{state | app_state_sync_ref: ref}

      :error ->
        _ = Process.send_after(self(), :complete_initial_sync, 25)
        state
    end
  end

  defp run_app_state_resync(%State{} = state, collections, opts) when is_list(collections) do
    socket_pid = Keyword.get_lazy(opts, :socket_pid, fn -> socket_pid!(state) end)
    me = Keyword.get_lazy(opts, :me, fn -> current_me(state) end)

    queryable = fn node ->
      state.socket_module.query(socket_pid, node, state.config.default_query_timeout_ms)
    end

    AppState.resync_app_state(
      queryable,
      state.store,
      collections,
      signal_store: state.signal_store,
      event_emitter: state.event_emitter,
      me: me,
      is_initial_sync: Keyword.get(opts, :initial_sync, false)
    )
  end

  defp increment_account_sync_counter(%State{} = state) do
    current_counter =
      state.store_ref
      |> Store.get(:creds, %{})
      |> Map.get(:account_sync_counter, 0)

    :ok =
      EventEmitter.emit(state.event_emitter, :creds_update, %{
        account_sync_counter: current_counter + 1
      })
  end

  defp normalize_sync_result(:ok), do: :ok
  defp normalize_sync_result({:error, _} = err), do: err

  defp normalize_patch_names(names) when is_list(names) do
    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, acc} ->
      case normalize_patch_name(name) do
        {:ok, collection} -> {:cont, {:ok, acc ++ [collection]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp normalize_patch_name(name) when is_atom(name) do
    if name in BaileysEx.Syncd.Codec.patch_names() do
      {:ok, name}
    else
      {:error, {:unknown_patch_name, name}}
    end
  end

  defp normalize_patch_name(name) when is_binary(name) do
    case Enum.find(BaileysEx.Syncd.Codec.patch_names(), &(Atom.to_string(&1) == name)) do
      nil -> {:error, {:unknown_patch_name, name}}
      collection -> {:ok, collection}
    end
  end

  defp normalize_patch_name(name), do: {:error, {:unknown_patch_name, name}}

  defp current_app_state_key_id(%State{} = state) do
    state.store_ref
    |> Store.get(:creds, %{})
    |> Map.get(:my_app_state_key_id)
  end

  defp current_me(%State{} = state) do
    state.store_ref
    |> Store.get(:creds, %{})
    |> Map.get(:me, %{})
  end

  defp socket_pid!(%State{} = state) do
    case fetch_socket_pid(state) do
      {:ok, socket_pid} -> socket_pid
      :error -> raise "socket not available"
    end
  end

  defp chat_id(%{id: id}) when is_binary(id), do: id
  defp chat_id(%{"id" => id}) when is_binary(id), do: id
  defp chat_id(_chat), do: nil

  defp maybe_put_callback(map, _key, nil), do: map
  defp maybe_put_callback(map, key, value), do: Map.put(map, key, value)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp nested_name(%{me: %{name: name}}) when is_binary(name), do: name
  defp nested_name(%{me: %{"name" => name}}) when is_binary(name), do: name
  defp nested_name(%{"me" => %{name: name}}) when is_binary(name), do: name
  defp nested_name(%{"me" => %{"name" => name}}) when is_binary(name), do: name
  defp nested_name(_creds), do: nil

  defp nested_id(%{me: %{id: id}}) when is_binary(id), do: id
  defp nested_id(%{me: %{"id" => id}}) when is_binary(id), do: id
  defp nested_id(%{"me" => %{id: id}}) when is_binary(id), do: id
  defp nested_id(%{"me" => %{"id" => id}}) when is_binary(id), do: id
  defp nested_id(_creds), do: nil

  defp nested_lid(%{me: %{lid: lid}}) when is_binary(lid), do: lid
  defp nested_lid(%{me: %{"lid" => lid}}) when is_binary(lid), do: lid
  defp nested_lid(%{"me" => %{lid: lid}}) when is_binary(lid), do: lid
  defp nested_lid(%{"me" => %{"lid" => lid}}) when is_binary(lid), do: lid
  defp nested_lid(_creds), do: nil

  defp encoded_device_identity(%{account: %ADVSignedDeviceIdentity{} = account}) do
    account
    |> normalize_account_signature_key()
    |> ADVSignedDeviceIdentity.encode()
    |> empty_identity_to_nil()
  end

  defp encoded_device_identity(%{account: %{} = account}) do
    case normalize_device_identity_account(account) do
      {:ok, normalized} when map_size(normalized) > 0 ->
        normalized
        |> normalize_account_signature_key()
        |> then(&struct(ADVSignedDeviceIdentity, &1))
        |> ADVSignedDeviceIdentity.encode()
        |> empty_identity_to_nil()

      {:ok, _normalized} ->
        nil

      {:error, reason} ->
        Logger.warning("dropping invalid device identity account: #{inspect(reason)}")
        nil
    end
  end

  defp encoded_device_identity(%{"account" => account}) when is_map(account) do
    encoded_device_identity(%{account: account})
  end

  defp encoded_device_identity(%{account: account}) when not is_nil(account) do
    Logger.warning("dropping invalid device identity account: #{inspect(account)}")
    nil
  end

  defp encoded_device_identity(%{"account" => account}) when not is_nil(account) do
    Logger.warning("dropping invalid device identity account: #{inspect(account)}")
    nil
  end

  defp encoded_device_identity(_creds), do: nil

  defp normalize_device_identity_account(account) when is_map(account) do
    Enum.reduce_while(account, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case normalize_account_key(key) do
        {:ok, normalized_key} ->
          normalize_device_identity_value(acc, normalized_key, value)

        :skip ->
          {:cont, {:ok, acc}}
      end
    end)
  end

  defp normalize_account_key(key) when is_atom(key) or is_binary(key) do
    case Map.get(@device_identity_account_keys, key) do
      nil -> :skip
      normalized_key -> {:ok, normalized_key}
    end
  end

  defp normalize_account_key(_key), do: :skip

  defp normalize_device_identity_value(acc, normalized_key, value)
       when is_binary(value) or is_nil(value) do
    {:cont, {:ok, Map.put(acc, normalized_key, value)}}
  end

  defp normalize_device_identity_value(_acc, normalized_key, value) do
    {:halt, {:error, {:invalid_account_value, normalized_key, value}}}
  end

  defp normalize_account_signature_key(account) when is_map(account) do
    case Map.get(account, :account_signature_key) do
      signature_key when is_binary(signature_key) and byte_size(signature_key) > 0 ->
        account

      _ ->
        Map.put(account, :account_signature_key, nil)
    end
  end

  defp empty_identity_to_nil(<<>>), do: nil
  defp empty_identity_to_nil(identity), do: identity
end
