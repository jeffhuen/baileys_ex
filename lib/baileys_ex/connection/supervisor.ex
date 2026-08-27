defmodule BaileysEx.Connection.Supervisor do
  @moduledoc """
  Supervised, per-connection runtime for transport, state, events, Signal storage,
  delayed work, and coordination.
  """

  use Elixir.Supervisor

  alias BaileysEx.Connection.Config
  alias BaileysEx.Connection.Coordinator
  alias BaileysEx.Connection.EventEmitter
  alias BaileysEx.Connection.RuntimeRef
  alias BaileysEx.Connection.Socket
  alias BaileysEx.Connection.Store
  alias BaileysEx.Signal.Store, as: SignalStore
  alias BaileysEx.Signal.Store.Memory, as: SignalStoreMemory
  alias BaileysEx.Telemetry

  @doc """
  Start the supervisor and its subtree of runtime connection processes.
  """
  @spec start_link(keyword()) :: Elixir.Supervisor.on_start()
  def start_link(opts) when is_list(opts) do
    {start_opts, init_opts} = split_start_opts(opts)
    Elixir.Supervisor.start_link(__MODULE__, init_opts, start_opts)
  end

  @doc "Return a host-supervisor child specification for one connection runtime."
  @spec child_spec(keyword()) :: Elixir.Supervisor.child_spec()
  def child_spec(opts) when is_list(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :transient,
      shutdown: :infinity
    }
  end

  @doc "Start a connection runtime from an auth state payload."
  @spec start_connection(term(), keyword()) :: Elixir.Supervisor.on_start()
  def start_connection(auth_state, opts \\ []) when is_list(opts) do
    Telemetry.span([:connection, :start], connection_start_metadata(opts), fn ->
      start_link(Keyword.put(opts, :auth_state, auth_state))
    end)
  end

  @doc "Stop a running connection runtime."
  @spec stop_connection(GenServer.server()) :: :ok | {:error, term()}
  def stop_connection(supervisor) do
    pid = resolve_pid(supervisor)

    Telemetry.span([:connection, :stop], %{connection_pid: pid}, fn ->
      case pid do
        pid when is_pid(pid) ->
          Elixir.Supervisor.stop(pid)

        _ ->
          {:error, :not_found}
      end
    end)
  end

  @doc """
  Safely returns the child specifications for the active connection supervisor subtree.
  """
  @spec which_children(GenServer.server()) ::
          [
            {term(), :restarting | :undefined | pid(), :supervisor | :worker,
             :dynamic | [module()]}
          ]
  def which_children(supervisor) do
    case resolve_pid(supervisor) do
      pid when is_pid(pid) ->
        try do
          Elixir.Supervisor.which_children(pid)
        catch
          :exit, _reason -> []
        end

      _ ->
        []
    end
  end

  @doc "Return a child pid by supervisor child id."
  @spec child_pid(GenServer.server(), term()) :: pid() | nil
  def child_pid(supervisor, child_id) do
    supervisor
    |> which_children()
    |> Enum.find_value(fn
      {^child_id, pid, _type, _modules} when is_pid(pid) -> pid
      _ -> nil
    end)
  end

  @doc "Return the coordinator pid when present."
  @spec coordinator(GenServer.server()) :: pid() | nil
  def coordinator(supervisor), do: child_pid(supervisor, Coordinator)

  @doc "Return the event emitter pid when present."
  @spec event_emitter(GenServer.server()) :: pid() | nil
  def event_emitter(supervisor), do: child_pid(supervisor, EventEmitter)

  @doc "Return the connection store pid when present."
  @spec store(GenServer.server()) :: pid() | nil
  def store(supervisor), do: child_pid(supervisor, Store)

  @doc false
  @spec task_supervisor(GenServer.server()) :: pid() | nil
  def task_supervisor(supervisor), do: child_pid(supervisor, Task.Supervisor)

  @doc "Return the `{socket_module, socket_pid}` transport tuple used by feature helpers."
  @spec queryable(GenServer.server()) :: {module(), pid()} | nil
  def queryable(supervisor) do
    supervisor
    |> which_children()
    |> Enum.find_value(fn
      {id, pid, _type, modules} when is_pid(pid) ->
        module =
          [id | List.wrap(modules)]
          |> Enum.find(&socket_module?/1)

        if is_atom(module) and not is_nil(module), do: {module, pid}

      _ ->
        nil
    end)
  end

  @doc "Return the wrapped Signal store for the connection when present."
  @spec signal_store(GenServer.server()) :: BaileysEx.Signal.Store.t() | nil
  def signal_store(supervisor) do
    supervisor
    |> which_children()
    |> Enum.find_value(fn
      {id, pid, _type, modules} when is_pid(pid) ->
        module =
          [id | List.wrap(modules)]
          |> Enum.find(&signal_store_module?/1)

        if is_atom(module) and not is_nil(module), do: SignalStore.wrap_running({module, pid})

      _ ->
        nil
    end)
  end

  @doc "Request a pairing code through the active socket."
  @spec request_pairing_code(GenServer.server(), binary(), keyword()) ::
          {:ok, binary()} | {:error, term()}
  def request_pairing_code(supervisor, phone_number, opts \\ [])
      when is_binary(phone_number) and is_list(opts) do
    case queryable(supervisor) do
      {socket_module, socket_pid} ->
        socket_module.request_pairing_code(
          socket_pid,
          phone_number,
          Keyword.take(opts, [:custom_pairing_code])
        )

      nil ->
        {:error, :socket_not_available}
    end
  end

  @doc "Subscribe to raw event maps emitted by the connection runtime."
  @spec subscribe(GenServer.server(), (map() -> term())) ::
          (-> :ok) | {:error, :event_emitter_not_available}
  def subscribe(supervisor, handler) when is_function(handler, 1) do
    case event_emitter(supervisor) do
      pid when is_pid(pid) ->
        try do
          EventEmitter.process(pid, handler)
        catch
          :exit, _reason -> {:error, :event_emitter_not_available}
        end

      _ ->
        {:error, :event_emitter_not_available}
    end
  end

  @doc "Send a message through the coordinator-managed send pipeline."
  @spec send_message(GenServer.server(), BaileysEx.JID.t(), map() | struct(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def send_message(supervisor, jid, content, opts \\ []) when is_list(opts) do
    case coordinator(supervisor) do
      pid when is_pid(pid) -> Coordinator.send_message(pid, jid, content, opts)
      _ -> {:error, :coordinator_not_available}
    end
  end

  @doc "Send a status message through the coordinator-managed send pipeline."
  @spec send_status(GenServer.server(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def send_status(supervisor, content, opts \\ []) when is_map(content) and is_list(opts) do
    case coordinator(supervisor) do
      pid when is_pid(pid) -> Coordinator.send_status(pid, content, opts)
      _ -> {:error, :coordinator_not_available}
    end
  end

  @doc "Request the phone to resend a placeholder message through the peer-data pipeline."
  @spec request_placeholder_resend(GenServer.server(), map(), map() | nil, keyword()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def request_placeholder_resend(supervisor, message_key, msg_data \\ nil, opts \\ [])
      when is_map(message_key) and (is_map(msg_data) or is_nil(msg_data)) and is_list(opts) do
    case coordinator(supervisor) do
      pid when is_pid(pid) ->
        Coordinator.request_placeholder_resend(pid, message_key, msg_data, opts)

      _ ->
        {:error, :coordinator_not_available}
    end
  end

  @doc "Send an ACK/NACK through the coordinator-managed socket."
  @spec send_message_ack(GenServer.server(), BaileysEx.BinaryNode.t(), non_neg_integer() | nil) ::
          :ok | {:error, term()}
  def send_message_ack(supervisor, %BaileysEx.BinaryNode{} = node, error_code \\ nil) do
    case coordinator(supervisor) do
      pid when is_pid(pid) -> Coordinator.send_message_ack(pid, node, error_code)
      _ -> {:error, :coordinator_not_available}
    end
  end

  @doc "Send a failed-decryption retry request through the coordinator-managed socket."
  @spec send_retry_request(GenServer.server(), BaileysEx.BinaryNode.t(), keyword()) ::
          :ok | {:error, term()}
  def send_retry_request(supervisor, %BaileysEx.BinaryNode{} = node, opts \\ [])
      when is_list(opts) do
    case coordinator(supervisor) do
      pid when is_pid(pid) -> Coordinator.send_retry_request(pid, node, opts)
      _ -> {:error, :coordinator_not_available}
    end
  end

  @doc false
  @spec message_retry_manager_available?(GenServer.server()) :: :ok | {:error, term()}
  def message_retry_manager_available?(supervisor) do
    case coordinator(supervisor) do
      pid when is_pid(pid) -> Coordinator.message_retry_manager_available?(pid)
      _ -> {:error, :coordinator_not_available}
    end
  end

  @doc false
  @spec message_retry_operation(GenServer.server(), tuple() | :clear) ::
          {:ok, term()} | {:error, term()}
  def message_retry_operation(supervisor, operation)
      when is_tuple(operation) or operation == :clear do
    case coordinator(supervisor) do
      pid when is_pid(pid) -> Coordinator.message_retry_operation(pid, operation)
      _ -> {:error, :coordinator_not_available}
    end
  end

  @doc "Send a WAM analytics buffer through the active socket."
  @spec send_wam_buffer(GenServer.server(), binary()) ::
          {:ok, BaileysEx.BinaryNode.t()} | {:error, term()}
  def send_wam_buffer(supervisor, wam_buffer) when is_binary(wam_buffer) do
    case queryable(supervisor) do
      {socket_module, socket_pid} ->
        socket_module.send_wam_buffer(socket_pid, wam_buffer)

      nil ->
        {:error, :socket_not_available}
    end
  end

  @impl true
  def init(opts) do
    supervisor = self()
    runtime_refs = RuntimeRef.new()
    config = Keyword.get(opts, :config, Config.new())
    socket_module = Keyword.get(opts, :socket_module, Socket)
    signal_store_module = Keyword.get(opts, :signal_store_module, SignalStoreMemory)
    signal_store_opts = Keyword.get(opts, :signal_store_opts, [])
    event_emitter = runtime_resolver(runtime_refs, EventEmitter)
    store = runtime_resolver(runtime_refs, Store)
    task_supervisor = runtime_resolver(runtime_refs, Task.Supervisor)

    signal_store = fn ->
      signal_store_module
      |> then(&{&1, RuntimeRef.fetch(runtime_refs, &1)})
      |> SignalStore.wrap_running()
    end

    socket_opts =
      opts
      |> Keyword.drop([
        :name,
        :socket_module,
        :signal_store_module,
        :signal_store_opts,
        :initial_event_subscribers,
        :max_dispatch_queue,
        :max_send_queue
      ])
      |> Keyword.put(:config, config)
      |> Keyword.put_new(:event_emitter, event_emitter)
      |> Keyword.put_new(:signal_store, signal_store)
      |> Keyword.put_new(:task_supervisor, task_supervisor)

    children =
      [
        Elixir.Supervisor.child_spec(
          {EventEmitter,
           [
             initial_subscribers: Keyword.get(opts, :initial_event_subscribers, []),
             max_dispatch_queue: Keyword.get(opts, :max_dispatch_queue, 1_024)
           ]},
          id: EventEmitter
        ),
        Elixir.Supervisor.child_spec({Store, [auth_state: opts[:auth_state]]},
          id: Store
        ),
        Elixir.Supervisor.child_spec(
          {signal_store_module, signal_store_opts},
          id: signal_store_module
        ),
        Elixir.Supervisor.child_spec(Task.Supervisor,
          id: Task.Supervisor
        ),
        Elixir.Supervisor.child_spec({socket_module, socket_opts}, id: socket_module),
        Elixir.Supervisor.child_spec(
          {Coordinator,
           [
             config: config,
             supervisor: supervisor,
             event_emitter: event_emitter,
             store: store,
             signal_store: signal_store,
             signal_repository: Keyword.get(opts, :signal_repository),
             signal_repository_adapter: Keyword.get(opts, :signal_repository_adapter),
             signal_repository_adapter_state: Keyword.get(opts, :signal_repository_adapter_state),
             history_sync_download_fun: Keyword.get(opts, :history_sync_download_fun),
             history_sync_inflate_fun: Keyword.get(opts, :history_sync_inflate_fun),
             get_message_fun: Keyword.get(opts, :get_message_fun),
             handle_encrypt_notification_fun: Keyword.get(opts, :handle_encrypt_notification_fun),
             device_notification_fun: Keyword.get(opts, :device_notification_fun),
             resync_app_state_fun: Keyword.get(opts, :resync_app_state_fun),
             max_send_queue: Keyword.get(opts, :max_send_queue, 256),
             socket_module: socket_module,
             task_supervisor: task_supervisor
           ]},
          id: Coordinator
        )
      ]
      |> Enum.map(&RuntimeRef.child_spec(&1, runtime_refs))

    Elixir.Supervisor.init(children, strategy: :rest_for_one)
  end

  defp split_start_opts(opts) do
    case Keyword.fetch(opts, :name) do
      {:ok, name} ->
        if valid_name?(name) do
          {[name: name], opts}
        else
          {[], opts}
        end

      _ ->
        {[], opts}
    end
  end

  defp runtime_resolver(runtime_refs, child_id) do
    fn -> RuntimeRef.fetch(runtime_refs, child_id) end
  end

  defp valid_name?(name) when is_atom(name), do: true
  defp valid_name?({:global, _}), do: true
  defp valid_name?({:via, _, _}), do: true
  defp valid_name?(_name), do: false

  defp connection_start_metadata(opts) do
    %{connection_name: opts[:name]}
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp resolve_pid(server) when is_pid(server), do: server

  defp resolve_pid(server) do
    GenServer.whereis(server)
  end

  defp socket_module?(module) when is_atom(module) do
    function_exported?(module, :query, 3) and function_exported?(module, :send_node, 2) and
      function_exported?(module, :connect, 1)
  end

  defp socket_module?(_module), do: false

  defp signal_store_module?(module) when module in [Store, EventEmitter, Coordinator, Socket],
    do: false

  defp signal_store_module?(module) when is_atom(module) do
    function_exported?(module, :wrap, 1) and function_exported?(module, :get, 3) and
      function_exported?(module, :set, 2)
  end

  defp signal_store_module?(_module), do: false
end
