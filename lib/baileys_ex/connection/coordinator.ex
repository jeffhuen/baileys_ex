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
  alias BaileysEx.Feature.Account
  alias BaileysEx.Feature.AppState
  alias BaileysEx.Feature.Call
  alias BaileysEx.Feature.Community
  alias BaileysEx.Feature.Group
  alias BaileysEx.Feature.Presence
  alias BaileysEx.Feature.TcToken
  alias BaileysEx.Message.Decode
  alias BaileysEx.Message.IdentityChangeHandler
  alias BaileysEx.Message.Normalizer
  alias BaileysEx.Message.NotificationHandler
  alias BaileysEx.Message.PeerData
  alias BaileysEx.Message.Receipt
  alias BaileysEx.Message.Receiver
  alias BaileysEx.Message.Retry
  alias BaileysEx.Message.Sender
  alias BaileysEx.Protocol.BinaryNode, as: BinaryNodeUtil
  alias BaileysEx.Protocol.JID, as: JIDUtil
  alias BaileysEx.Protocol.Proto.ADVSignedDeviceIdentity
  alias BaileysEx.Protocol.USync
  alias BaileysEx.Signal.Adapter.Signal, as: DefaultSignalAdapter
  alias BaileysEx.Signal.LIDMappingStore
  alias BaileysEx.Signal.PreKey
  alias BaileysEx.Signal.Repository
  alias BaileysEx.Signal.Session
  alias BaileysEx.Signal.Store, as: SignalStore
  alias BaileysEx.Syncd.Codec, as: SyncdCodec
  alias BaileysEx.Telemetry

  @s_whatsapp_net "s.whatsapp.net"
  @default_max_send_queue 256
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
      :send_task,
      :send_from,
      :send_operation,
      :max_send_queue,
      send_queue: :queue.new(),
      pending_events: :queue.new(),
      init_query_handlers: %{},
      event_buffer_seed: %{},
      identity_change_cache: %{},
      sync: %{
        generation: 0,
        state: :connecting,
        timeout_timer: nil,
        complete_timer: nil,
        task: nil,
        bg_tasks: %{},
        blocked: %{},
        pending_initial_counter?: false,
        initial_incomplete: MapSet.new(),
        initial_failed?: false
      },
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

  @doc "Request the phone to resend a placeholder message through the peer-data pipeline."
  @spec request_placeholder_resend(GenServer.server(), map(), map() | nil, keyword()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def request_placeholder_resend(server, message_key, msg_data \\ nil, opts \\ [])
      when is_map(message_key) and (is_map(msg_data) or is_nil(msg_data)) and is_list(opts) do
    GenServer.call(server, {:request_placeholder_resend, message_key, msg_data, opts}, :infinity)
  end

  @doc "Send an ACK/NACK through the coordinator-owned socket."
  @spec send_message_ack(GenServer.server(), BinaryNode.t(), non_neg_integer() | nil) ::
          :ok | {:error, term()}
  def send_message_ack(server, %BinaryNode{} = node, error_code \\ nil)
      when is_nil(error_code) or (is_integer(error_code) and error_code >= 0) do
    GenServer.call(server, {:send_message_ack, node, error_code}, :infinity)
  end

  @doc "Send a failed-decryption retry request through the coordinator-owned retry lane."
  @spec send_retry_request(GenServer.server(), BinaryNode.t(), keyword()) ::
          :ok | {:error, term()}
  def send_retry_request(server, %BinaryNode{} = node, opts \\ []) when is_list(opts) do
    GenServer.call(server, {:send_retry_request, node, opts}, :infinity)
  end

  @doc false
  @spec message_retry_manager_available?(GenServer.server()) :: :ok | {:error, term()}
  def message_retry_manager_available?(server) do
    GenServer.call(server, :message_retry_manager_available?)
  end

  @doc false
  @spec message_retry_operation(GenServer.server(), tuple() | :clear) ::
          {:ok, term()} | {:error, term()}
  def message_retry_operation(server, operation)
      when is_tuple(operation) or operation == :clear do
    GenServer.call(server, {:message_retry_operation, operation}, :infinity)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %State{
      config: Keyword.fetch!(opts, :config),
      event_emitter: opts |> Keyword.fetch!(:event_emitter) |> resolve_runtime_ref!(),
      socket_module: Keyword.get(opts, :socket_module, Socket),
      store: opts |> Keyword.fetch!(:store) |> resolve_runtime_ref!(),
      signal_store: opts |> Keyword.fetch!(:signal_store) |> resolve_runtime_ref!(),
      signal_repository: Keyword.get(opts, :signal_repository),
      supervisor: Keyword.fetch!(opts, :supervisor),
      task_supervisor: opts |> Keyword.fetch!(:task_supervisor) |> resolve_runtime_ref!(),
      history_sync_download_fun: Keyword.get(opts, :history_sync_download_fun),
      history_sync_inflate_fun: Keyword.get(opts, :history_sync_inflate_fun),
      get_message_fun: Keyword.get(opts, :get_message_fun),
      handle_encrypt_notification_fun: Keyword.get(opts, :handle_encrypt_notification_fun),
      device_notification_fun: Keyword.get(opts, :device_notification_fun),
      resync_app_state_fun: Keyword.get(opts, :resync_app_state_fun),
      max_send_queue: Keyword.get(opts, :max_send_queue, @default_max_send_queue)
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
        from,
        %State{signal_repository: %Repository{}} = state
      ) do
    operation = {:send_message, jid, content, opts}

    case enqueue_send(state, from, operation) do
      {:ok, state} -> {:noreply, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:send_status, content, opts},
        from,
        %State{signal_repository: %Repository{}} = state
      ) do
    case enqueue_send(state, from, {:send_status, content, opts}) do
      {:ok, state} -> {:noreply, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:request_placeholder_resend, message_key, msg_data, opts},
        from,
        %State{signal_repository: %Repository{}} = state
      ) do
    operation = {:request_placeholder_resend, message_key, msg_data, opts}

    case enqueue_send(state, from, operation) do
      {:ok, state} -> {:noreply, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:send_message_ack, node, error_code}, from, %State{} = state) do
    case enqueue_send(state, from, {:send_message_ack, node, error_code}) do
      {:ok, state} -> {:noreply, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:send_retry_request, node, opts},
        from,
        %State{signal_repository: %Repository{}} = state
      ) do
    case enqueue_send(state, from, {:send_retry_request, node, opts}) do
      {:ok, state} -> {:noreply, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:message_retry_manager_available?, _from, %State{} = state) do
    reply =
      if state.config.enable_recent_message_cache,
        do: :ok,
        else: {:error, :message_retry_manager_disabled}

    {:reply, reply, state}
  end

  def handle_call(
        {:message_retry_operation, operation},
        from,
        %State{config: %{enable_recent_message_cache: true}} = state
      ) do
    case enqueue_send(state, from, {:message_retry_operation, operation}) do
      {:ok, state} -> {:noreply, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:message_retry_operation, _operation}, _from, %State{} = state) do
    {:reply, {:error, :message_retry_manager_disabled}, state}
  end

  def handle_call({:events, previous_creds, events}, _from, %State{} = state)
      when is_map(previous_creds) and is_map(events) do
    {:reply, :ok, process_or_defer_events(state, previous_creds, events, false)}
  end

  def handle_call({:send_message, _jid, _content, _opts}, _from, %State{} = state) do
    {:reply, {:error, :signal_repository_not_ready}, state}
  end

  def handle_call({:send_status, _content, _opts}, _from, %State{} = state) do
    {:reply, {:error, :signal_repository_not_ready}, state}
  end

  def handle_call({:send_retry_request, _node, _opts}, _from, %State{} = state) do
    {:reply, {:error, :signal_repository_not_ready}, state}
  end

  def handle_call(
        {:request_placeholder_resend, _message_key, _msg_data, _opts},
        _from,
        %State{} = state
      ) do
    {:reply, {:error, :signal_repository_not_ready}, state}
  end

  def handle_call(request, _from, %State{} = state) do
    Logger.warning("unsupported coordinator request: #{inspect(request)}")
    {:reply, {:error, :unsupported_request}, state}
  end

  @impl true
  def handle_info({:events, previous_creds, events}, %State{} = state)
      when is_map(previous_creds) and is_map(events) do
    {:noreply, process_or_defer_events(state, previous_creds, events, false)}
  end

  def handle_info({:events, events}, %State{} = state) when is_map(events) do
    previous_creds = Store.get(state.store_ref, :creds, %{})
    {:noreply, process_or_defer_events(state, previous_creds, events, true)}
  end

  def handle_info(
        {task_ref, result},
        %State{send_task: %Task{ref: task_ref}} = state
      ) do
    Process.demonitor(task_ref, [:flush])
    {:noreply, complete_send(state, result)}
  end

  def handle_info(
        {:DOWN, task_ref, :process, _pid, reason},
        %State{send_task: %Task{ref: task_ref}, send_from: from} = state
      ) do
    maybe_reply(from, {:error, {:send_task_failed, reason}})
    {:noreply, finish_send(state)}
  end

  def handle_info(:reconnect_socket, %State{} = state) do
    {:noreply, connect_socket(%{state | reconnect_timer: nil})}
  end

  def handle_info(
        {:initial_sync_timeout, gen},
        %State{sync: %{generation: gen, state: :awaiting_initial_sync}} = state
      ) do
    Logger.debug("[SyncDiag] initial sync timeout fired, forcing :online")
    increment_account_sync_counter(state)

    {:noreply,
     state
     |> put_sync(:timeout_timer, nil)
     |> complete_initial_sync_online(:timeout)}
  end

  def handle_info({:initial_sync_timeout, _gen}, %State{} = state), do: {:noreply, state}

  def handle_info(
        {:complete_initial_sync, gen},
        %State{sync: %{generation: gen, task: %{ref: _}}} = state
      ) do
    {:noreply, put_sync(state, :complete_timer, nil)}
  end

  def handle_info(
        {:complete_initial_sync, gen},
        %State{sync: %{generation: gen, state: :syncing}} = state
      ) do
    Logger.debug("[SyncDiag] completing initial sync, transitioning to :online")

    {:noreply,
     state
     |> put_sync(:complete_timer, nil)
     |> complete_initial_sync_online(:initial_sync_complete)}
  end

  def handle_info({:complete_initial_sync, _gen}, %State{} = state), do: {:noreply, state}

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
        {ref, result},
        %State{
          sync: %{
            generation: gen,
            task: %{ref: ref, generation: gen} = task_info
          }
        } = state
      ) do
    Process.demonitor(ref, [:flush])
    {:noreply, complete_app_state_sync(state, result, task_info)}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %State{
          sync: %{
            generation: gen,
            task: %{ref: ref, generation: gen} = task_info
          }
        } = state
      ) do
    {:noreply, complete_app_state_sync(state, {:error, {:task_exit, reason}}, task_info)}
  end

  def handle_info(
        {ref, result},
        %State{sync: %{generation: gen, bg_tasks: bg_tasks}} = state
      )
      when is_reference(ref) and is_map_key(bg_tasks, ref) do
    Process.demonitor(ref, [:flush])
    {task_info, remaining} = Map.pop(bg_tasks, ref)
    state = put_sync(state, :bg_tasks, remaining)

    if task_info.generation == gen do
      {:noreply, complete_bg_app_state_sync(state, task_info, result)}
    else
      {:noreply, state}
    end
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %State{sync: %{generation: gen, bg_tasks: bg_tasks}} = state
      )
      when is_reference(ref) and is_map_key(bg_tasks, ref) do
    {task_info, remaining} = Map.pop(bg_tasks, ref)
    state = put_sync(state, :bg_tasks, remaining)

    if task_info.generation == gen do
      {:noreply, complete_bg_app_state_sync(state, task_info, {:error, {:task_exit, reason}})}
    else
      {:noreply, state}
    end
  end

  def handle_info(
        {:start_server_app_state_resync, gen, collections, name},
        %State{sync: %{generation: gen}} = state
      ) do
    {:noreply, launch_server_app_state_resync(state, collections, name)}
  end

  def handle_info({:start_server_app_state_resync, _gen, _collections, _name}, %State{} = state),
    do: {:noreply, state}

  def handle_info(
        {:app_state_collection_blocked, gen, name},
        %State{sync: %{generation: gen} = sync} = state
      )
      when is_atom(name) do
    blocked = Map.put(sync.blocked, name, true)
    {:noreply, put_sync(state, :blocked, blocked)}
  end

  def handle_info({:app_state_collection_blocked, _gen, _name}, %State{} = state),
    do: {:noreply, state}

  def handle_info({:EXIT, _pid, _reason}, %State{} = state), do: {:noreply, state}

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, %State{} = state), do: {:noreply, state}

  def handle_info({task_ref, _result}, %State{} = state) when is_reference(task_ref),
    do: {:noreply, state}

  @impl true
  def terminate(_reason, %State{unsubscribe: unsubscribe}) when is_function(unsubscribe, 0) do
    unsubscribe.()
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp complete_app_state_sync(%State{} = state, result, task_info) do
    blocked = state.sync.blocked

    state =
      state
      |> put_sync(:task, nil)
      |> record_initial_sync_outcome(task_info.collections, blocked, result)

    if task_info.resync_blocked? and map_size(blocked) > 0 do
      launch_initial_app_state_sync(state, Map.keys(blocked), reset_initial_tracking?: false)
    else
      state = finalize_initial_app_state_sync(state, result)
      schedule_complete_initial_sync(state)
    end
  end

  defp complete_bg_app_state_sync(%State{} = state, %{kind: :server, name: name}, result) do
    log_server_app_state_sync_result(result, name)
    state
  end

  defp complete_bg_app_state_sync(
         %State{} = state,
         %{kind: :blocked, collections: collections} = task_info,
         result
       ) do
    log_blocked_app_state_sync_result(result)
    blocked = state.sync.blocked

    state =
      if state.sync.pending_initial_counter? do
        record_initial_sync_outcome(state, collections, blocked, result)
      else
        state
      end

    if task_info.resync_blocked? and map_size(blocked) > 0 do
      launch_blocked_app_state_sync(put_sync(state, :blocked, %{}), blocked)
    else
      maybe_finish_pending_initial_counter(state, result)
    end
  end

  defp record_initial_sync_outcome(%State{sync: sync} = state, collections, blocked, result) do
    blocked_set = MapSet.new(Map.keys(blocked))

    {next_incomplete, next_failed?} =
      case result do
        :ok ->
          completed = MapSet.difference(MapSet.new(collections), blocked_set)
          {MapSet.difference(sync.initial_incomplete, completed), sync.initial_failed?}

        {:error, {:missing_collections, missing}} ->
          Logger.warning("initial app state sync missing collections: #{inspect(missing)}")
          missing_set = MapSet.new(missing)

          completed =
            collections
            |> MapSet.new()
            |> MapSet.difference(missing_set)
            |> MapSet.difference(blocked_set)

          incomplete =
            sync.initial_incomplete
            |> MapSet.difference(completed)
            |> MapSet.union(missing_set)

          {incomplete, sync.initial_failed?}

        {:error, reason} ->
          Logger.warning("initial app state sync failed: #{inspect(reason)}")
          {sync.initial_incomplete, true}
      end

    %{
      state
      | sync: %{
          sync
          | initial_incomplete: next_incomplete,
            initial_failed?: next_failed?
        }
    }
  end

  defp finalize_initial_app_state_sync(%State{sync: sync} = state, result) do
    cond do
      initial_sync_fully_complete?(sync, result) ->
        Logger.debug(
          "[AppStateDiag] initial app state sync complete " <>
            "store_name=#{inspect(AuthState.me_name(%{me: current_me(state)}))}"
        )

        increment_account_sync_counter(state)
        put_sync(state, :pending_initial_counter?, false)

      initial_sync_waiting_on_blocked?(sync) ->
        put_sync(state, :pending_initial_counter?, true)

      true ->
        put_sync(state, :pending_initial_counter?, false)
    end
  end

  defp maybe_finish_pending_initial_counter(
         %State{sync: %{pending_initial_counter?: true} = sync} = state,
         result
       ) do
    blocked_in_flight? =
      Enum.any?(sync.bg_tasks, fn {_ref, info} -> info.kind == :blocked end)

    cond do
      not blocked_in_flight? and initial_sync_fully_complete?(sync, result) ->
        increment_account_sync_counter(state)
        put_sync(state, :pending_initial_counter?, false)

      MapSet.size(sync.initial_incomplete) > 0 or sync.initial_failed? ->
        put_sync(state, :pending_initial_counter?, false)

      true ->
        state
    end
  end

  defp maybe_finish_pending_initial_counter(%State{} = state, _result), do: state

  defp initial_sync_fully_complete?(sync, :ok) do
    map_size(sync.blocked) == 0 and
      MapSet.size(sync.initial_incomplete) == 0 and
      not sync.initial_failed?
  end

  defp initial_sync_fully_complete?(_sync, _result), do: false

  defp initial_sync_waiting_on_blocked?(sync) do
    map_size(sync.blocked) > 0 and
      MapSet.size(sync.initial_incomplete) == 0 and
      not sync.initial_failed?
  end

  defp enqueue_send(%State{} = state, from, operation) do
    if send_queue_size(state) >= state.max_send_queue do
      {:error, :send_queue_full}
    else
      state =
        state
        |> Map.update!(:send_queue, &:queue.in({from, operation}, &1))
        |> maybe_start_send()

      {:ok, state}
    end
  end

  defp send_queue_size(%State{} = state) do
    :queue.len(state.send_queue) + if(state.send_task, do: 1, else: 0)
  end

  defp maybe_start_send(%State{send_task: %Task{}} = state), do: state

  defp maybe_start_send(%State{} = state) do
    case :queue.out(state.send_queue) do
      {{:value, {from, operation}}, remaining} ->
        repository = state.signal_repository

        task =
          Task.Supervisor.async(state.task_supervisor, fn ->
            run_send(state, repository, operation)
          end)

        %{
          state
          | send_queue: remaining,
            send_task: task,
            send_from: from,
            send_operation: operation
        }

      {:empty, _queue} ->
        state
    end
  end

  defp run_send(state, repository, {:send_message, jid, content, opts}) do
    Sender.send(sender_context(state, repository), jid, content, opts)
  end

  defp run_send(state, repository, {:send_status, content, opts}) do
    Sender.send_status(sender_context(state, repository), content, opts)
  end

  defp run_send(state, _repository, {:send_message_ack, node, error_code}) do
    result =
      case current_me_id(state) do
        me_id when is_binary(me_id) ->
          case receipt_sender_fun(state) do
            send_node_fun when is_function(send_node_fun, 1) ->
              node
              |> Receipt.build_ack_stanza(error_code, me_id)
              |> send_node_fun.()

            nil ->
              {:error, :socket_not_available}
          end

        nil ->
          {:error, :not_authenticated}
      end

    {:public_result, result}
  end

  defp run_send(state, %Repository{} = repository, {:send_retry_request, node, opts}) do
    {:retry_request_result, run_public_retry_request(state, repository, node, opts)}
  end

  defp run_send(state, _repository, {:message_retry_operation, operation}) do
    {:message_retry_result, run_message_retry_operation(state, operation)}
  end

  defp run_send(state, repository, {:repository_events, events}) do
    updated_state = handle_socket_node(%{state | signal_repository: repository}, events)

    {:repository_events,
     %{
       signal_repository: updated_state.signal_repository,
       identity_change_cache: updated_state.identity_change_cache
     }}
  end

  defp run_send(
         state,
         repository,
         {:request_placeholder_resend, message_key, msg_data, opts}
       ) do
    context = sender_context(state, repository)

    Retry.request_placeholder_resend(
      state.store_ref,
      message_key,
      msg_data,
      opts
      |> Keyword.put(:context, context)
      |> Keyword.put(:task_supervisor, state.task_supervisor)
      |> Keyword.put(:timer_owner, state.supervisor)
      |> Keyword.put(:send_request_fun, placeholder_request_fun(context))
    )
  end

  defp complete_send(%State{} = state, {:repository_events, updates}) do
    state
    |> Map.merge(updates)
    |> finish_send()
  end

  defp complete_send(%State{send_from: from} = state, {:public_result, result}) do
    maybe_reply(from, result)
    finish_send(state)
  end

  defp complete_send(
         %State{send_from: from} = state,
         {:retry_request_result, {result, %Repository{} = repository}}
       ) do
    maybe_reply(from, result)
    finish_send(%{state | signal_repository: repository})
  end

  defp complete_send(%State{send_from: from} = state, {:message_retry_result, result}) do
    maybe_reply(from, result)
    finish_send(state)
  end

  defp complete_send(%State{send_from: from} = state, result) do
    case result do
      {:ok, sent, %{signal_repository: %Repository{} = repository}} ->
        maybe_reply(from, {:ok, sent})
        finish_send(%{state | signal_repository: repository})

      {:error, _reason} = error ->
        maybe_reply(from, error)
        finish_send(state)

      other ->
        maybe_reply(from, {:error, {:invalid_send_result, other}})
        finish_send(state)
    end
  end

  defp maybe_reply(nil, _reply), do: :ok
  defp maybe_reply(from, reply), do: GenServer.reply(from, reply)

  defp finish_send(%State{} = state) do
    state
    |> Map.put(:send_task, nil)
    |> Map.put(:send_from, nil)
    |> Map.put(:send_operation, nil)
    |> drain_pending_events()
    |> maybe_start_send()
  end

  defp process_or_defer_events(%State{} = state, previous_creds, events, persist_creds?) do
    {state, repository_events} =
      process_immediate_events(state, previous_creds, events, persist_creds?)

    if is_nil(repository_events) do
      state
    else
      enqueue_repository_events(state, repository_events)
    end
  end

  defp process_immediate_events(%State{} = state, previous_creds, events, persist_creds?) do
    {immediate_events, repository_events} = split_repository_events(events, state)

    state =
      if map_size(immediate_events) == 0 do
        state
      else
        process_events(state, previous_creds, immediate_events, persist_creds?)
      end

    {state, repository_events}
  end

  defp split_repository_events(
         %{socket_node: %{node: %BinaryNode{} = node} = socket_event} = events,
         %State{signal_repository: %Repository{}}
       ) do
    if repository_mutating_node?(node) do
      {Map.delete(events, :socket_node), %{socket_node: socket_event}}
    else
      {events, nil}
    end
  end

  defp split_repository_events(events, %State{}), do: {events, nil}

  defp repository_mutating_node?(%BinaryNode{tag: "message"}), do: true

  defp repository_mutating_node?(%BinaryNode{tag: "receipt", attrs: %{"type" => "retry"}}),
    do: true

  defp repository_mutating_node?(%BinaryNode{
         tag: "notification",
         attrs: %{"type" => type}
       })
       when type in ["encrypt", "devices"],
       do: true

  defp repository_mutating_node?(%BinaryNode{}), do: false

  defp enqueue_repository_events(%State{} = state, events) do
    case enqueue_send(state, nil, {:repository_events, events}) do
      {:ok, state} ->
        state

      {:error, :send_queue_full} ->
        Logger.warning("dropping repository-mutating socket event because the work queue is full")
        state
    end
  end

  defp drain_pending_events(%State{} = state) do
    case :queue.out(state.pending_events) do
      {{:value, {:call, from, previous_creds, events}}, remaining} ->
        state =
          state
          |> Map.put(:pending_events, remaining)
          |> process_events(previous_creds, events, false)

        GenServer.reply(from, :ok)
        drain_pending_events(state)

      {{:value, {:events, previous_creds, events}}, remaining} ->
        state
        |> Map.put(:pending_events, remaining)
        |> process_events(previous_creds, events, false)
        |> drain_pending_events()

      {{:value, {:events, events}}, remaining} ->
        previous_creds = Store.get(state.store_ref, :creds, %{})

        state
        |> Map.put(:pending_events, remaining)
        |> process_events(previous_creds, events, true)
        |> drain_pending_events()

      {:empty, _queue} ->
        state
    end
  end

  defp process_events(%State{} = state, previous_creds, events, persist_creds?) do
    state = if persist_creds?, do: persist_creds_update(state, events), else: state

    state
    |> handle_socket_node(events)
    |> persist_lid_mapping_update(events)
    |> maybe_seed_event_buffer(events)
    |> maybe_send_push_name_presence_update(previous_creds, events)
    |> sync_creds_update_to_socket(events)
    |> handle_connection_update(events)
    |> handle_sync_event(events)
    |> maybe_start_initial_app_state_sync(events)
    |> maybe_resync_blocked_app_state_collections(events)
    |> handle_dirty_update(events)
  end

  defp start_owned_task(%State{task_supervisor: task_supervisor}, fun) do
    start_owned_task(task_supervisor, fun)
  end

  defp start_owned_task(task_supervisor, fun)
       when (is_pid(task_supervisor) or is_atom(task_supervisor) or is_tuple(task_supervisor)) and
              is_function(fun, 0) do
    task = Task.Supervisor.async(task_supervisor, fun)
    Process.demonitor(task.ref, [:flush])
    {:ok, task.pid}
  catch
    :exit, reason -> {:error, reason}
  end

  defp resolve_runtime_ref!(resolver) when is_function(resolver, 0) do
    case resolver.() do
      nil -> raise "connection runtime dependency is not available"
      ref -> ref
    end
  end

  defp resolve_runtime_ref!(ref), do: ref

  defp coordinator_event_tap(coordinator_pid, store_ref) do
    fn events ->
      previous_creds = Store.get(store_ref, :creds, %{})
      :ok = persist_tapped_creds_update(store_ref, events)
      send(coordinator_pid, {:events, previous_creds, events})
      :ok
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
        Logger.debug(fn -> "[Coordinator] message #{msg_id} processed OK" end)
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
    :ok = Receiver.handle_bad_ack(node, bad_ack_context(state))
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
         %{connection_update: %{connection: :close} = update}
       ) do
    state = reset_sync_on_close(state)

    case Map.fetch(update, :last_disconnect) do
      {:ok, last_disconnect} ->
        reason = disconnect_reason(last_disconnect)

        if should_schedule_reconnect?(state.config, reason, state.reconnect_attempts + 1) do
          schedule_reconnect(state, reason)
        else
          cancel_reconnect(state)
        end

      :error ->
        state
    end
  end

  defp handle_connection_update(
         %State{sync: %{state: :connecting}} = state,
         %{connection_update: %{received_pending_notifications: true}}
       ) do
    :ok = EventEmitter.buffer(state.event_emitter)
    will_sync_history = should_sync_history_message?(state.config, %{sync_type: :RECENT})
    account_sync_counter = current_account_sync_counter(state)

    Logger.debug(
      "[SyncDiag] received_pending_notifications=true sync_state=:connecting " <>
        "will_sync_history=#{inspect(will_sync_history)} " <>
        "account_sync_counter=#{inspect(account_sync_counter)}"
    )

    cond do
      not will_sync_history ->
        state
        |> cancel_initial_sync_timer()
        |> complete_initial_sync_online(:history_sync_disabled)

      account_sync_counter > 0 ->
        state
        |> cancel_initial_sync_timer()
        |> complete_initial_sync_online(:reconnection_existing_sync)

      true ->
        state
        |> schedule_initial_sync_timeout()
        |> put_sync(:state, :awaiting_initial_sync)
    end
  end

  defp handle_connection_update(%State{} = state, _events), do: state

  defp complete_initial_sync_online(%State{} = state, reason) when is_atom(reason) do
    _ = EventEmitter.flush(state.event_emitter)

    :ok =
      EventEmitter.emit(state.event_emitter, :connection_update, %{
        sync_state: :online,
        initial_sync_complete: true,
        initial_sync_reason: reason
      })

    state
    |> cancel_complete_initial_sync_timer()
    |> put_sync(:state, :online)
  end

  defp handle_sync_event(
         %State{sync: %{state: :awaiting_initial_sync}} = state,
         %{messaging_history_set: _history}
       ) do
    Logger.debug("[SyncDiag] messaging_history_set received, transitioning to :syncing")

    state
    |> cancel_initial_sync_timer()
    |> schedule_complete_initial_sync()
    |> put_sync(:state, :syncing)
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

    Telemetry.execute(
      [:connection, :reconnect],
      %{count: 1},
      %{
        reason: reason,
        retry_delay_ms: state.config.retry_delay_ms,
        attempt: attempt,
        max_retries: state.config.max_retries,
        reconnect_policy: state.config.reconnect_policy
      }
    )

    timer = Process.send_after(self(), :reconnect_socket, state.config.retry_delay_ms)
    %{state | reconnect_timer: timer, reconnect_attempts: attempt}
  end

  defp schedule_reconnect(%State{} = state, _reason), do: state

  defp cancel_reconnect(%State{reconnect_timer: nil} = state), do: state

  defp cancel_reconnect(%State{reconnect_timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | reconnect_timer: nil}
  end

  defp put_sync(%State{sync: sync} = state, key, value) do
    %{state | sync: Map.put(sync, key, value)}
  end

  defp reset_sync_on_close(%State{sync: sync} = state) do
    state =
      state
      |> cancel_initial_sync_timer()
      |> cancel_complete_initial_sync_timer()

    stop_app_state_sync_task(state.task_supervisor, sync.task)
    stop_bg_app_state_sync_tasks(state.task_supervisor, sync.bg_tasks)

    %{
      state
      | sync: %{
          generation: sync.generation + 1,
          state: :connecting,
          timeout_timer: nil,
          complete_timer: nil,
          task: nil,
          bg_tasks: %{},
          blocked: %{},
          pending_initial_counter?: false,
          initial_incomplete: MapSet.new(),
          initial_failed?: false
        }
    }
  end

  defp stop_bg_app_state_sync_tasks(task_supervisor, bg_tasks) when is_map(bg_tasks) do
    Enum.each(bg_tasks, fn {_ref, task_info} ->
      stop_app_state_sync_task(task_supervisor, task_info)
    end)
  end

  defp stop_app_state_sync_task(_task_supervisor, nil), do: :ok

  defp stop_app_state_sync_task(task_supervisor, %{ref: ref, pid: pid}) do
    Process.demonitor(ref, [:flush])
    terminate_sync_task_child(task_supervisor, pid)
  end

  defp terminate_sync_task_child(task_supervisor, pid)
       when not is_nil(task_supervisor) and is_pid(pid) do
    _ = Task.Supervisor.terminate_child(task_supervisor, pid)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp terminate_sync_task_child(_task_supervisor, _pid), do: :ok

  defp schedule_initial_sync_timeout(%State{sync: %{generation: gen}} = state) do
    state = cancel_initial_sync_timer(state)

    timer =
      Process.send_after(
        self(),
        {:initial_sync_timeout, gen},
        state.config.initial_sync_timeout_ms
      )

    put_sync(state, :timeout_timer, timer)
  end

  defp schedule_complete_initial_sync(%State{sync: %{generation: gen}} = state) do
    state = cancel_complete_initial_sync_timer(state)
    timer = Process.send_after(self(), {:complete_initial_sync, gen}, 25)
    put_sync(state, :complete_timer, timer)
  end

  defp cancel_initial_sync_timer(%State{sync: %{timeout_timer: nil}} = state), do: state

  defp cancel_initial_sync_timer(%State{sync: %{timeout_timer: timer}} = state) do
    Process.cancel_timer(timer)
    put_sync(state, :timeout_timer, nil)
  end

  defp cancel_complete_initial_sync_timer(%State{sync: %{complete_timer: nil}} = state), do: state

  defp cancel_complete_initial_sync_timer(%State{sync: %{complete_timer: timer}} = state) do
    Process.cancel_timer(timer)
    put_sync(state, :complete_timer, nil)
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
        start_owned_task(state, fn ->
          register_own_lid_session(state, pn, lid)
        end)

        state
    end
  end

  defp register_own_lid_session(%State{} = state, pn, lid) do
    require Logger

    :ok = LIDMappingStore.store_lid_pn_mappings(state.signal_store, [%{lid: lid, pn: pn}])

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
      attrs: %{
        "id" => Integer.to_string(System.unique_integer([:positive, :monotonic])),
        "to" => @s_whatsapp_net,
        "type" => "set",
        "xmlns" => "urn:xmpp:whatsapp:dirty"
      },
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

    context =
      %{
        signal_repository: repository,
        event_emitter: state.event_emitter,
        enable_recent_message_cache: state.config.enable_recent_message_cache,
        me_id: AuthState.me_id(creds),
        me_lid: AuthState.me_lid(creds),
        store_ref: state.store_ref,
        signal_store: state.signal_store,
        task_supervisor: state.task_supervisor,
        timer_owner: state.supervisor,
        retry_request_delay_ms: state.config.retry_request_delay_ms,
        placeholder_resend_delay_ms: state.config.retry_delay_ms
      }
      |> maybe_put_callback(:send_receipt_fun, receipt_sender_fun(state))
      |> maybe_put_callback(:send_node_fun, receipt_sender_fun(state))
      |> maybe_put_callback(:send_retry_request_fun, retry_request_fun(state, repository))
      |> maybe_put_callback(:query_fun, sender_query_fun(state))
      |> maybe_put_callback(:history_sync_download_fun, state.history_sync_download_fun)
      |> maybe_put_callback(:inflate_fun, state.history_sync_inflate_fun)
      |> maybe_put_callback(:get_message_fun, state.get_message_fun)

    context
    |> maybe_put_callback(:send_placeholder_request_fun, placeholder_request_fun(context))
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
    |> maybe_put(:privacy_token_on_1to1?, privacy_token_on_1to1?(state))
    |> maybe_put_callback(:query_fun, sender_query_fun(state))
    |> maybe_put_callback(:send_node_fun, receipt_sender_fun(state))
    |> maybe_put_callback(:cached_group_metadata, state.config.cached_group_metadata)
    |> maybe_put_callback(:group_metadata_fun, group_metadata_fun(state))
    |> maybe_put_callback(:tc_token_issue_fun, tc_token_issue_fun(state))
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
    receipt = parse_retry_receipt_context(state, node)

    if retry_receipt_eligible?(receipt) do
      device_key = canonical_retry_device_key(repository, receipt.requesting_device_jid)
      eligible_ids = filter_retry_eligible_ids(state, receipt, device_key)
      entries = lookup_retry_entries(state, receipt, eligible_ids)
      resend_retry_entries(state, repository, node, receipt, device_key, entries)
    else
      state
    end
  end

  defp maybe_handle_retry_receipt(%State{} = state, %BinaryNode{}), do: state

  defp canonical_retry_device_key(%Repository{} = repository, requesting_device_jid)
       when is_binary(requesting_device_jid) do
    case Repository.resolve_session_address(repository, requesting_device_jid) do
      {:ok, address} -> address
      _ -> requesting_device_jid
    end
  end

  defp parse_retry_receipt_context(%State{} = state, %BinaryNode{attrs: attrs} = node) do
    requesting_device_jid = attrs["participant"] || attrs["from"]
    is_node_from_me? = retry_requester_is_me?(state, requesting_device_jid)
    raw_conversation_jid = resolve_raw_conversation_jid(attrs, is_node_from_me?)

    %{
      conversation_jid: normalize_conversation_jid(raw_conversation_jid),
      raw_conversation_jid: raw_conversation_jid,
      requesting_device_jid: requesting_device_jid,
      from_me?: is_nil(attrs["recipient"]) or is_node_from_me?,
      ids: retry_receipt_ids(attrs, node),
      retry_count: retry_node_count(node)
    }
  end

  defp retry_requester_is_me?(%State{} = state, requesting_device_jid) do
    me = current_me(state)

    me_identity =
      if JIDUtil.lid?(requesting_device_jid) or JIDUtil.hosted_lid?(requesting_device_jid) do
        me[:lid] || me["lid"]
      else
        me[:id] || me["id"]
      end

    JIDUtil.same_user?(requesting_device_jid, me_identity)
  end

  defp resolve_raw_conversation_jid(attrs, is_node_from_me?) do
    from = attrs["from"]
    recipient_attr = attrs["recipient"]

    cond do
      not is_node_from_me? or JIDUtil.group?(from) or JIDUtil.status_broadcast?(from) ->
        from || recipient_attr || attrs["to"]

      is_binary(recipient_attr) ->
        recipient_attr

      true ->
        from || attrs["to"]
    end
  end

  defp normalize_conversation_jid(jid) when is_binary(jid) do
    case JIDUtil.normalized_user(jid) do
      "" -> jid
      normalized -> normalized
    end
  end

  defp normalize_conversation_jid(_jid), do: nil

  defp retry_receipt_eligible?(%{
         from_me?: true,
         conversation_jid: conversation_jid,
         requesting_device_jid: requesting_device_jid,
         ids: [_ | _]
       })
       when is_binary(conversation_jid) and is_binary(requesting_device_jid),
       do: true

  defp retry_receipt_eligible?(_receipt), do: false

  defp filter_retry_eligible_ids(%State{} = state, receipt, device_key) do
    max_retry_count = state.config.max_msg_retry_count

    Enum.filter(receipt.ids, fn id ->
      Retry.will_send_message_again?(
        state.store_ref,
        id,
        device_key,
        max_retry_count: max_retry_count
      )
    end)
  end

  defp lookup_retry_entries(_state, _receipt, []), do: []

  defp lookup_retry_entries(%State{} = state, receipt, eligible_ids) do
    Enum.flat_map(eligible_ids, fn id ->
      case lookup_recent_retry_message(state.store_ref, receipt, id) do
        %BaileysEx.Protocol.Proto.Message{} = message ->
          [%{id: id, message: message}]

        nil ->
          fetch_fallback_retry_message(state.get_message_fun, receipt, id)
      end
    end)
  end

  defp lookup_recent_retry_message(store_ref, receipt, id) do
    candidates =
      [receipt.conversation_jid, receipt.raw_conversation_jid]
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    Enum.find_value(candidates, fn jid ->
      case Retry.get_recent_message(store_ref, jid, id) do
        %{message: %BaileysEx.Protocol.Proto.Message{} = message} -> message
        _ -> nil
      end
    end)
  end

  defp fetch_fallback_retry_message(get_message_fun, receipt, id)
       when is_function(get_message_fun, 1) do
    key = %{
      remote_jid: receipt.conversation_jid,
      id: id,
      from_me: receipt.from_me?,
      participant: receipt.requesting_device_jid
    }

    case Normalizer.extract_fetched_message(get_message_fun.(key)) do
      %BaileysEx.Protocol.Proto.Message{} = message -> [%{id: id, message: message}]
      nil -> []
    end
  end

  defp fetch_fallback_retry_message(_get_message_fun, _receipt, _id), do: []

  defp retry_receipt_ids(attrs, node) do
    list_ids =
      node
      |> BinaryNodeUtil.child("list")
      |> BinaryNodeUtil.children("item")
      |> Enum.map(& &1.attrs["id"])
      |> Enum.reject(&is_nil/1)

    [attrs["id"] | list_ids] |> Enum.reject(&is_nil/1) |> Enum.uniq()
  end

  defp resend_retry_entries(%State{} = state, _repository, _node, _receipt, _device_key, []),
    do: state

  defp resend_retry_entries(
         %State{} = state,
         %Repository{} = repository,
         node,
         receipt,
         device_key,
         entries
       ) do
    Enum.each(entries, fn %{id: id} ->
      _count = Retry.increment_outbound_retry_count(state.store_ref, id, device_key)
    end)

    case prepare_retry_resend_session(state, repository, node, receipt, device_key) do
      {:ok, prepared_repo} ->
        Enum.reduce(entries, %{state | signal_repository: prepared_repo}, fn
          %{id: id, message: message}, acc ->
            resend_retry_message(acc, acc.signal_repository, receipt, id, message)
        end)

      {:error, _reason, updated_repo} ->
        %{state | signal_repository: updated_repo}
    end
  end

  defp prepare_retry_resend_session(
         %State{} = state,
         %Repository{} = repository,
         %BinaryNode{} = node,
         receipt,
         device_key
       ) do
    participant_jid = receipt.requesting_device_jid
    first_msg_id = hd(receipt.ids)

    {repository, injected_from_bundle?} =
      maybe_inject_retry_bundle(repository, participant_jid, node)

    {repository, reset_reg?} =
      if injected_from_bundle? do
        {repository, false}
      else
        maybe_reset_mismatched_registration(repository, participant_jid, node)
      end

    {repository, reset_base_key?} =
      maybe_handle_retry_base_key_collision(
        state.store_ref,
        repository,
        participant_jid,
        first_msg_id,
        receipt.retry_count
      )

    {repository, reset_recreate?} =
      maybe_auto_recreate_retry_session(
        state,
        repository,
        receipt,
        device_key,
        injected_from_bundle?
      )

    session_reset? = reset_reg? or reset_base_key? or reset_recreate?

    clear_group_sender_key_memory(state.signal_store, receipt.conversation_jid)

    if not injected_from_bundle? or session_reset? do
      force_assert_retry_session(state, repository, participant_jid)
    else
      {:ok, repository}
    end
  end

  defp clear_group_sender_key_memory(nil, _conversation_jid), do: :ok

  defp clear_group_sender_key_memory(signal_store, conversation_jid) do
    if is_binary(conversation_jid) and
         (JIDUtil.group?(conversation_jid) or JIDUtil.status_broadcast?(conversation_jid)) do
      _ = SignalStore.set(signal_store, %{:"sender-key-memory" => %{conversation_jid => nil}})
    end

    :ok
  end

  defp maybe_auto_recreate_retry_session(
         %State{config: %{enable_auto_session_recreation: true}} = state,
         repository,
         %{retry_count: retry_count, requesting_device_jid: participant_jid},
         device_key,
         false
       )
       when retry_count > 1 and is_binary(participant_jid) do
    with {:ok, %{exists: has_session}} <- Repository.validate_session(repository, participant_jid),
         %{recreate: true} <-
           Retry.should_recreate_session(state.store_ref, device_key, has_session),
         {:ok, next_repo} <- Repository.delete_session(repository, [participant_jid]) do
      {next_repo, true}
    else
      _ -> {repository, false}
    end
  end

  defp maybe_auto_recreate_retry_session(_state, repository, _receipt, _device_key, _injected?),
    do: {repository, false}

  defp force_assert_retry_session(%State{} = state, %Repository{} = repository, participant_jid) do
    ctx = sender_context(%{state | signal_repository: repository}, repository)

    case Session.assert_sessions(ctx, [participant_jid], force: true, require_injected: true) do
      {:ok, %{signal_repository: %Repository{} = next_repo}, _fetched?} ->
        {:ok, next_repo}

      {:error, reason} ->
        Logger.warning(
          "failed to force assert session for retry participant #{participant_jid}: #{inspect(reason)}"
        )

        {:error, reason, repository}
    end
  end

  defp maybe_inject_retry_bundle(repository, participant_jid, node)
       when is_binary(participant_jid) do
    with {:ok, bundle} <- Session.extract_e2e_session_from_retry_receipt(node),
         {:ok, next_repo} <-
           Repository.inject_e2e_session(repository, %{jid: participant_jid, session: bundle}) do
      {next_repo, true}
    else
      _ -> {repository, false}
    end
  end

  defp maybe_inject_retry_bundle(repository, _participant_jid, _node), do: {repository, false}

  defp maybe_reset_mismatched_registration(repository, participant_jid, node)
       when is_binary(participant_jid) do
    with {:ok, received_reg_id} <- extract_registration_id(node),
         {:ok, %{registration_id: stored_reg_id}}
         when is_integer(stored_reg_id) and stored_reg_id != 0 and
                stored_reg_id != received_reg_id <-
           Repository.session_info(repository, participant_jid),
         {:ok, next_repo} <- Repository.delete_session(repository, [participant_jid]) do
      {next_repo, true}
    else
      _ -> {repository, false}
    end
  end

  defp maybe_reset_mismatched_registration(repository, _participant_jid, _node),
    do: {repository, false}

  defp extract_registration_id(node) do
    case BinaryNodeUtil.child(node, "registration") do
      %BinaryNode{content: {:binary, bytes}} when byte_size(bytes) == 4 ->
        {:ok, :binary.decode_unsigned(bytes)}

      %BinaryNode{content: bytes} when is_binary(bytes) and byte_size(bytes) == 4 ->
        {:ok, :binary.decode_unsigned(bytes)}

      _ ->
        :error
    end
  end

  defp maybe_handle_retry_base_key_collision(
         store_ref,
         repository,
         participant_jid,
         msg_id,
         retry_count
       )
       when is_binary(participant_jid) and is_binary(msg_id) and retry_count >= 2 do
    with {:ok, session_id} <- Repository.resolve_session_address(repository, participant_jid),
         {:ok, %{base_key: base_key}} when is_binary(base_key) <-
           Repository.session_info(repository, participant_jid) do
      handle_base_key_collision_count(
        store_ref,
        repository,
        participant_jid,
        session_id,
        msg_id,
        base_key,
        retry_count
      )
    else
      _ -> {repository, false}
    end
  end

  defp maybe_handle_retry_base_key_collision(
         _store_ref,
         repository,
         _participant_jid,
         _msg_id,
         _retry_count
       ),
       do: {repository, false}

  defp handle_base_key_collision_count(
         store_ref,
         repository,
         _participant_jid,
         session_id,
         msg_id,
         base_key,
         2
       ) do
    :ok = Retry.save_base_key(store_ref, session_id, msg_id, base_key)
    {repository, false}
  end

  defp handle_base_key_collision_count(
         store_ref,
         repository,
         participant_jid,
         session_id,
         msg_id,
         base_key,
         _retry_count
       ) do
    {repository, deleted?} =
      if Retry.has_same_base_key?(store_ref, session_id, msg_id, base_key) do
        case Repository.delete_session(repository, [participant_jid]) do
          {:ok, next_repo} -> {next_repo, true}
          {:error, _reason} -> {repository, false}
        end
      else
        {repository, false}
      end

    :ok = Retry.delete_base_key(store_ref, session_id, msg_id)
    {repository, deleted?}
  end

  defp resend_retry_message(
         %State{} = state,
         %Repository{} = repository,
         receipt,
         message_id,
         %BaileysEx.Protocol.Proto.Message{} = message
       ) do
    with {:ok, jid} <- normalize_retry_jid(receipt.conversation_jid),
         participant <- retry_participant(receipt.requesting_device_jid, receipt.retry_count),
         resend_opts =
           [message_id_fun: fn -> message_id end]
           |> maybe_put_retry_target_opts(participant),
         {:ok, _result, %{signal_repository: %Repository{} = updated_repository}} <-
           Sender.send_proto(
             sender_context(%{state | signal_repository: repository}, repository),
             jid,
             message,
             resend_opts
           ) do
      %{state | signal_repository: updated_repository}
    else
      _ -> state
    end
  end

  defp maybe_put_retry_target_opts(opts, nil),
    do: Keyword.put(opts, :use_user_devices_cache, false)

  defp maybe_put_retry_target_opts(opts, participant),
    do: Keyword.put(opts, :participant, participant)

  defp retry_participant(requesting_device_jid, retry_count) do
    case is_binary(requesting_device_jid) && JIDUtil.parse(requesting_device_jid) do
      %BaileysEx.JID{device: device} when is_integer(device) and device > 0 ->
        %{jid: requesting_device_jid, count: retry_count}

      _ ->
        nil
    end
  end

  defp retry_node_count(%BinaryNode{} = node) do
    case BinaryNodeUtil.child(node, "retry") do
      %BinaryNode{attrs: %{"count" => retry_count}} -> parse_retry_count(retry_count)
      _ -> 1
    end
  end

  defp parse_retry_count(count) when is_binary(count) do
    case Integer.parse(count) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> 1
    end
  end

  defp normalize_retry_jid(jid) when is_binary(jid) do
    case JIDUtil.parse(jid) do
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
    |> maybe_put_callback(:signal_store, state.signal_store)
    |> maybe_put_callback(:signal_repository, state.signal_repository)
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

  defp bad_ack_context(%State{} = state) do
    %{
      event_emitter: state.event_emitter
    }
    |> maybe_put_callback(:fetch_reachout_timelock_fun, fetch_reachout_timelock_fun(state))
  end

  defp fetch_reachout_timelock_fun(%State{} = state) do
    case fetch_socket_pid(state) do
      {:ok, socket_pid} ->
        fn ->
          Account.fetch_account_reachout_timelock({state.socket_module, socket_pid},
            event_emitter: state.event_emitter,
            query_timeout: state.config.default_query_timeout_ms
          )
        end

      :error ->
        nil
    end
  end

  defp placeholder_request_fun(%{send_node_fun: send_node_fun, query_fun: query_fun} = context)
       when is_function(send_node_fun, 1) and is_function(query_fun, 1) do
    fn request -> PeerData.send_request(context, request) end
  end

  defp placeholder_request_fun(_context), do: nil

  defp run_public_retry_request(state, repository, node, opts) do
    creds = Store.get(state.store_ref, :creds, %{})

    with {:ok, _me_id} <- authenticated_me_id(creds),
         {:ok, envelope, %{signal_repository: %Repository{} = decoded_repository}} <-
           Decode.decode_envelope(node, receiver_context(state, repository)) do
      send_public_retry_request(state, decoded_repository, node, envelope, creds, opts)
    else
      {:error, _reason} = error -> {error, repository}
    end
  end

  defp authenticated_me_id(creds) do
    case AuthState.me_id(creds) do
      me_id when is_binary(me_id) -> {:ok, me_id}
      _other -> {:error, :not_authenticated}
    end
  end

  defp send_public_retry_request(state, repository, node, envelope, creds, opts) do
    {updated_repository, recreate?} =
      maybe_recreate_retry_session(
        state,
        repository,
        node,
        envelope.decryption_jid,
        nil
      )

    request_context = %{
      creds: creds,
      send_node_fun: receipt_sender_fun(state),
      force_include_keys?: Keyword.get(opts, :force_include_keys, false) || recreate?,
      error_reason: nil
    }

    case request_context.send_node_fun do
      send_node_fun when is_function(send_node_fun, 1) ->
        state
        |> send_retry_request_with_repository(updated_repository, node, request_context)
        |> normalize_public_retry_result(updated_repository)

      _other ->
        {{:error, :socket_not_available}, updated_repository}
    end
  end

  defp normalize_public_retry_result(
         {:ok, _receipt, %Repository{} = final_repository},
         _repository
       ),
       do: {:ok, final_repository}

  defp normalize_public_retry_result({:error, _reason} = error, repository),
    do: {error, repository}

  defp run_message_retry_operation(state, {:add_recent_message, to, id, message, opts}),
    do: {:ok, Retry.add_recent_message(state.store_ref, to, id, message, opts)}

  defp run_message_retry_operation(state, {:get_recent_message, to, id, opts}),
    do: {:ok, Retry.get_recent_message(state.store_ref, to, id, opts)}

  defp run_message_retry_operation(
         state,
         {:should_recreate_session, jid, has_session?, error_code, opts}
       ) do
    {:ok,
     Retry.should_recreate_session(
       state.store_ref,
       jid,
       has_session?,
       error_code,
       opts
     )}
  end

  defp run_message_retry_operation(state, {:increment_retry_count, message_id}),
    do: {:ok, Retry.increment_retry_count(state.store_ref, message_id)}

  defp run_message_retry_operation(state, {:get_retry_count, message_id}),
    do: {:ok, Retry.get_retry_count(state.store_ref, message_id)}

  defp run_message_retry_operation(state, {:has_exceeded_max_retries, message_id}) do
    {:ok,
     Retry.has_exceeded_max_retries?(
       state.store_ref,
       message_id,
       state.config.max_msg_retry_count
     )}
  end

  defp run_message_retry_operation(state, {:mark_retry_success, message_id}),
    do: {:ok, Retry.mark_retry_success(state.store_ref, message_id)}

  defp run_message_retry_operation(state, {:mark_retry_failed, message_id}),
    do: {:ok, Retry.mark_retry_failed(state.store_ref, message_id)}

  defp run_message_retry_operation(
         state,
         {:schedule_phone_request, message_id, callback, opts}
       ) do
    retry_opts =
      opts
      |> Keyword.put(:task_supervisor, state.task_supervisor)
      |> Keyword.put(:timer_owner, state.supervisor)

    {:ok,
     Retry.schedule_phone_request(
       state.store_ref,
       message_id,
       callback,
       retry_opts
     )}
  end

  defp run_message_retry_operation(state, {:cancel_pending_phone_request, message_id}),
    do: {:ok, Retry.cancel_phone_request(state.store_ref, message_id)}

  defp run_message_retry_operation(state, :clear),
    do: {:ok, Retry.clear(state.store_ref)}

  defp run_message_retry_operation(state, {:save_base_key, address, message_id, base_key, opts}),
    do: {:ok, Retry.save_base_key(state.store_ref, address, message_id, base_key, opts)}

  defp run_message_retry_operation(
         state,
         {:has_same_base_key, address, message_id, base_key, opts}
       ),
       do: {:ok, Retry.has_same_base_key?(state.store_ref, address, message_id, base_key, opts)}

  defp run_message_retry_operation(state, {:delete_base_key, address, message_id}),
    do: {:ok, Retry.delete_base_key(state.store_ref, address, message_id)}

  defp run_message_retry_operation(_state, _operation),
    do: {:error, :unsupported_retry_operation}

  defp retry_request_fun(%State{} = state, %Repository{} = repository) do
    case receipt_sender_fun(state) do
      send_node_fun when is_function(send_node_fun, 1) ->
        build_retry_request_fun(state, repository, send_node_fun)

      _other ->
        nil
    end
  end

  defp build_retry_request_fun(state, repository, send_node_fun) do
    fn node, decryption_jid, error_reason ->
      creds = Store.get(state.store_ref, :creds, %{})

      {repository, force_include_keys?} =
        maybe_recreate_retry_session(
          state,
          repository,
          node,
          decryption_jid,
          error_reason
        )

      send_retry_request_with_repository(
        state,
        repository,
        node,
        %{
          creds: creds,
          send_node_fun: send_node_fun,
          force_include_keys?: force_include_keys?,
          error_reason: error_reason
        }
      )
    end
  end

  defp send_retry_request_with_repository(
         state,
         repository,
         node,
         %{
           creds: creds,
           send_node_fun: send_node_fun,
           force_include_keys?: force_include_keys?,
           error_reason: error_reason
         }
       ) do
    case Retry.send_retry_request(state.store_ref, node,
           max_retry_count: state.config.max_msg_retry_count,
           registration_id: AuthState.get(creds, :registration_id),
           force_include_keys: force_include_keys?,
           error_code: error_reason,
           send_node_fun: send_node_fun,
           request_placeholder_resend_fun: fn message_key, message_data ->
             request_retry_placeholder(state, message_key, message_data)
           end,
           task_supervisor: state.task_supervisor,
           timer_owner: state.supervisor,
           keys_node_fun: fn -> retry_keys_node(state, creds) end
         ) do
      {:ok, receipt} -> {:ok, receipt, repository}
      {:error, _reason} = error -> error
    end
  end

  defp request_retry_placeholder(%State{} = state, message_key, message_data) do
    request_placeholder_resend(
      BaileysEx.Connection.Supervisor.coordinator(state.supervisor),
      message_key,
      message_data,
      delay_ms: state.config.retry_delay_ms
    )
  end

  defp maybe_recreate_retry_session(
         %State{config: %{enable_auto_session_recreation: true}} = state,
         %Repository{} = repository,
         %BinaryNode{attrs: attrs},
         decryption_jid,
         error_reason
       )
       when is_binary(decryption_jid) do
    upcoming_retry_count = Retry.get_retry_count(state.store_ref, attrs["id"]) + 1

    if upcoming_retry_count > 1 and upcoming_retry_count <= state.config.max_msg_retry_count do
      recreate_retry_session_if_needed(state, repository, decryption_jid, error_reason)
    else
      {repository, false}
    end
  end

  defp maybe_recreate_retry_session(
         %State{},
         %Repository{} = repository,
         %BinaryNode{},
         _decryption_jid,
         _error_reason
       ),
       do: {repository, false}

  defp recreate_retry_session_if_needed(state, repository, decryption_jid, error_reason) do
    with {:ok, %{exists: has_session?}} <- Repository.validate_session(repository, decryption_jid),
         %{recreate: true} <-
           Retry.should_recreate_session(
             state.store_ref,
             decryption_jid,
             has_session?,
             error_reason
           ),
         {:ok, repository} <- Repository.delete_session(repository, [decryption_jid]) do
      {repository, true}
    else
      _other -> {repository, false}
    end
  end

  defp retry_keys_node(%State{} = state, creds) do
    case PreKey.retry_keys_node(
           state.signal_store,
           Store.get(state.store_ref, :auth_state, %{}),
           encoded_device_identity(creds)
         ) do
      {:ok, %{update: update, node: keys_node}} ->
        :ok = Store.merge_creds(state.store_ref, update)
        :ok = EventEmitter.emit(state.event_emitter, :creds_update, update)
        {:ok, keys_node}

      {:error, _reason} = error ->
        error
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
        end,
        on_before_session_refresh_fun: tc_token_reissue_fun(state)
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

  defp tc_token_reissue_fun(%State{} = state) do
    case {fetch_socket_pid(state), state.signal_store, state.task_supervisor} do
      {{:ok, socket_pid}, %SignalStore{} = signal_store, task_supervisor}
      when not is_nil(task_supervisor) ->
        fn jid ->
          start_tc_token_reissue_task(state, task_supervisor, socket_pid, signal_store, jid)
          :ok
        end

      _other ->
        nil
    end
  end

  defp tc_token_issue_fun(%State{} = state) do
    case {fetch_socket_pid(state), state.signal_store, state.task_supervisor} do
      {{:ok, socket_pid}, %SignalStore{} = signal_store, task_supervisor}
      when not is_nil(task_supervisor) ->
        fn jid, _message, _opts ->
          start_tc_token_issue_task(state, task_supervisor, socket_pid, signal_store, jid)
          :ok
        end

      _other ->
        nil
    end
  end

  defp start_tc_token_reissue_task(state, task_supervisor, socket_pid, signal_store, jid) do
    start_owned_task(task_supervisor, fn ->
      reissue_tc_token(state, socket_pid, signal_store, jid)
    end)
  end

  defp reissue_tc_token(state, socket_pid, signal_store, jid) do
    opts = [
      issue_to_lid?: tc_token_issue_to_lid?(state),
      now: System.os_time(:second)
    ]

    {state.socket_module, socket_pid}
    |> TcToken.reissue_after_identity_change(signal_store, jid, opts)
    |> log_tc_token_result("re-issue")
  end

  defp start_tc_token_issue_task(state, task_supervisor, socket_pid, signal_store, jid) do
    start_owned_task(task_supervisor, fn ->
      issue_tc_token(state, socket_pid, signal_store, jid)
    end)
  end

  defp issue_tc_token(state, socket_pid, signal_store, jid) do
    opts = [
      issue_to_lid?: tc_token_issue_to_lid?(state),
      query_timeout: state.config.default_query_timeout_ms,
      now: System.os_time(:second)
    ]

    {state.socket_module, socket_pid}
    |> TcToken.issue_after_outgoing_message(signal_store, jid, opts)
    |> log_tc_token_result("issue")
  end

  defp log_tc_token_result(:ok, _action), do: :ok

  defp log_tc_token_result({:error, reason}, action) do
    Logger.debug("failed to #{action} tctoken: #{inspect(reason)}")
  end

  defp tc_token_issue_to_lid?(%State{} = state) do
    props = Store.get(state.store_ref, :props, %{}) || %{}

    case props["14303"] || props["lid_trusted_token_issue_to_lid"] do
      value when value in [true, 1, "1", "true"] -> true
      _value -> false
    end
  end

  defp privacy_token_on_1to1?(%State{} = state) do
    props = Store.get(state.store_ref, :props, %{}) || %{}

    case props["10518"] || props["privacy_token_sending_on_all_1_on_1_messages"] do
      nil -> true
      value when value in [true, 1, "1", "true"] -> true
      _value -> false
    end
  end

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
      existing =
        case SignalStore.get(signal_store, :tctoken, [jid]) do
          %{^jid => entry} when is_map(entry) -> entry
          _ -> %{}
        end

      entry =
        %{token: token, timestamp: timestamp}
        |> maybe_put(:sender_timestamp, tc_entry_sender_timestamp(existing))

      SignalStore.set(signal_store, %{tctoken: %{jid => entry}})
    end
  end

  defp privacy_token_store_fun(_signal_store), do: nil

  defp tc_entry_sender_timestamp(entry) when is_map(entry) do
    entry[:sender_timestamp] || entry["sender_timestamp"] || entry["senderTimestamp"]
  end

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

  defp built_in_resync_app_state_fun(%State{sync: %{generation: gen}}) do
    coordinator_pid = self()

    fn name ->
      with {:ok, collections} <- normalize_patch_names([name]) do
        Kernel.send(coordinator_pid, {:start_server_app_state_resync, gen, collections, name})
        :ok
      end
    end
  end

  defp launch_server_app_state_resync(%State{} = state, collections, name) do
    case fetch_socket_pid(state) do
      {:ok, socket_pid} ->
        start_tracked_bg_app_state_sync(state, collections, socket_pid, :server, name: name)

      :error ->
        Logger.warning("server_sync resync skipped for #{name}: socket not available")
        state
    end
  end

  defp log_server_app_state_sync_result(:ok, _name), do: :ok

  defp log_server_app_state_sync_result({:error, reason}, name) do
    Logger.warning("server_sync resync failed for #{name}: #{inspect(reason)}")
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
         %State{sync: %{state: :syncing, task: nil}} = state,
         %{messaging_history_set: _history}
       ) do
    maybe_launch_initial_app_state_sync(state)
  end

  defp maybe_start_initial_app_state_sync(
         %State{sync: %{state: :syncing, task: nil}} = state,
         %{creds_update: %{my_app_state_key_id: key_id}}
       )
       when is_binary(key_id) and key_id != "" do
    maybe_launch_initial_app_state_sync(state)
  end

  defp maybe_start_initial_app_state_sync(%State{} = state, _events), do: state

  defp maybe_resync_blocked_app_state_collections(
         %State{sync: %{state: sync_state, task: task, blocked: blocked}} = state,
         %{creds_update: %{my_app_state_key_id: key_id}}
       )
       when is_binary(key_id) and key_id != "" do
    case {sync_state, task} do
      {:syncing, %{ref: _} = active_task} ->
        put_sync(state, :task, %{active_task | resync_blocked?: true})

      _ when map_size(blocked) == 0 ->
        mark_in_flight_blocked_bg_tasks(state)

      {:syncing, nil} ->
        put_sync(state, :blocked, %{})

      _ ->
        launch_blocked_app_state_sync(put_sync(state, :blocked, %{}), blocked)
    end
  end

  defp maybe_resync_blocked_app_state_collections(%State{} = state, _events), do: state

  defp mark_in_flight_blocked_bg_tasks(%State{sync: %{bg_tasks: bg_tasks}} = state)
       when map_size(bg_tasks) == 0,
       do: state

  defp mark_in_flight_blocked_bg_tasks(%State{sync: %{bg_tasks: bg_tasks}} = state) do
    updated =
      Map.new(bg_tasks, fn
        {ref, %{kind: :blocked} = info} -> {ref, %{info | resync_blocked?: true}}
        entry -> entry
      end)

    put_sync(state, :bg_tasks, updated)
  end

  defp launch_blocked_app_state_sync(%State{} = state, blocked) do
    case fetch_socket_pid(state) do
      {:ok, socket_pid} ->
        start_blocked_app_state_sync(state, blocked, socket_pid)

      :error ->
        put_sync(state, :blocked, blocked)
    end
  end

  defp start_blocked_app_state_sync(state, blocked, socket_pid) do
    collections = Map.keys(blocked)

    case start_tracked_bg_app_state_sync_result(state, collections, socket_pid, :blocked, []) do
      {:ok, next_state} ->
        next_state

      {:error, reason} ->
        Logger.warning("failed to start blocked app state resync: #{inspect(reason)}")
        put_sync(state, :blocked, blocked)
    end
  end

  defp start_tracked_bg_app_state_sync(state, collections, socket_pid, kind, opts) do
    case start_tracked_bg_app_state_sync_result(state, collections, socket_pid, kind, opts) do
      {:ok, next_state} ->
        next_state

      {:error, reason} ->
        Logger.warning("failed to start #{kind} app state resync: #{inspect(reason)}")
        state
    end
  end

  defp start_tracked_bg_app_state_sync_result(state, collections, socket_pid, kind, opts) do
    coordinator_pid = self()
    generation = state.sync.generation

    task_fun = fn ->
      state
      |> run_app_state_resync(collections,
        initial_sync: false,
        socket_pid: socket_pid,
        coordinator_pid: coordinator_pid,
        sync_generation: generation
      )
      |> normalize_sync_result()
    end

    case start_async_sync_task(state.task_supervisor, task_fun) do
      {:ok, task} ->
        info = %{
          ref: task.ref,
          pid: task.pid,
          generation: generation,
          kind: kind,
          collections: collections,
          name: Keyword.get(opts, :name),
          resync_blocked?: false
        }

        {:ok, put_sync(state, :bg_tasks, Map.put(state.sync.bg_tasks, task.ref, info))}

      {:error, _reason} = error ->
        error
    end
  end

  defp start_async_sync_task(task_supervisor, fun)
       when not is_nil(task_supervisor) and is_function(fun, 0) do
    {:ok, Task.Supervisor.async_nolink(task_supervisor, fun)}
  catch
    :exit, reason -> {:error, reason}
  end

  defp start_async_sync_task(_task_supervisor, _fun), do: {:error, :task_supervisor_unavailable}

  defp log_blocked_app_state_sync_result(:ok), do: :ok

  defp log_blocked_app_state_sync_result({:error, reason}) do
    Logger.warning("blocked app state resync failed: #{inspect(reason)}")
  end

  # Baileys runs doAppStateSync as soon as history moves the socket into Syncing,
  # even before the app state key arrives: collections that cannot be decrypted
  # yet are parked as blocked and resynced when `my_app_state_key_id` arrives.
  defp maybe_launch_initial_app_state_sync(%State{} = state),
    do: launch_initial_app_state_sync(state)

  defp launch_initial_app_state_sync(
         %State{} = state,
         collections \\ SyncdCodec.patch_names(),
         opts \\ []
       ) do
    reset_tracking? = Keyword.get(opts, :reset_initial_tracking?, true)

    case fetch_socket_pid(state) do
      {:ok, socket_pid} ->
        coordinator_pid = self()
        me = current_me(state)
        generation = state.sync.generation

        task =
          Task.Supervisor.async_nolink(state.task_supervisor, fn ->
            Logger.debug("[AppStateDiag] sync Task started pid=#{inspect(self())}")

            result =
              run_app_state_resync(
                state,
                collections,
                initial_sync: true,
                socket_pid: socket_pid,
                coordinator_pid: coordinator_pid,
                sync_generation: generation,
                me: me
              )

            normalize_sync_result(result)
          end)

        next_sync =
          %{
            state.sync
            | task: %{
                ref: task.ref,
                pid: task.pid,
                generation: generation,
                collections: collections,
                resync_blocked?: false
              },
              blocked: %{}
          }
          |> maybe_reset_initial_sync_tracking(reset_tracking?)

        %{state | sync: next_sync}

      :error ->
        schedule_complete_initial_sync(state)
    end
  end

  defp maybe_reset_initial_sync_tracking(sync, true) do
    %{
      sync
      | pending_initial_counter?: false,
        initial_incomplete: MapSet.new(),
        initial_failed?: false
    }
  end

  defp maybe_reset_initial_sync_tracking(sync, false), do: sync

  defp run_app_state_resync(%State{} = state, collections, opts) when is_list(collections) do
    socket_pid = Keyword.get_lazy(opts, :socket_pid, fn -> socket_pid!(state) end)
    me = Keyword.get_lazy(opts, :me, fn -> current_me(state) end)
    coordinator_pid = Keyword.get(opts, :coordinator_pid, self())
    generation = Keyword.get(opts, :sync_generation, state.sync.generation)

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
      is_initial_sync: Keyword.get(opts, :initial_sync, false),
      on_blocked_collection: fn name ->
        Kernel.send(coordinator_pid, {:app_state_collection_blocked, generation, name})
      end
    )
  end

  defp current_account_sync_counter(%State{} = state) do
    case state.store_ref |> Store.get(:creds, %{}) |> Map.get(:account_sync_counter, 0) do
      counter when is_integer(counter) -> counter
      _ -> 0
    end
  end

  defp increment_account_sync_counter(%State{} = state) do
    current_counter = current_account_sync_counter(state)

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
