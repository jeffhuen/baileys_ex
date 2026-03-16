defmodule BaileysEx.PublicApiTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias BaileysEx.BinaryNode
  alias BaileysEx.Connection.Config
  alias BaileysEx.Connection.EventEmitter
  alias BaileysEx.Connection.Supervisor
  alias BaileysEx.Protocol.Proto.ADVSignedDeviceIdentity
  alias BaileysEx.Protocol.Proto.Message
  alias BaileysEx.Signal.Repository
  alias BaileysEx.Signal.Store
  alias BaileysEx.TestHelpers.MessageSignalHelpers
  alias BaileysEx.WAM

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

    def request_pairing_code(server, phone_number, opts),
      do: GenServer.call(server, {:request_pairing_code, phone_number, opts})

    def send_presence_update(server, type),
      do: GenServer.call(server, {:send_presence_update, type})

    def query(server, %BinaryNode{} = node, timeout),
      do: GenServer.call(server, {:query, node, timeout}, timeout + 100)

    def send_node(server, %BinaryNode{} = node), do: GenServer.call(server, {:send_node, node})

    def send_wam_buffer(server, wam_buffer),
      do: GenServer.call(server, {:send_wam_buffer, wam_buffer})

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
      send(state.test_pid, :fake_socket_connect)
      {:reply, :ok, state}
    end

    def handle_call({:request_pairing_code, phone_number, opts}, _from, state) do
      send(state.test_pid, {:fake_socket_pairing_code, phone_number, opts})
      {:reply, {:ok, "123-456"}, state}
    end

    def handle_call({:send_presence_update, type}, _from, state) do
      send(state.test_pid, {:fake_socket_presence_update, type})
      {:reply, :ok, state}
    end

    def handle_call({:query, node, timeout}, _from, state) do
      send(state.test_pid, {:fake_socket_query, node, timeout})
      {:reply, state.query_handler.(node, timeout), state}
    end

    def handle_call({:send_node, node}, _from, state) do
      send(state.test_pid, {:fake_socket_send_node, node})
      {:reply, :ok, state}
    end

    def handle_call({:send_wam_buffer, wam_buffer}, _from, state) do
      send(state.test_pid, {:fake_socket_send_wam_buffer, wam_buffer})

      {:reply,
       {:ok,
        %BinaryNode{
          tag: "iq",
          attrs: %{"type" => "result", "xmlns" => "w:stats"},
          content: nil
        }}, state}
    end
  end

  test "connect/2 wires convenience callbacks and subscribe/2 emits friendly events" do
    parent = self()

    assert {:ok, connection} =
             BaileysEx.connect(%{creds: %{}},
               config: Config.new(fire_init_queries: false),
               socket_module: FakeSocket,
               test_pid: self(),
               on_connection: &send(parent, {:on_connection, &1}),
               on_qr: &send(parent, {:on_qr, &1})
             )

    assert_receive :fake_socket_connect

    assert {:ok, emitter} = BaileysEx.event_emitter(connection)

    unsubscribe =
      BaileysEx.subscribe(connection, fn event ->
        send(parent, {:public_event, event})
      end)

    assert :ok = EventEmitter.emit(emitter, :connection_update, %{connection: :open})
    assert :ok = EventEmitter.emit(emitter, :connection_update, %{qr: "phase-12-qr"})

    message = %{key: %{id: "message-1"}, message: %Message{conversation: "hello"}}

    assert :ok =
             EventEmitter.emit(emitter, :messages_upsert, %{type: :notify, messages: [message]})

    assert_receive {:on_connection, %{connection: :open}}
    assert_receive {:on_qr, "phase-12-qr"}
    assert_receive {:public_event, {:connection, %{connection: :open}}}
    assert_receive {:public_event, {:connection, %{qr: "phase-12-qr"}}}
    assert_receive {:public_event, {:message, ^message}}

    unsubscribe.()
    assert :ok = BaileysEx.disconnect(connection)
  end

  test "send_message/4 and group_create/4 use the connection runtime" do
    {repo, _store} = MessageSignalHelpers.new_repo()
    session = MessageSignalHelpers.session_fixture()

    {:ok, repo} =
      Repository.inject_e2e_session(repo, %{
        jid: "15551234567:0@s.whatsapp.net",
        session: session
      })

    {:ok, repo} =
      Repository.inject_e2e_session(repo, %{
        jid: "15550001111:2@s.whatsapp.net",
        session: session
      })

    query_handler = fn _node, _timeout ->
      {:ok,
       %BinaryNode{
         tag: "iq",
         attrs: %{"type" => "result"},
         content: [
           %BinaryNode{
             tag: "group",
             attrs: %{
               "id" => "120363001234567890@g.us",
               "subject" => "Phase 12",
               "s_t" => "1710000000",
               "size" => "1",
               "creation" => "1710000000"
             }
           }
         ]
       }}
    end

    assert {:ok, connection} =
             BaileysEx.connect(
               %{creds: %{me: %{id: "15550001111:1@s.whatsapp.net", name: "Bailey"}}},
               config: Config.new(fire_init_queries: false),
               socket_module: FakeSocket,
               test_pid: self(),
               query_handler: query_handler,
               signal_repository_adapter: MessageSignalHelpers.FakeAdapter,
               signal_repository_adapter_state: repo.adapter_state
             )

    assert_receive :fake_socket_connect

    assert %Store{} = signal_store = Supervisor.signal_store(connection)

    assert :ok =
             Store.set(signal_store, %{
               :"device-list" => %{"15551234567" => ["0"], "15550001111" => ["1", "2"]}
             })

    assert {:ok, %{id: "3EB0PUBLIC"}} =
             BaileysEx.send_message(connection, "15551234567@s.whatsapp.net", %{text: "hello"},
               message_id_fun: fn _me_id -> "3EB0PUBLIC" end
             )

    assert_receive {:fake_socket_send_node,
                    %BinaryNode{
                      tag: "message",
                      attrs: %{"id" => "3EB0PUBLIC", "to" => "15551234567@s.whatsapp.net"}
                    }}

    assert {:ok, {FakeSocket, _socket_pid}} = BaileysEx.queryable(connection)

    assert {:ok, %{id: "120363001234567890@g.us", subject: "Phase 12"}} =
             BaileysEx.group_create(connection, "Phase 12", ["15551234567@s.whatsapp.net"])

    assert_receive {:fake_socket_query,
                    %BinaryNode{
                      tag: "iq",
                      attrs: %{"to" => "@g.us", "type" => "set", "xmlns" => "w:g2"}
                    }, _timeout}

    assert :ok = BaileysEx.disconnect(connection)
  end

  test "send_wam_buffer/2 encodes BinaryInfo inputs before handing them to the socket" do
    assert {:ok, connection} =
             BaileysEx.connect(%{creds: %{}},
               config: Config.new(fire_init_queries: false),
               socket_module: FakeSocket,
               test_pid: self()
             )

    assert_receive :fake_socket_connect

    wam_buffer =
      WAM.new(sequence: 7)
      |> WAM.put_event(
        "WamDroppedEvent",
        [droppedEventCode: 5, droppedEventCount: 300, isFromWamsys: true],
        appIsBetaRelease: true,
        appVersion: "2.24.7"
      )

    assert {:ok, %BinaryNode{attrs: %{"xmlns" => "w:stats"}}} =
             BaileysEx.send_wam_buffer(connection, wam_buffer)

    assert_receive {:fake_socket_send_wam_buffer, encoded}

    assert encoded ==
             Base.decode16!(
               "57414D05010007002015801106322E32342E37390611FF31010541022C012603",
               case: :mixed
             )

    assert :ok = BaileysEx.disconnect(connection)
  end

  test "send_message/4 ignores unknown account identity keys and still relays device identity" do
    auth_state = %{
      creds: %{
        me: %{id: "15550001111:1@s.whatsapp.net", name: "Bailey"},
        account: %{
          "details" => <<1, 2>>,
          "account_signature_key" => <<9, 9>>,
          "account_signature" => <<3, 4>>,
          "device_signature" => <<5, 6>>,
          "extra" => "ignored"
        }
      }
    }

    assert {:ok, connection} = connect_runtime_with_fake_signal(auth_state)
    assert_receive :fake_socket_connect
    assert :ok = seed_runtime_device_list(connection)

    assert {:ok, %{id: "3EB0STRINGKEYS"}} =
             BaileysEx.send_message(connection, "15551234567@s.whatsapp.net", %{text: "hello"},
               message_id_fun: fn _me_id -> "3EB0STRINGKEYS" end
             )

    assert_receive {:fake_socket_send_node, %BinaryNode{content: content}}

    assert %BinaryNode{tag: "device-identity", content: {:binary, encoded_device_identity}} =
             Enum.find(content, &match?(%BinaryNode{tag: "device-identity"}, &1))

    assert {:ok,
            %ADVSignedDeviceIdentity{
              details: <<1, 2>>,
              account_signature_key: <<9, 9>>,
              account_signature: <<3, 4>>,
              device_signature: <<5, 6>>
            }} = ADVSignedDeviceIdentity.decode(encoded_device_identity)

    assert :ok = BaileysEx.disconnect(connection)
  end

  test "send_message/4 omits empty account signature keys from device identity" do
    auth_state = %{
      creds: %{
        me: %{id: "15550001111:1@s.whatsapp.net", name: "Bailey"},
        account: %{
          "details" => <<1, 2>>,
          "account_signature_key" => <<>>,
          "account_signature" => <<3, 4>>,
          "device_signature" => <<5, 6>>
        }
      }
    }

    assert {:ok, connection} = connect_runtime_with_fake_signal(auth_state)
    assert_receive :fake_socket_connect
    assert :ok = seed_runtime_device_list(connection)

    assert {:ok, %{id: "3EB0EMPTYSIGKEY"}} =
             BaileysEx.send_message(connection, "15551234567@s.whatsapp.net", %{text: "hello"},
               message_id_fun: fn _me_id -> "3EB0EMPTYSIGKEY" end
             )

    assert_receive {:fake_socket_send_node, %BinaryNode{content: content}}

    assert %BinaryNode{tag: "device-identity", content: {:binary, encoded_device_identity}} =
             Enum.find(content, &match?(%BinaryNode{tag: "device-identity"}, &1))

    assert {:ok,
            %ADVSignedDeviceIdentity{
              details: <<1, 2>>,
              account_signature_key: nil,
              account_signature: <<3, 4>>,
              device_signature: <<5, 6>>
            }} = ADVSignedDeviceIdentity.decode(encoded_device_identity)

    assert :ok = BaileysEx.disconnect(connection)
  end

  test "send_message/4 logs and drops malformed account identity data" do
    auth_state = %{
      creds: %{
        me: %{id: "15550001111:1@s.whatsapp.net", name: "Bailey"},
        account: %{
          "details" => 123,
          "account_signature" => <<3, 4>>,
          "device_signature" => <<5, 6>>
        }
      }
    }

    assert {:ok, connection} = connect_runtime_with_fake_signal(auth_state)
    assert_receive :fake_socket_connect
    assert :ok = seed_runtime_device_list(connection)

    log =
      capture_log(fn ->
        assert {:ok, %{id: "3EB0BADIDENTITY"}} =
                 BaileysEx.send_message(
                   connection,
                   "15551234567@s.whatsapp.net",
                   %{text: "hello"},
                   message_id_fun: fn _me_id -> "3EB0BADIDENTITY" end
                 )

        assert_receive {:fake_socket_send_node, %BinaryNode{content: content}}

        refute Enum.any?(content, &match?(%BinaryNode{tag: "device-identity"}, &1))
      end)

    assert log =~ "dropping invalid device identity account"
    assert log =~ "details"

    assert :ok = BaileysEx.disconnect(connection)
  end

  defp connect_runtime_with_fake_signal(auth_state) do
    {repo, _store} = MessageSignalHelpers.new_repo()
    session = MessageSignalHelpers.session_fixture()

    {:ok, repo} =
      Repository.inject_e2e_session(repo, %{
        jid: "15551234567:0@s.whatsapp.net",
        session: session
      })

    {:ok, repo} =
      Repository.inject_e2e_session(repo, %{
        jid: "15550001111:2@s.whatsapp.net",
        session: session
      })

    BaileysEx.connect(auth_state,
      config: Config.new(fire_init_queries: false),
      socket_module: FakeSocket,
      test_pid: self(),
      signal_repository_adapter: MessageSignalHelpers.FakeAdapter,
      signal_repository_adapter_state: repo.adapter_state
    )
  end

  defp seed_runtime_device_list(connection) do
    assert %Store{} = signal_store = Supervisor.signal_store(connection)

    Store.set(signal_store, %{
      :"device-list" => %{"15551234567" => ["0"], "15550001111" => ["1", "2"]}
    })
  end
end
