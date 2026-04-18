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
  alias BaileysEx.Connection.Config
  alias BaileysEx.Connection.EventEmitter
  alias BaileysEx.Connection.Socket
  alias BaileysEx.Connection.Store
  alias BaileysEx.Feature.AppState
  alias BaileysEx.Feature.Call
  alias BaileysEx.Feature.Community
  alias BaileysEx.Feature.Group
  alias BaileysEx.Feature.Presence
  alias BaileysEx.Message.IdentityChangeHandler
  alias BaileysEx.Message.NotificationHandler
  alias BaileysEx.Message.Receipt
  alias BaileysEx.Message.Receiver
  alias BaileysEx.Message.Retry
  alias BaileysEx.Message.Sender
  alias BaileysEx.Protocol.BinaryNode, as: BinaryNodeUtil
  alias BaileysEx.Protocol.Proto.ADVSignedDeviceIdentity
  alias BaileysEx.Protocol.USync
  alias BaileysEx.Signal.Adapter.Signal, as: DefaultSignalAdapter
  alias BaileysEx.Signal.LIDMappingStore
  alias BaileysEx.Signal.Repository
  alias BaileysEx.Signal.Session
  alias BaileysEx.Signal.Store, as: SignalStore
  alias BaileysEx.Syncd.Codec, as: SyncdCodec
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
      init_query_handlers: %{},
      event_buffer_seed: %{},
      identity_change_cache: %{},
      sync_state: :connecting,
      reconnect_attempts: 0
    ]
  end

  @doc """
  Start the coordinator process.
  Accepts a keyword list containing `:config`, `:event_emitter`, `:store`, 
  `:signal_store`, `:supervisor`, and `:task_supervisor`.
  """
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

    wrapped_signal_store = SignalStore.wrap_running(state.signal_store)
    store_ref = Store.wrap(state.store)

    unsubscribe =
      EventEmitter.tap(state.event_emitter, coordinator_event_tap(coordinator_pid, store_ref))

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
          store_ref,
          state.supervisor,
          state.socket_module,
          state.config.default_query_timeout_ms
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
    require Logger
    ctx = sender_context(state, repository)

    socket_result = fetch_socket_pid(state)

    Logger.debug(
      "[Coordinator] send_message: jid=#{inspect(jid)} has_query_fun=#{is_function(ctx[:query_fun], 1)} " <>
        "has_send_node_fun=#{is_function(ctx[:send_node_fun], 1)} " <>
        "socket_lookup=#{inspect(socket_result)} " <>
        "supervisor_alive=#{Process.alive?(state.supervisor)}"
    )

    case Sender.send(ctx, jid, content, opts) do
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
  def handle_info({:events, previous_creds, events}, %State{} = state)
      when is_map(previous_creds) and is_map(events) do
    state =
      state
      |> handle_socket_node(events)
      |> persist_lid_mapping_update(events)
      |> maybe_seed_event_buffer(events)
      |> maybe_send_push_name_presence_update(previous_creds, events)
      |> sync_creds_update_to_socket(events)
      |> handle_connection_update(events)
      |> handle_sync_event(events)
      |> maybe_start_initial_app_state_sync(events)
      |> handle_dirty_update(events)

    {:noreply, state}
  end

  def handle_info({:events, events}, %State{} = state) when is_map(events) do
    previous_creds = Store.get(state.store_ref, :creds, %{})

    state =
      state
      |> handle_socket_node(events)
      |> persist_creds_update(events)
      |> persist_lid_mapping_update(events)
      |> maybe_seed_event_buffer(events)
      |> maybe_send_push_name_presence_update(previous_creds, events)
      |> sync_creds_update_to_socket(events)
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
    Logger.debug("[SyncDiag] initial sync timeout fired, forcing :online")
    _ = EventEmitter.flush(state.event_emitter)
    {:noreply, %{state | initial_sync_timer: nil, sync_state: :online}}
  end

  def handle_info(:initial_sync_timeout, %State{} = state) do
    {:noreply, %{state | initial_sync_timer: nil}}
  end

  def handle_info(:complete_initial_sync, %State{sync_state: :syncing} = state) do
    Logger.debug("[SyncDiag] completing initial sync, transitioning to :online")
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
        {socket_module, ref, {:ok, %BinaryNode{} = response}},
        %State{socket_module: socket_module, init_query_handlers: handlers} = state
      )
      when is_reference(ref) do
    case Map.pop(handlers, ref) do
      {handle_response, remaining_handlers} when is_function(handle_response, 1) ->
        handle_response.(response)
        {:noreply, %{state | init_query_handlers: remaining_handlers}}

      {nil, _remaining_handlers} ->
        {:noreply, state}
    end
  end

  def handle_info(
        {socket_module, ref, {:error, :timeout}},
        %State{socket_module: socket_module, init_query_handlers: handlers} = state
      )
      when is_reference(ref) do
    if Map.has_key?(handlers, ref) do
      Logger.warning("[Coordinator] init query timed out")
      {:noreply, %{state | init_query_handlers: Map.delete(handlers, ref)}}
    else
      {:noreply, state}
    end
  end

  def handle_info(
        {socket_module, ref, {:error, reason}},
        %State{socket_module: socket_module, init_query_handlers: handlers} = state
      )
      when is_reference(ref) do
    if Map.has_key?(handlers, ref) do
      Logger.warning("[Coordinator] init query failed: #{inspect(reason)}")
      {:noreply, %{state | init_query_handlers: Map.delete(handlers, ref)}}
    else
      {:noreply, state}
    end
  end

  def handle_info(
        {:app_state_sync_complete, ref, result},
        %State{app_state_sync_ref: ref} = state
      ) do
    state = %{state | app_state_sync_ref: nil}

    case result do
      :ok ->
        Logger.debug(
          "[AppStateDiag] initial app state sync complete " <>
            "store_name=#{inspect(AuthState.me_name(%{me: current_me(state)}))}"
        )

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

  defp coordinator_event_tap(coordinator_pid, store_ref) do
    fn events ->
      previous_creds = Store.get(store_ref, :creds, %{})
      :ok = persist_tapped_creds_update(store_ref, events)
      Kernel.send(coordinator_pid, {:events, previous_creds, events})
    end
  end

  defp persist_tapped_creds_update(store_ref, %{creds_update: creds_update})
       when is_map(creds_update) do
    Store.merge_creds(store_ref, creds_update)
  end

  defp persist_tapped_creds_update(_store_ref, _events), do: :ok

  defp handle_socket_node(
         %State{signal_repository: %Repository{} = repository} = state,
         %{socket_node: %{node: %BinaryNode{tag: "message"} = node}}
       ) do
    msg_id = node.attrs["id"]

    case Receiver.process_node(node, receiver_context(state, repository)) do
      {:ok, _message, %{signal_repository: %Repository{} = updated_repository}} ->
        Logger.warning("[Coordinator] message #{msg_id} processed OK")
        %{state | signal_repository: updated_repository}

      {:error, reason} ->
        Logger.warning("[Coordinator] message #{msg_id} failed: #{inspect(reason)}")
        state
    end
  end

  defp handle_socket_node(
         %State{signal_repository: nil} = state,
         %{socket_node: %{node: %BinaryNode{tag: "message"} = node}}
       ) do
    Logger.warning(
      "[Coordinator] message #{node.attrs["id"]} DROPPED — no signal_repository configured"
    )

    state
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
    state = maybe_handle_retry_receipt(state, node)
    :ok = Receipt.process_receipt(node, state.event_emitter)
    send_transport_ack(state, node)
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
    send_notification_ack(state, node)
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
    send_notification_ack(state, node)
  end

  defp handle_socket_node(%State{} = state, events) do
    # Diagnostic catch-all: log any socket_node events that aren't handled above
    case events do
      %{socket_node: %{node: %BinaryNode{tag: tag}}} ->
        Logger.warning(
          "[Coordinator] UNHANDLED socket_node tag=#{tag} " <>
            "signal_repo=#{inspect(state.signal_repository != nil and is_struct(state.signal_repository, Repository))}"
        )

      _ ->
        :ok
    end

    state
  end

  defp persist_creds_update(%State{} = state, %{creds_update: creds_update})
       when is_map(creds_update) do
    :ok = Store.merge_creds(state.store, creds_update)
    state
  end

  defp persist_creds_update(%State{} = state, _events), do: state

  # Forwards creds_update to the socket so its in-memory auth_state stays
  # in sync with external updates (e.g. app-state sync pushNameSetting).
  # Uses :sync_creds_update so the socket merges without re-emitting.
  defp sync_creds_update_to_socket(%State{} = state, %{creds_update: creds_update})
       when is_map(creds_update) do
    case fetch_socket_pid(state) do
      {:ok, socket_pid} -> Kernel.send(socket_pid, {:sync_creds_update, creds_update})
      :error -> :ok
    end

    state
  end

  defp sync_creds_update_to_socket(%State{} = state, _events), do: state

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
    |> Map.put(:reconnect_attempts, 0)
    |> maybe_execute_init_queries()
    |> maybe_send_presence_update()
    |> maybe_send_open_unified_session()
    |> maybe_register_own_lid_session()
  end

  defp handle_connection_update(
         %State{} = state,
         %{connection_update: %{connection: :close, last_disconnect: last_disconnect}}
       ) do
    reason = disconnect_reason(last_disconnect)

    if should_schedule_reconnect?(state.config, reason, state.reconnect_attempts + 1) do
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
    will_sync_history = should_sync_history_message?(state.config, %{sync_type: :RECENT})

    Logger.debug(
      "[SyncDiag] received_pending_notifications=true sync_state=:connecting " <>
        "will_sync_history=#{inspect(will_sync_history)}"
    )

    if will_sync_history do
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
    Logger.debug("[SyncDiag] messaging_history_set received, transitioning to :syncing")
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
    attempt = state.reconnect_attempts + 1

    # Exponential backoff with jitter
    base_delay = state.config.base_retry_delay_ms
    max_delay = state.config.max_retry_delay_ms
    jitter_factor = state.config.retry_delay_random_factor

    delay = min(base_delay * attempt, max_delay)
    jittered_delay = delay * (1 + jitter_factor * (:rand.uniform() - 0.5))
    actual_delay = trunc(jittered_delay)

    Telemetry.execute(
      [:connection, :reconnect],
      %{count: 1},
      %{
        reason: reason,
        retry_delay_ms: actual_delay,
        base_delay_ms: base_delay,
        max_delay_ms: max_delay,
        attempt: attempt,
        max_retries: state.config.max_retries,
        reconnect_policy: state.config.reconnect_policy
      }
    )

    timer = Process.send_after(self(), :reconnect_socket, actual_delay)
    %{state | reconnect_timer: timer, reconnect_attempts: attempt}
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

  defp disconnect_reason(%{error: %{reason: reason}}), do: reason
  defp disconnect_reason(%{reason: reason}), do: reason
  defp disconnect_reason(%{error: %{status_code: 401}}), do: :logged_out
  defp disconnect_reason(%{error: %{status_code: 440}}), do: :connection_replaced
  defp disconnect_reason(%{error: %{status_code: 411}}), do: :multidevice_mismatch
  defp disconnect_reason(%{error: %{status_code: 515}}), do: :restart_required
  defp disconnect_reason(%{error: %{status_code: 403}}), do: :forbidden
  defp disconnect_reason(%{error: %{status_code: 503}}), do: :unavailable_service
  defp disconnect_reason(%{error: %{status_code: 408}}), do: :connection_lost
  defp disconnect_reason(%{error: %{status_code: 500}}), do: :bad_session
  defp disconnect_reason(_last_disconnect), do: nil

  defp should_schedule_reconnect?(config, reason, attempt),
    do: Config.should_reconnect?(config, reason, attempt)

  defp should_sync_history_message?(%{should_sync_history_message: fun}, history_message)
       when is_function(fun, 1) do
    !!fun.(history_message)
  end

  defp should_sync_history_message?(_config, history_message),
    do: Config.default_should_sync_history_message(history_message)

  defp maybe_execute_init_queries(%State{config: %{fire_init_queries: false}} = state), do: state

  defp maybe_execute_init_queries(%State{} = state) do
    case fetch_socket_pid(state) do
      {:ok, socket_pid} ->
        Enum.reduce(init_query_work(state), state, fn spec, acc ->
          start_init_query(acc, socket_pid, spec)
        end)

      :error ->
        state
    end
  end

  defp start_init_query(acc, socket_pid, spec) do
    case acc.socket_module.start_query(
           socket_pid,
           self(),
           spec.node,
           acc.config.default_query_timeout_ms
         ) do
      {:ok, ref} ->
        %{acc | init_query_handlers: Map.put(acc.init_query_handlers, ref, spec.handle_response)}

      {:error, :timeout} ->
        Logger.warning("[Coordinator] init query timed out")
        acc

      {:error, reason} ->
        Logger.warning("[Coordinator] init query failed: #{inspect(reason)}")
        acc
    end
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

  # Mirrors Baileys socket.ts:944-965 — after connection:open, register the
  # companion's own LID↔PN mapping and device list so the server can route
  # messages to this device and the phone clears "Logging in..."
  defp maybe_register_own_lid_session(%State{} = state) do
    auth_state = Store.get(state.store_ref, :auth_state, %{})
    me = AuthState.get(auth_state, :me, %{}) || %{}
    lid = me[:lid] || me["lid"]
    pn = me[:id] || me["id"]

    cond do
      not (is_binary(lid) and is_binary(pn)) ->
        state

      state.signal_store == nil ->
        state

      true ->
        Task.Supervisor.start_child(state.task_supervisor, fn ->
          register_own_lid_session(state, pn, lid)
        end)

        state
    end
  end

  defp register_own_lid_session(%State{} = state, pn, lid) do
    require Logger

    try do
      # 1. Store own LID-PN mapping
      :ok = LIDMappingStore.store_lid_pn_mappings(state.signal_store, [%{lid: lid, pn: pn}])

      # 2. Create device list for own user
      {user, device} = parse_own_device(pn)

      if user do
        existing_devices =
          case SignalStore.get(state.signal_store, :"device-list", [user]) do
            %{^user => ids} when is_list(ids) -> ids
            _ -> []
          end

        SignalStore.set(state.signal_store, %{
          :"device-list" => %{
            user => merge_own_device_ids(existing_devices, device)
          }
        })
      end

      # 3. Migrate own session PN → LID (if signal repository available)
      if state.signal_repository do
        case Repository.migrate_session(state.signal_repository, pn, lid) do
          {:ok, _repo, result} ->
            Logger.info(
              "[Coordinator] own LID session registered — pn=#{pn}, lid=#{lid}, " <>
                "migrated=#{result.migrated}"
            )

          {:error, reason} ->
            Logger.warning("[Coordinator] own LID session migration failed: #{inspect(reason)}")
        end
      else
        Logger.info(
          "[Coordinator] own LID session registered (no session migration) — pn=#{pn}, lid=#{lid}"
        )
      end
    rescue
      error ->
        Logger.warning("[Coordinator] own LID registration failed: #{Exception.message(error)}")
    end
  end

  defp parse_own_device(pn) when is_binary(pn) do
    case BaileysEx.Protocol.JID.parse(pn) do
      %BaileysEx.JID{user: user, device: device} when is_binary(user) ->
        {user, Integer.to_string(device || 0)}

      _ ->
        {nil, nil}
    end
  end

  defp merge_own_device_ids(existing_devices, current_device) when is_list(existing_devices) do
    ["0", current_device | existing_devices]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
  end

  defp init_query_work(%State{} = state) do
    [
      %{node: props_query_node(state), handle_response: &handle_props_response(state, &1)},
      %{node: blocklist_query_node(), handle_response: &handle_blocklist_response(state, &1)},
      %{
        node: privacy_settings_query_node(),
        handle_response: &handle_privacy_settings_response(state, &1)
      }
    ]
  end

  defp props_query_node(%State{} = state) do
    props_hash =
      state.store_ref
      |> Store.get(:creds, %{})
      |> Map.get(:last_prop_hash, "")
      |> normalize_props_hash()

    Logger.debug("[PropsDiag] fetch_props sending hash=#{inspect(props_hash)}")

    %BinaryNode{
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
  end

  defp handle_props_response(%State{} = state, %BinaryNode{} = response) do
    props_node = BinaryNodeUtil.child(response, "props")
    props = reduce_children_to_dictionary(props_node, "prop")
    response_hash = props_node && props_node.attrs["hash"]

    Logger.debug(
      "[PropsDiag] fetch_props received props_count=#{map_size(props)} " <>
        "hash=#{inspect(response_hash)}"
    )

    :ok = Store.put(state.store, :props, props)

    case response_hash do
      hash when is_binary(hash) and hash != "" ->
        :ok = Store.merge_creds(state.store, %{last_prop_hash: hash})
        :ok = EventEmitter.emit(state.event_emitter, :creds_update, %{last_prop_hash: hash})

      _ ->
        :ok
    end

    :ok = EventEmitter.emit(state.event_emitter, :settings_update, %{props: props})
    :ok
  end

  defp blocklist_query_node do
    %BinaryNode{
      tag: "iq",
      attrs: %{"xmlns" => "blocklist", "to" => @s_whatsapp_net, "type" => "get"},
      content: nil
    }
  end

  defp handle_blocklist_response(%State{} = state, %BinaryNode{} = response) do
    blocklist =
      response
      |> BinaryNodeUtil.child("list")
      |> BinaryNodeUtil.children("item")
      |> Enum.map(& &1.attrs["jid"])
      |> Enum.reject(&is_nil/1)

    :ok = Store.put(state.store, :blocklist, blocklist)
    :ok = EventEmitter.emit(state.event_emitter, :blocklist_set, %{blocklist: blocklist})
  end

  defp privacy_settings_query_node do
    %BinaryNode{
      tag: "iq",
      attrs: %{"xmlns" => "privacy", "to" => @s_whatsapp_net, "type" => "get"},
      content: [%BinaryNode{tag: "privacy", attrs: %{}, content: nil}]
    }
  end

  defp handle_privacy_settings_response(%State{} = state, %BinaryNode{} = response) do
    privacy_settings =
      response
      |> BinaryNodeUtil.child("privacy")
      |> reduce_children_to_dictionary("category")

    :ok = Store.put(state.store, :privacy_settings, privacy_settings)
    :ok = EventEmitter.emit(state.event_emitter, :settings_update, %{privacy: privacy_settings})
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

  defp normalize_props_hash(hash) when is_binary(hash), do: hash
  defp normalize_props_hash(_hash), do: ""

  defp maybe_send_push_name_presence_update(
         %State{} = state,
         previous_creds,
         %{creds_update: %{me: me_update}}
       )
       when is_map(previous_creds) and is_map(me_update) do
    previous_name = AuthState.me_name(previous_creds)
    next_name = AuthState.me_name(%{me: me_update})

    if is_binary(next_name) and next_name != "" and next_name != previous_name do
      Logger.debug(
        "[PushNameDiag] creds_update changed push name " <>
          "previous=#{inspect(previous_name)} next=#{inspect(next_name)}"
      )

      node = %BinaryNode{tag: "presence", attrs: %{"name" => next_name}, content: nil}

      case fetch_socket_pid(state) do
        {:ok, socket_pid} ->
          Logger.debug("[PushNameDiag] sending bare presence name=#{inspect(next_name)}")
          _ = state.socket_module.send_node(socket_pid, node)

        :error ->
          Logger.debug(
            "[PushNameDiag] skipped bare presence send because socket pid is unavailable"
          )

          :ok
      end
    end

    state
  end

  defp maybe_send_push_name_presence_update(%State{} = state, _previous_creds, _events), do: state

  defp maybe_send_open_unified_session(%State{} = state) do
    case fetch_socket_pid(state) do
      {:ok, socket_pid} ->
        _ = state.socket_module.send_unified_session(socket_pid)
        state

      :error ->
        state
    end
  end

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

  defp send_transport_ack(%State{} = state, %BinaryNode{} = node) do
    ack = build_transport_ack(state, node)

    case {ack, fetch_socket_pid(state)} do
      {%BinaryNode{} = ack, {:ok, socket_pid}} ->
        _ = state.socket_module.send_node(socket_pid, ack)
        state

      _ ->
        state
    end
  end

  defp build_transport_ack(%State{} = state, %BinaryNode{tag: tag, attrs: attrs} = node)
       when tag in ["message", "receipt"] do
    attrs =
      %{"id" => attrs["id"], "to" => attrs["from"], "class" => tag}
      |> maybe_put_transport_ack_attr("participant", attrs["participant"])
      |> maybe_put_transport_ack_attr("recipient", attrs["recipient"])
      |> maybe_put_transport_ack_attr("type", transport_ack_type(node))
      |> maybe_put_transport_ack_from(node, state)

    %BinaryNode{tag: "ack", attrs: attrs, content: nil}
  end

  defp build_transport_ack(%State{}, %BinaryNode{}), do: nil

  defp maybe_put_transport_ack_attr(attrs, _key, nil), do: attrs

  defp maybe_put_transport_ack_attr(attrs, key, value) when is_binary(value),
    do: Map.put(attrs, key, value)

  defp maybe_put_transport_ack_attr(attrs, _key, _value), do: attrs

  defp transport_ack_type(%BinaryNode{tag: "message"} = node) do
    if BinaryNodeUtil.child(node, "unavailable"), do: node.attrs["type"], else: nil
  end

  defp transport_ack_type(%BinaryNode{attrs: attrs}), do: attrs["type"]

  defp maybe_put_transport_ack_from(attrs, %BinaryNode{tag: "message"} = node, %State{} = state) do
    if BinaryNodeUtil.child(node, "unavailable") do
      case current_me_id(state) do
        jid when is_binary(jid) -> Map.put(attrs, "from", jid)
        _ -> attrs
      end
    else
      attrs
    end
  end

  defp maybe_put_transport_ack_from(attrs, _node, _state), do: attrs

  defp current_me_id(%State{} = state) do
    state.store_ref
    |> Store.get(:auth_state, %{})
    |> AuthState.get(:me, %{})
    |> case do
      %{id: jid} when is_binary(jid) -> jid
      %{"id" => jid} when is_binary(jid) -> jid
      _ -> nil
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

  defp build_signal_repository(
         %Repository{} = repository,
         _adapter,
         _adapter_state,
         _signal_store,
         _store_ref,
         _supervisor,
         _socket_module,
         _query_timeout_ms
       ),
       do: repository

  defp build_signal_repository(
         nil,
         adapter,
         adapter_state,
         %SignalStore{} = signal_store,
         _store_ref,
         supervisor,
         socket_module,
         query_timeout_ms
       )
       when is_atom(adapter) and not is_nil(adapter) do
    Repository.new(
      adapter: adapter,
      adapter_state: adapter_state,
      store: signal_store,
      pn_to_lid_lookup: pn_to_lid_lookup_fun(supervisor, socket_module, query_timeout_ms)
    )
  end

  defp build_signal_repository(
         nil,
         nil,
         _adapter_state,
         %SignalStore{} = signal_store,
         %Store.Ref{} = store_ref,
         supervisor,
         socket_module,
         query_timeout_ms
       ) do
    case build_default_signal_adapter_state(store_ref, signal_store) do
      {:ok, adapter_state} ->
        Repository.new(
          adapter: DefaultSignalAdapter,
          adapter_state: adapter_state,
          store: signal_store,
          pn_to_lid_lookup: pn_to_lid_lookup_fun(supervisor, socket_module, query_timeout_ms)
        )

      :error ->
        nil
    end
  end

  defp build_signal_repository(
         repository,
         _adapter,
         _adapter_state,
         _signal_store,
         _store_ref,
         _supervisor,
         _socket_module,
         _query_timeout_ms
       ),
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
      enable_recent_message_cache: state.config.enable_recent_message_cache,
      me_id: AuthState.me_id(creds),
      me_lid: AuthState.me_lid(creds),
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
      enable_recent_message_cache: state.config.enable_recent_message_cache,
      signal_repository: repository,
      signal_store: state.signal_store,
      me_id: AuthState.me_id(creds),
      me_lid: AuthState.me_lid(creds)
    }
    |> maybe_put(:device_identity, encoded_device_identity(creds))
    |> maybe_put(:store_ref, state.store_ref)
    |> maybe_put_callback(:query_fun, sender_query_fun(state))
    |> maybe_put_callback(:send_node_fun, receipt_sender_fun(state))
    |> maybe_put_callback(:cached_group_metadata, state.config.cached_group_metadata)
    |> maybe_put_callback(:group_metadata_fun, group_metadata_fun(state))
  end

  defp group_metadata_fun(%State{} = state) do
    case fetch_socket_pid(state) do
      {:ok, socket_pid} ->
        fn jid ->
          Group.get_metadata(socket_pid, jid)
        end

      :error ->
        nil
    end
  end

  defp maybe_handle_retry_receipt(
         %State{signal_repository: %Repository{} = repository} = state,
         %BinaryNode{attrs: %{"type" => "retry"}} = node
       ) do
    case Retry.handle_retry_receipt(state.store_ref, node,
           max_retry_count: state.config.max_msg_retry_count
         ) do
      {:ok, entries} ->
        Enum.reduce(entries, state, fn %{id: id, message: message}, acc ->
          resend_retry_message(acc, repository_for_retry(acc, repository), node, id, message)
        end)

      {:error, _reason} ->
        state
    end
  end

  defp maybe_handle_retry_receipt(%State{} = state, %BinaryNode{}), do: state

  defp resend_retry_message(
         %State{} = state,
         %Repository{} = repository,
         %BinaryNode{attrs: attrs} = node,
         message_id,
         %BaileysEx.Protocol.Proto.Message{} = message
       ) do
    with {:ok, jid} <- normalize_retry_jid(attrs["from"] || attrs["recipient"] || attrs["to"]),
         participant <- retry_participant(node),
         {:ok, _result, %{signal_repository: %Repository{} = updated_repository}} <-
           Sender.send_proto(
             sender_context(%{state | signal_repository: repository}, repository),
             jid,
             message,
             message_id_fun: fn -> message_id end,
             participant: participant
           ) do
      %{state | signal_repository: updated_repository}
    else
      _ -> state
    end
  end

  defp repository_for_retry(%State{signal_repository: %Repository{} = repository}, _fallback),
    do: repository

  defp repository_for_retry(%State{}, %Repository{} = repository), do: repository

  defp retry_participant(%BinaryNode{attrs: %{"participant" => participant}} = node)
       when is_binary(participant) do
    count =
      case BinaryNodeUtil.child(node, "retry") do
        %BinaryNode{attrs: %{"count" => retry_count}} -> parse_retry_count(retry_count)
        _ -> 1
      end

    %{jid: participant, count: count}
  end

  defp retry_participant(_node), do: nil

  defp parse_retry_count(count) when is_binary(count) do
    case Integer.parse(count) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> 1
    end
  end

  defp normalize_retry_jid(jid) when is_binary(jid) do
    case BaileysEx.Protocol.JID.parse(jid) do
      %BaileysEx.JID{} = parsed -> {:ok, parsed}
      _ -> {:error, {:invalid_jid, jid}}
    end
  end

  defp notification_context(%State{} = state) do
    resync_app_state_fun = state.resync_app_state_fun || built_in_resync_app_state_fun(state)
    me = current_me(state)
    me_id = me[:id] || me["id"]

    %{event_emitter: state.event_emitter}
    |> maybe_put_callback(:me_id, me_id)
    |> maybe_put_callback(:store_privacy_token_fun, privacy_token_store_fun(state.signal_store))
    |> maybe_put_callback(:handle_encrypt_notification_fun, state.handle_encrypt_notification_fun)
    |> maybe_put_callback(:device_notification_fun, state.device_notification_fun)
    |> maybe_put_callback(:resync_app_state_fun, resync_app_state_fun)
  end

  defp send_notification_ack(%State{} = state, %BinaryNode{attrs: attrs} = _node) do
    ack = %BinaryNode{
      tag: "ack",
      attrs:
        %{"id" => attrs["id"], "class" => "notification"}
        |> maybe_put("type", attrs["type"])
        |> maybe_put("to", attrs["from"] || "s.whatsapp.net")
        |> maybe_put("participant", attrs["participant"]),
      content: nil
    }

    case fetch_socket_pid(state) do
      {:ok, socket_pid} ->
        _ = state.socket_module.send_node(socket_pid, ack)
        state

      :error ->
        state
    end
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
        me_id: AuthState.me_id(creds),
        me_lid: AuthState.me_lid(creds),
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

  defp pn_to_lid_lookup_fun(supervisor, socket_module, query_timeout_ms)
       when is_pid(supervisor) and is_atom(socket_module) and is_integer(query_timeout_ms) do
    fn pns ->
      case socket_pid(supervisor, socket_module) do
        pid when is_pid(pid) ->
          fetch_lid_mappings_via_usync(socket_module, pid, query_timeout_ms, pns)

        nil ->
          nil
      end
    end
  end

  defp pn_to_lid_lookup_fun(_supervisor, _socket_module, _query_timeout_ms), do: nil

  defp fetch_lid_mappings_via_usync(socket_module, socket_pid, query_timeout_ms, pns)
       when is_list(pns) do
    query =
      pns
      |> Enum.uniq()
      |> Enum.reduce(USync.new(context: :background), fn pn, acc ->
        USync.with_user(acc, %{id: pn})
      end)
      |> USync.with_protocol(:lid)

    with {:ok, node} <- USync.to_node(query, "background-lid-query"),
         {:ok, response} <- socket_module.query(socket_pid, node, query_timeout_ms),
         {:ok, %{list: results}} <- USync.parse_result(query, response) do
      Enum.flat_map(results, fn
        %{id: pn, lid: lid} when is_binary(pn) and is_binary(lid) -> [%{pn: pn, lid: lid}]
        _ -> []
      end)
    else
      {:error, reason} ->
        Logger.debug("[LIDDiag] background pn->lid usync failed: #{inspect(reason)}")
        nil
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
        collections = SyncdCodec.patch_names()

        {:ok, _pid} =
          Task.Supervisor.start_child(state.task_supervisor, fn ->
            Logger.debug("[AppStateDiag] sync Task started pid=#{inspect(self())}")

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
                  Logger.debug(
                    "[AppStateDiag] sync Task rescued: #{Exception.message(exception)}"
                  )

                  {:error, exception}
              catch
                kind, reason ->
                  Logger.debug("[AppStateDiag] sync Task caught #{kind}: #{inspect(reason)}")
                  {:error, {kind, reason}}
              end

            Logger.debug("[AppStateDiag] sync Task sending completion result=#{inspect(result)}")

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
      validate_snapshot_macs: state.config.validate_snapshot_macs,
      validate_patch_macs: state.config.validate_patch_macs,
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
        {:ok, collection} -> {:cont, {:ok, [collection | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, collections} -> {:ok, Enum.reverse(collections)}
      {:error, _} = error -> error
    end
  end

  defp normalize_patch_name(name) when is_atom(name) do
    if name in SyncdCodec.patch_names() do
      {:ok, name}
    else
      {:error, {:unknown_patch_name, name}}
    end
  end

  defp normalize_patch_name(name) when is_binary(name) do
    case Enum.find(SyncdCodec.patch_names(), &(Atom.to_string(&1) == name)) do
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
