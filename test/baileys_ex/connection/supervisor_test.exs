defmodule BaileysEx.Connection.SupervisorTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias BaileysEx.BinaryNode
  alias BaileysEx.Connection.Config
  alias BaileysEx.Connection.Coordinator
  alias BaileysEx.Connection.EventEmitter
  alias BaileysEx.Connection.Socket
  alias BaileysEx.Connection.Store
  alias BaileysEx.Connection.Supervisor
  alias BaileysEx.Crypto
  alias BaileysEx.Message.Builder
  alias BaileysEx.Message.Retry
  alias BaileysEx.Message.Wire
  alias BaileysEx.Protocol.BinaryNode, as: BinaryNodeUtil
  alias BaileysEx.Protocol.Proto.Message
  alias BaileysEx.Signal.Adapter.Signal, as: SignalAdapter
  alias BaileysEx.Signal.Curve
  alias BaileysEx.Signal.LIDMappingStore
  alias BaileysEx.Signal.Repository
  alias BaileysEx.Signal.Store, as: SignalStore
  alias BaileysEx.Signal.Store.Memory, as: SignalStoreMemory
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

    def received_pending_notifications?(server),
      do: GenServer.call(server, :received_pending_notifications?)

    def send_presence_update(server, type),
      do: GenServer.call(server, {:send_presence_update, type})

    def send_unified_session(server), do: GenServer.call(server, :send_unified_session)

    def query(server, %BinaryNode{} = node, timeout),
      do: GenServer.call(server, {:query, node, timeout}, timeout + 100)

    def start_query(server, %BinaryNode{} = node, timeout),
      do: GenServer.call(server, {:start_query, self(), node, timeout}, timeout + 100)

    def start_query(server, reply_to, %BinaryNode{} = node, timeout),
      do: GenServer.call(server, {:start_query, reply_to, node, timeout}, timeout + 100)

    def send_node(server, %BinaryNode{} = node), do: GenServer.call(server, {:send_node, node})

    @impl true
    def init(opts) do
      {:ok,
       %{
         test_pid: Keyword.fetch!(opts, :test_pid),
         connect_handler: Keyword.get(opts, :connect_handler, fn -> :ok end),
         offline_received_handler: Keyword.get(opts, :offline_received_handler, fn -> nil end),
         query_handler:
           Keyword.get(opts, :query_handler, fn _node, _timeout -> {:error, :unhandled} end),
         send_node_handler: Keyword.get(opts, :send_node_handler, fn _node -> :ok end)
       }}
    end

    @impl true
    def handle_call(:connect, _from, state) do
      Kernel.send(state.test_pid, :fake_socket_connect)
      {:reply, state.connect_handler.(), state}
    end

    def handle_call(:received_pending_notifications?, _from, state) do
      {:reply, state.offline_received_handler.(), state}
    end

    def handle_call({:send_presence_update, type}, _from, state) do
      Kernel.send(state.test_pid, {:fake_socket_presence_update, type})
      {:reply, :ok, state}
    end

    def handle_call(:send_unified_session, _from, state) do
      Kernel.send(state.test_pid, :fake_socket_unified_session)
      {:reply, :ok, state}
    end

    def handle_call({:query, node, timeout}, _from, state) do
      Kernel.send(state.test_pid, {:fake_socket_query, node, timeout})
      {:reply, state.query_handler.(node, timeout), state}
    end

    def handle_call({:start_query, caller, node, timeout}, _from, state) do
      ref = make_ref()
      Kernel.send(state.test_pid, {:fake_socket_query, node, timeout})
      Kernel.send(caller, {__MODULE__, ref, state.query_handler.(node, timeout)})
      {:reply, {:ok, ref}, state}
    end

    def handle_call({:send_node, node}, _from, state) do
      Kernel.send(state.test_pid, {:fake_socket_send_node, node})
      {:reply, state.send_node_handler.(node), state}
    end

    @impl true
    def handle_info({:sync_creds_update, creds_update}, state) do
      Kernel.send(state.test_pid, {:fake_socket_sync_creds_update, creds_update})
      {:noreply, state}
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

  defmodule BlockingSignalAdapter do
    @behaviour Repository.Adapter

    alias BaileysEx.TestHelpers.MessageSignalHelpers.FakeAdapter

    @impl true
    defdelegate inject_e2e_session(state, address, session), to: FakeAdapter

    @impl true
    defdelegate validate_session(state, address), to: FakeAdapter

    @impl true
    def decrypt_message(state, address, type, ciphertext) do
      case state do
        %{blocking_decrypt_test_pid: test_pid, blocking_decrypt_gate: gate} ->
          send(test_pid, {:signal_decrypt_started, self()})

          receive do
            {:continue_signal_decrypt, ^gate} -> :ok
          end

          FakeAdapter.decrypt_message(
            Map.drop(state, [:blocking_decrypt_test_pid, :blocking_decrypt_gate]),
            address,
            type,
            ciphertext
          )

        _other ->
          FakeAdapter.decrypt_message(state, address, type, ciphertext)
      end
    end

    @impl true
    defdelegate delete_sessions(state, addresses), to: FakeAdapter

    @impl true
    defdelegate migrate_sessions(state, operations), to: FakeAdapter

    @impl true
    defdelegate encrypt_group_message(state, sender_key_name, plaintext), to: FakeAdapter

    @impl true
    defdelegate process_sender_key_distribution_message(
                  state,
                  sender_key_name,
                  distribution_message
                ),
                to: FakeAdapter

    @impl true
    defdelegate decrypt_group_message(state, sender_key_name, ciphertext), to: FakeAdapter

    @impl true
    def encrypt_message(state, address, plaintext) do
      test_pid = Map.fetch!(state, :blocking_test_pid)
      gate = Map.fetch!(state, :blocking_gate)
      send(test_pid, {:signal_encrypt_started, self()})

      receive do
        {:continue_signal_encrypt, ^gate} -> :ok
      end

      metadata = Map.take(state, [:blocking_test_pid, :blocking_gate])

      case FakeAdapter.encrypt_message(Map.drop(state, Map.keys(metadata)), address, plaintext) do
        {:ok, next_state, result} -> {:ok, Map.merge(next_state, metadata), result}
        other -> other
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
      try do
        Elixir.Supervisor.stop(supervisor)
      catch
        :exit, _reason -> :ok
      end
    end)

    assert :ok = Supervisor.stop_connection(via_name)

    assert_receive {:telemetry, [:baileys_ex, :connection, :stop, :start],
                    %{system_time: _system_time}, %{connection_pid: ^supervisor}}

    assert_receive {:telemetry, [:baileys_ex, :connection, :stop, :stop], %{duration: _duration},
                    %{connection_pid: ^supervisor, status: :ok}}
  end

  test "start_connection/2 connects with the default config when none is supplied" do
    assert {:ok, supervisor} =
             Supervisor.start_connection(%{creds: %{}},
               socket_module: FakeSocket,
               test_pid: self()
             )

    assert_receive :fake_socket_connect

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

  test "crashing the store reconnects the runtime and preserves dynamic subscriptions" do
    name = {:phase6_test, System.unique_integer([:positive])}

    assert {:ok, supervisor} =
             Supervisor.start_link(
               name: name,
               config: Config.new(fire_init_queries: false),
               auth_state: %{creds: %{}},
               socket_module: FakeSocket,
               test_pid: self(),
               transport: {NoopTransport, %{}}
             )

    assert_receive :fake_socket_connect

    store_pid = child_pid!(supervisor, Store)
    emitter_pid = child_pid!(supervisor, EventEmitter)
    parent = self()

    unsubscribe =
      EventEmitter.process(emitter_pid, fn events ->
        send(parent, {:processed_events, events})
      end)

    Process.exit(store_pid, :kill)

    assert_receive :fake_socket_connect, 500

    assert :ok = EventEmitter.emit(emitter_pid, :connection_update, %{marker: :after_restart})
    assert_receive {:processed_events, %{connection_update: %{marker: :after_restart}}}

    unsubscribe.()
    assert :ok = EventEmitter.emit(emitter_pid, :connection_update, %{marker: :after_unsubscribe})
    refute_receive {:processed_events, %{connection_update: %{marker: :after_unsubscribe}}}
  end

  test "crashing the emitter restarts dependent runtime children" do
    assert {:ok, supervisor} =
             Supervisor.start_link(
               config: Config.new(fire_init_queries: false),
               auth_state: %{creds: %{}},
               transport: {NoopTransport, %{}}
             )

    socket_pid = child_pid!(supervisor, Socket)
    store_pid = child_pid!(supervisor, Store)
    emitter_pid = child_pid!(supervisor, EventEmitter)
    coordinator_pid = child_pid!(supervisor, BaileysEx.Connection.Coordinator)
    Process.exit(emitter_pid, :kill)

    assert_eventually(fn -> child_pid!(supervisor, EventEmitter) != emitter_pid end)

    assert_eventually(fn ->
      child_pid!(supervisor, BaileysEx.Connection.Coordinator) != coordinator_pid
    end)

    assert_eventually(fn -> child_pid!(supervisor, Socket) != socket_pid end)
    assert_eventually(fn -> child_pid!(supervisor, Store) != store_pid end)
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

    assert_receive :transport_connected_attempt, 1_000
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

    assert_receive :transport_connected_attempt, 1_000

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
             Repository.inject_e2e_session(repo, %{
               jid: "15551234567:2@s.whatsapp.net",
               session: session
             })

    query_handler = fn
      %BinaryNode{
        attrs: %{"xmlns" => "encrypt", "type" => "get"},
        content: [%BinaryNode{tag: "key", content: [%BinaryNode{tag: "user", attrs: user_attrs}]}]
      },
      _timeout ->
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
                       content: {:binary, session.identity_key}
                     },
                     %BinaryNode{
                       tag: "skey",
                       attrs: %{},
                       content: [
                         %BinaryNode{tag: "id", attrs: %{}, content: {:binary, <<0, 0, 0, 7>>}},
                         %BinaryNode{
                           tag: "value",
                           attrs: %{},
                           content: {:binary, session.signed_pre_key.public_key}
                         },
                         %BinaryNode{
                           tag: "signature",
                           attrs: %{},
                           content: {:binary, session.signed_pre_key.signature}
                         }
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
               config: Config.new(fire_init_queries: false, mark_online_on_connect: false),
               auth_state: %{creds: %{me: %{id: "15550001111:1@s.whatsapp.net"}}},
               socket_module: FakeSocket,
               test_pid: self(),
               query_handler: query_handler,
               signal_repository: repo
             )

    assert_receive :fake_socket_connect

    runtime_store =
      supervisor
      |> child_pid!(Store)
      |> Store.wrap()

    assert :ok =
             Retry.add_recent_message(
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
                                "jid" => "15551234567:2@s.whatsapp.net",
                                "reason" => "identity"
                              }
                            }
                          ]
                        }
                      ]
                    }, _timeout},
                   500

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
                    }},
                   500
  end

  test "failed message decryption sends a retry receipt and unhandled-error ack" do
    {repo, _signal_store} = MessageSignalHelpers.new_repo()

    assert {:ok, supervisor} =
             Supervisor.start_link(
               config:
                 Config.new(
                   fire_init_queries: false,
                   mark_online_on_connect: false
                 ),
               auth_state: %{
                 creds: %{
                   me: %{id: "15550001111:1@s.whatsapp.net"},
                   registration_id: 1_234
                 }
               },
               socket_module: FakeSocket,
               test_pid: self(),
               signal_repository: repo
             )

    assert_receive :fake_socket_connect

    node = %BinaryNode{
      tag: "message",
      attrs: %{
        "id" => "decrypt-failure-1",
        "from" => "15551234567@s.whatsapp.net",
        "participant" => "15551234567:2@s.whatsapp.net",
        "t" => "1710000000"
      },
      content: [
        %BinaryNode{tag: "enc", attrs: %{"type" => "msg"}, content: {:binary, <<1, 2, 3>>}}
      ]
    }

    assert :ok =
             supervisor
             |> child_pid!(EventEmitter)
             |> EventEmitter.emit(:socket_node, %{node: node})

    assert_receive {:fake_socket_send_node,
                    %BinaryNode{
                      tag: "receipt",
                      attrs: %{
                        "id" => "decrypt-failure-1",
                        "to" => "15551234567@s.whatsapp.net",
                        "participant" => "15551234567:2@s.whatsapp.net",
                        "type" => "retry"
                      },
                      content: [
                        %BinaryNode{
                          tag: "retry",
                          attrs: %{
                            "count" => "1",
                            "error" => "0",
                            "id" => "decrypt-failure-1",
                            "t" => "1710000000",
                            "v" => "1"
                          }
                        },
                        %BinaryNode{tag: "registration", content: <<0, 0, 4, 210>>}
                      ]
                    }},
                   1_500

    assert_receive {:fake_socket_send_node,
                    %BinaryNode{
                      tag: "ack",
                      attrs: %{
                        "class" => "message",
                        "error" => "500",
                        "id" => "decrypt-failure-1",
                        "participant" => "15551234567:2@s.whatsapp.net",
                        "to" => "15551234567@s.whatsapp.net"
                      }
                    }},
                   1_500
  end

  test "send_message issues trusted-contact tokens after eligible direct sends" do
    name = {:phase17_test, System.unique_integer([:positive])}
    {repo, _signal_store} = MessageSignalHelpers.new_repo()
    session = MessageSignalHelpers.session_fixture()

    assert {:ok, repo} =
             Repository.inject_e2e_session(repo, %{
               jid: "15551234567:0@s.whatsapp.net",
               session: session
             })

    query_handler = fn
      %BinaryNode{
        attrs: %{"xmlns" => "privacy", "type" => "set"},
        content: [
          %BinaryNode{
            tag: "tokens",
            content: [
              %BinaryNode{
                tag: "token",
                attrs: %{
                  "jid" => "15551234567@s.whatsapp.net",
                  "type" => "trusted_contact"
                }
              }
            ]
          }
        ]
      },
      _timeout ->
        {:ok,
         %BinaryNode{
           tag: "iq",
           attrs: %{"type" => "result"},
           content: [
             %BinaryNode{
               tag: "tokens",
               attrs: %{},
               content: [
                 %BinaryNode{
                   tag: "token",
                   attrs: %{"type" => "trusted_contact", "t" => "1710001000"},
                   content: {:binary, "issued-token"}
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
               signal_repository: repo,
               test_pid: self(),
               query_handler: query_handler,
               transport: {NoopTransport, %{}}
             )

    assert_receive :fake_socket_connect

    assert %SignalStore{} = signal_store = Supervisor.signal_store(supervisor)

    assert :ok =
             SignalStore.set(signal_store, %{
               :"device-list" => %{"15551234567" => ["0"], "15550001111" => []}
             })

    jid = %BaileysEx.JID{user: "15551234567", server: "s.whatsapp.net"}

    assert {:ok, %{id: "3EB0COORDTC"}} =
             Supervisor.send_message(supervisor, jid, %{text: "hello"},
               message_id_fun: fn _me_id -> "3EB0COORDTC" end
             )

    assert_receive {:fake_socket_send_node,
                    %BinaryNode{
                      tag: "message",
                      attrs: %{"id" => "3EB0COORDTC", "to" => "15551234567@s.whatsapp.net"}
                    }},
                   500

    assert_receive {:fake_socket_query,
                    %BinaryNode{
                      attrs: %{"xmlns" => "privacy", "type" => "set"},
                      content: [
                        %BinaryNode{
                          tag: "tokens",
                          content: [
                            %BinaryNode{
                              attrs: %{
                                "jid" => "15551234567@s.whatsapp.net",
                                "type" => "trusted_contact"
                              }
                            }
                          ]
                        }
                      ]
                    }, _timeout},
                   500

    assert_eventually(fn ->
      match?(
        %{
          "15551234567@s.whatsapp.net" => %{
            token: "issued-token",
            timestamp: "1710001000",
            sender_timestamp: sender_timestamp
          }
        }
        when is_integer(sender_timestamp),
        SignalStore.get(signal_store, :tctoken, ["15551234567@s.whatsapp.net"])
      )
    end)
  end

  test "coordinator stays responsive and owns in-flight send tasks" do
    {:ok, signal_store} = SignalStore.new()
    gate = make_ref()

    repo =
      Repository.new(
        adapter: BlockingSignalAdapter,
        adapter_state: %{blocking_test_pid: self(), blocking_gate: gate},
        store: signal_store
      )

    session = MessageSignalHelpers.session_fixture()

    assert {:ok, repo} =
             Repository.inject_e2e_session(repo, %{
               jid: "15551234567:0@s.whatsapp.net",
               session: session
             })

    assert {:ok, supervisor} =
             Supervisor.start_link(
               config: Config.new(fire_init_queries: false, mark_online_on_connect: false),
               auth_state: %{creds: %{me: %{id: "15550001111@s.whatsapp.net"}}},
               socket_module: FakeSocket,
               signal_repository: repo,
               max_send_queue: 1,
               test_pid: self(),
               transport: {NoopTransport, %{}}
             )

    assert_receive :fake_socket_connect

    assert %SignalStore{} = runtime_signal_store = Supervisor.signal_store(supervisor)

    assert :ok =
             SignalStore.set(runtime_signal_store, %{
               :"device-list" => %{"15551234567" => ["0"], "15550001111" => []}
             })

    coordinator = child_pid!(supervisor, BaileysEx.Connection.Coordinator)

    parent = self()

    caller =
      spawn(fn ->
        jid = %BaileysEx.JID{user: "15551234567", server: "s.whatsapp.net"}

        result =
          try do
            Supervisor.send_message(supervisor, jid, %{text: "blocked"})
          catch
            :exit, reason -> {:exit, reason}
          end

        send(parent, {:blocked_send_result, result})
      end)

    caller_ref = Process.monitor(caller)

    assert_receive {:signal_encrypt_started, send_task_pid}
    send_task_ref = Process.monitor(send_task_pid)

    jid = %BaileysEx.JID{user: "15551234567", server: "s.whatsapp.net"}

    assert {:error, :send_queue_full} =
             Supervisor.send_message(supervisor, jid, %{text: "over capacity"})

    emitter = child_pid!(supervisor, EventEmitter)
    assert :ok = EventEmitter.emit(emitter, :connection_update, %{connection: :open})
    assert_receive :fake_socket_unified_session, 100
    assert_receive {:fake_socket_presence_update, presence}, 100
    assert presence in [:available, :unavailable]

    Process.exit(coordinator, :kill)

    assert_receive {:DOWN, ^send_task_ref, :process, ^send_task_pid, _reason}, 500
    assert_receive {:blocked_send_result, _result}, 500
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :normal}, 500
    assert_receive :fake_socket_connect, 500
  end

  test "repository-mutating message work does not delay receipt ACKs or connection events" do
    {:ok, signal_store} = SignalStore.new()
    gate = make_ref()

    base_repo =
      Repository.new(
        adapter: MessageSignalHelpers.FakeAdapter,
        adapter_state: %{},
        store: signal_store
      )

    assert {:ok, base_repo} =
             Repository.inject_e2e_session(base_repo, %{
               jid: "15551234567:0@s.whatsapp.net",
               session: MessageSignalHelpers.session_fixture()
             })

    plaintext = Message.encode(Builder.build(%{text: "blocked inbound"}))

    assert {:ok, base_repo, %{ciphertext: ciphertext}} =
             Repository.encrypt_message(base_repo, %{
               jid: "15551234567:0@s.whatsapp.net",
               data: plaintext
             })

    repository = %{
      base_repo
      | adapter: BlockingSignalAdapter,
        adapter_state:
          Map.merge(base_repo.adapter_state, %{
            blocking_decrypt_test_pid: self(),
            blocking_decrypt_gate: gate
          })
    }

    assert {:ok, supervisor} =
             Supervisor.start_link(
               config: Config.new(fire_init_queries: false, mark_online_on_connect: false),
               auth_state: %{creds: %{me: %{id: "15550001111@s.whatsapp.net"}}},
               socket_module: FakeSocket,
               signal_repository: repository,
               test_pid: self(),
               transport: {NoopTransport, %{}}
             )

    assert_receive :fake_socket_connect
    emitter = child_pid!(supervisor, EventEmitter)

    message_node = %BinaryNode{
      tag: "message",
      attrs: %{
        "id" => "blocked-receive-1",
        "from" => "15551234567@s.whatsapp.net",
        "t" => "1710000800"
      },
      content: [
        %BinaryNode{tag: "enc", attrs: %{"type" => "pkmsg"}, content: {:binary, ciphertext}}
      ]
    }

    assert :ok = EventEmitter.emit(emitter, :socket_node, %{node: message_node})
    assert_receive {:signal_decrypt_started, decrypt_task}

    receipt = %BinaryNode{
      tag: "receipt",
      attrs: %{
        "id" => "unrelated-receipt-1",
        "from" => "15557654321@s.whatsapp.net",
        "t" => "1710000801"
      },
      content: nil
    }

    assert :ok = EventEmitter.emit(emitter, :socket_node, %{node: receipt})
    assert :ok = EventEmitter.emit(emitter, :connection_update, %{connection: :open})

    assert_receive {:fake_socket_send_node,
                    %BinaryNode{
                      tag: "ack",
                      attrs: %{"class" => "receipt", "id" => "unrelated-receipt-1"}
                    }},
                   100

    assert_receive :fake_socket_unified_session, 100
    assert_receive {:fake_socket_presence_update, _presence}, 100

    send(decrypt_task, {:continue_signal_decrypt, gate})

    assert_receive {:fake_socket_send_node,
                    %BinaryNode{
                      tag: "receipt",
                      attrs: %{"id" => "blocked-receive-1"}
                    }},
                   500
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
    parent = self()

    assert {:ok, supervisor} =
             Supervisor.start_link(
               name: name,
               config: Config.new(initial_sync_timeout_ms: 20),
               auth_state: %{creds: %{}},
               transport: {NoopTransport, %{}}
             )

    emitter_pid = child_pid!(supervisor, EventEmitter)
    unsubscribe = EventEmitter.process(emitter_pid, &send(parent, {:processed_events, &1}))

    assert false == EventEmitter.buffering?(emitter_pid)

    assert :ok =
             EventEmitter.emit(emitter_pid, :connection_update, %{
               received_pending_notifications: true
             })

    assert_eventually(fn -> EventEmitter.buffering?(emitter_pid) end)
    assert_eventually(fn -> EventEmitter.buffering?(emitter_pid) == false end)

    assert_receive {:processed_events,
                    %{
                      connection_update: %{
                        sync_state: :online,
                        initial_sync_complete: true,
                        initial_sync_reason: :timeout
                      }
                    }}

    unsubscribe.()
  end

  test "history sync events transition the coordinator through awaiting_initial_sync, syncing, and online" do
    name = {:phase6_test, System.unique_integer([:positive])}
    parent = self()

    assert {:ok, supervisor} =
             Supervisor.start_link(
               name: name,
               config: Config.new(initial_sync_timeout_ms: 50),
               auth_state: %{creds: %{}},
               transport: {NoopTransport, %{}}
             )

    emitter_pid = child_pid!(supervisor, EventEmitter)
    unsubscribe = EventEmitter.process(emitter_pid, &send(parent, {:processed_events, &1}))

    assert :ok =
             EventEmitter.emit(emitter_pid, :connection_update, %{
               received_pending_notifications: true
             })

    assert_eventually(fn -> EventEmitter.buffering?(emitter_pid) end)

    assert :ok =
             EventEmitter.emit(emitter_pid, :messaging_history_set, %{
               chats: [],
               contacts: [],
               messages: [],
               sync_type: :recent
             })

    assert_eventually(fn -> EventEmitter.buffering?(emitter_pid) == false end)

    assert_receive {:processed_events,
                    %{
                      connection_update: %{
                        sync_state: :online,
                        initial_sync_complete: true,
                        initial_sync_reason: :initial_sync_complete
                      }
                    }}

    unsubscribe.()
  end

  test "pending notifications do not wait for history when should_sync_history_message disables RECENT" do
    name = {:phase10_test, System.unique_integer([:positive])}
    parent = self()

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
    unsubscribe = EventEmitter.process(emitter_pid, &send(parent, {:processed_events, &1}))

    assert :ok =
             EventEmitter.emit(emitter_pid, :connection_update, %{
               received_pending_notifications: true
             })

    assert_receive {:processed_events,
                    %{
                      connection_update: %{
                        sync_state: :online,
                        initial_sync_complete: true,
                        initial_sync_reason: :history_sync_disabled
                      }
                    }},
                   500

    refute EventEmitter.buffering?(emitter_pid)
    unsubscribe.()
  end

  test "pending notifications use the Baileys default history-sync callback when config omits one" do
    name = {:phase10_test, System.unique_integer([:positive])}
    parent = self()

    assert {:ok, supervisor} =
             Supervisor.start_link(
               name: name,
               config: %{
                 Config.new(initial_sync_timeout_ms: 50)
                 | should_sync_history_message: nil
               },
               auth_state: %{creds: %{}},
               transport: {NoopTransport, %{}}
             )

    emitter_pid = child_pid!(supervisor, EventEmitter)
    unsubscribe = EventEmitter.process(emitter_pid, &send(parent, {:processed_events, &1}))

    assert :ok =
             EventEmitter.emit(emitter_pid, :connection_update, %{
               received_pending_notifications: true
             })

    assert_eventually(fn -> EventEmitter.buffering?(emitter_pid) end)

    assert_receive {:processed_events,
                    %{
                      connection_update: %{
                        sync_state: :online,
                        initial_sync_complete: true,
                        initial_sync_reason: :timeout
                      }
                    }},
                   500

    unsubscribe.()
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

    assert :ok =
             EventEmitter.emit(emitter_pid, :connection_update, %{
               received_pending_notifications: true
             })

    assert_eventually(fn -> EventEmitter.buffering?(emitter_pid) end)

    assert :ok =
             EventEmitter.emit(emitter_pid, :messaging_history_set, %{
               chats: [%{id: "chat-1", conversation_timestamp: 1_710_000_000}],
               contacts: [],
               messages: [],
               sync_type: :recent
             })

    assert :ok =
             EventEmitter.emit(emitter_pid, :creds_update, %{my_app_state_key_id: "AQIDBA=="})

    # Drain the sync_creds_update forwarded to the fake socket before the query
    assert_receive {:fake_socket_sync_creds_update, _}, 200

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
  end

  test "history sync starts the initial app state resync before the app state key arrives" do
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

    assert :ok =
             EventEmitter.emit(emitter_pid, :connection_update, %{
               received_pending_notifications: true
             })

    assert_eventually(fn -> EventEmitter.buffering?(emitter_pid) end)

    assert :ok =
             EventEmitter.emit(emitter_pid, :messaging_history_set, %{
               chats: [%{id: "chat-1", conversation_timestamp: 1_710_000_000}],
               contacts: [],
               messages: [],
               sync_type: :recent
             })

    assert_receive {:fake_socket_query,
                    %BinaryNode{
                      attrs: %{"xmlns" => "w:sync:app:state"},
                      content: [%BinaryNode{tag: "sync", content: collections}]
                    }, _timeout},
                   500

    assert Enum.map(collections, & &1.attrs["name"]) ==
             ["critical_block", "critical_unblock_low", "regular_high", "regular_low", "regular"]
  end

  test "contacts upserted by the initial app state sync reach on_event subscribers" do
    name = {:phase10_test, System.unique_integer([:positive])}
    test_pid = self()

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
               transport: {NoopTransport, %{}},
               initial_event_subscribers: [fn events -> send(test_pid, {:on_event, events}) end]
             )

    assert_receive :fake_socket_connect
    emitter_pid = child_pid!(supervisor, EventEmitter)

    assert :ok =
             EventEmitter.emit(emitter_pid, :connection_update, %{
               received_pending_notifications: true
             })

    assert_eventually(fn -> EventEmitter.buffering?(emitter_pid) end)

    assert :ok =
             EventEmitter.emit(emitter_pid, :messaging_history_set, %{
               chats: [],
               contacts: [],
               messages: [],
               sync_type: :recent
             })

    contact_count = 300

    EventEmitter.create_buffered_function(emitter_pid, fn ->
      for i <- 1..contact_count do
        assert :ok =
                 EventEmitter.emit(emitter_pid, :contacts_upsert, [
                   %{id: "#{i}@s.whatsapp.net", name: "C#{i}"}
                 ])

        assert :ok =
                 EventEmitter.emit(emitter_pid, :lid_mapping_update, %{
                   lid: "#{i}@lid",
                   pn: "#{i}@s.whatsapp.net"
                 })
      end
    end).()

    upserted =
      collect_upserted_contact_ids(
        contact_count,
        %{},
        System.monotonic_time(:millisecond) + 2_000
      )

    assert map_size(upserted) == contact_count
    assert Enum.all?(1..contact_count, &Map.has_key?(upserted, "#{&1}@s.whatsapp.net"))
  end

  defp collect_upserted_contact_ids(target, seen, _deadline) when map_size(seen) >= target,
    do: seen

  defp collect_upserted_contact_ids(target, seen, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:on_event, events} ->
        next_seen =
          events
          |> Map.get(:contacts_upsert, [])
          |> Enum.reduce(seen, fn contact, acc -> Map.put(acc, contact.id, true) end)

        collect_upserted_contact_ids(target, next_seen, deadline)
    after
      remaining -> seen
    end
  end

  test "app state key arrival does not trigger an initial app state resync before syncing" do
    name = {:phase10_test, System.unique_integer([:positive])}

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
               test_pid: self(),
               transport: {NoopTransport, %{}}
             )

    assert_receive :fake_socket_connect

    emitter_pid = child_pid!(supervisor, EventEmitter)

    assert :ok =
             EventEmitter.emit(emitter_pid, :creds_update, %{my_app_state_key_id: "AQIDBA=="})

    refute_receive {:fake_socket_query, %BinaryNode{attrs: %{"xmlns" => "w:sync:app:state"}},
                    _timeout},
                   50
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

    assert_query_xmlns_sequence(["w", "blocklist", "privacy"])
    assert_receive :fake_socket_unified_session

    assert_eventually(fn ->
      Store.get(store_ref, :props) == %{"web:voip" => "1"} and
        Store.get(store_ref, :blocklist) == ["11111@s.whatsapp.net", "22222@s.whatsapp.net"] and
        Store.get(store_ref, :privacy_settings) == %{"last" => "contacts"} and
        Store.get(store_ref, :creds)[:last_prop_hash] == "next-prop-hash"
    end)

    unsubscribe.()
  end

  test "connection open normalizes nil last_prop_hash to an empty props hash" do
    name = {:phase6_nil_prop_hash_test, System.unique_integer([:positive])}

    query_handler = fn
      %BinaryNode{
        attrs: %{"xmlns" => "w"},
        content: [%BinaryNode{tag: "props", attrs: %{"protocol" => "2", "hash" => ""}}]
      },
      _timeout ->
        {:ok,
         %BinaryNode{
           tag: "iq",
           attrs: %{"type" => "result"},
           content: [%BinaryNode{tag: "props", attrs: %{"hash" => "next-prop-hash"}, content: []}]
         }}

      %BinaryNode{attrs: %{"xmlns" => "blocklist"}}, _timeout ->
        {:ok,
         %BinaryNode{
           tag: "iq",
           attrs: %{"type" => "result"},
           content: [%BinaryNode{tag: "list", attrs: %{}, content: []}]
         }}

      %BinaryNode{attrs: %{"xmlns" => "privacy"}}, _timeout ->
        {:ok,
         %BinaryNode{
           tag: "iq",
           attrs: %{"type" => "result"},
           content: [%BinaryNode{tag: "privacy", attrs: %{}, content: []}]
         }}
    end

    assert {:ok, supervisor} =
             Supervisor.start_link(
               name: name,
               config: Config.new(),
               auth_state: %{creds: %{last_prop_hash: nil}},
               socket_module: FakeSocket,
               test_pid: self(),
               query_handler: query_handler,
               transport: {NoopTransport, %{}}
             )

    assert_receive :fake_socket_connect

    emitter_pid = child_pid!(supervisor, EventEmitter)
    assert :ok = EventEmitter.emit(emitter_pid, :connection_update, %{connection: :open})

    assert_receive {:fake_socket_query,
                    %BinaryNode{
                      tag: "iq",
                      attrs: %{"xmlns" => "w", "type" => "get"},
                      content: [
                        %BinaryNode{
                          tag: "props",
                          attrs: %{"protocol" => "2", "hash" => ""}
                        }
                      ]
                    }, 60_000}
  end

  test "connection open preserves existing own devices and adds the primary device for direct fanout" do
    name = {:phase8_own_device_list_test, System.unique_integer([:positive])}

    assert {:ok, supervisor} =
             Supervisor.start_link(
               name: name,
               config: Config.new(fire_init_queries: false, mark_online_on_connect: false),
               auth_state: %{
                 creds: %{me: %{id: "15550001111:57@s.whatsapp.net", lid: "99999:57@lid"}}
               },
               socket_module: FakeSocket,
               test_pid: self(),
               transport: {NoopTransport, %{}}
             )

    assert_receive :fake_socket_connect

    signal_store = Supervisor.signal_store(supervisor)
    assert :ok = SignalStore.set(signal_store, %{:"device-list" => %{"15550001111" => ["2"]}})

    emitter_pid = child_pid!(supervisor, EventEmitter)
    assert :ok = EventEmitter.emit(emitter_pid, :connection_update, %{connection: :open})

    assert_eventually(fn ->
      SignalStore.get(signal_store, :"device-list", ["15550001111"])["15550001111"] ==
        ["0", "57", "2"]
    end)
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
      |> child_pid!(SignalStoreMemory)
      |> SignalStoreMemory.wrap()

    assert :ok =
             EventEmitter.emit(emitter_pid, :lid_mapping_update, %{
               lid: "123456789@lid",
               pn: "15551234567@s.whatsapp.net"
             })

    assert_eventually(fn ->
      SignalStoreMemory.get(signal_store_ref, :"lid-mapping", [
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
                    }},
                   500

    assert :ok = unsubscribe.()
  end

  test "socket_node message events are routed through the receiver and send delivery receipts without message transport acks" do
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

    refute_receive {:fake_socket_send_node,
                    %BinaryNode{
                      tag: "ack",
                      attrs: %{
                        "class" => "message",
                        "to" => "15551234567@s.whatsapp.net",
                        "id" => "runtime-msg-1"
                      }
                    }}

    unsubscribe.()
  end

  test "socket_node message events resolve missing pn-to-lid mappings through background usync" do
    name = {:phase8_test, System.unique_integer([:positive])}

    query_handler = fn
      %BinaryNode{
        tag: "iq",
        attrs: %{"xmlns" => "usync", "type" => "get"},
        content: [
          %BinaryNode{
            tag: "usync",
            attrs: %{"context" => "background", "mode" => "query"},
            content: [
              %BinaryNode{tag: "query", content: [%BinaryNode{tag: "lid"}]},
              %BinaryNode{
                tag: "list",
                content: [
                  %BinaryNode{tag: "user", attrs: %{"jid" => "15551234567@s.whatsapp.net"}}
                ]
              }
            ]
          }
        ]
      },
      _timeout ->
        {:ok,
         %BinaryNode{
           tag: "iq",
           attrs: %{"type" => "result"},
           content: [
             %BinaryNode{
               tag: "usync",
               attrs: %{},
               content: [
                 %BinaryNode{
                   tag: "list",
                   attrs: %{},
                   content: [
                     %BinaryNode{
                       tag: "user",
                       attrs: %{"jid" => "15551234567@s.whatsapp.net"},
                       content: [%BinaryNode{tag: "lid", attrs: %{"val" => "12345@lid"}}]
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
               auth_state: %{
                 creds: %{me: %{id: "15550001111@s.whatsapp.net", lid: "15550001111@lid"}}
               },
               socket_module: FakeSocket,
               signal_repository_adapter: MessageSignalHelpers.FakeAdapter,
               signal_repository_adapter_state: %{},
               test_pid: self(),
               query_handler: query_handler,
               transport: {NoopTransport, %{}}
             )

    assert_receive :fake_socket_connect

    emitter_pid = child_pid!(supervisor, EventEmitter)
    parent = self()
    unsubscribe = EventEmitter.process(emitter_pid, &send(parent, {:events, &1}))

    message_node = %BinaryNode{
      tag: "message",
      attrs: %{
        "id" => "runtime-msg-lid-lookup-1",
        "from" => "15551234567@s.whatsapp.net",
        "category" => "peer",
        "t" => "1710000801"
      },
      content: [
        %BinaryNode{
          tag: "plaintext",
          attrs: %{},
          content:
            Message.encode(%Message{
              protocol_message: %Message.ProtocolMessage{
                type: :APP_STATE_SYNC_KEY_SHARE,
                app_state_sync_key_share: %Message.AppStateSyncKeyShare{keys: []}
              }
            })
        }
      ]
    }

    assert :ok =
             EventEmitter.emit(emitter_pid, :socket_node, %{node: message_node, state: :connected})

    assert_receive {:fake_socket_query,
                    %BinaryNode{attrs: %{"xmlns" => "usync", "type" => "get"}}, _timeout}

    assert_receive {:events,
                    %{
                      messages_upsert: %{
                        type: :notify,
                        messages: [%{key: %{id: "runtime-msg-lid-lookup-1"}}]
                      }
                    }}

    assert {:ok, "12345@lid"} =
             supervisor
             |> Supervisor.signal_store()
             |> LIDMappingStore.get_lid_for_pn("15551234567@s.whatsapp.net")

    unsubscribe.()
  end

  test "socket_node receipt, ack, and notification events are routed through the messaging handlers" do
    name = {:phase8_test, System.unique_integer([:positive])}

    query_handler = fn node, _timeout ->
      [
        %BinaryNode{
          tag: "query",
          attrs: %{"query_id" => "23983697327930364"}
        }
      ] = node.content

      {:ok,
       %BinaryNode{
         tag: "iq",
         attrs: %{"type" => "result"},
         content: [
           %BinaryNode{
             tag: "result",
             attrs: %{},
             content:
               {:binary,
                JSON.encode!(%{
                  "data" => %{
                    "xwa2_fetch_account_reachout_timelock" => %{
                      "is_active" => true,
                      "time_enforcement_ends" => "1710000000",
                      "enforcement_type" => "WEB_COMPANION_ONLY"
                    }
                  }
                })}
           }
         ]
       }}
    end

    assert {:ok, supervisor} =
             Supervisor.start_link(
               name: name,
               config: Config.new(fire_init_queries: false, mark_online_on_connect: false),
               auth_state: %{creds: %{me: %{id: "15550001111@s.whatsapp.net"}}},
               socket_module: FakeSocket,
               test_pid: self(),
               query_handler: query_handler,
               transport: {NoopTransport, %{}}
             )

    assert_receive :fake_socket_connect

    emitter_pid = child_pid!(supervisor, EventEmitter)

    signal_store =
      child_pid!(supervisor, SignalStoreMemory)
      |> SignalStoreMemory.wrap()

    assert :ok =
             SignalStoreMemory.set(signal_store, %{
               tctoken: %{
                 "15551234567@s.whatsapp.net" => %{
                   token: "",
                   timestamp: "100",
                   sender_timestamp: 1_710_000_804
                 }
               }
             })

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
        "error" => "463"
      },
      content: nil
    }

    picture_notification = %BinaryNode{
      tag: "notification",
      attrs: %{
        "type" => "picture",
        "from" => "12345-67890@g.us",
        "id" => "picture-notif-1",
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
      attrs: %{
        "type" => "privacy_token",
        "from" => "15551234567@s.whatsapp.net",
        "id" => "privacy-token-notif-1"
      },
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

    assert_receive {:fake_socket_send_node,
                    %BinaryNode{
                      tag: "ack",
                      attrs: %{
                        "class" => "receipt",
                        "to" => "15551234567@s.whatsapp.net",
                        "id" => "receipt-msg-1"
                      }
                    }}

    assert_receive(
      {:events,
       %{
         messages_update: [
           %{
             key: %{id: "ack-msg-1"},
             update: %{
               status: :ERROR,
               message_stub_parameters: ["463", "Your account has been restricted"]
             }
           }
         ]
       }},
      500
    )

    assert_receive {:fake_socket_query,
                    %BinaryNode{
                      tag: "iq",
                      attrs: %{"xmlns" => "w:mex"},
                      content: [
                        %BinaryNode{
                          tag: "query",
                          attrs: %{"query_id" => "23983697327930364"}
                        }
                      ]
                    }, 60_000}

    assert_receive(
      {:events,
       %{
         connection_update: %{
           reachout_time_lock: %{
             is_active: true,
             time_enforcement_ends: ~U[2024-03-09 16:00:00Z],
             enforcement_type: "WEB_COMPANION_ONLY"
           }
         }
       }},
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

    assert_receive {:fake_socket_send_node,
                    %BinaryNode{
                      tag: "ack",
                      attrs: %{
                        "class" => "notification",
                        "type" => "picture",
                        "to" => "12345-67890@g.us",
                        "participant" => "15551234567@s.whatsapp.net",
                        "id" => "picture-notif-1"
                      }
                    }}

    assert_receive {:fake_socket_send_node,
                    %BinaryNode{
                      tag: "ack",
                      attrs: %{
                        "class" => "notification",
                        "type" => "privacy_token",
                        "to" => "15551234567@s.whatsapp.net",
                        "id" => "privacy-token-notif-1"
                      }
                    }}

    assert_eventually(fn ->
      SignalStoreMemory.get(signal_store, :tctoken, ["15551234567@s.whatsapp.net"])[
        "15551234567@s.whatsapp.net"
      ] == %{token: "trusted-token", timestamp: "1710000803", sender_timestamp: 1_710_000_804}
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
             Repository.inject_e2e_session(signal_repository, %{
               jid: "15551234567@s.whatsapp.net",
               session: session
             })

    key_bundle_response = fn
      %BinaryNode{
        attrs: %{"xmlns" => "privacy", "type" => "set"},
        content: [
          %BinaryNode{
            tag: "tokens",
            content: [
              %BinaryNode{
                tag: "token",
                attrs: %{
                  "jid" => "15551234567@s.whatsapp.net",
                  "t" => "4102444800",
                  "type" => "trusted_contact"
                }
              }
            ]
          }
        ]
      },
      _timeout ->
        {:ok,
         %BinaryNode{
           tag: "iq",
           attrs: %{"type" => "result"},
           content: [
             %BinaryNode{
               tag: "tokens",
               attrs: %{},
               content: [
                 %BinaryNode{
                   tag: "token",
                   attrs: %{"type" => "trusted_contact", "t" => "4102444900"},
                   content: {:binary, "fresh-token"}
                 }
               ]
             }
           ]
         }}

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

    signal_store =
      %SignalStore{
        module: SignalStoreMemory,
        ref:
          supervisor
          |> child_pid!(SignalStoreMemory)
          |> SignalStoreMemory.wrap()
      }

    assert :ok =
             SignalStore.set(signal_store, %{
               tctoken: %{
                 "15551234567@s.whatsapp.net" => %{
                   token: "",
                   timestamp: "100",
                   sender_timestamp: 4_102_444_800
                 }
               }
             })

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

    assert_receive {:fake_socket_query,
                    %BinaryNode{
                      attrs: %{"xmlns" => "privacy", "type" => "set"},
                      content: [
                        %BinaryNode{
                          tag: "tokens",
                          content: [
                            %BinaryNode{
                              tag: "token",
                              attrs: %{
                                "jid" => "15551234567@s.whatsapp.net",
                                "t" => "4102444800",
                                "type" => "trusted_contact"
                              }
                            }
                          ]
                        }
                      ]
                    }, _timeout}

    assert_eventually(fn ->
      match?(
        %{
          "15551234567@s.whatsapp.net" => %{
            token: "fresh-token",
            timestamp: "4102444900",
            sender_timestamp: 4_102_444_800
          }
        },
        SignalStore.get(signal_store, :tctoken, ["15551234567@s.whatsapp.net"])
      )
    end)
  end

  test "account_sync dirty-bit clean IQ carries a non-empty id attribute" do
    name = {:release_dirty_id_test, System.unique_integer([:positive])}
    parent = self()

    assert {:ok, supervisor} =
             Supervisor.start_link(
               name: name,
               config: Config.new(fire_init_queries: false, mark_online_on_connect: false),
               auth_state: %{creds: %{me: %{id: "15550001111@s.whatsapp.net"}}},
               socket_module: FakeSocket,
               test_pid: parent,
               transport: {NoopTransport, %{}}
             )

    assert_receive :fake_socket_connect
    emitter_pid = child_pid!(supervisor, EventEmitter)
    store_pid = child_pid!(supervisor, Store)
    :ok = Store.put(store_pid, :last_account_sync_timestamp, 1_710_000_000)

    assert :ok =
             EventEmitter.emit(emitter_pid, :dirty_update, %{
               type: "account_sync",
               timestamp: 1_710_000_100
             })

    assert_receive {:fake_socket_send_node,
                    %BinaryNode{
                      tag: "iq",
                      attrs: %{
                        "id" => id,
                        "to" => "s.whatsapp.net",
                        "type" => "set",
                        "xmlns" => "urn:xmpp:whatsapp:dirty"
                      },
                      content: [
                        %BinaryNode{
                          tag: "clean",
                          attrs: %{"type" => "account_sync", "timestamp" => "1710000000"}
                        }
                      ]
                    }},
                   1_000

    assert is_binary(id) and id != ""
  end

  test "initial sync waits for in-flight app-state sync before transitioning online" do
    name = {:release_sync_test, System.unique_integer([:positive])}
    parent = self()
    gate = make_ref()

    query_handler = fn
      %BinaryNode{attrs: %{"xmlns" => "w:sync:app:state"}} = node, _timeout ->
        collections =
          node
          |> BinaryNodeUtil.child("sync")
          |> BinaryNodeUtil.children("collection")
          |> Enum.map(& &1.attrs["name"])

        reply =
          {:ok,
           %BinaryNode{
             tag: "iq",
             attrs: %{"type" => "result"},
             content: [
               %BinaryNode{
                 tag: "sync",
                 attrs: %{},
                 content:
                   Enum.map(collections, fn name ->
                     %BinaryNode{
                       tag: "collection",
                       attrs: %{"name" => name, "version" => "0", "has_more_patches" => "false"},
                       content: []
                     }
                   end)
               }
             ]
           }}

        send(parent, {:sync_query_started, self(), node})

        receive do
          {:release_sync, ^gate} ->
            reply
        after
          2_000 -> {:error, :timeout}
        end

      _node, _timeout ->
        {:ok, %BinaryNode{tag: "iq", attrs: %{"type" => "result"}, content: []}}
    end

    assert {:ok, supervisor} =
             Supervisor.start_link(
               name: name,
               config: Config.new(fire_init_queries: false, mark_online_on_connect: false),
               auth_state: %{creds: %{me: %{id: "15550001111@s.whatsapp.net"}}},
               socket_module: FakeSocket,
               test_pid: parent,
               query_handler: query_handler,
               transport: {NoopTransport, %{}}
             )

    assert_receive :fake_socket_connect
    emitter_pid = child_pid!(supervisor, EventEmitter)
    unsubscribe = EventEmitter.process(emitter_pid, &send(parent, {:processed_events, &1}))

    assert :ok =
             EventEmitter.emit(emitter_pid, :connection_update, %{
               received_pending_notifications: true
             })

    assert_eventually(fn -> EventEmitter.buffering?(emitter_pid) end)

    assert :ok =
             EventEmitter.emit(emitter_pid, :messaging_history_set, %{
               chats: [],
               contacts: [],
               messages: [],
               sync_type: :INITIAL_BOOTSTRAP
             })

    assert_receive {:sync_query_started, sync_task_pid, _node}, 1_000

    # Even well past the 25ms fallback timer, sync_state must stay :syncing while app-state sync is in flight
    refute_receive {:processed_events, %{connection_update: %{sync_state: :online}}}, 80
    assert EventEmitter.buffering?(emitter_pid)

    send(sync_task_pid, {:release_sync, gate})

    assert_receive {:processed_events,
                    %{
                      connection_update: %{
                        sync_state: :online,
                        initial_sync_complete: true,
                        initial_sync_reason: :initial_sync_complete
                      }
                    }},
                   1_000

    store_ref = Store.wrap(child_pid!(supervisor, Store))
    assert_eventually(fn -> Store.get(store_ref, :creds, %{})[:account_sync_counter] == 1 end)

    unsubscribe.()
  end

  test "disconnect with last_disconnect resets sync_state and reconnection with account_sync_counter skips timeout wait" do
    name = {:release_reconnect_sync_test, System.unique_integer([:positive])}
    parent = self()

    assert {:ok, supervisor} =
             Supervisor.start_link(
               name: name,
               config:
                 Config.new(
                   fire_init_queries: false,
                   mark_online_on_connect: false,
                   initial_sync_timeout_ms: 40,
                   reconnect_policy: :disabled
                 ),
               auth_state: %{creds: %{me: %{id: "15550001111@s.whatsapp.net"}}},
               socket_module: FakeSocket,
               test_pid: parent,
               transport: {NoopTransport, %{}}
             )

    assert_receive :fake_socket_connect
    emitter_pid = child_pid!(supervisor, EventEmitter)
    store_pid = child_pid!(supervisor, Store)
    store_ref = Store.wrap(store_pid)
    unsubscribe = EventEmitter.process(emitter_pid, &send(parent, {:processed_events, &1}))

    # First connection times out awaiting initial sync and increments account_sync_counter
    assert :ok =
             EventEmitter.emit(emitter_pid, :connection_update, %{
               received_pending_notifications: true
             })

    assert_receive {:processed_events,
                    %{
                      connection_update: %{
                        sync_state: :online,
                        initial_sync_complete: true,
                        initial_sync_reason: :timeout
                      }
                    }},
                   1_000

    assert_eventually(fn -> Store.get(store_ref, :creds, %{})[:account_sync_counter] == 1 end)

    # Real close event carrying :last_disconnect resets sync_state back to :connecting
    assert :ok =
             EventEmitter.emit(emitter_pid, :connection_update, %{
               connection: :close,
               last_disconnect: %{error: %{reason: :connection_closed}}
             })

    # Reconnect: account_sync_counter > 0 skips the 40ms wait and goes online immediately
    assert :ok =
             EventEmitter.emit(emitter_pid, :connection_update, %{
               received_pending_notifications: true
             })

    assert_receive {:processed_events,
                    %{
                      connection_update: %{
                        sync_state: :online,
                        initial_sync_complete: true,
                        initial_sync_reason: :reconnection_existing_sync
                      }
                    }},
                   500

    unsubscribe.()
  end

  test "blocked app-state collections parked during in-flight initial sync resync when key arrives mid-sync" do
    name = {:release_blocked_mid_sync_test, System.unique_integer([:positive])}
    parent = self()
    gate = make_ref()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    query_handler = fn
      %BinaryNode{attrs: %{"xmlns" => "w:sync:app:state"}} = node, _timeout ->
        call = Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end)

        collections =
          node
          |> BinaryNodeUtil.child("sync")
          |> BinaryNodeUtil.children("collection")
          |> Enum.map(& &1.attrs["name"])

        send(parent, {:app_state_query, call, self(), collections})

        reply =
          {:ok,
           %BinaryNode{
             tag: "iq",
             attrs: %{"type" => "result"},
             content: [
               %BinaryNode{
                 tag: "sync",
                 attrs: %{},
                 content:
                   Enum.map(collections, fn name ->
                     %BinaryNode{
                       tag: "collection",
                       attrs: %{"name" => name, "version" => "0", "has_more_patches" => "false"},
                       content: []
                     }
                   end)
               }
             ]
           }}

        if call == 1 do
          receive do
            {:continue_initial_sync, ^gate} -> reply
          after
            2_000 -> {:error, :timeout}
          end
        else
          reply
        end

      _node, _timeout ->
        {:ok, %BinaryNode{tag: "iq", attrs: %{"type" => "result"}, content: []}}
    end

    assert {:ok, supervisor} =
             Supervisor.start_link(
               name: name,
               config: Config.new(fire_init_queries: false, mark_online_on_connect: false),
               auth_state: %{creds: %{me: %{id: "15550001111@s.whatsapp.net"}}},
               socket_module: FakeSocket,
               test_pid: parent,
               query_handler: query_handler,
               transport: {NoopTransport, %{}}
             )

    assert_receive :fake_socket_connect
    emitter_pid = child_pid!(supervisor, EventEmitter)
    coordinator_pid = child_pid!(supervisor, Coordinator)
    unsubscribe = EventEmitter.process(emitter_pid, &send(parent, {:processed_events, &1}))

    assert :ok =
             EventEmitter.emit(emitter_pid, :connection_update, %{
               received_pending_notifications: true
             })

    assert_eventually(fn -> EventEmitter.buffering?(emitter_pid) end)

    assert :ok =
             EventEmitter.emit(emitter_pid, :messaging_history_set, %{
               chats: [],
               contacts: [],
               messages: [],
               sync_type: :INITIAL_BOOTSTRAP
             })

    assert_receive {:app_state_query, 1, first_task_pid, _collections}, 1_000

    # Park :critical_block while initial sync is still in flight, then deliver the app-state key
    send(coordinator_pid, {:app_state_collection_blocked, 0, :critical_block})
    assert :ok = EventEmitter.emit(emitter_pid, :creds_update, %{my_app_state_key_id: "key-1"})

    # Release the first initial-sync pass; Coordinator must follow up with :critical_block before going :online
    send(first_task_pid, {:continue_initial_sync, gate})

    assert_receive {:app_state_query, 2, _second_task_pid, ["critical_block"]}, 1_000

    assert_receive {:processed_events,
                    %{
                      connection_update: %{
                        sync_state: :online,
                        initial_sync_complete: true,
                        initial_sync_reason: :initial_sync_complete
                      }
                    }},
                   1_000

    store_ref = Store.wrap(child_pid!(supervisor, Store))
    assert_eventually(fn -> Store.get(store_ref, :creds, %{})[:account_sync_counter] == 1 end)

    unsubscribe.()
  end

  test "1:1 companion retry receipt with key bundle injects session and resends targeted enc node" do
    name = {:release_retry_bundle_test, System.unique_integer([:positive])}
    parent = self()

    {:ok, alice_store} = SignalStore.new()
    alice_identity = Crypto.generate_key_pair(:x25519, private_key: <<701::256>>)
    alice_spk = Crypto.generate_key_pair(:x25519, private_key: <<702::256>>)

    alice_adapter_state =
      SignalAdapter.new(
        store: alice_store,
        identity_key_pair: alice_identity,
        registration_id: 7001,
        signed_pre_key: %{key_id: 1, key_pair: alice_spk}
      )

    signal_repository =
      Repository.new(
        adapter: SignalAdapter,
        adapter_state: alice_adapter_state,
        store: alice_store
      )

    bob_identity = Crypto.generate_key_pair(:x25519, private_key: <<703::256>>)
    bob_spk = Crypto.generate_key_pair(:x25519, private_key: <<704::256>>)
    {:ok, bob_spk_pub} = Curve.generate_signal_pub_key(bob_spk.public)
    {:ok, bob_sig} = Curve.sign(bob_identity.private, bob_spk_pub)

    assert {:ok, supervisor} =
             Supervisor.start_link(
               name: name,
               config: Config.new(fire_init_queries: false, mark_online_on_connect: false),
               auth_state: %{creds: %{me: %{id: "15550001111@s.whatsapp.net"}}},
               socket_module: FakeSocket,
               signal_repository: signal_repository,
               test_pid: parent,
               transport: {NoopTransport, %{}}
             )

    assert_receive :fake_socket_connect

    runtime_store = supervisor |> child_pid!(Store) |> Store.wrap()

    assert :ok =
             Retry.add_recent_message(
               runtime_store,
               "15551234567:2@s.whatsapp.net",
               "retry-bundle-1",
               Builder.build(%{text: "resent with injected bundle"})
             )

    receipt = %BinaryNode{
      tag: "receipt",
      attrs: %{
        "id" => "retry-bundle-1",
        "from" => "15551234567:2@s.whatsapp.net",
        "type" => "retry"
      },
      content: [
        %BinaryNode{tag: "retry", attrs: %{"count" => "2"}, content: nil},
        %BinaryNode{
          tag: "registration",
          attrs: %{},
          content: {:binary, <<8002::unsigned-big-32>>}
        },
        %BinaryNode{
          tag: "keys",
          attrs: %{},
          content: [
            %BinaryNode{tag: "type", attrs: %{}, content: {:binary, <<5>>}},
            %BinaryNode{tag: "identity", attrs: %{}, content: {:binary, bob_identity.public}},
            %BinaryNode{
              tag: "skey",
              attrs: %{},
              content: [
                %BinaryNode{tag: "id", attrs: %{}, content: {:binary, <<11::unsigned-big-24>>}},
                %BinaryNode{tag: "value", attrs: %{}, content: {:binary, bob_spk.public}},
                %BinaryNode{tag: "signature", attrs: %{}, content: {:binary, bob_sig}}
              ]
            }
          ]
        }
      ]
    }

    assert :ok =
             supervisor
             |> child_pid!(EventEmitter)
             |> EventEmitter.emit(:socket_node, %{node: receipt})

    assert_receive {:fake_socket_send_node,
                    %BinaryNode{
                      tag: "message",
                      attrs: %{
                        "id" => "retry-bundle-1",
                        "to" => "15551234567:2@s.whatsapp.net",
                        "device_fanout" => "false"
                      },
                      content: [
                        %BinaryNode{
                          tag: "enc",
                          attrs: %{"type" => "pkmsg", "v" => "2", "count" => "2"}
                        }
                      ]
                    }},
                   1_000
  end

  test "closing during an active initial app-state sync cancels the task without crashing Coordinator or leaking stale messages" do
    name = {:release_close_mid_sync_test, System.unique_integer([:positive])}
    parent = self()
    gate = make_ref()

    query_handler = fn
      %BinaryNode{attrs: %{"xmlns" => "w:sync:app:state"}}, _timeout ->
        send(parent, {:sync_task_started, self()})

        receive do
          {:finish_sync, ^gate} ->
            {:ok, %BinaryNode{tag: "iq", attrs: %{"type" => "result"}, content: []}}
        after
          5_000 -> {:error, :timeout}
        end

      _node, _timeout ->
        {:ok, %BinaryNode{tag: "iq", attrs: %{"type" => "result"}, content: []}}
    end

    assert {:ok, supervisor} =
             Supervisor.start_link(
               name: name,
               config:
                 Config.new(
                   fire_init_queries: false,
                   mark_online_on_connect: false,
                   reconnect_policy: :disabled
                 ),
               auth_state: %{creds: %{me: %{id: "15550001111@s.whatsapp.net"}}},
               socket_module: FakeSocket,
               test_pid: parent,
               query_handler: query_handler,
               transport: {NoopTransport, %{}}
             )

    assert_receive :fake_socket_connect
    emitter_pid = child_pid!(supervisor, EventEmitter)
    coordinator_pid = child_pid!(supervisor, Coordinator)
    coord_mon = Process.monitor(coordinator_pid)

    assert :ok =
             EventEmitter.emit(emitter_pid, :connection_update, %{
               received_pending_notifications: true
             })

    assert_eventually(fn -> EventEmitter.buffering?(emitter_pid) end)

    assert :ok =
             EventEmitter.emit(emitter_pid, :messaging_history_set, %{
               chats: [],
               contacts: [],
               messages: [],
               sync_type: :INITIAL_BOOTSTRAP
             })

    assert_receive {:sync_task_started, fake_socket_pid}, 1_000
    task_supervisor = child_pid!(supervisor, Task.Supervisor)
    assert [sync_task_pid] = Task.Supervisor.children(task_supervisor)
    task_mon = Process.monitor(sync_task_pid)

    # Disconnect while the app-state sync task is still running
    assert :ok =
             EventEmitter.emit(emitter_pid, :connection_update, %{
               connection: :close,
               last_disconnect: %{error: %{reason: :connection_closed}}
             })

    assert_receive {:DOWN, ^task_mon, :process, ^sync_task_pid, _reason}, 1_000
    send(fake_socket_pid, {:finish_sync, gate})

    # Even if a late stale :DOWN or stale blocked collection arrives, Coordinator stays alive
    send(coordinator_pid, {:DOWN, make_ref(), :process, sync_task_pid, :normal})
    send(coordinator_pid, {:app_state_collection_blocked, 0, :critical_block})

    refute_receive {:DOWN, ^coord_mon, :process, ^coordinator_pid, _reason}, 80
    assert Process.alive?(coordinator_pid)

    # Delivering app-state key on the next generation must NOT trigger resync for stale gen-0 blocked collections
    assert :ok = EventEmitter.emit(emitter_pid, :creds_update, %{my_app_state_key_id: "key-next"})
    refute_receive {:sync_task_started, _}, 80
  end

  test "omitted app-state collections during initial sync do not advance account_sync_counter" do
    name = {:release_omitted_counter_test, System.unique_integer([:positive])}
    parent = self()

    query_handler = fn
      %BinaryNode{attrs: %{"xmlns" => "w:sync:app:state"}}, _timeout ->
        {:ok,
         %BinaryNode{
           tag: "iq",
           attrs: %{"type" => "result"},
           content: [%BinaryNode{tag: "sync", attrs: %{}, content: []}]
         }}

      _node, _timeout ->
        {:ok, %BinaryNode{tag: "iq", attrs: %{"type" => "result"}, content: []}}
    end

    assert {:ok, supervisor} =
             Supervisor.start_link(
               name: name,
               config: Config.new(fire_init_queries: false, mark_online_on_connect: false),
               auth_state: %{creds: %{me: %{id: "15550001111@s.whatsapp.net"}}},
               socket_module: FakeSocket,
               test_pid: parent,
               query_handler: query_handler,
               transport: {NoopTransport, %{}}
             )

    assert_receive :fake_socket_connect
    emitter_pid = child_pid!(supervisor, EventEmitter)
    unsubscribe = EventEmitter.process(emitter_pid, &send(parent, {:processed_events, &1}))

    assert :ok =
             EventEmitter.emit(emitter_pid, :connection_update, %{
               received_pending_notifications: true
             })

    assert_eventually(fn -> EventEmitter.buffering?(emitter_pid) end)

    assert :ok =
             EventEmitter.emit(emitter_pid, :messaging_history_set, %{
               chats: [],
               contacts: [],
               messages: [],
               sync_type: :INITIAL_BOOTSTRAP
             })

    assert_receive {:processed_events,
                    %{connection_update: %{sync_state: :online, initial_sync_complete: true}}},
                   1_000

    store_ref = Store.wrap(child_pid!(supervisor, Store))
    assert Store.get(store_ref, :creds, %{})[:account_sync_counter] in [nil, 0]
    unsubscribe.()
  end

  test "coordinator ACKs call nodes without info child and survives call ACK transport errors" do
    name = {:release_call_ack_safety_test, System.unique_integer([:positive])}
    parent = self()

    assert {:ok, supervisor} =
             Supervisor.start_link(
               name: name,
               config: Config.new(fire_init_queries: false, mark_online_on_connect: false),
               auth_state: %{creds: %{me: %{id: "15550001111@s.whatsapp.net"}}},
               socket_module: FakeSocket,
               test_pid: parent,
               transport: {NoopTransport, %{}}
             )

    assert_receive :fake_socket_connect
    emitter_pid = child_pid!(supervisor, EventEmitter)
    coordinator_pid = child_pid!(supervisor, Coordinator)

    empty_call = %BinaryNode{
      tag: "call",
      attrs: %{"id" => "coord-call-empty-1", "from" => "15551234567@s.whatsapp.net"},
      content: []
    }

    assert :ok =
             EventEmitter.emit(emitter_pid, :socket_node, %{node: empty_call, state: :connected})

    assert_receive {:fake_socket_send_node,
                    %BinaryNode{
                      tag: "ack",
                      attrs: %{
                        "id" => "coord-call-empty-1",
                        "to" => "15551234567@s.whatsapp.net",
                        "class" => "call"
                      }
                    }},
                   1_000

    assert Process.alive?(coordinator_pid)

    # Also test live dispatch of a valid call when transport send_node fails with {:error, :not_connected}
    {:ok, failing_sup} =
      Supervisor.start_link(
        name: {:release_call_ack_fail_test, System.unique_integer([:positive])},
        config: Config.new(fire_init_queries: false, mark_online_on_connect: false),
        auth_state: %{creds: %{me: %{id: "15550001111@s.whatsapp.net"}}},
        socket_module: FakeSocket,
        send_node_handler: fn _node -> {:error, :not_connected} end,
        test_pid: parent,
        transport: {NoopTransport, %{}}
      )

    assert_receive :fake_socket_connect
    failing_emitter = child_pid!(failing_sup, EventEmitter)
    failing_coord = child_pid!(failing_sup, Coordinator)
    coord_mon = Process.monitor(failing_coord)

    valid_call = %BinaryNode{
      tag: "call",
      attrs: %{
        "id" => "coord-call-fail-ack-1",
        "from" => "15551234567@s.whatsapp.net",
        "t" => "1710000000"
      },
      content: [
        %BinaryNode{
          tag: "offer",
          attrs: %{"call-id" => "call-fail-ack", "call-creator" => "15551234567@s.whatsapp.net"},
          content: nil
        }
      ]
    }

    assert :ok =
             EventEmitter.emit(failing_emitter, :socket_node, %{
               node: valid_call,
               state: :connected
             })

    assert_receive {:fake_socket_send_node,
                    %BinaryNode{
                      tag: "ack",
                      attrs: %{"id" => "coord-call-fail-ack-1", "class" => "call"}
                    }},
                   1_000

    refute_receive {:DOWN, ^coord_mon, :process, ^failing_coord, _reason}, 80
    assert Process.alive?(failing_coord)
  end

  test "retry receipt separates conversation and requesting device for own-companion DSM and base-chat cache lookup" do
    name = {:release_retry_own_companion_test, System.unique_integer([:positive])}
    parent = self()

    {:ok, alice_store} = SignalStore.new()
    {:ok, companion_store} = SignalStore.new()

    alice_id = Crypto.generate_key_pair(:x25519, private_key: <<801::256>>)
    alice_spk = Crypto.generate_key_pair(:x25519, private_key: <<802::256>>)
    comp_id = Crypto.generate_key_pair(:x25519, private_key: <<803::256>>)
    comp_spk = Crypto.generate_key_pair(:x25519, private_key: <<804::256>>)
    {:ok, comp_spk_pub} = Curve.generate_signal_pub_key(comp_spk.public)
    {:ok, comp_sig} = Curve.sign(comp_id.private, comp_spk_pub)

    peer_id = Crypto.generate_key_pair(:x25519, private_key: <<805::256>>)
    peer_spk = Crypto.generate_key_pair(:x25519, private_key: <<806::256>>)
    {:ok, peer_spk_pub} = Curve.generate_signal_pub_key(peer_spk.public)
    {:ok, peer_sig} = Curve.sign(peer_id.private, peer_spk_pub)

    signal_repository =
      Repository.new(
        adapter: SignalAdapter,
        adapter_state:
          SignalAdapter.new(
            store: alice_store,
            identity_key_pair: alice_id,
            registration_id: 8001,
            signed_pre_key: %{key_id: 1, key_pair: alice_spk}
          ),
        store: alice_store
      )

    companion_repo =
      Repository.new(
        adapter: SignalAdapter,
        adapter_state:
          SignalAdapter.new(
            store: companion_store,
            identity_key_pair: comp_id,
            registration_id: 8002,
            signed_pre_key: %{key_id: 2, key_pair: comp_spk}
          ),
        store: companion_store
      )

    get_message_fun = fn key ->
      send(parent, {:get_message_called, key})

      case key do
        %{
          remote_jid: "15559998888@s.whatsapp.net",
          id: "own-comp-msg-1",
          from_me: true,
          participant: "15550001111:2@s.whatsapp.net"
        } ->
          %{message: Builder.build(%{text: "hello to B from companion retry"})}

        _ ->
          nil
      end
    end

    assert {:ok, supervisor} =
             Supervisor.start_link(
               name: name,
               config: Config.new(fire_init_queries: false, mark_online_on_connect: false),
               auth_state: %{creds: %{me: %{id: "15550001111:1@s.whatsapp.net"}}},
               socket_module: FakeSocket,
               signal_repository: signal_repository,
               get_message_fun: get_message_fun,
               test_pid: parent,
               transport: {NoopTransport, %{}}
             )

    assert_receive :fake_socket_connect
    emitter_pid = child_pid!(supervisor, EventEmitter)

    # 1. Own companion A:2 asks retry for conversation B via recipient attr
    own_companion_receipt = %BinaryNode{
      tag: "receipt",
      attrs: %{
        "id" => "own-comp-msg-1",
        "from" => "15550001111:2@s.whatsapp.net",
        "recipient" => "15559998888@s.whatsapp.net",
        "type" => "retry"
      },
      content: [
        %BinaryNode{tag: "retry", attrs: %{"count" => "2"}, content: nil},
        %BinaryNode{
          tag: "registration",
          attrs: %{},
          content: {:binary, <<8002::unsigned-big-32>>}
        },
        %BinaryNode{
          tag: "keys",
          attrs: %{},
          content: [
            %BinaryNode{tag: "type", attrs: %{}, content: {:binary, <<5>>}},
            %BinaryNode{tag: "identity", attrs: %{}, content: {:binary, comp_id.public}},
            %BinaryNode{
              tag: "skey",
              attrs: %{},
              content: [
                %BinaryNode{tag: "id", attrs: %{}, content: {:binary, <<2::unsigned-big-24>>}},
                %BinaryNode{tag: "value", attrs: %{}, content: {:binary, comp_spk.public}},
                %BinaryNode{tag: "signature", attrs: %{}, content: {:binary, comp_sig}}
              ]
            }
          ]
        }
      ]
    }

    assert :ok = EventEmitter.emit(emitter_pid, :socket_node, %{node: own_companion_receipt})

    assert_receive {:get_message_called,
                    %{
                      remote_jid: "15559998888@s.whatsapp.net",
                      id: "own-comp-msg-1",
                      from_me: true,
                      participant: "15550001111:2@s.whatsapp.net"
                    }},
                   1_000

    assert_receive {:fake_socket_send_node,
                    %BinaryNode{
                      tag: "message",
                      attrs: %{
                        "id" => "own-comp-msg-1",
                        "to" => "15550001111:2@s.whatsapp.net",
                        "recipient" => "15559998888@s.whatsapp.net",
                        "device_fanout" => "false"
                      },
                      content: [
                        %BinaryNode{
                          tag: "enc",
                          attrs: %{"type" => "pkmsg", "v" => "2", "count" => "2"},
                          content: {:binary, comp_ciphertext}
                        }
                      ]
                    }},
                   1_000

    assert {:ok, _companion_repo, plaintext} =
             Repository.decrypt_message(companion_repo, %{
               jid: "15550001111:1@s.whatsapp.net",
               type: :pkmsg,
               ciphertext: comp_ciphertext
             })

    assert {:ok,
            %Message{
              device_sent_message: %Message.DeviceSentMessage{
                destination_jid: "15559998888@s.whatsapp.net",
                message: %Message{
                  extended_text_message: %Message.ExtendedTextMessage{
                    text: "hello to B from companion retry"
                  }
                }
              }
            }} = Wire.decode(plaintext)

    # 2. Peer companion B:2 hits base-chat recent cache key B
    runtime_store = supervisor |> child_pid!(Store) |> Store.wrap()

    assert :ok =
             Retry.add_recent_message(
               runtime_store,
               "15551234567@s.whatsapp.net",
               "peer-base-cache-1",
               Builder.build(%{text: "cached under base chat"})
             )

    peer_receipt = %BinaryNode{
      tag: "receipt",
      attrs: %{
        "id" => "peer-base-cache-1",
        "from" => "15551234567:2@s.whatsapp.net",
        "type" => "retry"
      },
      content: [
        %BinaryNode{tag: "retry", attrs: %{"count" => "2"}, content: nil},
        %BinaryNode{
          tag: "registration",
          attrs: %{},
          content: {:binary, <<8003::unsigned-big-32>>}
        },
        %BinaryNode{
          tag: "keys",
          attrs: %{},
          content: [
            %BinaryNode{tag: "type", attrs: %{}, content: {:binary, <<5>>}},
            %BinaryNode{tag: "identity", attrs: %{}, content: {:binary, peer_id.public}},
            %BinaryNode{
              tag: "skey",
              attrs: %{},
              content: [
                %BinaryNode{tag: "id", attrs: %{}, content: {:binary, <<3::unsigned-big-24>>}},
                %BinaryNode{tag: "value", attrs: %{}, content: {:binary, peer_spk.public}},
                %BinaryNode{tag: "signature", attrs: %{}, content: {:binary, peer_sig}}
              ]
            }
          ]
        }
      ]
    }

    assert :ok = EventEmitter.emit(emitter_pid, :socket_node, %{node: peer_receipt})

    assert_receive {:fake_socket_send_node,
                    %BinaryNode{
                      tag: "message",
                      attrs: %{
                        "id" => "peer-base-cache-1",
                        "to" => "15551234567:2@s.whatsapp.net",
                        "device_fanout" => "false"
                      }
                    }},
                   1_000
  end

  test "PN retry receipt with known PN-to-LID mapping injects and deletes the canonical LID session" do
    name = {:release_retry_pn_lid_test, System.unique_integer([:positive])}
    parent = self()

    {:ok, alice_store} = SignalStore.new()
    {:ok, bob_store} = SignalStore.new()

    alice_id = Crypto.generate_key_pair(:x25519, private_key: <<811::256>>)
    alice_spk = Crypto.generate_key_pair(:x25519, private_key: <<812::256>>)
    bob_id = Crypto.generate_key_pair(:x25519, private_key: <<813::256>>)
    bob_spk = Crypto.generate_key_pair(:x25519, private_key: <<814::256>>)
    {:ok, bob_spk_pub} = Curve.generate_signal_pub_key(bob_spk.public)
    {:ok, bob_sig} = Curve.sign(bob_id.private, bob_spk_pub)

    bob_new_spk = Crypto.generate_key_pair(:x25519, private_key: <<815::256>>)
    {:ok, bob_new_spk_pub} = Curve.generate_signal_pub_key(bob_new_spk.public)
    {:ok, bob_new_sig} = Curve.sign(bob_id.private, bob_new_spk_pub)

    signal_repository =
      Repository.new(
        adapter: SignalAdapter,
        adapter_state:
          SignalAdapter.new(
            store: alice_store,
            identity_key_pair: alice_id,
            registration_id: 8101,
            signed_pre_key: %{key_id: 1, key_pair: alice_spk}
          ),
        store: alice_store
      )

    {:ok, signal_repository} =
      Repository.store_lid_pn_mappings(signal_repository, [
        %{lid: "77777@lid", pn: "15551234567@s.whatsapp.net"}
      ])

    # Pre-existing LID session with old registration ID 8102
    {:ok, signal_repository} =
      Repository.inject_e2e_session(signal_repository, %{
        jid: "77777:2@lid",
        session: %{
          registration_id: 8102,
          identity_key: bob_id.public,
          signed_pre_key: %{key_id: 10, public_key: bob_spk.public, signature: bob_sig},
          pre_key: nil
        }
      })

    bob_new_repo =
      Repository.new(
        adapter: SignalAdapter,
        adapter_state:
          SignalAdapter.new(
            store: bob_store,
            identity_key_pair: bob_id,
            registration_id: 8199,
            signed_pre_key: %{key_id: 20, key_pair: bob_new_spk}
          ),
        store: bob_store
      )

    assert {:ok, supervisor} =
             Supervisor.start_link(
               name: name,
               config: Config.new(fire_init_queries: false, mark_online_on_connect: false),
               auth_state: %{creds: %{me: %{id: "15550001111@s.whatsapp.net"}}},
               socket_module: FakeSocket,
               signal_repository: signal_repository,
               test_pid: parent,
               transport: {NoopTransport, %{}}
             )

    assert_receive :fake_socket_connect
    runtime_store = supervisor |> child_pid!(Store) |> Store.wrap()

    assert :ok =
             Retry.add_recent_message(
               runtime_store,
               "15551234567@s.whatsapp.net",
               "pn-lid-retry-1",
               Builder.build(%{text: "decryptable via updated LID session"})
             )

    # PN retry receipt carries Bob's new bundle (reg_id 8199, skey 20)
    receipt = %BinaryNode{
      tag: "receipt",
      attrs: %{
        "id" => "pn-lid-retry-1",
        "from" => "15551234567:2@s.whatsapp.net",
        "type" => "retry"
      },
      content: [
        %BinaryNode{tag: "retry", attrs: %{"count" => "2"}, content: nil},
        %BinaryNode{
          tag: "registration",
          attrs: %{},
          content: {:binary, <<8199::unsigned-big-32>>}
        },
        %BinaryNode{
          tag: "keys",
          attrs: %{},
          content: [
            %BinaryNode{tag: "type", attrs: %{}, content: {:binary, <<5>>}},
            %BinaryNode{tag: "identity", attrs: %{}, content: {:binary, bob_id.public}},
            %BinaryNode{
              tag: "skey",
              attrs: %{},
              content: [
                %BinaryNode{tag: "id", attrs: %{}, content: {:binary, <<20::unsigned-big-24>>}},
                %BinaryNode{tag: "value", attrs: %{}, content: {:binary, bob_new_spk.public}},
                %BinaryNode{tag: "signature", attrs: %{}, content: {:binary, bob_new_sig}}
              ]
            }
          ]
        }
      ]
    }

    assert :ok =
             supervisor
             |> child_pid!(EventEmitter)
             |> EventEmitter.emit(:socket_node, %{node: receipt})

    assert_receive {:fake_socket_send_node,
                    %BinaryNode{
                      tag: "message",
                      attrs: %{"id" => "pn-lid-retry-1", "to" => "15551234567:2@s.whatsapp.net"},
                      content: [
                        %BinaryNode{
                          tag: "enc",
                          attrs: %{"type" => "pkmsg"},
                          content: {:binary, ciphertext}
                        }
                      ]
                    }},
                   1_000

    # Must be encrypted against Bob's NEW key (skey 20) installed in canonical LID session 77777_1.2
    assert {:ok, _bob_repo, plaintext} =
             Repository.decrypt_message(bob_new_repo, %{
               jid: "15550001111@s.whatsapp.net",
               type: :pkmsg,
               ciphertext: ciphertext
             })

    assert {:ok,
            %Message{
              extended_text_message: %Message.ExtendedTextMessage{
                text: "decryptable via updated LID session"
              }
            }} = Wire.decode(plaintext)

    # PN address must NOT have a duplicate session written; canonical LID address has reg_id 8199
    assert SignalStore.get(alice_store, :session, ["15551234567.2"]) == %{}

    assert {:ok, %{registration_id: 8199}} =
             Repository.session_info(signal_repository, "15551234567:2@s.whatsapp.net")

    # Registration mismatch on bundle-less PN retry deletes the canonical LID session (77777_1.2)
    assert :ok =
             Retry.add_recent_message(
               runtime_store,
               "15551234567@s.whatsapp.net",
               "pn-lid-retry-2",
               Builder.build(%{text: "mismatch"})
             )

    mismatch_receipt = %BinaryNode{
      tag: "receipt",
      attrs: %{
        "id" => "pn-lid-retry-2",
        "from" => "15551234567:2@s.whatsapp.net",
        "type" => "retry"
      },
      content: [
        %BinaryNode{tag: "retry", attrs: %{"count" => "1"}, content: nil},
        %BinaryNode{
          tag: "registration",
          attrs: %{},
          content: {:binary, <<9999::unsigned-big-32>>}
        }
      ]
    }

    assert :ok =
             supervisor
             |> child_pid!(EventEmitter)
             |> EventEmitter.emit(:socket_node, %{node: mismatch_receipt})

    assert_receive {:fake_socket_query,
                    %BinaryNode{
                      attrs: %{"xmlns" => "encrypt", "type" => "get"},
                      content: [
                        %BinaryNode{
                          tag: "key",
                          content: [
                            %BinaryNode{
                              tag: "user",
                              attrs: %{"jid" => "77777:2@lid", "reason" => "identity"}
                            }
                          ]
                        }
                      ]
                    }, _timeout},
                   1_000

    assert_eventually(fn ->
      SignalStore.get(alice_store, :session, ["77777_1.2"]) == %{}
    end)
  end

  test "retry receipt enforces local outbound attempt bound with persistent get_message_fun and still ACKs exhausted receipts" do
    name = {:release_retry_local_bound_test, System.unique_integer([:positive])}
    parent = self()

    {:ok, alice_store} = SignalStore.new()
    alice_id = Crypto.generate_key_pair(:x25519, private_key: <<821::256>>)
    alice_spk = Crypto.generate_key_pair(:x25519, private_key: <<822::256>>)
    peer_id = Crypto.generate_key_pair(:x25519, private_key: <<823::256>>)
    peer_spk = Crypto.generate_key_pair(:x25519, private_key: <<824::256>>)
    {:ok, peer_spk_pub} = Curve.generate_signal_pub_key(peer_spk.public)
    {:ok, peer_sig} = Curve.sign(peer_id.private, peer_spk_pub)

    signal_repository =
      Repository.new(
        adapter: SignalAdapter,
        adapter_state:
          SignalAdapter.new(
            store: alice_store,
            identity_key_pair: alice_id,
            registration_id: 8201,
            signed_pre_key: %{key_id: 1, key_pair: alice_spk}
          ),
        store: alice_store
      )

    assert {:ok, supervisor} =
             Supervisor.start_link(
               name: name,
               config:
                 Config.new(
                   fire_init_queries: false,
                   mark_online_on_connect: false,
                   max_msg_retry_count: 2
                 ),
               auth_state: %{creds: %{me: %{id: "15550001111@s.whatsapp.net"}}},
               socket_module: FakeSocket,
               signal_repository: signal_repository,
               get_message_fun: fn %{id: "bounded-msg-1"} ->
                 %{message: Builder.build(%{text: "persistent fallback"})}
               end,
               test_pid: parent,
               transport: {NoopTransport, %{}}
             )

    assert_receive :fake_socket_connect
    emitter_pid = child_pid!(supervisor, EventEmitter)

    receipt = %BinaryNode{
      tag: "receipt",
      attrs: %{
        "id" => "bounded-msg-1",
        "from" => "15551234567:2@s.whatsapp.net",
        "type" => "retry"
      },
      content: [
        %BinaryNode{tag: "retry", attrs: %{"count" => "1"}, content: nil},
        %BinaryNode{
          tag: "registration",
          attrs: %{},
          content: {:binary, <<8202::unsigned-big-32>>}
        },
        %BinaryNode{
          tag: "keys",
          attrs: %{},
          content: [
            %BinaryNode{tag: "type", attrs: %{}, content: {:binary, <<5>>}},
            %BinaryNode{tag: "identity", attrs: %{}, content: {:binary, peer_id.public}},
            %BinaryNode{
              tag: "skey",
              attrs: %{},
              content: [
                %BinaryNode{tag: "id", attrs: %{}, content: {:binary, <<4::unsigned-big-24>>}},
                %BinaryNode{tag: "value", attrs: %{}, content: {:binary, peer_spk.public}},
                %BinaryNode{tag: "signature", attrs: %{}, content: {:binary, peer_sig}}
              ]
            }
          ]
        }
      ]
    }

    # Attempts 1 and 2 resend and ACK
    for _ <- 1..2 do
      assert :ok = EventEmitter.emit(emitter_pid, :socket_node, %{node: receipt})

      assert_receive {:fake_socket_send_node,
                      %BinaryNode{tag: "message", attrs: %{"id" => "bounded-msg-1"}}},
                     1_000

      assert_receive {:fake_socket_send_node,
                      %BinaryNode{
                        tag: "ack",
                        attrs: %{"class" => "receipt", "id" => "bounded-msg-1"}
                      }},
                     1_000
    end

    # Attempt 3 with the same count="1" is blocked by the local counter but STILL ACKed
    assert :ok = EventEmitter.emit(emitter_pid, :socket_node, %{node: receipt})

    assert_receive {:fake_socket_send_node,
                    %BinaryNode{
                      tag: "ack",
                      attrs: %{"class" => "receipt", "id" => "bounded-msg-1"}
                    }},
                   1_000

    refute_receive {:fake_socket_send_node,
                    %BinaryNode{tag: "message", attrs: %{"id" => "bounded-msg-1"}}},
                   80
  end

  test "incoming pkmsg session is not deleted by bundle-less retry carrying peer's unchanged registration ID" do
    name = {:release_retry_incoming_regid_test, System.unique_integer([:positive])}
    parent = self()

    {:ok, alice_store} = SignalStore.new()
    {:ok, bob_store} = SignalStore.new()

    alice_id = Crypto.generate_key_pair(:x25519, private_key: <<831::256>>)
    alice_spk = Crypto.generate_key_pair(:x25519, private_key: <<832::256>>)
    {:ok, alice_spk_pub} = Curve.generate_signal_pub_key(alice_spk.public)
    {:ok, alice_sig} = Curve.sign(alice_id.private, alice_spk_pub)

    bob_id = Crypto.generate_key_pair(:x25519, private_key: <<833::256>>)
    bob_spk = Crypto.generate_key_pair(:x25519, private_key: <<834::256>>)

    alice_repo =
      Repository.new(
        adapter: SignalAdapter,
        adapter_state:
          SignalAdapter.new(
            store: alice_store,
            identity_key_pair: alice_id,
            registration_id: 7001,
            signed_pre_key: %{key_id: 1, key_pair: alice_spk}
          ),
        store: alice_store
      )

    bob_repo =
      Repository.new(
        adapter: SignalAdapter,
        adapter_state:
          SignalAdapter.new(
            store: bob_store,
            identity_key_pair: bob_id,
            registration_id: 8888,
            signed_pre_key: %{key_id: 2, key_pair: bob_spk}
          ),
        store: bob_store
      )

    # Bob initiates session to Alice via pkmsg carrying Bob's registration_id 8888
    {:ok, bob_repo} =
      Repository.inject_e2e_session(bob_repo, %{
        jid: "15550001111@s.whatsapp.net",
        session: %{
          registration_id: 7001,
          identity_key: alice_id.public,
          signed_pre_key: %{key_id: 1, public_key: alice_spk.public, signature: alice_sig},
          pre_key: nil
        }
      })

    {:ok, _bob_repo, %{type: :pkmsg, ciphertext: pkmsg_ct}} =
      Repository.encrypt_message(bob_repo, %{jid: "15550001111@s.whatsapp.net", data: "hi alice"})

    {:ok, alice_repo, "hi alice"} =
      Repository.decrypt_message(alice_repo, %{
        jid: "15551234567:2@s.whatsapp.net",
        type: :pkmsg,
        ciphertext: pkmsg_ct
      })

    assert {:ok, supervisor} =
             Supervisor.start_link(
               name: name,
               config: Config.new(fire_init_queries: false, mark_online_on_connect: false),
               auth_state: %{creds: %{me: %{id: "15550001111@s.whatsapp.net"}}},
               socket_module: FakeSocket,
               signal_repository: alice_repo,
               test_pid: parent,
               transport: {NoopTransport, %{}}
             )

    assert_receive :fake_socket_connect
    runtime_store = supervisor |> child_pid!(Store) |> Store.wrap()

    assert :ok =
             Retry.add_recent_message(
               runtime_store,
               "15551234567@s.whatsapp.net",
               "incoming-sess-retry-1",
               Builder.build(%{text: "reply"})
             )

    # Bundle-less count=1 retry with Bob's unchanged reg_id 8888 (encrypt IQ unhandled -> aborts cleanly)
    receipt = %BinaryNode{
      tag: "receipt",
      attrs: %{
        "id" => "incoming-sess-retry-1",
        "from" => "15551234567:2@s.whatsapp.net",
        "type" => "retry"
      },
      content: [
        %BinaryNode{tag: "retry", attrs: %{"count" => "1"}, content: nil},
        %BinaryNode{
          tag: "registration",
          attrs: %{},
          content: {:binary, <<8888::unsigned-big-32>>}
        }
      ]
    }

    assert :ok =
             supervisor
             |> child_pid!(EventEmitter)
             |> EventEmitter.emit(:socket_node, %{node: receipt})

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
                                "jid" => "15551234567:2@s.whatsapp.net",
                                "reason" => "identity"
                              }
                            }
                          ]
                        }
                      ]
                    }, _timeout},
                   1_000

    # Because stored remote reg_id (8888) matches received reg_id (8888), live session was NOT deleted!
    assert {:ok, %{registration_id: 8888}} =
             Repository.session_info(alice_repo, "15551234567:2@s.whatsapp.net")
  end

  test "close cancels tracked blocked-recovery and server_sync tasks and preserves incomplete initial sync across reconnect" do
    name = {:release_bg_task_ownership_test, System.unique_integer([:positive])}
    parent = self()
    blocked_gate = make_ref()
    server_gate = make_ref()

    query_handler = fn
      %BinaryNode{attrs: %{"xmlns" => "w:sync:app:state"}} = node, _timeout ->
        collections =
          node
          |> BinaryNodeUtil.child("sync")
          |> BinaryNodeUtil.children("collection")
          |> Enum.map(& &1.attrs["name"])

        reply =
          {:ok,
           %BinaryNode{
             tag: "iq",
             attrs: %{"type" => "result"},
             content: [
               %BinaryNode{
                 tag: "sync",
                 attrs: %{},
                 content:
                   Enum.map(collections, fn col ->
                     %BinaryNode{
                       tag: "collection",
                       attrs: %{"name" => col, "version" => "0", "has_more_patches" => "false"},
                       content: []
                     }
                   end)
               }
             ]
           }}

        cond do
          collections == ["critical_block"] ->
            send(parent, {:blocked_recovery_started, self()})

            receive do
              {:release_blocked, ^blocked_gate} -> reply
            after
              2_000 -> {:error, :timeout}
            end

          collections == ["regular_high"] ->
            send(parent, {:server_sync_started, self()})

            receive do
              {:release_server, ^server_gate} -> reply
            after
              2_000 -> {:error, :timeout}
            end

          true ->
            send(parent, {:initial_sync_query, self(), collections})

            receive do
              {:release_initial, ^blocked_gate} -> reply
            after
              2_000 -> {:error, :timeout}
            end
        end

      _node, _timeout ->
        {:ok, %BinaryNode{tag: "iq", attrs: %{"type" => "result"}, content: []}}
    end

    assert {:ok, supervisor} =
             Supervisor.start_link(
               name: name,
               config:
                 Config.new(
                   fire_init_queries: false,
                   mark_online_on_connect: false,
                   initial_sync_timeout_ms: 400,
                   reconnect_policy: :disabled
                 ),
               auth_state: %{creds: %{me: %{id: "15550001111@s.whatsapp.net"}}},
               socket_module: FakeSocket,
               test_pid: parent,
               query_handler: query_handler,
               transport: {NoopTransport, %{}}
             )

    assert_receive :fake_socket_connect
    emitter_pid = child_pid!(supervisor, EventEmitter)
    coordinator_pid = child_pid!(supervisor, Coordinator)
    task_supervisor = child_pid!(supervisor, Task.Supervisor)
    store_ref = Store.wrap(child_pid!(supervisor, Store))
    unsubscribe = EventEmitter.process(emitter_pid, &send(parent, {:processed_events, &1}))

    # 1. Start initial sync, park :critical_block, finish pass 1 without key share
    assert :ok =
             EventEmitter.emit(emitter_pid, :connection_update, %{
               received_pending_notifications: true
             })

    assert_eventually(fn -> EventEmitter.buffering?(emitter_pid) end)

    assert :ok =
             EventEmitter.emit(emitter_pid, :messaging_history_set, %{
               chats: [],
               contacts: [],
               messages: [],
               sync_type: :INITIAL_BOOTSTRAP
             })

    assert_receive {:initial_sync_query, init_socket_pid, _collections}, 1_000
    send(coordinator_pid, {:app_state_collection_blocked, 0, :critical_block})
    send(init_socket_pid, {:release_initial, blocked_gate})

    assert_receive {:processed_events,
                    %{connection_update: %{sync_state: :online, initial_sync_complete: true}}},
                   1_000

    # Parked collection means initial sync is NOT complete -> account_sync_counter stays 0
    assert Store.get(store_ref, :creds, %{})[:account_sync_counter] in [nil, 0]

    # 2. Key share starts a tracked blocked-recovery task; close kills it before it finishes
    assert :ok = EventEmitter.emit(emitter_pid, :creds_update, %{my_app_state_key_id: "key-1"})
    assert_receive {:blocked_recovery_started, blocked_socket_pid}, 1_000
    assert [blocked_task_pid] = Task.Supervisor.children(task_supervisor)
    blocked_mon = Process.monitor(blocked_task_pid)

    assert :ok =
             EventEmitter.emit(emitter_pid, :connection_update, %{
               connection: :close,
               last_disconnect: %{error: %{reason: :connection_closed}}
             })

    assert_receive {:DOWN, ^blocked_mon, :process, ^blocked_task_pid, _reason}, 1_000
    send(blocked_socket_pid, {:release_blocked, blocked_gate})
    assert Store.get(store_ref, :creds, %{})[:account_sync_counter] in [nil, 0]

    # 3. Reconnect WITHOUT history replay must immediately resume :critical_block instead of waiting
    #    for the no-history watchdog to falsely increment account_sync_counter
    assert :ok =
             EventEmitter.emit(emitter_pid, :connection_update, %{
               received_pending_notifications: true
             })

    assert_receive {:blocked_recovery_started, resume_socket_pid}, 1_000
    # Park :critical_block again on generation 1 and release -> still incomplete, counter stays 0
    send(coordinator_pid, {:app_state_collection_blocked, 1, :critical_block})
    send(resume_socket_pid, {:release_blocked, blocked_gate})

    assert_receive {:processed_events,
                    %{
                      connection_update: %{
                        sync_state: :online,
                        initial_sync_complete: true,
                        initial_sync_reason: :initial_sync_complete
                      }
                    }},
                   1_000

    assert Store.get(store_ref, :creds, %{})[:account_sync_counter] in [nil, 0]

    # 4. server_sync notification defers ACK until completion; cancelling on close leaves it un-ACKed for redelivery
    notification = %BinaryNode{
      tag: "notification",
      attrs: %{"id" => "srv-close-1", "type" => "server_sync", "from" => "s.whatsapp.net"},
      content: [%BinaryNode{tag: "collection", attrs: %{"name" => "regular_high"}, content: nil}]
    }

    assert :ok =
             EventEmitter.emit(emitter_pid, :socket_node, %{node: notification, state: :connected})

    assert_receive {:server_sync_started, server_socket_pid}, 1_000
    assert [server_task_pid] = Task.Supervisor.children(task_supervisor)
    server_mon = Process.monitor(server_task_pid)

    refute_receive {:fake_socket_send_node,
                    %BinaryNode{tag: "ack", attrs: %{"id" => "srv-close-1"}}},
                   50

    assert :ok =
             EventEmitter.emit(emitter_pid, :connection_update, %{
               connection: :close,
               last_disconnect: %{error: %{reason: :connection_closed}}
             })

    assert_receive {:DOWN, ^server_mon, :process, ^server_task_pid, _reason}, 1_000
    send(server_socket_pid, {:release_server, server_gate})

    refute_receive {:fake_socket_send_node,
                    %BinaryNode{tag: "ack", attrs: %{"id" => "srv-close-1"}}},
                   50

    assert Process.alive?(coordinator_pid)

    # 5. Next reconnect WITHOUT history replay resumes :critical_block and advances counter on completion
    assert :ok =
             EventEmitter.emit(emitter_pid, :connection_update, %{
               received_pending_notifications: true
             })

    assert_receive {:blocked_recovery_started, final_resume_socket_pid}, 1_000
    send(final_resume_socket_pid, {:release_blocked, blocked_gate})

    assert_receive {:processed_events,
                    %{
                      connection_update: %{
                        sync_state: :online,
                        initial_sync_complete: true,
                        initial_sync_reason: :initial_sync_complete
                      }
                    }},
                   1_000

    assert_eventually(fn -> Store.get(store_ref, :creds, %{})[:account_sync_counter] == 1 end)

    unsubscribe.()
  end

  test "abnormal Coordinator restart kills parked workers and auto-resumes pending work on connected socket" do
    name = {:release_coordinator_restart_tasks_test, System.unique_integer([:positive])}
    parent = self()
    gate = make_ref()
    {:ok, connect_calls} = Agent.start_link(fn -> 0 end)

    # Model real Socket.connect/1: first call succeeds, subsequent calls on surviving connected socket
    # return {:error, {:invalid_state, :connected}} without emitting a new offline-complete frame.
    connect_handler = fn ->
      case Agent.get_and_update(connect_calls, fn n -> {n + 1, n + 1} end) do
        1 -> :ok
        _ -> {:error, {:invalid_state, :connected}}
      end
    end

    query_handler = fn
      %BinaryNode{attrs: %{"xmlns" => "w:sync:app:state"}} = node, _timeout ->
        collections =
          node
          |> BinaryNodeUtil.child("sync")
          |> BinaryNodeUtil.children("collection")
          |> Enum.map(& &1.attrs["name"])

        reply =
          {:ok,
           %BinaryNode{
             tag: "iq",
             attrs: %{"type" => "result"},
             content: [
               %BinaryNode{
                 tag: "sync",
                 attrs: %{},
                 content:
                   Enum.map(collections, fn col ->
                     %BinaryNode{
                       tag: "collection",
                       attrs: %{"name" => col, "version" => "0", "has_more_patches" => "false"},
                       content: []
                     }
                   end)
               }
             ]
           }}

        cond do
          collections == ["critical_block"] ->
            send(parent, {:parked_blocked_query, self()})

            receive do
              {:release_blocked, ^gate} -> reply
            after
              2_000 -> {:error, :timeout}
            end

          collections == ["regular_high"] ->
            send(parent, {:parked_server_query, self()})

            receive do
              {:release_server, ^gate} -> reply
            after
              2_000 -> {:error, :timeout}
            end

          true ->
            send(parent, {:parked_initial_query, self()})

            receive do
              {:release_initial, ^gate} -> reply
            after
              2_000 -> {:error, :timeout}
            end
        end

      _node, _timeout ->
        {:ok, %BinaryNode{tag: "iq", attrs: %{"type" => "result"}, content: []}}
    end

    assert {:ok, supervisor} =
             Supervisor.start_link(
               name: name,
               config:
                 Config.new(
                   fire_init_queries: false,
                   mark_online_on_connect: false,
                   reconnect_policy: :disabled
                 ),
               auth_state: %{creds: %{me: %{id: "15550001111@s.whatsapp.net"}}},
               socket_module: FakeSocket,
               connect_handler: connect_handler,
               test_pid: parent,
               query_handler: query_handler,
               transport: {NoopTransport, %{}}
             )

    assert_receive :fake_socket_connect
    emitter_pid = child_pid!(supervisor, EventEmitter)
    coordinator_pid = child_pid!(supervisor, Coordinator)
    task_supervisor = child_pid!(supervisor, Task.Supervisor)
    store_ref = Store.wrap(child_pid!(supervisor, Store))
    unsubscribe = EventEmitter.process(emitter_pid, &send(parent, {:processed_events, &1}))

    # Reach :online with :critical_block parked so pending work persists across Coordinator restart
    assert :ok =
             EventEmitter.emit(emitter_pid, :connection_update, %{
               received_pending_notifications: true
             })

    assert_eventually(fn -> EventEmitter.buffering?(emitter_pid) end)

    assert :ok =
             EventEmitter.emit(emitter_pid, :messaging_history_set, %{
               chats: [],
               contacts: [],
               messages: [],
               sync_type: :INITIAL_BOOTSTRAP
             })

    assert_receive {:parked_initial_query, init_socket_pid}, 1_000
    send(coordinator_pid, {:app_state_collection_blocked, 0, :critical_block})
    send(init_socket_pid, {:release_initial, gate})

    assert_receive {:processed_events,
                    %{connection_update: %{sync_state: :online, initial_sync_complete: true}}},
                   1_000

    # 1. Park a blocked-recovery task under surviving Task.Supervisor, then kill ONLY Coordinator
    assert :ok = EventEmitter.emit(emitter_pid, :creds_update, %{my_app_state_key_id: "key-1"})
    assert_receive {:parked_blocked_query, blocked_socket_pid}, 1_000
    assert [blocked_task_pid] = Task.Supervisor.children(task_supervisor)
    blocked_mon = Process.monitor(blocked_task_pid)

    Process.exit(coordinator_pid, :kill)
    assert_receive {:DOWN, ^blocked_mon, :process, ^blocked_task_pid, _reason}, 1_000
    send(blocked_socket_pid, {:release_blocked, gate})

    # Replacement Coordinator attaches to surviving connected socket ({:error, {:invalid_state, :connected}})
    # and AUTOMATICALLY resumes :critical_block with NO synthesized transport event
    assert_receive :fake_socket_connect, 1_000
    assert_receive {:parked_blocked_query, resumed_blocked_socket_pid}, 1_000
    send(resumed_blocked_socket_pid, {:release_blocked, gate})
    assert_eventually(fn -> Store.get(store_ref, :creds, %{})[:account_sync_counter] == 1 end)

    restarted_coordinator = child_pid!(supervisor, Coordinator)
    refute restarted_coordinator == coordinator_pid

    # 2. Park a server_sync task (ACK deferred), kill ONLY Coordinator, verify ACK still omitted until
    #    replacement Coordinator auto-resumes regular_high on the surviving connected socket
    server_notification = %BinaryNode{
      tag: "notification",
      attrs: %{"id" => "srv-restart-1", "type" => "server_sync", "from" => "s.whatsapp.net"},
      content: [%BinaryNode{tag: "collection", attrs: %{"name" => "regular_high"}, content: nil}]
    }

    assert :ok =
             EventEmitter.emit(emitter_pid, :socket_node, %{
               node: server_notification,
               state: :connected
             })

    assert_receive {:parked_server_query, server_socket_pid}, 1_000
    assert [server_task_pid] = Task.Supervisor.children(task_supervisor)
    server_mon = Process.monitor(server_task_pid)

    refute_receive {:fake_socket_send_node,
                    %BinaryNode{tag: "ack", attrs: %{"id" => "srv-restart-1"}}},
                   50

    Process.exit(restarted_coordinator, :kill)
    assert_receive {:DOWN, ^server_mon, :process, ^server_task_pid, _reason}, 1_000
    send(server_socket_pid, {:release_server, gate})

    refute_receive {:fake_socket_send_node,
                    %BinaryNode{tag: "ack", attrs: %{"id" => "srv-restart-1"}}},
                   50

    # Third Coordinator auto-resumes regular_high on the surviving connected socket and ACKs ONLY after completion
    assert_receive :fake_socket_connect, 1_000
    assert_receive {:parked_server_query, resumed_server_socket_pid}, 1_000

    refute_receive {:fake_socket_send_node,
                    %BinaryNode{tag: "ack", attrs: %{"id" => "srv-restart-1"}}},
                   50

    send(resumed_server_socket_pid, {:release_server, gate})

    assert_receive {:fake_socket_send_node,
                    %BinaryNode{
                      tag: "ack",
                      attrs: %{
                        "id" => "srv-restart-1",
                        "class" => "notification",
                        "type" => "server_sync",
                        "to" => "s.whatsapp.net"
                      }
                    }},
                   1_000

    unsubscribe.()
  end

  test "replacement Coordinator recovers pending work when old Coordinator dies before handling offline-complete" do
    name = {:release_offline_handoff_crash_test, System.unique_integer([:positive])}
    parent = self()
    {:ok, connect_calls} = Agent.start_link(fn -> 0 end)
    {:ok, offline_flag} = Agent.start_link(fn -> false end)

    connect_handler = fn ->
      case Agent.get_and_update(connect_calls, fn n -> {n + 1, n + 1} end) do
        1 -> :ok
        _ -> {:error, {:invalid_state, :connected}}
      end
    end

    query_handler = fn
      %BinaryNode{attrs: %{"xmlns" => "w:sync:app:state"}} = node, _timeout ->
        collections =
          node
          |> BinaryNodeUtil.child("sync")
          |> BinaryNodeUtil.children("collection")
          |> Enum.map(& &1.attrs["name"])

        send(parent, {:recovered_after_handoff_query, collections})

        {:ok,
         %BinaryNode{
           tag: "iq",
           attrs: %{"type" => "result"},
           content: [
             %BinaryNode{
               tag: "sync",
               attrs: %{},
               content:
                 Enum.map(collections, fn col ->
                   %BinaryNode{
                     tag: "collection",
                     attrs: %{"name" => col, "version" => "0", "has_more_patches" => "false"},
                     content: []
                   }
                 end)
             }
           ]
         }}

      _node, _timeout ->
        {:ok, %BinaryNode{tag: "iq", attrs: %{"type" => "result"}, content: []}}
    end

    assert {:ok, supervisor} =
             Supervisor.start_link(
               name: name,
               config:
                 Config.new(
                   fire_init_queries: false,
                   mark_online_on_connect: false,
                   reconnect_policy: :disabled
                 ),
               auth_state: %{creds: %{me: %{id: "15550001111@s.whatsapp.net"}}},
               socket_module: FakeSocket,
               connect_handler: connect_handler,
               offline_received_handler: fn -> Agent.get(offline_flag, & &1) end,
               test_pid: parent,
               query_handler: query_handler,
               transport: {NoopTransport, %{}}
             )

    assert_receive :fake_socket_connect
    emitter_pid = child_pid!(supervisor, EventEmitter)
    store_pid = child_pid!(supervisor, Store)
    store_ref = Store.wrap(store_pid)
    coordinator_pid = child_pid!(supervisor, Coordinator)

    # Seed retained pending initial work from an earlier session while Store's offline marker is absent
    assert :ok =
             Store.put(
               store_pid,
               :pending_initial_app_state_collections,
               MapSet.new([:critical_block])
             )

    assert Store.get(store_ref, :offline_notifications_received) == nil

    # First verify: if Coordinator dies BEFORE socket marks offline-complete, replacement stays :connecting
    Process.exit(coordinator_pid, :kill)
    assert_receive :fake_socket_connect, 1_000
    refute_receive {:recovered_after_handoff_query, _}, 80

    second_coordinator = child_pid!(supervisor, Coordinator)
    refute second_coordinator == coordinator_pid

    # Now suspend second Coordinator so offline-complete sits unhandled in its mailbox when it dies
    :ok = :sys.suspend(second_coordinator)
    Agent.update(offline_flag, fn _ -> true end)

    assert :ok =
             EventEmitter.emit(emitter_pid, :connection_update, %{
               received_pending_notifications: true
             })

    # Confirm second Coordinator never handled the event or updated Store before dying
    assert Store.get(store_ref, :offline_notifications_received) == nil
    Process.exit(second_coordinator, :kill)

    # Replacement Coordinator queries the surviving socket's authoritative offline state and resumes :critical_block
    assert_receive :fake_socket_connect, 1_000
    assert_receive {:recovered_after_handoff_query, ["critical_block"]}, 1_000
    assert_eventually(fn -> Store.get(store_ref, :creds, %{})[:account_sync_counter] == 1 end)
  end

  test "online blocked-collection recovery advances account_sync_counter once the parked collection completes" do
    name = {:release_online_blocked_recovery_test, System.unique_integer([:positive])}
    parent = self()
    gate = make_ref()

    query_handler = fn
      %BinaryNode{attrs: %{"xmlns" => "w:sync:app:state"}} = node, _timeout ->
        collections =
          node
          |> BinaryNodeUtil.child("sync")
          |> BinaryNodeUtil.children("collection")
          |> Enum.map(& &1.attrs["name"])

        reply =
          {:ok,
           %BinaryNode{
             tag: "iq",
             attrs: %{"type" => "result"},
             content: [
               %BinaryNode{
                 tag: "sync",
                 attrs: %{},
                 content:
                   Enum.map(collections, fn col ->
                     %BinaryNode{
                       tag: "collection",
                       attrs: %{"name" => col, "version" => "0", "has_more_patches" => "false"},
                       content: []
                     }
                   end)
               }
             ]
           }}

        if collections == ["critical_block"] do
          send(parent, {:online_blocked_recovery_query, collections})
          reply
        else
          send(parent, {:online_initial_query, self(), collections})

          receive do
            {:release, ^gate} -> reply
          after
            2_000 -> {:error, :timeout}
          end
        end

      _node, _timeout ->
        {:ok, %BinaryNode{tag: "iq", attrs: %{"type" => "result"}, content: []}}
    end

    assert {:ok, supervisor} =
             Supervisor.start_link(
               name: name,
               config: Config.new(fire_init_queries: false, mark_online_on_connect: false),
               auth_state: %{creds: %{me: %{id: "15550001111@s.whatsapp.net"}}},
               socket_module: FakeSocket,
               test_pid: parent,
               query_handler: query_handler,
               transport: {NoopTransport, %{}}
             )

    assert_receive :fake_socket_connect
    emitter_pid = child_pid!(supervisor, EventEmitter)
    coordinator_pid = child_pid!(supervisor, Coordinator)
    store_ref = Store.wrap(child_pid!(supervisor, Store))
    unsubscribe = EventEmitter.process(emitter_pid, &send(parent, {:processed_events, &1}))

    assert :ok =
             EventEmitter.emit(emitter_pid, :connection_update, %{
               received_pending_notifications: true
             })

    assert_eventually(fn -> EventEmitter.buffering?(emitter_pid) end)

    assert :ok =
             EventEmitter.emit(emitter_pid, :messaging_history_set, %{
               chats: [],
               contacts: [],
               messages: [],
               sync_type: :INITIAL_BOOTSTRAP
             })

    assert_receive {:online_initial_query, init_socket_pid, _collections}, 1_000
    send(coordinator_pid, {:app_state_collection_blocked, 0, :critical_block})
    send(init_socket_pid, {:release, gate})

    assert_receive {:processed_events,
                    %{connection_update: %{sync_state: :online, initial_sync_complete: true}}},
                   1_000

    assert Store.get(store_ref, :creds, %{})[:account_sync_counter] in [nil, 0]

    assert :ok = EventEmitter.emit(emitter_pid, :creds_update, %{my_app_state_key_id: "key-1"})
    assert_receive {:online_blocked_recovery_query, ["critical_block"]}, 1_000
    assert_eventually(fn -> Store.get(store_ref, :creds, %{})[:account_sync_counter] == 1 end)

    unsubscribe.()
  end

  test "mixed omitted and blocked collections during initial sync do not advance account_sync_counter after follow-on blocked pass" do
    name = {:release_mixed_omitted_blocked_test, System.unique_integer([:positive])}
    parent = self()
    gate = make_ref()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    query_handler = fn
      %BinaryNode{attrs: %{"xmlns" => "w:sync:app:state"}} = node, _timeout ->
        call = Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end)

        collections =
          node
          |> BinaryNodeUtil.child("sync")
          |> BinaryNodeUtil.children("collection")
          |> Enum.map(& &1.attrs["name"])

        send(parent, {:mixed_app_state_query, call, self(), collections})

        # Omit "regular" on initial pass so it exhausts omission retries while :critical_block parks
        returned_collections =
          if collections == ["critical_block"] do
            collections
          else
            Enum.reject(collections, &(&1 == "regular"))
          end

        reply =
          {:ok,
           %BinaryNode{
             tag: "iq",
             attrs: %{"type" => "result"},
             content: [
               %BinaryNode{
                 tag: "sync",
                 attrs: %{},
                 content:
                   Enum.map(returned_collections, fn col ->
                     %BinaryNode{
                       tag: "collection",
                       attrs: %{"name" => col, "version" => "0", "has_more_patches" => "false"},
                       content: []
                     }
                   end)
               }
             ]
           }}

        if call == 1 do
          receive do
            {:release_pass_1, ^gate} -> reply
          after
            2_000 -> {:error, :timeout}
          end
        else
          reply
        end

      _node, _timeout ->
        {:ok, %BinaryNode{tag: "iq", attrs: %{"type" => "result"}, content: []}}
    end

    assert {:ok, supervisor} =
             Supervisor.start_link(
               name: name,
               config:
                 Config.new(
                   fire_init_queries: false,
                   mark_online_on_connect: false,
                   initial_sync_timeout_ms: 400,
                   reconnect_policy: :disabled
                 ),
               auth_state: %{creds: %{me: %{id: "15550001111@s.whatsapp.net"}}},
               socket_module: FakeSocket,
               test_pid: parent,
               query_handler: query_handler,
               transport: {NoopTransport, %{}}
             )

    assert_receive :fake_socket_connect
    emitter_pid = child_pid!(supervisor, EventEmitter)
    coordinator_pid = child_pid!(supervisor, Coordinator)
    store_ref = Store.wrap(child_pid!(supervisor, Store))
    unsubscribe = EventEmitter.process(emitter_pid, &send(parent, {:processed_events, &1}))

    assert :ok =
             EventEmitter.emit(emitter_pid, :connection_update, %{
               received_pending_notifications: true
             })

    assert_eventually(fn -> EventEmitter.buffering?(emitter_pid) end)

    assert :ok =
             EventEmitter.emit(emitter_pid, :messaging_history_set, %{
               chats: [],
               contacts: [],
               messages: [],
               sync_type: :INITIAL_BOOTSTRAP
             })

    assert_receive {:mixed_app_state_query, 1, first_socket_pid, _collections}, 1_000
    send(coordinator_pid, {:app_state_collection_blocked, 0, :critical_block})
    assert :ok = EventEmitter.emit(emitter_pid, :creds_update, %{my_app_state_key_id: "key-1"})
    send(first_socket_pid, {:release_pass_1, gate})

    # Pass 1 retries "regular" once more, fails with missing_collections, then follows up on :critical_block
    assert_receive {:mixed_app_state_query, 2, _socket_pid, ["regular"]}, 1_000
    assert_receive {:mixed_app_state_query, 3, _socket_pid, ["critical_block"]}, 1_000

    assert_receive {:processed_events,
                    %{connection_update: %{sync_state: :online, initial_sync_complete: true}}},
                   1_000

    # Follow-on pass for :critical_block succeeded, but :regular was omitted -> counter MUST stay 0!
    assert Store.get(store_ref, :creds, %{})[:account_sync_counter] in [nil, 0]

    unsubscribe.()
  end

  test "bundle-less retry aborts resend when forced encrypt IQ omits requester while still ACKing receipt" do
    name = {:release_empty_encrypt_iq_test, System.unique_integer([:positive])}
    parent = self()
    {repo, _signal_store} = MessageSignalHelpers.new_repo()
    session = MessageSignalHelpers.session_fixture()

    assert {:ok, repo} =
             Repository.inject_e2e_session(repo, %{
               jid: "15551234567:2@s.whatsapp.net",
               session: session
             })

    query_handler = fn
      %BinaryNode{attrs: %{"xmlns" => "encrypt", "type" => "get"}}, _timeout ->
        {:ok,
         %BinaryNode{
           tag: "iq",
           attrs: %{"type" => "result"},
           content: [%BinaryNode{tag: "list", attrs: %{}, content: []}]
         }}

      _node, _timeout ->
        {:ok, %BinaryNode{tag: "iq", attrs: %{"type" => "result"}, content: []}}
    end

    assert {:ok, supervisor} =
             Supervisor.start_link(
               name: name,
               config: Config.new(fire_init_queries: false, mark_online_on_connect: false),
               auth_state: %{creds: %{me: %{id: "15550001111@s.whatsapp.net"}}},
               socket_module: FakeSocket,
               signal_repository: repo,
               query_handler: query_handler,
               test_pid: parent,
               transport: {NoopTransport, %{}}
             )

    assert_receive :fake_socket_connect
    runtime_store = supervisor |> child_pid!(Store) |> Store.wrap()

    assert :ok =
             Retry.add_recent_message(
               runtime_store,
               "15551234567@s.whatsapp.net",
               "empty-encrypt-retry-1",
               Builder.build(%{text: "must not resend on stale session"})
             )

    receipt = %BinaryNode{
      tag: "receipt",
      attrs: %{
        "id" => "empty-encrypt-retry-1",
        "from" => "15551234567:2@s.whatsapp.net",
        "type" => "retry"
      },
      content: [%BinaryNode{tag: "retry", attrs: %{"count" => "1"}, content: nil}]
    }

    assert :ok =
             supervisor
             |> child_pid!(EventEmitter)
             |> EventEmitter.emit(:socket_node, %{node: receipt})

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
                                "jid" => "15551234567:2@s.whatsapp.net",
                                "reason" => "identity"
                              }
                            }
                          ]
                        }
                      ]
                    }, _timeout},
                   1_000

    assert_receive {:fake_socket_send_node,
                    %BinaryNode{
                      tag: "ack",
                      attrs: %{
                        "class" => "receipt",
                        "id" => "empty-encrypt-retry-1",
                        "type" => "retry"
                      }
                    }},
                   1_000

    refute_receive {:fake_socket_send_node,
                    %BinaryNode{tag: "message", attrs: %{"id" => "empty-encrypt-retry-1"}}},
                   100
  end

  test "primary-device retry bypasses device-list cache via USync and fans out to newly discovered companion devices" do
    name = {:release_primary_retry_usync_test, System.unique_integer([:positive])}
    parent = self()
    {repo, signal_store} = MessageSignalHelpers.new_repo()
    session = MessageSignalHelpers.session_fixture()

    # Stale cache only knows about primary device 0
    assert :ok = SignalStore.set(signal_store, %{:"device-list" => %{"15551234567" => ["0"]}})

    assert {:ok, repo} =
             Repository.inject_e2e_session(repo, %{
               jid: "15551234567@s.whatsapp.net",
               session: session
             })

    query_handler = fn
      %BinaryNode{attrs: %{"xmlns" => "usync"}} = node, _timeout ->
        send(parent, {:primary_retry_usync, node})

        {:ok,
         %BinaryNode{
           tag: "iq",
           attrs: %{"type" => "result"},
           content: [
             %BinaryNode{
               tag: "usync",
               attrs: %{},
               content: [
                 %BinaryNode{
                   tag: "list",
                   attrs: %{},
                   content: [
                     %BinaryNode{
                       tag: "user",
                       attrs: %{"jid" => "15551234567@s.whatsapp.net"},
                       content: [
                         %BinaryNode{
                           tag: "devices",
                           attrs: %{},
                           content: [
                             %BinaryNode{
                               tag: "device-list",
                               attrs: %{},
                               content: [
                                 %BinaryNode{tag: "device", attrs: %{"id" => "0"}},
                                 %BinaryNode{tag: "device", attrs: %{"id" => "3"}}
                               ]
                             }
                           ]
                         }
                       ]
                     }
                   ]
                 }
               ]
             }
           ]
         }}

      %BinaryNode{
        attrs: %{"xmlns" => "encrypt", "type" => "get"},
        content: [%BinaryNode{tag: "key", content: user_nodes}]
      },
      _timeout ->
        {:ok,
         %BinaryNode{
           tag: "iq",
           attrs: %{"type" => "result"},
           content: [
             %BinaryNode{
               tag: "list",
               attrs: %{},
               content:
                 Enum.map(user_nodes, fn %BinaryNode{attrs: %{"jid" => user_jid}} ->
                   %BinaryNode{
                     tag: "user",
                     attrs: %{"jid" => user_jid},
                     content: [
                       %BinaryNode{
                         tag: "registration",
                         attrs: %{},
                         content: {:binary, <<0, 0, 0, 42>>}
                       },
                       %BinaryNode{
                         tag: "identity",
                         attrs: %{},
                         content: {:binary, session.identity_key}
                       },
                       %BinaryNode{
                         tag: "skey",
                         attrs: %{},
                         content: [
                           %BinaryNode{tag: "id", attrs: %{}, content: {:binary, <<0, 0, 0, 7>>}},
                           %BinaryNode{
                             tag: "value",
                             attrs: %{},
                             content: {:binary, session.signed_pre_key.public_key}
                           },
                           %BinaryNode{
                             tag: "signature",
                             attrs: %{},
                             content: {:binary, session.signed_pre_key.signature}
                           }
                         ]
                       }
                     ]
                   }
                 end)
             }
           ]
         }}

      _node, _timeout ->
        {:ok, %BinaryNode{tag: "iq", attrs: %{"type" => "result"}, content: []}}
    end

    assert {:ok, supervisor} =
             Supervisor.start_link(
               name: name,
               config: Config.new(fire_init_queries: false, mark_online_on_connect: false),
               auth_state: %{creds: %{me: %{id: "15550001111@s.whatsapp.net"}}},
               socket_module: FakeSocket,
               signal_repository: repo,
               signal_store: signal_store,
               query_handler: query_handler,
               test_pid: parent,
               transport: {NoopTransport, %{}}
             )

    assert_receive :fake_socket_connect
    runtime_store = supervisor |> child_pid!(Store) |> Store.wrap()

    assert :ok =
             Retry.add_recent_message(
               runtime_store,
               "15551234567@s.whatsapp.net",
               "primary-usync-retry-1",
               Builder.build(%{text: "fanout to newly added companion"})
             )

    receipt = %BinaryNode{
      tag: "receipt",
      attrs: %{
        "id" => "primary-usync-retry-1",
        "from" => "15551234567@s.whatsapp.net",
        "type" => "retry"
      },
      content: [%BinaryNode{tag: "retry", attrs: %{"count" => "1"}, content: nil}]
    }

    assert :ok =
             supervisor
             |> child_pid!(EventEmitter)
             |> EventEmitter.emit(:socket_node, %{node: receipt})

    assert_receive {:primary_retry_usync, %BinaryNode{tag: "iq", attrs: %{"xmlns" => "usync"}}},
                   1_000

    assert_receive {:fake_socket_send_node,
                    %BinaryNode{
                      tag: "message",
                      attrs: %{"id" => "primary-usync-retry-1"},
                      content: children
                    }},
                   1_000

    assert %BinaryNode{tag: "participants", content: participant_nodes} =
             Enum.find(children, &(&1.tag == "participants"))

    sent_jids = Enum.map(participant_nodes, & &1.attrs["jid"])
    assert "15551234567@s.whatsapp.net" in sent_jids
    assert "15551234567:3@s.whatsapp.net" in sent_jids
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

  defp assert_query_xmlns_sequence(expected) when is_list(expected) do
    actual =
      Enum.map(expected, fn _ ->
        receive do
          {:fake_socket_query, %BinaryNode{attrs: %{"xmlns" => xmlns}}, 60_000} -> xmlns
        after
          1_000 -> flunk("expected init query sequence #{inspect(expected)}, got fewer queries")
        end
      end)

    assert actual == expected
  end
end
