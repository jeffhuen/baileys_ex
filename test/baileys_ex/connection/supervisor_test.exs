defmodule BaileysEx.Connection.SupervisorTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Connection.Config
  alias BaileysEx.Connection.EventEmitter
  alias BaileysEx.Connection.Socket
  alias BaileysEx.Connection.Store
  alias BaileysEx.Connection.Supervisor

  defmodule ReconnectTransport do
    @behaviour BaileysEx.Connection.Transport

    @impl true
    def connect(config, %{test_pid: test_pid} = opts) do
      Kernel.send(test_pid, :transport_connected_attempt)
      {:ok, %{config: config, opts: opts}}
    end

    @impl true
    def handle_info(state, {:emit_closed, reason}), do: {:ok, state, [{:closed, reason}]}
    def handle_info(state, _message), do: {:ok, state, []}

    @impl true
    def disconnect(_transport_state), do: :ok

    @impl true
    def send_binary(state, _payload), do: {:ok, state}
  end

  defmodule NoopTransport do
    @behaviour BaileysEx.Connection.Transport

    @impl true
    def connect(config, opts), do: {:ok, %{config: config, opts: opts}}

    @impl true
    def handle_info(state, _message), do: {:ok, state, []}

    @impl true
    def disconnect(_transport_state), do: :ok

    @impl true
    def send_binary(state, _payload), do: {:ok, state}
  end

  test "starts socket, store, and event emitter under a rest_for_one tree" do
    name = {:phase6_test, System.unique_integer([:positive])}

    assert {:ok, supervisor} =
             Supervisor.start_link(
               name: name,
               config: Config.new(),
               auth_state: %{creds: %{}},
               transport: {NoopTransport, %{}}
             )

    children = Supervisor.which_children(supervisor)
    child_ids = Enum.map(children, &elem(&1, 0))

    assert Socket in child_ids
    assert Store in child_ids
    assert EventEmitter in child_ids
  end

  test "crashing the store restarts the store and event emitter while preserving the socket" do
    name = {:phase6_test, System.unique_integer([:positive])}

    assert {:ok, supervisor} =
             Supervisor.start_link(
               name: name,
               config: Config.new(),
               auth_state: %{creds: %{}},
               transport: {NoopTransport, %{}}
             )

    socket_pid = child_pid!(supervisor, Socket)
    store_pid = child_pid!(supervisor, Store)
    emitter_pid = child_pid!(supervisor, EventEmitter)

    Process.exit(store_pid, :kill)

    assert_eventually(fn -> child_pid!(supervisor, Store) != store_pid end)
    assert_eventually(fn -> child_pid!(supervisor, EventEmitter) != emitter_pid end)
    assert child_pid!(supervisor, Socket) == socket_pid
  end

  test "supervisor auto-connects the socket and reconnects after unexpected close" do
    name = {:phase6_test, System.unique_integer([:positive])}

    assert {:ok, supervisor} =
             Supervisor.start_link(
               name: name,
               config: Config.new(retry_delay_ms: 10),
               auth_state: %{creds: %{}},
               transport: {ReconnectTransport, %{test_pid: self()}}
             )

    assert_receive :transport_connected_attempt

    socket_pid = child_pid!(supervisor, Socket)
    Kernel.send(socket_pid, {:emit_closed, :tcp_closed})

    assert_receive :transport_connected_attempt, 200
  end

  test "supervisor does not reconnect after a logged out close" do
    name = {:phase6_test, System.unique_integer([:positive])}

    assert {:ok, supervisor} =
             Supervisor.start_link(
               name: name,
               config: Config.new(retry_delay_ms: 10),
               auth_state: %{creds: %{}},
               transport: {ReconnectTransport, %{test_pid: self()}}
             )

    assert_receive :transport_connected_attempt

    socket_pid = child_pid!(supervisor, Socket)
    Kernel.send(socket_pid, {:emit_closed, :logged_out})

    refute_receive :transport_connected_attempt, 200
  end

  test "supervisor persists creds updates into the store" do
    name = {:phase6_test, System.unique_integer([:positive])}

    assert {:ok, supervisor} =
             Supervisor.start_link(
               name: name,
               config: Config.new(),
               auth_state: %{creds: %{me: %{id: "15551234567@s.whatsapp.net"}}},
               transport: {NoopTransport, %{}}
             )

    emitter_pid = child_pid!(supervisor, EventEmitter)
    store_ref = supervisor |> child_pid!(Store) |> Store.wrap()

    assert :ok =
             EventEmitter.emit(emitter_pid, :creds_update, %{
               routing_info: <<1, 2, 3>>,
               me: %{lid: "12345678901234@lid"}
             })

    assert_eventually(fn ->
      Store.get(store_ref, :creds) == %{
        me: %{id: "15551234567@s.whatsapp.net", lid: "12345678901234@lid"},
        routing_info: <<1, 2, 3>>
      }
    end)
  end

  test "supervisor buffers pending notifications and flushes after the initial sync timeout" do
    name = {:phase6_test, System.unique_integer([:positive])}

    assert {:ok, supervisor} =
             Supervisor.start_link(
               name: name,
               config: Config.new(initial_sync_timeout_ms: 20),
               auth_state: %{creds: %{}},
               transport: {NoopTransport, %{}}
             )

    emitter_pid = child_pid!(supervisor, EventEmitter)
    assert false == EventEmitter.buffering?(emitter_pid)

    assert :ok =
             EventEmitter.emit(emitter_pid, :connection_update, %{
               received_pending_notifications: true
             })

    assert_eventually(fn -> EventEmitter.buffering?(emitter_pid) end)
    assert_eventually(fn -> EventEmitter.buffering?(emitter_pid) == false end)
  end

  defp child_pid!(supervisor, child_id) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {^child_id, pid, _type, _modules} when is_pid(pid) -> pid
      _ -> nil
    end)
    |> case do
      nil -> flunk("child #{inspect(child_id)} not found")
      pid -> pid
    end
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      assert true
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition was not met in time")
end
