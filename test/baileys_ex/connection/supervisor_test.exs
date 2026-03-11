defmodule BaileysEx.Connection.SupervisorTest do
  use ExUnit.Case, async: true

  alias BaileysEx.BinaryNode
  alias BaileysEx.Auth.FilePersistence
  alias BaileysEx.Auth.KeyStore
  alias BaileysEx.Auth.State
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

  test "connection open fires init queries, updates store caches, and marks presence available" do
    name = {:phase6_test, System.unique_integer([:positive])}

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

      %BinaryNode{attrs: %{"xmlns" => "encrypt"}, content: [%BinaryNode{tag: "count"}]},
      _timeout ->
        {:ok,
         %BinaryNode{
           tag: "iq",
           attrs: %{"type" => "result"},
           content: [%BinaryNode{tag: "count", attrs: %{"value" => "10"}, content: nil}]
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

    assert :ok = EventEmitter.emit(emitter_pid, :connection_update, %{connection: :open})

    assert_receive {:fake_socket_presence_update, :available}

    assert_eventually_xmlns(["w", "blocklist", "privacy", "encrypt"])

    assert_eventually(fn ->
      Store.get(store_ref, :props) == %{"web:voip" => "1"} and
        Store.get(store_ref, :blocklist) == ["11111@s.whatsapp.net", "22222@s.whatsapp.net"] and
        Store.get(store_ref, :privacy_settings) == %{"last" => "contacts"} and
        Store.get(store_ref, :creds)[:last_prop_hash] == "next-prop-hash"
    end)
  end

  @tag :tmp_dir
  test "connection open uploads pre-keys when the current pre-key is missing from storage", %{
    tmp_dir: tmp_dir
  } do
    name = {:phase7_test, System.unique_integer([:positive])}
    test_pid = self()

    query_handler = fn
      %BinaryNode{
        attrs: %{"xmlns" => "encrypt", "type" => "get"},
        content: [%BinaryNode{tag: "count"}]
      },
      _timeout ->
        {:ok,
         %BinaryNode{
           tag: "iq",
           attrs: %{"type" => "result"},
           content: [%BinaryNode{tag: "count", attrs: %{"value" => "10"}, content: nil}]
         }}

      %BinaryNode{attrs: %{"xmlns" => "encrypt", "type" => "set"}} = node, _timeout ->
        send(test_pid, {:prekey_upload_query, node})
        {:ok, %BinaryNode{tag: "iq", attrs: %{"type" => "result"}, content: nil}}
    end

    auth_state =
      State.new()
      |> Map.put(:me, %{id: "15551234567@s.whatsapp.net", name: "~"})
      |> Map.put(:next_pre_key_id, 2)
      |> Map.put(:first_unuploaded_pre_key_id, 2)

    assert {:ok, supervisor} =
             Supervisor.start_link(
               name: name,
               config: Config.new(fire_init_queries: false, mark_online_on_connect: false),
               auth_state: auth_state,
               socket_module: FakeSocket,
               signal_store_module: KeyStore,
               signal_store_opts: [
                 persistence_module: FilePersistence,
                 persistence_context: tmp_dir
               ],
               test_pid: self(),
               query_handler: query_handler,
               transport: {NoopTransport, %{}}
             )

    assert_receive :fake_socket_connect

    emitter_pid = child_pid!(supervisor, EventEmitter)
    store_ref = supervisor |> child_pid!(Store) |> Store.wrap()

    assert :ok = EventEmitter.emit(emitter_pid, :connection_update, %{connection: :open})

    assert_receive {:fake_socket_query,
                    %BinaryNode{attrs: %{"xmlns" => "encrypt", "type" => "get"}}, 60_000}

    assert_eventually(fn ->
      receive do
        {:prekey_upload_query, %BinaryNode{attrs: %{"xmlns" => "encrypt", "type" => "set"}}} ->
          true

        {:fake_socket_presence_update, :unavailable} ->
          false
      after
        0 ->
          false
      end
    end)

    assert_eventually(fn ->
      Store.get(store_ref, :creds)[:next_pre_key_id] == 7 and
        Store.get(store_ref, :creds)[:first_unuploaded_pre_key_id] == 7
    end)

    assert {:ok, %{public: public, private: private}} =
             FilePersistence.load_keys(tmp_dir, :"pre-key", "2")

    assert is_binary(public)
    assert is_binary(private)
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

  test "community dirty notifications reuse the groups clean bucket" do
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

    assert :ok = EventEmitter.emit(emitter_pid, :dirty_update, %{type: "communities"})

    assert_receive {:fake_socket_send_node,
                    %BinaryNode{
                      tag: "iq",
                      attrs: %{"xmlns" => "urn:xmpp:whatsapp:dirty", "type" => "set"},
                      content: [%BinaryNode{tag: "clean", attrs: %{"type" => "groups"}}]
                    }}
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
