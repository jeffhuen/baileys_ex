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
  alias BaileysEx.Protocol.BinaryNode, as: BinaryNodeUtil
  alias BaileysEx.Signal.PreKey
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
      :store_ref,
      :supervisor,
      :task_supervisor,
      :unsubscribe,
      :reconnect_timer,
      :initial_sync_timer,
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
      supervisor: Keyword.fetch!(opts, :supervisor),
      task_supervisor: Keyword.fetch!(opts, :task_supervisor)
    }

    {:ok, state, {:continue, :setup}}
  end

  @impl true
  def handle_continue(:setup, %State{} = state) do
    coordinator_pid = self()

    unsubscribe =
      EventEmitter.tap(state.event_emitter, &Kernel.send(coordinator_pid, {:events, &1}))

    state =
      state
      |> Map.put(:unsubscribe, unsubscribe)
      |> Map.put(:store_ref, Store.wrap(state.store))
      |> Map.put(:signal_store, wrap_signal_store(state.signal_store))
      |> Map.put(:reconnect_timer, nil)

    {:noreply, connect_socket(state)}
  end

  @impl true
  def handle_info({:events, events}, %State{} = state) when is_map(events) do
    state =
      state
      |> persist_creds_update(events)
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
    |> maybe_upload_prekeys()
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
    send_clean_dirty_bits(state, "groups")
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

  defp maybe_upload_prekeys(%State{signal_store: nil} = state), do: state

  defp maybe_upload_prekeys(%State{} = state) do
    _ =
      Task.Supervisor.start_child(state.task_supervisor, fn ->
        with {:ok, socket_pid} <- fetch_socket_pid(state) do
          prekey_opts = prekey_runtime_opts(state, socket_pid)
          _ = PreKey.upload_if_required(prekey_opts)
          _ = PreKey.digest_key_bundle(prekey_opts)
        end
      end)

    state
  end

  defp prekey_runtime_opts(%State{} = state, socket_pid) do
    [
      store: state.signal_store,
      auth_state: Store.get(state.store_ref, :auth_state, %{}),
      query_fun: fn node ->
        state.socket_module.query(socket_pid, node, state.config.default_query_timeout_ms)
      end,
      emit_creds_update: fn update ->
        EventEmitter.emit(state.event_emitter, :creds_update, update)
      end,
      upload_key: {:prekey_upload, state.supervisor},
      get_last_upload_at: fn ->
        Store.get(state.store_ref, :last_pre_key_upload_at)
      end,
      put_last_upload_at: fn timestamp ->
        Store.put(state.store, :last_pre_key_upload_at, timestamp)
      end
    ]
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
end
