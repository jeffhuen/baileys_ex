defmodule BaileysEx.Connection.SocketTest do
  use ExUnit.Case, async: true

  import Kernel, except: [send: 2]

  alias BaileysEx.BinaryNode
  alias BaileysEx.Crypto
  alias BaileysEx.Auth.QR
  alias BaileysEx.Connection.Config
  alias BaileysEx.Connection.EventEmitter
  alias BaileysEx.Connection.Socket
  alias BaileysEx.Protocol.BinaryNode, as: BinaryNodeUtil
  alias BaileysEx.Protocol.Noise
  alias BaileysEx.Protocol.Proto.ADVDeviceIdentity
  alias BaileysEx.Protocol.Proto.ADVSignedDeviceIdentity
  alias BaileysEx.Protocol.Proto.ADVSignedDeviceIdentityHMAC
  alias BaileysEx.Protocol.Proto.HandshakeMessage
  alias BaileysEx.Protocol.Proto.HandshakeMessage.ClientHello
  alias BaileysEx.Signal.Curve
  alias BaileysEx.TestSupport.Connection.NoiseServer

  defmodule ScriptedTransport do
    import Kernel, except: [send: 2]

    @behaviour BaileysEx.Connection.Transport

    @impl true
    def connect(config, opts), do: {:ok, %{config: config, opts: opts}}

    @impl true
    def handle_info(state, {:scripted_transport, event}), do: {:ok, state, [event]}

    def handle_info(_state, _message), do: :unknown

    @impl true
    def disconnect(_transport_state), do: :ok

    @impl true
    def send_binary(%{opts: %{test_pid: test_pid}} = state, payload) do
      Kernel.send(test_pid, {:transport_sent, payload})
      {:ok, state}
    end
  end

  defmodule FailingTransport do
    @behaviour BaileysEx.Connection.Transport

    @impl true
    def connect(_config, opts), do: {:error, Map.fetch!(opts, :reason)}

    @impl true
    def handle_info(_state, _message), do: :unknown

    @impl true
    def disconnect(_transport_state), do: :ok

    @impl true
    def send_binary(state, _payload), do: {:error, state, :not_connected}
  end

  test "starts disconnected with an empty runtime snapshot" do
    assert {:ok, pid} = Socket.start_link(config: Config.new(), auth_state: %{creds: %{}})

    assert :disconnected == Socket.state(pid)

    assert %{
             state: :disconnected,
             retry_count: 0,
             buffer_size: 0,
             transport_connected?: false,
             last_error: nil
           } = Socket.snapshot(pid)
  end

  test "connect/1 waits for a transport connected event before starting the noise handshake" do
    client_noise_key_pair = Crypto.generate_key_pair(:x25519)
    root_key_pair = Crypto.generate_key_pair(:x25519)
    trusted_cert = %{serial: 0, public_key: root_key_pair.public}

    assert {:ok, pid} =
             Socket.start_link(
               config: Config.new(),
               auth_state: %{noise_key: client_noise_key_pair, creds: %{routing_info: nil}},
               client_payload: "client-payload",
               noise_opts: [trusted_cert: trusted_cert],
               transport: {ScriptedTransport, %{test_pid: self()}}
             )

    assert :ok = Socket.connect(pid)
    assert_eventually(fn -> Socket.state(pid) == :connecting end)
    assert Socket.snapshot(pid).transport_connected? == false
    refute_received {:transport_sent, _payload}

    Kernel.send(pid, {:scripted_transport, :connected})

    assert_receive {:transport_sent, client_hello}

    assert {:ok,
            %HandshakeMessage{
              client_hello: %ClientHello{ephemeral: client_ephemeral}
            }} = HandshakeMessage.decode(client_hello)

    assert is_binary(client_ephemeral)

    assert_eventually(fn ->
      Socket.state(pid) == :noise_handshake and Socket.snapshot(pid).transport_connected?
    end)
  end

  test "a valid server hello advances the socket into authenticating and sends client finish" do
    client_payload = "client-payload"
    client_noise_key_pair = Crypto.generate_key_pair(:x25519)
    root_key_pair = Crypto.generate_key_pair(:x25519)
    intermediate_key_pair = Crypto.generate_key_pair(:x25519)
    server_static_key_pair = Crypto.generate_key_pair(:x25519)
    trusted_cert = %{serial: 0, public_key: root_key_pair.public}

    assert {:ok, pid} =
             Socket.start_link(
               config: Config.new(),
               auth_state: %{noise_key: client_noise_key_pair, creds: %{routing_info: nil}},
               client_payload: client_payload,
               noise_opts: [trusted_cert: trusted_cert],
               transport: {ScriptedTransport, %{test_pid: self()}}
             )

    assert :ok = Socket.connect(pid)
    Kernel.send(pid, {:scripted_transport, :connected})
    assert_receive {:transport_sent, client_hello}

    assert {:ok, server_hello, server_state} =
             NoiseServer.build_server_hello(client_hello,
               root_key_pair: root_key_pair,
               intermediate_key_pair: intermediate_key_pair,
               server_static_key_pair: server_static_key_pair,
               issuer_serial: trusted_cert.serial
             )

    Kernel.send(pid, {:scripted_transport, {:binary, server_hello}})

    assert_receive {:transport_sent, client_finish}

    assert {:ok, %{client_payload: ^client_payload, client_static: client_static}} =
             NoiseServer.process_client_finish(server_state, client_finish)

    assert client_static == client_noise_key_pair.public
    assert_eventually(fn -> Socket.state(pid) == :authenticating end)
  end

  test "an invalid server hello returns the socket to disconnected and records the error" do
    client_noise_key_pair = Crypto.generate_key_pair(:x25519)
    root_key_pair = Crypto.generate_key_pair(:x25519)
    trusted_cert = %{serial: 0, public_key: root_key_pair.public}

    assert {:ok, pid} =
             Socket.start_link(
               config: Config.new(),
               auth_state: %{noise_key: client_noise_key_pair, creds: %{routing_info: nil}},
               client_payload: "client-payload",
               noise_opts: [trusted_cert: trusted_cert],
               transport: {ScriptedTransport, %{test_pid: self()}}
             )

    assert :ok = Socket.connect(pid)
    Kernel.send(pid, {:scripted_transport, :connected})
    assert_receive {:transport_sent, _client_hello}

    invalid_server_hello = HandshakeMessage.encode(%HandshakeMessage{})

    Kernel.send(pid, {:scripted_transport, {:binary, invalid_server_hello}})

    assert_eventually(fn ->
      Socket.snapshot(pid) == %{
        state: :disconnected,
        retry_count: 1,
        buffer_size: 0,
        transport_connected?: false,
        last_error: :invalid_server_hello
      }
    end)
  end

  test "socket transitions through disconnected, connecting, noise_handshake, authenticating, connected, and disconnected" do
    client_payload = "client-payload"
    client_noise_key_pair = Crypto.generate_key_pair(:x25519)
    root_key_pair = Crypto.generate_key_pair(:x25519)
    intermediate_key_pair = Crypto.generate_key_pair(:x25519)
    server_static_key_pair = Crypto.generate_key_pair(:x25519)
    trusted_cert = %{serial: 0, public_key: root_key_pair.public}

    assert {:ok, pid} =
             Socket.start_link(
               config: Config.new(keep_alive_interval_ms: 5_000),
               auth_state: %{noise_key: client_noise_key_pair, creds: %{routing_info: nil}},
               client_payload: client_payload,
               noise_opts: [trusted_cert: trusted_cert],
               transport: {ScriptedTransport, %{test_pid: self()}}
             )

    assert :disconnected == Socket.state(pid)

    assert :ok = Socket.connect(pid)
    assert_eventually(fn -> Socket.state(pid) == :connecting end)

    Kernel.send(pid, {:scripted_transport, :connected})
    assert_receive {:transport_sent, client_hello}
    assert_eventually(fn -> Socket.state(pid) == :noise_handshake end)

    assert {:ok, server_hello, server_state} =
             NoiseServer.build_server_hello(client_hello,
               root_key_pair: root_key_pair,
               intermediate_key_pair: intermediate_key_pair,
               server_static_key_pair: server_static_key_pair,
               issuer_serial: trusted_cert.serial
             )

    Kernel.send(pid, {:scripted_transport, {:binary, server_hello}})
    assert_receive {:transport_sent, client_finish}

    assert {:ok, %{transport: server_transport}} =
             NoiseServer.process_client_finish(server_state, client_finish)

    assert_eventually(fn -> Socket.state(pid) == :authenticating end)

    success_node = %BinaryNode{tag: "success", attrs: %{"t" => "1_710_000_000"}}
    {_server_transport, success_frame} = server_transport_frame(server_transport, success_node)
    Kernel.send(pid, {:scripted_transport, {:binary, success_frame}})

    assert_receive {:transport_sent, _passive_iq_frame}
    assert_receive {:transport_sent, _unified_session_frame}
    assert_eventually(fn -> Socket.state(pid) == :connected end)

    assert :ok = Socket.disconnect(pid)
    assert :disconnected == Socket.state(pid)
  end

  test "connect/1 returns to disconnected and records the error on transport failure" do
    assert {:ok, pid} =
             Socket.start_link(
               config: Config.new(),
               auth_state: %{creds: %{}},
               transport: {FailingTransport, %{reason: :tcp_closed}}
             )

    assert :ok = Socket.connect(pid)

    assert_eventually(fn ->
      Socket.snapshot(pid) == %{
        state: :disconnected,
        retry_count: 1,
        buffer_size: 0,
        transport_connected?: false,
        last_error: :tcp_closed
      }
    end)
  end

  test "send_payload/2 rejects sends before the socket is connected" do
    assert {:ok, pid} = Socket.start_link(config: Config.new(), auth_state: %{creds: %{}})

    assert {:error, :not_connected} = Socket.send_payload(pid, "hello")
  end

  test "connect/1 emits a connecting connection update before the transport opens" do
    test_pid = self()
    {:ok, event_emitter} = EventEmitter.start_link(buffer_timeout_ms: 50)

    _unsubscribe =
      EventEmitter.process(event_emitter, &Kernel.send(test_pid, {:processed_events, &1}))

    assert {:ok, pid} =
             Socket.start_link(
               config: Config.new(),
               auth_state: %{creds: %{}},
               event_emitter: event_emitter,
               transport: {ScriptedTransport, %{test_pid: self()}}
             )

    assert :ok = Socket.connect(pid)

    assert_receive {:processed_events, %{connection_update: %{connection: :connecting}}}
  end

  test "a success node advances the socket into connected, emits open, and sends unified_session" do
    test_pid = self()
    {:ok, event_emitter} = EventEmitter.start_link(buffer_timeout_ms: 50)

    _unsubscribe =
      EventEmitter.process(event_emitter, &Kernel.send(test_pid, {:processed_events, &1}))

    {:ok, pid, server_transport} =
      start_authenticated_socket(
        event_emitter: event_emitter,
        config: Config.new(keep_alive_interval_ms: 5_000)
      )

    success_node =
      %BinaryNode{
        tag: "success",
        attrs: %{"t" => "1_710_000_000", "lid" => "12345678901234@lid"}
      }

    {server_transport, success_frame} = server_transport_frame(server_transport, success_node)
    Kernel.send(pid, {:scripted_transport, {:binary, success_frame}})

    assert_receive {:processed_events, %{connection_update: %{connection: :open}}}
    assert_eventually(fn -> Socket.state(pid) == :connected end)

    assert_receive {:transport_sent, passive_iq_frame}

    {server_transport, passive_iq_node} =
      decode_client_transport_frame(server_transport, passive_iq_frame)

    assert %BinaryNode{
             tag: "iq",
             attrs: %{"xmlns" => "passive", "type" => "set"}
           } = passive_iq_node

    assert %BinaryNode{tag: "active"} = BinaryNodeUtil.child(passive_iq_node, "active")

    assert_receive {:transport_sent, unified_session_frame}

    {_, unified_session_node} =
      decode_client_transport_frame(server_transport, unified_session_frame)

    assert %BinaryNode{tag: "ib"} = unified_session_node

    assert %BinaryNode{tag: "unified_session"} =
             BinaryNodeUtil.child(unified_session_node, "unified_session")
  end

  test "connected sockets send keep alive pings on the configured interval" do
    test_pid = self()
    {:ok, event_emitter} = EventEmitter.start_link(buffer_timeout_ms: 50)

    _unsubscribe =
      EventEmitter.process(event_emitter, &Kernel.send(test_pid, {:processed_events, &1}))

    {:ok, _pid, server_transport} =
      start_connected_socket(
        event_emitter: event_emitter,
        config: Config.new(keep_alive_interval_ms: 25)
      )

    assert_receive {:transport_sent, keep_alive_frame}, 200

    {_, keep_alive_node} = decode_client_transport_frame(server_transport, keep_alive_frame)

    assert %BinaryNode{
             tag: "iq",
             attrs: %{"xmlns" => "w:p", "type" => "get"}
           } = keep_alive_node

    assert %BinaryNode{tag: "ping"} = BinaryNodeUtil.child(keep_alive_node, "ping")
  end

  test "offline preview requests an offline batch and offline emits received_pending_notifications" do
    test_pid = self()
    {:ok, event_emitter} = EventEmitter.start_link(buffer_timeout_ms: 50)

    _unsubscribe =
      EventEmitter.process(event_emitter, &Kernel.send(test_pid, {:processed_events, &1}))

    {:ok, pid, server_transport} =
      start_connected_socket(
        event_emitter: event_emitter,
        config: Config.new(keep_alive_interval_ms: 5_000)
      )

    offline_preview_node =
      %BinaryNode{
        tag: "ib",
        attrs: %{},
        content: [%BinaryNode{tag: "offline_preview", attrs: %{}, content: nil}]
      }

    {server_transport, offline_preview_frame} =
      server_transport_frame(server_transport, offline_preview_node)

    Kernel.send(pid, {:scripted_transport, {:binary, offline_preview_frame}})

    assert_receive {:transport_sent, offline_batch_frame}

    {server_transport, offline_batch_node} =
      decode_client_transport_frame(server_transport, offline_batch_frame)

    assert %BinaryNode{tag: "ib"} = offline_batch_node

    assert %BinaryNode{tag: "offline_batch", attrs: %{"count" => "100"}} =
             BinaryNodeUtil.child(offline_batch_node, "offline_batch")

    offline_node =
      %BinaryNode{
        tag: "ib",
        attrs: %{},
        content: [%BinaryNode{tag: "offline", attrs: %{"count" => "3"}}]
      }

    {_, offline_frame} = server_transport_frame(server_transport, offline_node)
    Kernel.send(pid, {:scripted_transport, {:binary, offline_frame}})

    assert_receive {:processed_events,
                    %{connection_update: %{received_pending_notifications: true}}}
  end

  test "edge routing updates emit creds updates with the new routing info" do
    test_pid = self()
    {:ok, event_emitter} = EventEmitter.start_link(buffer_timeout_ms: 50)

    _unsubscribe =
      EventEmitter.process(event_emitter, &Kernel.send(test_pid, {:processed_events, &1}))

    routing_info = <<1, 2, 3, 4>>

    {:ok, pid, server_transport} =
      start_connected_socket(
        event_emitter: event_emitter,
        config: Config.new(keep_alive_interval_ms: 5_000)
      )

    edge_routing_node =
      %BinaryNode{
        tag: "ib",
        attrs: %{},
        content: [
          %BinaryNode{
            tag: "edge_routing",
            attrs: %{},
            content: [
              %BinaryNode{tag: "routing_info", attrs: %{}, content: {:binary, routing_info}}
            ]
          }
        ]
      }

    {_, frame} = server_transport_frame(server_transport, edge_routing_node)
    Kernel.send(pid, {:scripted_transport, {:binary, frame}})

    assert_receive {:processed_events, %{creds_update: %{routing_info: ^routing_info}}}
  end

  test "socket does not blanket-ack inbound nodes outside the explicit pairing parity cases" do
    test_pid = self()
    {:ok, event_emitter} = EventEmitter.start_link(buffer_timeout_ms: 50)

    _unsubscribe =
      EventEmitter.process(event_emitter, &Kernel.send(test_pid, {:processed_events, &1}))

    {:ok, pid, server_transport} =
      start_connected_socket(
        event_emitter: event_emitter,
        config: Config.new(keep_alive_interval_ms: 5_000)
      )

    dirty_node =
      %BinaryNode{
        tag: "ib",
        attrs: %{},
        content: [
          %BinaryNode{
            tag: "dirty",
            attrs: %{"type" => "account_sync", "timestamp" => "1710000000"},
            content: nil
          }
        ]
      }

    {_, frame} = server_transport_frame(server_transport, dirty_node)
    Kernel.send(pid, {:scripted_transport, {:binary, frame}})

    assert_receive {:processed_events,
                    %{dirty_update: %{type: "account_sync", timestamp: 1_710_000_000}}}

    refute_receive {:transport_sent, _unexpected_ack}, 50
  end

  test "logout/1 sends remove-companion-device and transitions the socket to disconnected" do
    test_pid = self()
    {:ok, event_emitter} = EventEmitter.start_link(buffer_timeout_ms: 50)

    _unsubscribe =
      EventEmitter.process(event_emitter, &Kernel.send(test_pid, {:processed_events, &1}))

    {:ok, pid, server_transport} =
      start_connected_socket(
        event_emitter: event_emitter,
        config: Config.new(keep_alive_interval_ms: 5_000),
        auth_state: %{creds: %{me: %{id: "15551234567@s.whatsapp.net"}}}
      )

    assert :ok = Socket.logout(pid)
    assert_receive {:transport_sent, logout_frame}

    {_, logout_node} = decode_client_transport_frame(server_transport, logout_frame)

    assert %BinaryNode{tag: "iq", attrs: %{"xmlns" => "md", "type" => "set"}} = logout_node

    assert %BinaryNode{
             tag: "remove-companion-device",
             attrs: %{"jid" => "15551234567@s.whatsapp.net", "reason" => "user_initiated"}
           } = BinaryNodeUtil.child(logout_node, "remove-companion-device")

    assert_eventually(fn -> Socket.state(pid) == :disconnected end)
    assert_receive {:processed_events, %{connection_update: %{connection: :close}}}
  end

  test "transport close returns the socket to disconnected and emits the close reason" do
    test_pid = self()
    {:ok, event_emitter} = EventEmitter.start_link(buffer_timeout_ms: 50)

    _unsubscribe =
      EventEmitter.process(event_emitter, &Kernel.send(test_pid, {:processed_events, &1}))

    {:ok, pid, _server_transport} =
      start_connected_socket(
        event_emitter: event_emitter,
        config: Config.new(keep_alive_interval_ms: 5_000)
      )

    Kernel.send(pid, {:scripted_transport, {:closed, :tcp_closed}})

    assert_eventually(fn -> Socket.state(pid) == :disconnected end)

    assert_receive {:processed_events,
                    %{
                      connection_update: %{
                        connection: :close,
                        last_disconnect: %{reason: :tcp_closed}
                      }
                    }}
  end

  test "send_presence_update available emits is_online, resends unified_session, and sends presence" do
    test_pid = self()
    {:ok, event_emitter} = EventEmitter.start_link(buffer_timeout_ms: 50)

    _unsubscribe =
      EventEmitter.process(event_emitter, &Kernel.send(test_pid, {:processed_events, &1}))

    {:ok, pid, server_transport} =
      start_connected_socket(
        event_emitter: event_emitter,
        config: Config.new(keep_alive_interval_ms: 5_000),
        auth_state: %{
          creds: %{
            me: %{id: "15551234567@s.whatsapp.net", name: "Jeff@"}
          }
        }
      )

    assert :ok = Socket.send_presence_update(pid, :available)
    assert_receive {:processed_events, %{connection_update: %{is_online: true}}}

    assert_receive {:transport_sent, unified_session_frame}

    {server_transport, unified_session_node} =
      decode_client_transport_frame(server_transport, unified_session_frame)

    assert %BinaryNode{tag: "ib"} = unified_session_node

    assert %BinaryNode{tag: "unified_session"} =
             BinaryNodeUtil.child(unified_session_node, "unified_session")

    assert_receive {:transport_sent, presence_frame}
    {_, presence_node} = decode_client_transport_frame(server_transport, presence_frame)

    assert %BinaryNode{
             tag: "presence",
             attrs: %{"name" => "Jeff", "type" => "available"}
           } = presence_node
  end

  test "send_presence_update unavailable emits is_online false and sends presence without unified_session" do
    test_pid = self()
    {:ok, event_emitter} = EventEmitter.start_link(buffer_timeout_ms: 50)

    _unsubscribe =
      EventEmitter.process(event_emitter, &Kernel.send(test_pid, {:processed_events, &1}))

    {:ok, pid, server_transport} =
      start_connected_socket(
        event_emitter: event_emitter,
        config: Config.new(keep_alive_interval_ms: 5_000),
        auth_state: %{
          creds: %{
            me: %{id: "15551234567@s.whatsapp.net", name: "Jeff@"}
          }
        }
      )

    assert :ok = Socket.send_presence_update(pid, :unavailable)
    assert_receive {:processed_events, %{connection_update: %{is_online: false}}}

    assert_receive {:transport_sent, presence_frame}
    {_, presence_node} = decode_client_transport_frame(server_transport, presence_frame)

    assert %BinaryNode{
             tag: "presence",
             attrs: %{"name" => "Jeff", "type" => "unavailable"}
           } = presence_node

    refute_received {:transport_sent, _unified_session_frame}
  end

  test "query/3 sends an iq and resolves with the matching response node" do
    test_pid = self()
    {:ok, event_emitter} = EventEmitter.start_link(buffer_timeout_ms: 50)

    _unsubscribe =
      EventEmitter.process(event_emitter, &Kernel.send(test_pid, {:processed_events, &1}))

    {:ok, pid, server_transport} =
      start_connected_socket(
        event_emitter: event_emitter,
        config: Config.new(keep_alive_interval_ms: 5_000)
      )

    query_task =
      Task.async(fn ->
        Socket.query(pid, %BinaryNode{
          tag: "iq",
          attrs: %{"xmlns" => "w", "type" => "get", "to" => "s.whatsapp.net"},
          content: [
            %BinaryNode{tag: "props", attrs: %{"protocol" => "2", "hash" => ""}, content: nil}
          ]
        })
      end)

    assert_receive {:transport_sent, query_frame}

    {server_transport, query_node} = decode_client_transport_frame(server_transport, query_frame)

    assert %BinaryNode{
             tag: "iq",
             attrs: %{"xmlns" => "w", "type" => "get", "to" => "s.whatsapp.net", "id" => query_id}
           } = query_node

    response_node =
      %BinaryNode{
        tag: "iq",
        attrs: %{"id" => query_id, "type" => "result", "from" => "s.whatsapp.net"},
        content: [
          %BinaryNode{
            tag: "props",
            attrs: %{"hash" => "next-hash"},
            content: [
              %BinaryNode{
                tag: "prop",
                attrs: %{"name" => "web:voip", "value" => "1"},
                content: nil
              }
            ]
          }
        ]
      }

    {_, response_frame} = server_transport_frame(server_transport, response_node)
    Kernel.send(pid, {:scripted_transport, {:binary, response_frame}})

    assert {:ok, ^response_node} = Task.await(query_task)
  end

  test "query/3 returns timeout when no matching response arrives" do
    test_pid = self()
    {:ok, event_emitter} = EventEmitter.start_link(buffer_timeout_ms: 50)

    _unsubscribe =
      EventEmitter.process(event_emitter, &Kernel.send(test_pid, {:processed_events, &1}))

    {:ok, pid, _server_transport} =
      start_connected_socket(
        event_emitter: event_emitter,
        config: Config.new(keep_alive_interval_ms: 5_000)
      )

    assert {:error, :timeout} =
             Socket.query(
               pid,
               %BinaryNode{
                 tag: "iq",
                 attrs: %{"xmlns" => "privacy", "type" => "get", "to" => "s.whatsapp.net"},
                 content: [%BinaryNode{tag: "privacy", attrs: %{}, content: nil}]
               },
               25
             )
  end

  test "pair-device acknowledges the stanza and emits a QR update" do
    test_pid = self()
    {:ok, event_emitter} = EventEmitter.start_link(buffer_timeout_ms: 50)

    _unsubscribe =
      EventEmitter.process(event_emitter, &Kernel.send(test_pid, {:processed_events, &1}))

    auth_state = pairing_auth_state()

    {:ok, pid, server_transport} =
      start_authenticated_socket(
        event_emitter: event_emitter,
        config: Config.new(keep_alive_interval_ms: 5_000),
        auth_state: auth_state
      )

    pair_device_node = pair_device_stanza("pair-device-1", ["ref-1", "ref-2"])
    {server_transport, frame} = server_transport_frame(server_transport, pair_device_node)
    Kernel.send(pid, {:scripted_transport, {:binary, frame}})

    assert_receive {:transport_sent, ack_frame}
    {_server_transport, ack_node} = decode_client_transport_frame(server_transport, ack_frame)

    assert %BinaryNode{
             tag: "iq",
             attrs: %{"id" => "pair-device-1", "to" => "s.whatsapp.net", "type" => "result"}
           } = ack_node

    assert_receive {:processed_events, %{connection_update: %{qr: qr_payload}}}

    assert qr_payload == QR.generate("ref-1", auth_state)

    refute_receive {:processed_events, %{connection_update: %{qr: _next_qr}}}, 50
  end

  test "pair-success updates creds, emits is_new_login, and replies with pair-device-sign" do
    test_pid = self()
    {:ok, event_emitter} = EventEmitter.start_link(buffer_timeout_ms: 50)

    _unsubscribe =
      EventEmitter.process(event_emitter, &Kernel.send(test_pid, {:processed_events, &1}))

    auth_state = pairing_auth_state()

    {:ok, pid, server_transport} =
      start_authenticated_socket(
        event_emitter: event_emitter,
        config: Config.new(keep_alive_interval_ms: 5_000),
        auth_state: auth_state
      )

    {
      pair_success_node,
      expected_lid,
      expected_jid,
      expected_platform,
      expected_key_index
    } = pair_success_stanza("pair-success-1", auth_state)

    {server_transport, frame} = server_transport_frame(server_transport, pair_success_node)
    Kernel.send(pid, {:scripted_transport, {:binary, frame}})

    assert_receive {:processed_events,
                    %{
                      creds_update: %{
                        me: %{id: ^expected_jid, lid: ^expected_lid},
                        platform: ^expected_platform
                      }
                    }}

    assert_receive {:processed_events, %{connection_update: %{is_new_login: true, qr: nil}}}

    assert_receive {:transport_sent, reply_frame}
    {server_transport, reply_node} = decode_client_transport_frame(server_transport, reply_frame)

    assert %BinaryNode{
             tag: "iq",
             attrs: %{"id" => "pair-success-1", "to" => "s.whatsapp.net", "type" => "result"}
           } = reply_node

    assert %BinaryNode{tag: "pair-device-sign"} =
             pair_device_sign_node =
             BinaryNodeUtil.child(reply_node, "pair-device-sign")

    assert %BinaryNode{
             tag: "device-identity",
             attrs: %{"key-index" => ^expected_key_index}
           } = BinaryNodeUtil.child(pair_device_sign_node, "device-identity")

    assert_receive {:transport_sent, unified_session_frame}

    {_, unified_session_node} =
      decode_client_transport_frame(server_transport, unified_session_frame)

    assert %BinaryNode{tag: "ib"} = unified_session_node

    assert %BinaryNode{tag: "unified_session"} =
             BinaryNodeUtil.child(unified_session_node, "unified_session")
  end

  test "request_pairing_code/3 sends the companion hello node and emits creds updates" do
    test_pid = self()
    {:ok, event_emitter} = EventEmitter.start_link(buffer_timeout_ms: 50)

    _unsubscribe =
      EventEmitter.process(event_emitter, &Kernel.send(test_pid, {:processed_events, &1}))

    auth_state = phone_pairing_auth_state()

    {:ok, pid, server_transport} =
      start_authenticated_socket(
        event_emitter: event_emitter,
        config: Config.new(browser: {"BaileysEx", "Chrome", "0.1.0"}),
        auth_state: auth_state
      )

    assert {:ok, "ABCDEFGH"} =
             Socket.request_pairing_code(pid, "15551234567", custom_pairing_code: "ABCDEFGH")

    assert_receive {:processed_events,
                    %{
                      creds_update: %{
                        pairing_code: "ABCDEFGH",
                        me: %{id: "15551234567@s.whatsapp.net"}
                      }
                    }}

    assert_receive {:transport_sent, pairing_frame}

    {_server_transport, pairing_node} =
      decode_client_transport_frame(server_transport, pairing_frame)

    assert %BinaryNode{
             tag: "iq",
             attrs: %{"to" => "s.whatsapp.net", "type" => "set", "xmlns" => "md"}
           } = pairing_node

    assert %BinaryNode{tag: "link_code_companion_reg", attrs: %{"stage" => "companion_hello"}} =
             BinaryNodeUtil.child(pairing_node, "link_code_companion_reg")
  end

  test "phone pairing notifications emit registered creds updates and send the companion finish node" do
    test_pid = self()
    {:ok, event_emitter} = EventEmitter.start_link(buffer_timeout_ms: 50)

    _unsubscribe =
      EventEmitter.process(event_emitter, &Kernel.send(test_pid, {:processed_events, &1}))

    auth_state = phone_pairing_auth_state()

    {:ok, pid, server_transport} =
      start_authenticated_socket(
        event_emitter: event_emitter,
        config: Config.new(browser: {"BaileysEx", "Chrome", "0.1.0"}),
        auth_state: auth_state
      )

    assert {:ok, "ABCDEFGH"} =
             Socket.request_pairing_code(pid, "15551234567", custom_pairing_code: "ABCDEFGH")

    assert_receive {:transport_sent, pairing_request_frame}

    {server_transport, _pairing_request_node} =
      decode_client_transport_frame(server_transport, pairing_request_frame)

    notification = phone_pairing_notification("ref-123", "ABCDEFGH")

    {server_transport, notification_frame} =
      server_transport_frame(server_transport, notification)

    Kernel.send(pid, {:scripted_transport, {:binary, notification_frame}})

    assert_receive {:processed_events,
                    %{creds_update: %{registered: true, adv_secret_key: adv_secret_key}}}

    assert {:ok, decoded_adv_secret_key} = Base.decode64(adv_secret_key)
    assert byte_size(decoded_adv_secret_key) == 32

    assert_receive {:transport_sent, finish_frame}

    {_server_transport, finish_node} =
      decode_client_transport_frame(server_transport, finish_frame)

    assert %BinaryNode{
             tag: "iq",
             attrs: %{"to" => "s.whatsapp.net", "type" => "set", "xmlns" => "md"}
           } = finish_node

    assert %BinaryNode{tag: "link_code_companion_reg", attrs: %{"stage" => "companion_finish"}} =
             BinaryNodeUtil.child(finish_node, "link_code_companion_reg")
  end

  defp start_connected_socket(opts) do
    {:ok, pid, server_transport} = start_authenticated_socket(opts)

    success_node = %BinaryNode{tag: "success", attrs: %{"t" => "1_710_000_000"}}
    {server_transport, success_frame} = server_transport_frame(server_transport, success_node)
    Kernel.send(pid, {:scripted_transport, {:binary, success_frame}})
    assert_eventually(fn -> Socket.state(pid) == :connected end)

    assert_receive {:transport_sent, passive_iq_frame}

    {server_transport, _passive_iq_node} =
      decode_client_transport_frame(server_transport, passive_iq_frame)

    # swallow the unified session side effect so follow-up tests can assert on their own writes
    assert_receive {:transport_sent, unified_session_frame}

    {server_transport, _unified_session_node} =
      decode_client_transport_frame(server_transport, unified_session_frame)

    {:ok, pid, server_transport}
  end

  defp start_authenticated_socket(opts) do
    client_payload = "client-payload"
    client_noise_key_pair = Crypto.generate_key_pair(:x25519)
    root_key_pair = Crypto.generate_key_pair(:x25519)
    intermediate_key_pair = Crypto.generate_key_pair(:x25519)
    server_static_key_pair = Crypto.generate_key_pair(:x25519)
    trusted_cert = %{serial: 0, public_key: root_key_pair.public}

    config = Keyword.get(opts, :config, Config.new())
    event_emitter = Keyword.fetch!(opts, :event_emitter)

    auth_state =
      merge_maps(
        %{
          noise_key: client_noise_key_pair,
          creds: %{routing_info: nil}
        },
        Keyword.get(opts, :auth_state, %{})
      )

    assert {:ok, pid} =
             Socket.start_link(
               config: config,
               auth_state: auth_state,
               client_payload: client_payload,
               noise_opts: [trusted_cert: trusted_cert],
               event_emitter: event_emitter,
               transport: {ScriptedTransport, %{test_pid: self()}}
             )

    assert :ok = Socket.connect(pid)
    Kernel.send(pid, {:scripted_transport, :connected})
    assert_receive {:transport_sent, client_hello}

    assert {:ok, server_hello, server_state} =
             NoiseServer.build_server_hello(client_hello,
               root_key_pair: root_key_pair,
               intermediate_key_pair: intermediate_key_pair,
               server_static_key_pair: server_static_key_pair,
               issuer_serial: trusted_cert.serial
             )

    Kernel.send(pid, {:scripted_transport, {:binary, server_hello}})
    assert_receive {:transport_sent, client_finish}

    assert {:ok, %{transport: server_transport}} =
             NoiseServer.process_client_finish(server_state, client_finish)

    assert_eventually(fn -> Socket.state(pid) == :authenticating end)

    {:ok, pid, server_transport}
  end

  defp server_transport_frame(server_transport, %BinaryNode{} = node) do
    plaintext = BinaryNodeUtil.encode(node)
    server_transport_frame(server_transport, plaintext)
  end

  defp server_transport_frame(server_transport, plaintext) when is_binary(plaintext) do
    iv = <<0::64, server_transport.write_counter::32-big>>
    {:ok, ciphertext} = Crypto.aes_gcm_encrypt(server_transport.enc_key, iv, plaintext, "")

    {
      %{server_transport | write_counter: server_transport.write_counter + 1},
      <<byte_size(ciphertext)::24-big, ciphertext::binary>>
    }
  end

  defp decode_client_transport_frame(server_transport, frame) do
    frame = strip_intro_header(frame)
    <<length::24-big, ciphertext::binary-size(length)>> = frame
    iv = <<0::64, server_transport.read_counter::32-big>>
    {:ok, plaintext} = Crypto.aes_gcm_decrypt(server_transport.dec_key, iv, ciphertext, "")
    server_transport = %{server_transport | read_counter: server_transport.read_counter + 1}
    {:ok, node} = BinaryNodeUtil.decode(plaintext)
    {server_transport, node}
  end

  defp strip_intro_header(frame) do
    noise_header = Noise.noise_header()
    noise_header_size = byte_size(noise_header)

    cond do
      String.starts_with?(frame, noise_header) ->
        <<_intro_header::binary-size(noise_header_size), rest::binary>> = frame
        rest

      String.starts_with?(frame, "ED") ->
        <<"ED", 0, 1, routing_length_high, routing_length_low::16-big, rest::binary>> = frame
        routing_length = routing_length_high * 65_536 + routing_length_low

        <<_routing_info::binary-size(routing_length),
          _noise_header::binary-size(noise_header_size), tail::binary>> = rest

        tail

      true ->
        frame
    end
  end

  defp pair_device_stanza(id, refs) when is_binary(id) and is_list(refs) do
    %BinaryNode{
      tag: "iq",
      attrs: %{"id" => id, "to" => "s.whatsapp.net", "type" => "set"},
      content: [
        %BinaryNode{
          tag: "pair-device",
          attrs: %{},
          content: Enum.map(refs, &%BinaryNode{tag: "ref", attrs: %{}, content: &1})
        }
      ]
    }
  end

  defp pair_success_stanza(id, auth_state) do
    expected_lid = "12345678901234@lid"
    expected_jid = "15551234567@s.whatsapp.net"
    expected_platform = "Chrome"
    expected_key_index = "7"
    account_signature_key = Crypto.generate_key_pair(:x25519)

    device_identity =
      %ADVDeviceIdentity{
        raw_id: 1,
        timestamp: 1_710_000_000,
        key_index: String.to_integer(expected_key_index),
        device_type: 0
      }

    device_details = ADVDeviceIdentity.encode(device_identity)

    {:ok, account_signature} =
      Curve.sign(
        account_signature_key.private,
        <<6, 0, device_details::binary, auth_state.signed_identity_key.public::binary>>
      )

    account =
      %ADVSignedDeviceIdentity{
        details: device_details,
        account_signature_key: account_signature_key.public,
        account_signature: account_signature,
        device_signature: nil
      }

    account_details = ADVSignedDeviceIdentity.encode(account)

    device_identity_hmac =
      %ADVSignedDeviceIdentityHMAC{
        details: account_details,
        hmac: Crypto.hmac_sha256(auth_state.adv_secret_key, account_details),
        account_type: nil
      }
      |> ADVSignedDeviceIdentityHMAC.encode()

    stanza =
      %BinaryNode{
        tag: "iq",
        attrs: %{"id" => id, "to" => "s.whatsapp.net", "type" => "result"},
        content: [
          %BinaryNode{
            tag: "pair-success",
            attrs: %{},
            content: [
              %BinaryNode{
                tag: "device-identity",
                attrs: %{},
                content: {:binary, device_identity_hmac}
              },
              %BinaryNode{tag: "platform", attrs: %{"name" => expected_platform}, content: nil},
              %BinaryNode{
                tag: "device",
                attrs: %{"jid" => expected_jid, "lid" => expected_lid},
                content: nil
              }
            ]
          }
        ]
      }

    {stanza, expected_lid, expected_jid, expected_platform, expected_key_index}
  end

  defp pairing_auth_state do
    %{
      noise_key: Crypto.generate_key_pair(:x25519),
      signed_identity_key: Crypto.generate_key_pair(:x25519),
      adv_secret_key: Crypto.random_bytes(32),
      signal_identities: [],
      creds: %{routing_info: nil}
    }
  end

  defp phone_pairing_auth_state do
    state = BaileysEx.Auth.State.new()

    %{
      noise_key: state.noise_key,
      pairing_ephemeral_key: state.pairing_ephemeral_key,
      signed_identity_key: state.signed_identity_key,
      adv_secret_key: state.adv_secret_key,
      pairing_code: state.pairing_code,
      me: state.me,
      registered: state.registered,
      creds: %{routing_info: nil}
    }
  end

  defp phone_pairing_notification(ref, pairing_code) do
    primary_identity_key = Crypto.generate_key_pair(:x25519)
    code_pairing_key = Crypto.generate_key_pair(:x25519)
    salt = :binary.copy(<<17>>, 32)
    iv = :binary.copy(<<29>>, 16)
    {:ok, pairing_key} = BaileysEx.Auth.Phone.derive_pairing_code_key(pairing_code, salt)
    {:ok, wrapped_public_key} = Crypto.aes_ctr_encrypt(pairing_key, iv, code_pairing_key.public)

    %BinaryNode{
      tag: "notification",
      attrs: %{"type" => "set"},
      content: [
        %BinaryNode{
          tag: "link_code_companion_reg",
          attrs: %{},
          content: [
            %BinaryNode{tag: "link_code_pairing_ref", attrs: %{}, content: ref},
            %BinaryNode{
              tag: "primary_identity_pub",
              attrs: %{},
              content: {:binary, primary_identity_key.public}
            },
            %BinaryNode{
              tag: "link_code_pairing_wrapped_primary_ephemeral_pub",
              attrs: %{},
              content: {:binary, salt <> iv <> wrapped_public_key}
            }
          ]
        }
      ]
    }
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

  defp merge_maps(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      if is_map(left_value) and is_map(right_value) do
        merge_maps(left_value, right_value)
      else
        right_value
      end
    end)
  end
end
