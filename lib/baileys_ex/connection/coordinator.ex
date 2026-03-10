defmodule BaileysEx.Connection.Coordinator do
  @moduledoc """
  Runtime wrapper around the raw connection socket.

  This process owns wrapper concerns that Baileys keeps outside `makeSocket`:
  initial connect/reconnect policy and persisting emitted credential updates.
  """

  use GenServer

  alias BaileysEx.Connection.EventEmitter
  alias BaileysEx.Connection.Socket
  alias BaileysEx.Connection.Store

  defmodule State do
    @moduledoc false

    @enforce_keys [:config, :event_emitter, :store, :supervisor]
    defstruct [
      :config,
      :event_emitter,
      :store,
      :supervisor,
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
      store: Keyword.fetch!(opts, :store),
      supervisor: Keyword.fetch!(opts, :supervisor)
    }

    {:ok, state, {:continue, :setup}}
  end

  @impl true
  def handle_continue(:setup, %State{} = state) do
    coordinator_pid = self()

    unsubscribe =
      EventEmitter.process(state.event_emitter, &Kernel.send(coordinator_pid, {:events, &1}))

    state = %{state | unsubscribe: unsubscribe}
    {:noreply, connect_socket(%{state | reconnect_timer: nil})}
  end

  @impl true
  def handle_info({:events, events}, %State{} = state) when is_map(events) do
    state =
      state
      |> persist_creds_update(events)
      |> handle_connection_update(events)

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

  defp handle_connection_update(
         %State{} = state,
         %{connection_update: %{connection: :close}}
       ) do
    state
    |> cancel_initial_sync_timer()
    |> Map.put(:sync_state, :connecting)
  end

  defp handle_connection_update(%State{} = state, _events), do: state

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

  defp connect_socket(%State{} = state) do
    case socket_pid(state.supervisor) do
      nil ->
        state

      socket_pid ->
        case Socket.connect(socket_pid) do
          :ok -> state
          {:error, {:invalid_state, _state_name}} -> state
        end
    end
  end

  defp socket_pid(supervisor) do
    supervisor
    |> Elixir.Supervisor.which_children()
    |> Enum.find_value(fn
      {Socket, pid, _type, _modules} when is_pid(pid) -> pid
      _ -> nil
    end)
  end
end
