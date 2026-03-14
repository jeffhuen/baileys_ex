defmodule BaileysEx.Connection.Coordinator do
  @moduledoc """
  Runtime wrapper around the raw connection socket.

  This process owns wrapper concerns that Baileys keeps outside `makeSocket`:
  initial connect/reconnect policy, init queries, dirty-bit handling, and
  persisting emitted credential updates.
  """

  use GenServer

  alias BaileysEx.BinaryNode
  alias BaileysEx.Connection.EventEmitter
  alias BaileysEx.Connection.Socket
  alias BaileysEx.Connection.Store
  alias BaileysEx.Feature.Group
  alias BaileysEx.Feature.Presence
  alias BaileysEx.Message.IdentityChangeHandler
  alias BaileysEx.Message.NotificationHandler
  alias BaileysEx.Message.Receipt
  alias BaileysEx.Message.Receiver
  alias BaileysEx.Protocol.BinaryNode, as: BinaryNodeUtil
  alias BaileysEx.Signal.Repository
  alias BaileysEx.Signal.Session
  alias BaileysEx.Signal.Store, as: SignalStore
  alias BaileysEx.Signal.Store.Memory, as: SignalStoreMemory

  @s_whatsapp_net "s.whatsapp.net"

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

    state =
      state
      |> Map.put(:unsubscribe, unsubscribe)
      |> Map.put(:store_ref, Store.wrap(state.store))
      |> Map.put(:signal_store, wrapped_signal_store)
      |> Map.put(
        :signal_repository,
        build_signal_repository(
          state.signal_repository,
          Keyword.get(opts, :signal_repository_adapter),
          Keyword.get(opts, :signal_repository_adapter_state, %{}),
          wrapped_signal_store
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
  def handle_info({:events, events}, %State{} = state) when is_map(events) do
    previous_creds = Store.get(state.store_ref, :creds, %{})

    state =
      state
      |> handle_socket_node(events)
      |> persist_creds_update(events)
      |> maybe_send_push_name_presence_update(previous_creds, events)
      |> handle_connection_update(events)
      |> handle_sync_event(events)
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

  def handle_info(:complete_initial_sync, %State{} = state) do
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
      schedule_reconnect(state)
    else
      cancel_reconnect(state)
    end
  end

  defp handle_connection_update(
         %State{sync_state: :connecting} = state,
         %{connection_update: %{received_pending_notifications: true}}
       ) do
    :ok = EventEmitter.buffer(state.event_emitter)

    timer =
      Process.send_after(self(), :initial_sync_timeout, state.config.initial_sync_timeout_ms)

    %{
      cancel_initial_sync_timer(state)
      | initial_sync_timer: timer,
        sync_state: :awaiting_initial_sync
    }
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
        _ =
          Group.handle_dirty_update({state.socket_module, socket_pid}, %{type: type},
            event_emitter: state.event_emitter,
            sendable: {state.socket_module, socket_pid}
          )

      :error ->
        send_clean_dirty_bits(state, "groups")
    end

    state
  end

  defp handle_dirty_update(%State{} = state, _events), do: state

  defp schedule_reconnect(%State{reconnect_timer: nil} = state) do
    timer = Process.send_after(self(), :reconnect_socket, state.config.retry_delay_ms)
    %{state | reconnect_timer: timer}
  end

  defp schedule_reconnect(%State{} = state), do: state

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
    node = %BinaryNode{
      tag: "iq",
      attrs: %{"xmlns" => "blocklist", "to" => @s_whatsapp_net, "type" => "get"},
      content: nil
    }

    with {:ok, socket_pid} <- fetch_socket_pid(state),
         {:ok, response} <-
           state.socket_module.query(socket_pid, node, state.config.default_query_timeout_ms) do
      blocklist =
        response
        |> BinaryNodeUtil.child("list")
        |> BinaryNodeUtil.children("item")
        |> Enum.map(& &1.attrs["jid"])
        |> Enum.reject(&is_nil/1)

      :ok = Store.put(state.store, :blocklist, blocklist)
      :ok = EventEmitter.emit(state.event_emitter, :blocklist_update, blocklist)
      :ok
    else
      _ -> :ok
    end
  end

  defp fetch_privacy_settings(%State{} = state) do
    node = %BinaryNode{
      tag: "iq",
      attrs: %{"xmlns" => "privacy", "to" => @s_whatsapp_net, "type" => "get"},
      content: [%BinaryNode{tag: "privacy", attrs: %{}, content: nil}]
    }

    with {:ok, socket_pid} <- fetch_socket_pid(state),
         {:ok, response} <-
           state.socket_module.query(socket_pid, node, state.config.default_query_timeout_ms) do
      privacy_settings =
        response
        |> BinaryNodeUtil.child("privacy")
        |> reduce_children_to_dictionary("category")

      :ok = Store.put(state.store, :privacy_settings, privacy_settings)
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
         _signal_store
       ),
       do: repository

  defp build_signal_repository(nil, adapter, adapter_state, %SignalStore{} = signal_store)
       when is_atom(adapter) do
    Repository.new(
      adapter: adapter,
      adapter_state: adapter_state,
      store: signal_store,
      pn_to_lid_lookup: lid_lookup_fun(signal_store)
    )
  end

  defp build_signal_repository(repository, _adapter, _adapter_state, _signal_store),
    do: repository

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

  defp notification_context(%State{} = state) do
    %{event_emitter: state.event_emitter}
    |> maybe_put_callback(:store_privacy_token_fun, privacy_token_store_fun(state.signal_store))
    |> maybe_put_callback(:handle_encrypt_notification_fun, state.handle_encrypt_notification_fun)
    |> maybe_put_callback(:device_notification_fun, state.device_notification_fun)
    |> maybe_put_callback(:resync_app_state_fun, state.resync_app_state_fun)
  end

  defp receipt_sender_fun(%State{} = state) do
    case fetch_socket_pid(state) do
      {:ok, socket_pid} -> fn node -> state.socket_module.send_node(socket_pid, node) end
      :error -> nil
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

  defp maybe_put_callback(map, _key, nil), do: map
  defp maybe_put_callback(map, key, value), do: Map.put(map, key, value)

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
end
