defmodule BaileysEx.Connection.SupervisorTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias BaileysEx.BinaryNode
  alias BaileysEx.Connection.Config
  alias BaileysEx.Connection.EventEmitter
  alias BaileysEx.Connection.Socket
  alias BaileysEx.Connection.Store
  alias BaileysEx.Connection.Supervisor
  alias BaileysEx.Message.Builder
  alias BaileysEx.Protocol.Proto.Message
  alias BaileysEx.TestHelpers.MessageSignalHelpers
  alias BaileysEx.TestHelpers.TelemetryHelpers

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

  defmodule FakeSocket do
    use GenServer

    alias BaileysEx.BinaryNode

    @spec start_link(keyword()) :: GenServer.on_start()
    def start_link(opts) do
      genserver_opts =
        case Keyword.fetch(opts, :name) do
          {:ok, name} -> [name: name]
          :error -> []
        end

      GenServer.start_link(__MODULE__, opts, genserver_opts)
    end

    @spec child_spec(keyword()) :: Supervisor.child_spec()
    def child_spec(opts) do
      %{
        id: __MODULE__,
        start: {__MODULE__, :start_link, [opts]},
        type: :worker,
        restart: :permanent,
        shutdown: 5_000
      }
    end

    def connect(server), do: GenServer.call(server, :connect)

    def send_presence_update(server, type),
      do: GenServer.call(server, {:send_presence_update, type})

    def query(server, %BinaryNode{} = node, timeout),
      do: GenServer.call(server, {:query, node, timeout}, timeout + 100)

    def send_node(server, %BinaryNode{} = node), do: GenServer.call(server, {:send_node, node})

    @impl true
    def init(opts) do
      {:ok,
       %{
         test_pid: Keyword.fetch!(opts, :test_pid),
         query_handler:
           Keyword.get(opts, :query_handler, fn _node, _timeout -> {:error, :unhandled} end)
       }}
    end

    @impl true
    def handle_call(:connect, _from, state) do
      Kernel.send(state.test_pid, :fake_socket_connect)
      {:reply, :ok, state}
    end

    def handle_call({:send_presence_update, type}, _from, state) do
      Kernel.send(state.test_pid, {:fake_socket_presence_update, type})
      {:reply, :ok, state}
    end

    def handle_call({:query, node, timeout}, _from, state) do
      Kernel.send(state.test_pid, {:fake_socket_query, node, timeout})
      {:reply, state.query_handler.(node, timeout), state}
    end

    def handle_call({:send_node, node}, _from, state) do
      Kernel.send(state.test_pid, {:fake_socket_send_node, node})
      {:reply, :ok, state}
    end
  end

  defmodule OneShotVia do
    def register_name({registry, key}, pid) do
      Agent.update(registry, &Map.put(&1, key, %{pid: pid, whereis_calls: 0}))
      :yes
    end

    def unregister_name({registry, key}) do
      Agent.update(registry, &Map.delete(&1, key))
      :ok
    end

    def whereis_name({registry, key}) do
      Agent.get_and_update(registry, fn state ->
        case Map.get(state, key) do
          %{pid: pid, whereis_calls: 0} = entry ->
            {pid, Map.put(state, key, %{entry | whereis_calls: 1})}

          %{whereis_calls: _count} ->
            {:undefined, state}

          nil ->
            {:undefined, state}
        end
      end)
    end

    def send({registry, key}, message) do
      case Agent.get(registry, &Map.get(&1, key)) do
        %{pid: pid} when is_pid(pid) ->
          Kernel.send(pid, message)
          pid

        _ ->
          :undefined
      end
    end
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

  test "start_connection/2 and stop_connection/1 emit connection telemetry" do
    telemetry_id =
      TelemetryHelpers.attach_events(self(), [
        [:baileys_ex, :connection, :start, :start],
        [:baileys_ex, :connection, :start, :stop],
        [:baileys_ex, :connection, :stop, :start],
        [:baileys_ex, :connection, :stop, :stop]
      ])

    on_exit(fn -> TelemetryHelpers.detach(telemetry_id) end)

    assert {:ok, supervisor} =
             Supervisor.start_connection(%{creds: %{}},
               config: Config.new(fire_init_queries: false),
               transport: {NoopTransport, %{}}
             )

    assert_receive {:telemetry, [:baileys_ex, :connection, :start, :start],
                    %{system_time: start_time}, _metadata}

    assert is_integer(start_time)

    assert_receive {:telemetry, [:baileys_ex, :connection, :start, :stop], %{duration: duration},
                    %{status: :ok}}

    assert is_integer(duration)

    assert :ok = Supervisor.stop_connection(supervisor)

    assert_receive {:telemetry, [:baileys_ex, :connection, :stop, :start],
                    %{system_time: stop_time}, %{connection_pid: ^supervisor}}

    assert is_integer(stop_time)

    assert_receive {:telemetry, [:baileys_ex, :connection, :stop, :stop],
                    %{duration: stop_duration}, %{connection_pid: ^supervisor, status: :ok}}

    assert is_integer(stop_duration)
  end

  test "stop_connection/1 resolves a named supervisor once before stopping it" do
    telemetry_id =
      TelemetryHelpers.attach_events(self(), [
        [:baileys_ex, :connection, :stop, :start],
        [:baileys_ex, :connection, :stop, :stop]
      ])

    on_exit(fn -> TelemetryHelpers.detach(telemetry_id) end)

    {:ok, registry} = Agent.start_link(fn -> %{} end)
    via_name = {:via, OneShotVia, {registry, :phase12_stop}}

    assert {:ok, supervisor} =
             Supervisor.start_connection(%{creds: %{}},
               name: via_name,
               config: Config.new(fire_init_queries: false),
               transport: {NoopTransport, %{}}
             )

    on_exit(fn ->
      if Process.alive?(supervisor) do
        Elixir.Supervisor.stop(supervisor)
      end
    end)

    assert :ok = Supervisor.stop_connection(via_name)

    assert_receive {:telemetry, [:baileys_ex, :connection, :stop, :start],
                    %{system_time: _system_time}, %{connection_pid: ^supervisor}}

    assert_receive {:telemetry, [:baileys_ex, :connection, :stop, :stop], %{duration: _duration},
                    %{connection_pid: ^supervisor, status: :ok}}
  end

  test "start_connection/2 injects a default config into the coordinator when none is supplied" do
    assert {:ok, supervisor} =
             Supervisor.start_connection(%{creds: %{}},
               socket_module: FakeSocket,
               test_pid: self()
             )

    assert_receive :fake_socket_connect

    coordinator = Supervisor.coordinator(supervisor)
    assert %Config{} = :sys.get_state(coordinator).config

    assert :ok = Supervisor.stop_connection(supervisor)
  end

  test "coordinator logs unsupported requests" do
    assert {:ok, supervisor} =
             Supervisor.start_link(
               config: Config.new(fire_init_queries: false),
               auth_state: %{creds: %{}},
               transport: {NoopTransport, %{}}
             )

    coordinator_pid = child_pid!(supervisor, BaileysEx.Connection.Coordinator)

    log =
      capture_log(fn ->
        assert {:error, :unsupported_request} = GenServer.call(coordinator_pid, :unsupported)
      end)

    assert log =~ "unsupported coordinator request"
    assert log =~ ":unsupported"

    assert :ok = Supervisor.stop_connection(supervisor)
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

  test "supervisor does not auto-reconnect by default after an unexpected close" do
    telemetry_id =
      TelemetryHelpers.attach_events(self(), [
        [:baileys_ex, :connection, :reconnect]
      ])

    on_exit(fn -> TelemetryHelpers.detach(telemetry_id) end)

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

    refute_receive {:telemetry, [:baileys_ex, :connection, :reconnect], _, _}, 50
    refute_receive :transport_connected_attempt, 200
  end

  test "supervisor does not reconnect for non-restart closes under restart-required policy" do
    name = {:phase6_test, System.unique_integer([:positive])}

    assert {:ok, supervisor} =
             Supervisor.start_link(
               name: name,
               config: Config.new(retry_delay_ms: 10, reconnect_policy: :restart_required),
               auth_state: %{creds: %{}},
               transport: {ReconnectTransport, %{test_pid: self()}}
             )

    assert_receive :transport_connected_attempt

    socket_pid = child_pid!(supervisor, Socket)
    Kernel.send(socket_pid, {:emit_closed, :tcp_closed})

    refute_receive :transport_connected_attempt, 50
  end

  test "supervisor reconnects for restart-required when configured" do
    name = {:phase6_test, System.unique_integer([:positive])}

    assert {:ok, supervisor} =
             Supervisor.start_link(
               name: name,
               config: Config.new(retry_delay_ms: 10, reconnect_policy: :restart_required),
               auth_state: %{creds: %{}},
               transport: {ReconnectTransport, %{test_pid: self()}}
             )

    assert_receive :transport_connected_attempt

    socket_pid = child_pid!(supervisor, Socket)
    Kernel.send(socket_pid, {:emit_closed, :restart_required})

    assert_receive :transport_connected_attempt, 200
  end

  test "supervisor enforces max_retries for configured reconnect policy" do
    telemetry_id =
      TelemetryHelpers.attach_events(self(), [
        [:baileys_ex, :connection, :reconnect]
      ])

    on_exit(fn -> TelemetryHelpers.detach(telemetry_id) end)

    name = {:phase6_test, System.unique_integer([:positive])}

    assert {:ok, supervisor} =
             Supervisor.start_link(
               name: name,
               config:
                 Config.new(
                   retry_delay_ms: 10,
                   reconnect_policy: :all_non_logged_out,
                   max_retries: 1
                 ),
               auth_state: %{creds: %{}},
               transport: {ReconnectTransport, %{test_pid: self()}}
             )

    assert_receive :transport_connected_attempt

    socket_pid = child_pid!(supervisor, Socket)
    Kernel.send(socket_pid, {:emit_closed, :tcp_closed})

    assert_receive {:telemetry, [:baileys_ex, :connection, :reconnect], %{count: 1},
                    %{
                      reason: :tcp_closed,
                      retry_delay_ms: 10,
                      attempt: 1,
                      max_retries: 1,
                      reconnect_policy: :all_non_logged_out
                    }}

    assert_receive :transport_connected_attempt, 200

    socket_pid = child_pid!(supervisor, Socket)
    Kernel.send(socket_pid, {:emit_closed, :tcp_closed})

    refute_receive {:telemetry, [:baileys_ex, :connection, :reconnect], %{count: 1}, _}, 50
    refute_receive :transport_connected_attempt, 200
  end

  test "supervisor does not reconnect after a logged out close" do
    name = {:phase6_test, System.unique_integer([:positive])}

    assert {:ok, supervisor} =
             Supervisor.start_link(
               name: name,
               config: Config.new(retry_delay_ms: 10, reconnect_policy: :all_non_logged_out),
               auth_state: %{creds: %{}},
               transport: {ReconnectTransport, %{test_pid: self()}}
             )

    assert_receive :transport_connected_attempt

    socket_pid = child_pid!(supervisor, Socket)
    Kernel.send(socket_pid, {:emit_closed, :logged_out})

    refute_receive :transport_connected_attempt, 200
  end

  test "supervisor replays cached messages for retry receipts through the runtime" do
    {repo, _signal_store} = MessageSignalHelpers.new_repo()
    session = MessageSignalHelpers.session_fixture()

    assert {:ok, repo} =
             BaileysEx.Signal.Repository.inject_e2e_session(repo, %{
               jid: "15551234567:2@s.whatsapp.net",
               session: session
             })

    assert {:ok, supervisor} =
             Supervisor.start_link(
               config: Config.new(fire_init_queries: false, mark_online_on_connect: false),
               auth_state: %{creds: %{me: %{id: "15550001111:1@s.whatsapp.net"}}},
               socket_module: FakeSocket,
               test_pid: self(),
               signal_repository: repo
             )

    assert_receive :fake_socket_connect

    runtime_store =
      supervisor
      |> child_pid!(Store)
      |> Store.wrap()

    assert :ok =
             BaileysEx.Message.Retry.add_recent_message(
               runtime_store,
               "15551234567@s.whatsapp.net",
               "retry-runtime-1",
               Builder.build(%{text: "retry runtime replay"})
             )

    emitter_pid = child_pid!(supervisor, EventEmitter)

    receipt = %BinaryNode{
      tag: "receipt",
      attrs: %{
        "id" => "retry-runtime-1",
        "from" => "15551234567@s.whatsapp.net",
        "participant" => "15551234567:2@s.whatsapp.net",
        "type" => "retry",
        "count" => "2"
      },
      content: [
        %BinaryNode{
          tag: "retry",
          attrs: %{"count" => "2"},
          content: nil
        }
      ]
    }

    assert :ok = EventEmitter.emit(emitter_pid, :socket_node, %{node: receipt})

    assert_receive {:fake_socket_send_node,
                    %BinaryNode{
                      tag: "message",
                      attrs: %{
                        "id" => "retry-runtime-1",
                        "to" => "15551234567:2@s.whatsapp.net",
                        "device_fanout" => "false"
                      },
                      content: [
                        %BinaryNode{
                          tag: "enc",
                          attrs: %{"count" => "2", "v" => "2"}
                        }
                      ]
                    }}
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

  test "history sync events transition the coordinator through awaiting_initial_sync, syncing, and online" do
    name = {:phase6_test, System.unique_integer([:positive])}

    assert {:ok, supervisor} =
             Supervisor.start_link(
               name: name,
               config: Config.new(initial_sync_timeout_ms: 50),
               auth_state: %{creds: %{}},
               transport: {NoopTransport, %{}}
             )

    emitter_pid = child_pid!(supervisor, EventEmitter)
    coordinator_pid = child_pid!(supervisor, BaileysEx.Connection.Coordinator)

    assert :ok =
             EventEmitter.emit(emitter_pid, :connection_update, %{
               received_pending_notifications: true
             })

    assert_eventually(fn ->
      :sys.get_state(coordinator_pid).sync_state == :awaiting_initial_sync and
        EventEmitter.buffering?(emitter_pid)
    end)

    assert :ok =
             EventEmitter.emit(emitter_pid, :messaging_history_set, %{
               chats: [],
               contacts: [],
               messages: [],
               sync_type: :recent
             })

    assert_eventually(fn -> :sys.get_state(coordinator_pid).sync_state == :syncing end)
    assert_eventually(fn -> :sys.get_state(coordinator_pid).sync_state == :online end)
    assert_eventually(fn -> EventEmitter.buffering?(emitter_pid) == false end)
  end

  test "pending notifications do not wait for history when should_sync_history_message disables RECENT" do
    name = {:phase10_test, System.unique_integer([:positive])}

    assert {:ok, supervisor} =
             Supervisor.start_link(
               name: name,
               config:
                 Config.new(
                   initial_sync_timeout_ms: 5_000,
                   should_sync_history_message: fn
                     %{sync_type: :RECENT} -> false
                     _history_message -> true
                   end
                 ),
               auth_state: %{creds: %{}},
               transport: {NoopTransport, %{}}
             )

    emitter_pid = child_pid!(supervisor, EventEmitter)
    coordinator_pid = child_pid!(supervisor, BaileysEx.Connection.Coordinator)

    assert :ok =
             EventEmitter.emit(emitter_pid, :connection_update, %{
               received_pending_notifications: true
             })

    assert_eventually(fn ->
      :sys.get_state(coordinator_pid).sync_state == :online and
        EventEmitter.buffering?(emitter_pid) == false
    end)
  end

  test "server_sync notifications trigger the built-in app state resync callback" do
    name = {:phase10_test, System.unique_integer([:positive])}

    query_handler = fn
      %BinaryNode{attrs: %{"xmlns" => "w:sync:app:state"}}, _timeout ->
        {:ok,
         %BinaryNode{
           tag: "iq",
           attrs: %{"type" => "result"},
           content: [%BinaryNode{tag: "sync", attrs: %{}, content: []}]
         }}

      _node, _timeout ->
        {:error, :unhandled}
    end

    assert {:ok, supervisor} =
             Supervisor.start_link(
               name: name,
               config: Config.new(fire_init_queries: false, mark_online_on_connect: false),
               auth_state: %{creds: %{me: %{id: "15550001111@s.whatsapp.net"}}},
               socket_module: FakeSocket,
               query_handler: query_handler,
               test_pid: self(),
               transport: {NoopTransport, %{}}
             )

    assert_receive :fake_socket_connect

    emitter_pid = child_pid!(supervisor, EventEmitter)

    notification = %BinaryNode{
      tag: "notification",
      attrs: %{"type" => "server_sync", "from" => "s.whatsapp.net"},
      content: [
        %BinaryNode{tag: "collection", attrs: %{"name" => "regular_high"}, content: nil}
      ]
    }

    assert :ok =
             EventEmitter.emit(emitter_pid, :socket_node, %{node: notification, state: :connected})

    assert_receive {:fake_socket_query,
                    %BinaryNode{
                      attrs: %{"xmlns" => "w:sync:app:state"},
                      content: [
                        %BinaryNode{
                          tag: "sync",
                          content: [
                            %BinaryNode{tag: "collection", attrs: %{"name" => "regular_high"}}
                          ]
                        }
                      ]
                    }, _timeout}
  end

  test "server_sync resync failures do not crash the coordinator" do
    name = {:phase10_test, System.unique_integer([:positive])}

    assert {:ok, supervisor} =
             Supervisor.start_link(
               name: name,
               config: Config.new(fire_init_queries: false, mark_online_on_connect: false),
               auth_state: %{creds: %{me: %{id: "15550001111@s.whatsapp.net"}}},
               socket_module: FakeSocket,
               test_pid: self(),
               resync_app_state_fun: fn "regular_high" -> {:error, :decrypt_failed} end,
               transport: {NoopTransport, %{}}
             )

    assert_receive :fake_socket_connect

    emitter_pid = child_pid!(supervisor, EventEmitter)
    coordinator_pid = child_pid!(supervisor, BaileysEx.Connection.Coordinator)

    notification = %BinaryNode{
      tag: "notification",
      attrs: %{"type" => "server_sync", "from" => "s.whatsapp.net"},
      content: [
        %BinaryNode{tag: "collection", attrs: %{"name" => "regular_high"}, content: nil}
      ]
    }

    _ =
      capture_log(fn ->
        assert :ok =
                 EventEmitter.emit(emitter_pid, :socket_node, %{
                   node: notification,
                   state: :connected
                 })

        assert_eventually(fn -> Process.alive?(coordinator_pid) end)
      end)
  end

  test "app state key arrival while syncing triggers an initial app state resync" do
    name = {:phase10_test, System.unique_integer([:positive])}

    query_handler = fn
      %BinaryNode{attrs: %{"xmlns" => "w:sync:app:state"}}, _timeout ->
        {:ok,
         %BinaryNode{
           tag: "iq",
           attrs: %{"type" => "result"},
           content: [%BinaryNode{tag: "sync", attrs: %{}, content: []}]
         }}

      _node, _timeout ->
        {:error, :unhandled}
    end

    assert {:ok, supervisor} =
             Supervisor.start_link(
               name: name,
               config:
                 Config.new(
                   fire_init_queries: false,
                   mark_online_on_connect: false,
                   initial_sync_timeout_ms: 50
                 ),
               auth_state: %{creds: %{me: %{id: "15550001111@s.whatsapp.net"}}},
               socket_module: FakeSocket,
               query_handler: query_handler,
               test_pid: self(),
               transport: {NoopTransport, %{}}
             )

    assert_receive :fake_socket_connect

    emitter_pid = child_pid!(supervisor, EventEmitter)
    coordinator_pid = child_pid!(supervisor, BaileysEx.Connection.Coordinator)

    assert :ok =
             EventEmitter.emit(emitter_pid, :connection_update, %{
               received_pending_notifications: true
             })

    assert_eventually(fn ->
      :sys.get_state(coordinator_pid).sync_state == :awaiting_initial_sync
    end)

    assert :ok =
             EventEmitter.emit(emitter_pid, :messaging_history_set, %{
               chats: [%{id: "chat-1", conversation_timestamp: 1_710_000_000}],
               contacts: [],
               messages: [],
               sync_type: :recent
             })

    assert_eventually(fn -> :sys.get_state(coordinator_pid).sync_state == :syncing end)

    assert :ok =
             EventEmitter.emit(emitter_pid, :creds_update, %{my_app_state_key_id: "AQIDBA=="})

    assert_receive {:fake_socket_query,
                    %BinaryNode{
                      attrs: %{"xmlns" => "w:sync:app:state"},
                      content: [
                        %BinaryNode{
                          tag: "sync",
                          content: collections
                        }
                      ]
                    }, _timeout}

    assert Enum.map(collections, & &1.attrs["name"]) ==
             ["critical_block", "critical_unblock_low", "regular_high", "regular_low", "regular"]

    assert_eventually(fn -> :sys.get_state(coordinator_pid).sync_state == :online end)
  end

  test "connection open fires init queries, updates store caches, and marks presence available" do
    name = {:phase6_test, System.unique_integer([:positive])}
    parent = self()

    query_handler = fn
      %BinaryNode{attrs: %{"xmlns" => "w"}, content: [%BinaryNode{tag: "props"}]}, _timeout ->
        {:ok,
         %BinaryNode{
           tag: "iq",
           attrs: %{"type" => "result"},
           content: [
             %BinaryNode{
               tag: "props",
               attrs: %{"hash" => "next-prop-hash"},
               content: [
                 %BinaryNode{
                   tag: "prop",
                   attrs: %{"name" => "web:voip", "value" => "1"},
                   content: nil
                 }
               ]
             }
           ]
         }}

      %BinaryNode{attrs: %{"xmlns" => "blocklist"}}, _timeout ->
        {:ok,
         %BinaryNode{
           tag: "iq",
           attrs: %{"type" => "result"},
           content: [
             %BinaryNode{
               tag: "list",
               attrs: %{},
               content: [
                 %BinaryNode{
                   tag: "item",
                   attrs: %{"jid" => "11111@s.whatsapp.net"},
                   content: nil
                 },
                 %BinaryNode{tag: "item", attrs: %{"jid" => "22222@s.whatsapp.net"}, content: nil}
               ]
             }
           ]
         }}

      %BinaryNode{attrs: %{"xmlns" => "privacy"}}, _timeout ->
        {:ok,
         %BinaryNode{
           tag: "iq",
           attrs: %{"type" => "result"},
           content: [
             %BinaryNode{
               tag: "privacy",
               attrs: %{},
               content: [
                 %BinaryNode{
                   tag: "category",
                   attrs: %{"name" => "last", "value" => "contacts"},
                   content: nil
                 }
               ]
             }
           ]
         }}
    end

    assert {:ok, supervisor} =
             Supervisor.start_link(
               name: name,
               config: Config.new(),
               auth_state: %{creds: %{last_prop_hash: "prev-prop-hash"}},
               socket_module: FakeSocket,
               test_pid: self(),
               query_handler: query_handler,
               transport: {NoopTransport, %{}}
             )

    assert_receive :fake_socket_connect

    emitter_pid = child_pid!(supervisor, EventEmitter)
    store_ref = supervisor |> child_pid!(Store) |> Store.wrap()
    unsubscribe = EventEmitter.process(emitter_pid, &send(parent, {:processed_events, &1}))

    assert :ok = EventEmitter.emit(emitter_pid, :connection_update, %{connection: :open})

    assert_receive {:fake_socket_presence_update, :available}

    assert_receive {:processed_events,
                    %{
                      blocklist_set: %{
                        blocklist: ["11111@s.whatsapp.net", "22222@s.whatsapp.net"]
                      }
                    }}

    assert_eventually_xmlns(["w", "blocklist", "privacy"])

    assert_eventually(fn ->
      Store.get(store_ref, :props) == %{"web:voip" => "1"} and
        Store.get(store_ref, :blocklist) == ["11111@s.whatsapp.net", "22222@s.whatsapp.net"] and
        Store.get(store_ref, :privacy_settings) == %{"last" => "contacts"} and
        Store.get(store_ref, :creds)[:last_prop_hash] == "next-prop-hash"
    end)

    unsubscribe.()
  end

  test "creds updates that change push name send a presence node through the socket" do
    name = {:phase7_test, System.unique_integer([:positive])}

    assert {:ok, supervisor} =
             Supervisor.start_link(
               name: name,
               config: Config.new(fire_init_queries: false, mark_online_on_connect: false),
               auth_state: %{creds: %{me: %{id: "15551234567@s.whatsapp.net", name: "Old"}}},
               socket_module: FakeSocket,
               test_pid: self(),
               transport: {NoopTransport, %{}}
             )

    assert_receive :fake_socket_connect

    emitter_pid = child_pid!(supervisor, EventEmitter)

    assert :ok = EventEmitter.emit(emitter_pid, :creds_update, %{me: %{name: "New"}})

    assert_receive {:fake_socket_send_node,
                    %BinaryNode{tag: "presence", attrs: %{"name" => "New"}}}
  end

  test "account sync dirty updates last_account_sync_timestamp and cleans from the previous timestamp" do
    name = {:phase6_test, System.unique_integer([:positive])}

    assert {:ok, supervisor} =
             Supervisor.start_link(
               name: name,
               config: Config.new(),
               auth_state: %{creds: %{}},
               socket_module: FakeSocket,
               test_pid: self(),
               transport: {NoopTransport, %{}}
             )

    emitter_pid = child_pid!(supervisor, EventEmitter)
    store_ref = supervisor |> child_pid!(Store) |> Store.wrap()
    assert :ok = Store.put(store_ref, :last_account_sync_timestamp, 1_700_000_000)

    assert :ok =
             EventEmitter.emit(emitter_pid, :dirty_update, %{
               type: "account_sync",
               timestamp: 1_710_000_000
             })

    assert_receive {:fake_socket_send_node,
                    %BinaryNode{
                      tag: "iq",
                      attrs: %{"xmlns" => "urn:xmpp:whatsapp:dirty", "type" => "set"},
                      content: [
                        %BinaryNode{
                          tag: "clean",
                          attrs: %{"type" => "account_sync", "timestamp" => "1700000000"}
                        }
                      ]
                    }}

    assert_eventually(fn ->
      Store.get(store_ref, :last_account_sync_timestamp) == 1_710_000_000 and
        Store.get(store_ref, :creds)[:last_account_sync_timestamp] == 1_710_000_000
    end)
  end

  test "community dirty notifications refetch communities, emit groups_update, and clean the groups bucket" do
    name = {:phase6_test, System.unique_integer([:positive])}
    parent = self()

    query_handler = fn
      %BinaryNode{content: [%BinaryNode{tag: "participating"}]}, _timeout ->
        {:ok,
         %BinaryNode{
           tag: "iq",
           attrs: %{"type" => "result"},
           content: [
             %BinaryNode{
               tag: "communities",
               attrs: %{},
               content: [
                 %BinaryNode{
                   tag: "community",
                   attrs: %{
                     "id" => "1234567890",
                     "subject" => "Phase 10 Community",
                     "s_t" => "1710000000",
                     "creation" => "1709999999",
                     "size" => "1"
                   },
                   content: [
                     %BinaryNode{tag: "parent", attrs: %{}},
                     %BinaryNode{
                       tag: "participant",
                       attrs: %{"jid" => "15550001111@s.whatsapp.net"}
                     }
                   ]
                 }
               ]
             }
           ]
         }}

      _node, _timeout ->
        {:error, :unhandled}
    end

    assert {:ok, supervisor} =
             Supervisor.start_link(
               name: name,
               config: Config.new(),
               auth_state: %{creds: %{}},
               socket_module: FakeSocket,
               query_handler: query_handler,
               test_pid: self(),
               transport: {NoopTransport, %{}}
             )

    emitter_pid = child_pid!(supervisor, EventEmitter)
    unsubscribe = EventEmitter.process(emitter_pid, &Kernel.send(parent, {:processed_events, &1}))
    assert_receive :fake_socket_connect

    assert :ok = EventEmitter.emit(emitter_pid, :dirty_update, %{type: "communities"})

    assert_receive {:fake_socket_query,
                    %BinaryNode{
                      tag: "iq",
                      attrs: %{"to" => "@g.us", "type" => "get", "xmlns" => "w:g2"},
                      content: [%BinaryNode{tag: "participating"}]
                    }, 60_000}

    assert_receive {:fake_socket_send_node,
                    %BinaryNode{
                      tag: "iq",
                      attrs: %{"xmlns" => "urn:xmpp:whatsapp:dirty", "type" => "set"},
                      content: [%BinaryNode{tag: "clean", attrs: %{"type" => "groups"}}]
                    }}

    assert_receive {:processed_events,
                    %{
                      groups_update: [
                        %{
                          id: "1234567890@g.us",
                          subject: "Phase 10 Community",
                          is_community: true
                        }
                      ]
                    }}

    assert :ok = unsubscribe.()
  end

  test "lid_mapping_update events are persisted into the signal store" do
    name = {:phase10_test, System.unique_integer([:positive])}

    assert {:ok, supervisor} =
             Supervisor.start_link(
               name: name,
               config: Config.new(fire_init_queries: false, mark_online_on_connect: false),
               auth_state: %{creds: %{}},
               transport: {NoopTransport, %{}}
             )

    emitter_pid = child_pid!(supervisor, EventEmitter)

    signal_store_ref =
      supervisor
      |> child_pid!(BaileysEx.Signal.Store.Memory)
      |> BaileysEx.Signal.Store.Memory.wrap()

    assert :ok =
             EventEmitter.emit(emitter_pid, :lid_mapping_update, %{
               lid: "123456789@lid",
               pn: "15551234567@s.whatsapp.net"
             })

    assert_eventually(fn ->
      BaileysEx.Signal.Store.Memory.get(signal_store_ref, :"lid-mapping", [
        "15551234567",
        "123456789_reverse"
      ]) == %{
        "15551234567" => "123456789",
        "123456789_reverse" => "15551234567"
      }
    end)
  end

  test "group dirty notifications refetch participating groups, emit groups_update, and clean the groups bucket" do
    name = {:phase10_test, System.unique_integer([:positive])}
    parent = self()

    query_handler = fn
      %BinaryNode{content: [%BinaryNode{tag: "participating"}]}, _timeout ->
        {:ok,
         %BinaryNode{
           tag: "iq",
           attrs: %{"type" => "result"},
           content: [
             %BinaryNode{
               tag: "groups",
               attrs: %{},
               content: [
                 %BinaryNode{
                   tag: "group",
                   attrs: %{
                     "id" => "1234567890",
                     "subject" => "Phase 10",
                     "s_t" => "1710000000",
                     "creation" => "1709999999",
                     "size" => "1"
                   },
                   content: [
                     %BinaryNode{
                       tag: "participant",
                       attrs: %{"jid" => "15550001111@s.whatsapp.net"}
                     }
                   ]
                 }
               ]
             }
           ]
         }}

      _node, _timeout ->
        {:error, :unhandled}
    end

    assert {:ok, supervisor} =
             Supervisor.start_link(
               name: name,
               config: Config.new(fire_init_queries: false, mark_online_on_connect: false),
               auth_state: %{creds: %{}},
               socket_module: FakeSocket,
               query_handler: query_handler,
               test_pid: self(),
               transport: {NoopTransport, %{}}
             )

    emitter_pid = child_pid!(supervisor, EventEmitter)
    unsubscribe = EventEmitter.process(emitter_pid, &Kernel.send(parent, {:processed_events, &1}))

    assert :ok = EventEmitter.emit(emitter_pid, :dirty_update, %{type: "groups"})

    assert_receive {:fake_socket_query,
                    %BinaryNode{
                      tag: "iq",
                      attrs: %{"to" => "@g.us", "type" => "get", "xmlns" => "w:g2"},
                      content: [%BinaryNode{tag: "participating"}]
                    }, 60_000}

    assert_receive {:processed_events,
                    %{
                      groups_update: [
                        %{id: "1234567890@g.us", subject: "Phase 10"}
                      ]
                    }}

    assert_receive {:fake_socket_send_node,
                    %BinaryNode{
                      tag: "iq",
                      attrs: %{"xmlns" => "urn:xmpp:whatsapp:dirty", "type" => "set"},
                      content: [%BinaryNode{tag: "clean", attrs: %{"type" => "groups"}}]
                    }}

    assert :ok = unsubscribe.()
  end

  test "socket presence nodes are translated into presence_update events" do
    name = {:phase10_presence_test, System.unique_integer([:positive])}
    parent = self()

    assert {:ok, supervisor} =
             Supervisor.start_link(
               name: name,
               config: Config.new(fire_init_queries: false, mark_online_on_connect: false),
               auth_state: %{creds: %{}},
               transport: {NoopTransport, %{}}
             )

    emitter_pid = child_pid!(supervisor, EventEmitter)
    unsubscribe = EventEmitter.process(emitter_pid, &Kernel.send(parent, {:processed_events, &1}))

    assert :ok =
             EventEmitter.emit(emitter_pid, :socket_node, %{
               node: %BinaryNode{
                 tag: "chatstate",
                 attrs: %{
                   "from" => "120363001234567890@g.us",
                   "participant" => "15557654321@s.whatsapp.net"
                 },
                 content: [
                   %BinaryNode{
                     tag: "composing",
                     attrs: %{"media" => "audio"},
                     content: nil
                   }
                 ]
               }
             })

    assert_receive {:processed_events,
                    %{
                      presence_update: %{
                        id: "120363001234567890@g.us",
                        presences: %{
                          "15557654321@s.whatsapp.net" => %{last_known_presence: :recording}
                        }
                      }
                    }}

    assert :ok = unsubscribe.()
  end

  test "socket_node message events are routed through the receiver and send delivery receipts" do
    name = {:phase8_test, System.unique_integer([:positive])}
    {signal_repository, _signal_store} = MessageSignalHelpers.new_repo()

    assert {:ok, supervisor} =
             Supervisor.start_link(
               name: name,
               config: Config.new(fire_init_queries: false, mark_online_on_connect: false),
               auth_state: %{
                 creds: %{me: %{id: "15550001111@s.whatsapp.net", lid: "15550001111@lid"}}
               },
               socket_module: FakeSocket,
               signal_repository: signal_repository,
               test_pid: self(),
               transport: {NoopTransport, %{}}
             )

    assert_receive :fake_socket_connect

    emitter_pid = child_pid!(supervisor, EventEmitter)
    parent = self()
    unsubscribe = EventEmitter.process(emitter_pid, &send(parent, {:events, &1}))

    message_node = %BinaryNode{
      tag: "message",
      attrs: %{
        "id" => "runtime-msg-1",
        "from" => "15551234567@s.whatsapp.net",
        "t" => "1710000800"
      },
      content: [
        %BinaryNode{
          tag: "plaintext",
          attrs: %{},
          content: Message.encode(Builder.build(%{text: "runtime hello"}))
        }
      ]
    }

    assert :ok =
             EventEmitter.emit(emitter_pid, :socket_node, %{node: message_node, state: :connected})

    assert_receive {:events,
                    %{
                      messages_upsert: %{
                        type: :notify,
                        messages: [%{key: %{id: "runtime-msg-1"}}]
                      }
                    }}

    assert_receive {:fake_socket_send_node,
                    %BinaryNode{
                      tag: "receipt",
                      attrs: %{"to" => "15551234567@s.whatsapp.net", "id" => "runtime-msg-1"}
                    }}

    unsubscribe.()
  end

  test "socket_node receipt, ack, and notification events are routed through the messaging handlers" do
    name = {:phase8_test, System.unique_integer([:positive])}

    assert {:ok, supervisor} =
             Supervisor.start_link(
               name: name,
               config: Config.new(fire_init_queries: false, mark_online_on_connect: false),
               auth_state: %{creds: %{me: %{id: "15550001111@s.whatsapp.net"}}},
               socket_module: FakeSocket,
               test_pid: self(),
               transport: {NoopTransport, %{}}
             )

    assert_receive :fake_socket_connect

    emitter_pid = child_pid!(supervisor, EventEmitter)

    signal_store =
      child_pid!(supervisor, BaileysEx.Signal.Store.Memory)
      |> BaileysEx.Signal.Store.Memory.wrap()

    parent = self()
    unsubscribe = EventEmitter.process(emitter_pid, &send(parent, {:events, &1}))

    receipt_node = %BinaryNode{
      tag: "receipt",
      attrs: %{
        "from" => "15551234567@s.whatsapp.net",
        "id" => "receipt-msg-1",
        "t" => "1710000801"
      },
      content: nil
    }

    ack_node = %BinaryNode{
      tag: "ack",
      attrs: %{
        "class" => "message",
        "from" => "15551234567@s.whatsapp.net",
        "id" => "ack-msg-1",
        "error" => "406"
      },
      content: nil
    }

    picture_notification = %BinaryNode{
      tag: "notification",
      attrs: %{
        "type" => "picture",
        "from" => "12345-67890@g.us",
        "participant" => "15551234567@s.whatsapp.net",
        "t" => "1710000802"
      },
      content: [
        %BinaryNode{
          tag: "set",
          attrs: %{"id" => "pic-1", "author" => "15551234567@s.whatsapp.net"}
        }
      ]
    }

    privacy_token_notification = %BinaryNode{
      tag: "notification",
      attrs: %{"type" => "privacy_token", "from" => "15551234567@s.whatsapp.net"},
      content: [
        %BinaryNode{
          tag: "tokens",
          attrs: %{},
          content: [
            %BinaryNode{
              tag: "token",
              attrs: %{"type" => "trusted_contact", "t" => "1710000803"},
              content: "trusted-token"
            }
          ]
        }
      ]
    }

    assert :ok =
             EventEmitter.emit(emitter_pid, :socket_node, %{node: receipt_node, state: :connected})

    assert :ok =
             EventEmitter.emit(emitter_pid, :socket_node, %{node: ack_node, state: :connected})

    assert :ok =
             EventEmitter.emit(emitter_pid, :socket_node, %{
               node: picture_notification,
               state: :connected
             })

    assert :ok =
             EventEmitter.emit(emitter_pid, :socket_node, %{
               node: privacy_token_notification,
               state: :connected
             })

    assert_receive(
      {:events,
       %{
         messages_update: [
           %{key: %{id: "receipt-msg-1"}, update: %{status: :delivery_ack}}
         ]
       }},
      500
    )

    assert_receive(
      {:events, %{messages_update: [%{key: %{id: "ack-msg-1"}, update: %{status: :ERROR}}]}},
      500
    )

    assert_receive(
      {:events, %{contacts_update: [%{id: "12345-67890@g.us", img_url: :changed}]}},
      500
    )

    assert_receive(
      {:events, %{messages_upsert: %{messages: [%{message_stub_type: :GROUP_CHANGE_ICON}]}}},
      500
    )

    assert_eventually(fn ->
      BaileysEx.Signal.Store.Memory.get(signal_store, :tctoken, ["15551234567@s.whatsapp.net"])[
        "15551234567@s.whatsapp.net"
      ] == %{token: "trusted-token", timestamp: "1710000803"}
    end)

    unsubscribe.()
  end

  test "socket_node call events are routed through call handling and emit call updates" do
    name = {:phase6_test, System.unique_integer([:positive])}
    parent = self()

    assert {:ok, supervisor} =
             Supervisor.start_link(
               name: name,
               config: Config.new(),
               auth_state: %{creds: %{me: %{id: "15550001111@s.whatsapp.net"}}},
               socket_module: FakeSocket,
               test_pid: parent,
               query_handler: fn _node, _timeout ->
                 {:ok, %BinaryNode{tag: "call", attrs: %{"type" => "result"}, content: nil}}
               end,
               transport: {NoopTransport, %{}}
             )

    emitter_pid = child_pid!(supervisor, EventEmitter)
    unsubscribe = EventEmitter.process(emitter_pid, &send(parent, {:events, &1}))

    call_node = %BinaryNode{
      tag: "call",
      attrs: %{"id" => "call-node-1", "from" => "15551234567@s.whatsapp.net", "t" => "1710000000"},
      content: [
        %BinaryNode{
          tag: "offer",
          attrs: %{
            "call-id" => "call-1",
            "from" => "15551234567@s.whatsapp.net",
            "caller_pn" => "15551234567@s.whatsapp.net"
          },
          content: [%BinaryNode{tag: "video", attrs: %{}, content: nil}]
        }
      ]
    }

    assert :ok =
             EventEmitter.emit(emitter_pid, :socket_node, %{node: call_node, state: :connected})

    assert_receive {:events,
                    %{
                      call: [
                        %{
                          id: "call-1",
                          status: :offer,
                          caller_pn: "15551234567@s.whatsapp.net",
                          is_video: true
                        }
                      ]
                    }}

    assert_receive {:fake_socket_send_node,
                    %BinaryNode{
                      tag: "ack",
                      attrs: %{
                        "id" => "call-node-1",
                        "to" => "15551234567@s.whatsapp.net",
                        "class" => "call"
                      }
                    }}

    unsubscribe.()
    Process.exit(supervisor, :shutdown)
  end

  test "encrypt notifications from peers trigger session refresh through the coordinator runtime" do
    name = {:phase8_test, System.unique_integer([:positive])}
    {signal_repository, _signal_store} = MessageSignalHelpers.new_repo()
    session = MessageSignalHelpers.session_fixture()

    assert {:ok, signal_repository} =
             BaileysEx.Signal.Repository.inject_e2e_session(signal_repository, %{
               jid: "15551234567@s.whatsapp.net",
               session: session
             })

    key_bundle_response = fn
      %BinaryNode{
        attrs: %{"xmlns" => "encrypt", "type" => "get"},
        content: [%BinaryNode{tag: "key", content: [%BinaryNode{tag: "user", attrs: user_attrs}]}]
      },
      _timeout ->
        public_key = <<12::256>>

        {:ok,
         %BinaryNode{
           tag: "iq",
           attrs: %{"type" => "result"},
           content: [
             %BinaryNode{
               tag: "list",
               attrs: %{},
               content: [
                 %BinaryNode{
                   tag: "user",
                   attrs: %{"jid" => user_attrs["jid"]},
                   content: [
                     %BinaryNode{
                       tag: "registration",
                       attrs: %{},
                       content: {:binary, <<0, 0, 0, 42>>}
                     },
                     %BinaryNode{
                       tag: "identity",
                       attrs: %{},
                       content: {:binary, public_key}
                     },
                     %BinaryNode{
                       tag: "skey",
                       attrs: %{},
                       content: [
                         %BinaryNode{tag: "id", attrs: %{}, content: {:binary, <<0, 0, 0, 7>>}},
                         %BinaryNode{tag: "value", attrs: %{}, content: {:binary, public_key}},
                         %BinaryNode{
                           tag: "signature",
                           attrs: %{},
                           content: {:binary, :binary.copy(<<13>>, 64)}
                         }
                       ]
                     },
                     %BinaryNode{
                       tag: "key",
                       attrs: %{},
                       content: [
                         %BinaryNode{tag: "id", attrs: %{}, content: {:binary, <<0, 0, 0, 8>>}},
                         %BinaryNode{tag: "value", attrs: %{}, content: {:binary, public_key}}
                       ]
                     }
                   ]
                 }
               ]
             }
           ]
         }}

      _node, _timeout ->
        {:error, :unexpected_query}
    end

    assert {:ok, supervisor} =
             Supervisor.start_link(
               name: name,
               config: Config.new(fire_init_queries: false, mark_online_on_connect: false),
               auth_state: %{creds: %{me: %{id: "15550001111@s.whatsapp.net"}}},
               socket_module: FakeSocket,
               signal_repository: signal_repository,
               test_pid: self(),
               query_handler: key_bundle_response,
               transport: {NoopTransport, %{}}
             )

    assert_receive :fake_socket_connect

    emitter_pid = child_pid!(supervisor, EventEmitter)

    notification = %BinaryNode{
      tag: "notification",
      attrs: %{"type" => "encrypt", "from" => "15551234567@s.whatsapp.net"},
      content: [%BinaryNode{tag: "identity", attrs: %{}, content: nil}]
    }

    assert :ok =
             EventEmitter.emit(emitter_pid, :socket_node, %{node: notification, state: :connected})

    assert_receive {:fake_socket_query,
                    %BinaryNode{
                      attrs: %{"xmlns" => "encrypt", "type" => "get"},
                      content: [
                        %BinaryNode{
                          tag: "key",
                          content: [
                            %BinaryNode{
                              tag: "user",
                              attrs: %{
                                "jid" => "15551234567@s.whatsapp.net",
                                "reason" => "identity"
                              }
                            }
                          ]
                        }
                      ]
                    }, _timeout}
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

  defp assert_eventually_xmlns(expected, attempts \\ 20, seen \\ MapSet.new())

  defp assert_eventually_xmlns(expected, attempts, seen) when attempts > 0 do
    seen = drain_fake_socket_queries(seen)

    if MapSet.equal?(seen, MapSet.new(expected)) do
      assert true
    else
      Process.sleep(10)
      assert_eventually_xmlns(expected, attempts - 1, seen)
    end
  end

  defp assert_eventually_xmlns(expected, 0, seen) do
    flunk(
      "expected query xmlns #{inspect(Enum.sort(expected))}, got #{inspect(seen |> MapSet.to_list() |> Enum.sort())}"
    )
  end

  defp drain_fake_socket_queries(seen) do
    receive do
      {:fake_socket_query, %BinaryNode{attrs: %{"xmlns" => xmlns}}, 60_000} ->
        drain_fake_socket_queries(MapSet.put(seen, xmlns))
    after
      0 ->
        seen
    end
  end
end
