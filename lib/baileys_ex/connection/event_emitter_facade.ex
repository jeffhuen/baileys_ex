defmodule BaileysEx.Connection.EventEmitter do
  @moduledoc """
  Supervised buffered connection event emitter modeled after Baileys'
  `makeEventBuffer`.

  Each emitter owns its buffering server and callback task supervisor. Internal
  taps remain ordered, while each public subscriber has an independent serial,
  bounded delivery lane. Slow or reentrant subscribers therefore do not block
  event ingestion or internal protocol handling.
  """

  use Supervisor

  alias BaileysEx.Connection.EventEmitter.Server

  @type event :: atom()
  @type emit_error :: :dispatch_queue_full

  @doc "Start a supervised event emitter runtime."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    {start_opts, init_opts} = Keyword.split(opts, [:name])
    Supervisor.start_link(__MODULE__, init_opts, start_opts)
  end

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :permanent,
      shutdown: :infinity
    }
  end

  @doc "Register an event-map subscriber and return its unsubscribe function."
  @spec process(GenServer.server(), (map() -> term())) :: (-> :ok)
  def process(emitter, handler) when is_function(handler, 1) do
    emitter |> server!() |> Server.process(handler)
  end

  @doc "Register a pre-dispatch tap and return its unsubscribe function."
  @spec tap(GenServer.server(), (map() -> term())) :: (-> :ok)
  def tap(emitter, handler) when is_function(handler, 1) do
    emitter |> server!() |> Server.tap(handler)
  end

  @doc "Emit one event, buffering it when the current buffer policy requires it."
  @spec emit(GenServer.server(), event(), term()) :: :ok | {:error, emit_error()}
  def emit(emitter, event, data), do: emitter |> server!() |> Server.emit(event, data)

  @doc "Enter buffering mode."
  @spec buffer(GenServer.server()) :: :ok
  def buffer(emitter), do: emitter |> server!() |> Server.buffer()

  @doc "Wrap work in a nested buffering context."
  @spec create_buffered_function(GenServer.server(), (-> term())) :: (-> term())
  def create_buffered_function(emitter, work) when is_function(work, 0) do
    fn ->
      :ok = buffer(emitter)

      try do
        work.()
      after
        :ok = GenServer.call(server!(emitter), :buffer_complete)
      end
    end
  end

  @doc "Flush the active buffer, retaining it when the dispatch queue is full."
  @spec flush(GenServer.server()) :: boolean() | {:error, emit_error()}
  def flush(emitter), do: emitter |> server!() |> Server.flush()

  @doc "Return whether buffering is active."
  @spec buffering?(GenServer.server()) :: boolean()
  def buffering?(emitter), do: emitter |> server!() |> Server.buffering?()

  @doc "Add values used by conditional buffered-event evaluation."
  @spec seed(GenServer.server(), map()) :: :ok
  def seed(emitter, values) when is_map(values),
    do: emitter |> server!() |> Server.seed(values)

  defp server(emitter) do
    emitter
    |> resolve_pid()
    |> case do
      pid when is_pid(pid) ->
        pid
        |> Supervisor.which_children()
        |> Enum.find_value(fn
          {Server, child, :worker, _modules} when is_pid(child) -> child
          _ -> nil
        end)

      _ ->
        nil
    end
  catch
    :exit, _reason -> nil
  end

  @impl true
  def init(opts) do
    emitter = self()

    server_opts =
      opts
      |> Keyword.put(:task_supervisor, fn -> child_pid(emitter, Task.Supervisor) end)

    children = [
      Supervisor.child_spec(Task.Supervisor, id: Task.Supervisor),
      {Server, server_opts}
      |> Supervisor.child_spec([])
      |> Map.merge(%{id: Server, restart: :temporary, significant: true})
    ]

    Supervisor.init(children,
      strategy: :one_for_one,
      auto_shutdown: :any_significant
    )
  end

  defp server!(emitter) do
    case server(emitter) do
      pid when is_pid(pid) -> pid
      nil -> exit({:noproc, {__MODULE__, :server, [emitter]}})
    end
  end

  defp child_pid(supervisor, child_id) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {^child_id, pid, _type, _modules} when is_pid(pid) -> pid
      _ -> nil
    end)
  catch
    :exit, _reason -> nil
  end

  defp resolve_pid(pid) when is_pid(pid), do: pid
  defp resolve_pid(server), do: GenServer.whereis(server)
end
