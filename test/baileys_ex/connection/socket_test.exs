defmodule BaileysEx.Connection.SocketTest do
  use ExUnit.Case, async: true

  import Kernel, except: [send: 2]

  alias BaileysEx.BinaryNode
  alias BaileysEx.Auth.State
  alias BaileysEx.Crypto
  alias BaileysEx.Auth.QR
  alias BaileysEx.Connection.Config
  alias BaileysEx.Connection.EventEmitter
  alias BaileysEx.Connection.Socket
  alias BaileysEx.Protocol.BinaryNode, as: BinaryNodeUtil
  alias BaileysEx.Protocol.Noise
  alias BaileysEx.Protocol.Proto.ClientPayload
  alias BaileysEx.Protocol.Proto.ADVDeviceIdentity
  alias BaileysEx.Protocol.Proto.ADVSignedDeviceIdentity
  alias BaileysEx.Protocol.Proto.ADVSignedDeviceIdentityHMAC
  alias BaileysEx.Protocol.Proto.HandshakeMessage
  alias BaileysEx.Protocol.Proto.HandshakeMessage.ClientHello
  alias BaileysEx.Signal.Curve
  alias BaileysEx.Signal.Store, as: SignalStore
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
    client_noise_key_pair = x25519_key_pair(101)
    root_key_pair = x25519_key_pair(102)
    trusted_cert = %{serial: 0, public_key: root_key_pair.public}

    assert {:ok, pid} =
             Socket.start_link(
               config: Config.new(),
               auth_state:
                 deterministic_state(200)
                 |> Map.put(:noise_key, client_noise_key_pair)
                 |> Map.put(:routing_info, nil),
               noise_opts: [trusted_cert: trusted_cert],
               transport: {ScriptedTransport, %{test_pid: self()}}
             )

    assert :ok = Socket.connect(pid)
    assert_eventually(fn -> Socket.state(pid) == :connecting end)
    assert Socket.snapshot(pid).transport_connected? == false
    refute_received {:transport_sent, _payload}

    Kernel.send(pid, {:scripted_transport, :connected})

    assert_receive {:transport_sent, framed_client_hello}

    client_hello = NoiseServer.strip_handshake_frame(framed_client_hello)

    assert {:ok,
            %HandshakeMessage{
              client_hello: %ClientHello{ephemeral: client_ephemeral}
            }} = HandshakeMessage.decode(client_hello)

    assert is_binary(client_ephemeral)

    assert_eventually(fn ->
      Socket.state(pid) == :noise_handshake and Socket.snapshot(pid).transport_connected?
    end)
  end

  test "a valid server hello sends the rc9 registration payload when no jid is present" do
    client_noise_key_pair = x25519_key_pair(111)
    root_key_pair = x25519_key_pair(112)
    intermediate_key_pair = x25519_key_pair(113)
    server_static_key_pair = x25519_key_pair(114)
    trusted_cert = %{serial: 0, public_key: root_key_pair.public}

    assert {:ok, pid} =
             Socket.start_link(
               config:
                 Config.new(version: [2, 24, 7], browser: {"Windows", "Edge", "10.0.22631"}),
               auth_state:
                 deterministic_state(210)
                 |> Map.put(:noise_key, client_noise_key_pair)
                 |> Map.put(:routing_info, nil),
               noise_opts: [trusted_cert: trusted_cert],
               transport: {ScriptedTransport, %{test_pid: self()}}
             )

    assert :ok = Socket.connect(pid)
    Kernel.send(pid, {:scripted_transport, :connected})
    assert_receive {:transport_sent, framed_client_hello}

    client_hello = NoiseServer.strip_handshake_frame(framed_client_hello)

    assert {:ok, server_hello, server_state} =
             NoiseServer.build_server_hello(client_hello,
               root_key_pair: root_key_pair,
               intermediate_key_pair: intermediate_key_pair,
               server_static_key_pair: server_static_key_pair,
               issuer_serial: trusted_cert.serial
             )

    framed_server_hello = NoiseServer.frame_handshake_response(server_hello)
    Kernel.send(pid, {:scripted_transport, {:binary, framed_server_hello}})

    assert_receive {:transport_sent, framed_client_finish}

    client_finish = NoiseServer.strip_handshake_frame(framed_client_finish)

    assert {:ok, %{client_payload: client_payload, client_static: client_static}} =
             NoiseServer.process_client_finish(server_state, client_finish)

    assert client_static == client_noise_key_pair.public
    assert {:ok, decoded_payload} = ClientPayload.decode(client_payload)
    assert decoded_payload.passive == false
    assert decoded_payload.pull == false
    assert decoded_payload.device_pairing_data != nil
    assert_eventually(fn -> Socket.state(pid) == :authenticating end)
  end

  test "a valid server hello sends the rc9 login payload when creds.me is present" do
    client_noise_key_pair = x25519_key_pair(121)
    root_key_pair = x25519_key_pair(122)
    intermediate_key_pair = x25519_key_pair(123)
    server_static_key_pair = x25519_key_pair(124)
    trusted_cert = %{serial: 0, public_key: root_key_pair.public}

    auth_state =
      deterministic_state(220)
      |> Map.put(:noise_key, client_noise_key_pair)
      |> Map.put(:me, %{id: "15551234567:3@s.whatsapp.net", name: "~"})
      |> Map.put(:routing_info, nil)

    assert {:ok, pid} =
             Socket.start_link(
               config: Config.new(version: [2, 24, 7], country_code: "GB"),
               auth_state: auth_state,
               noise_opts: [trusted_cert: trusted_cert],
               transport: {ScriptedTransport, %{test_pid: self()}}
             )

    assert :ok = Socket.connect(pid)
    Kernel.send(pid, {:scripted_transport, :connected})
    assert_receive {:transport_sent, framed_client_hello}

    client_hello = NoiseServer.strip_handshake_frame(framed_client_hello)

    assert {:ok, server_hello, server_state} =
             NoiseServer.build_server_hello(client_hello,
               root_key_pair: root_key_pair,
               intermediate_key_pair: intermediate_key_pair,
               server_static_key_pair: server_static_key_pair,
               issuer_serial: trusted_cert.serial
             )

    framed_server_hello = NoiseServer.frame_handshake_response(server_hello)
    Kernel.send(pid, {:scripted_transport, {:binary, framed_server_hello}})

    assert_receive {:transport_sent, framed_client_finish}

    client_finish = NoiseServer.strip_handshake_frame(framed_client_finish)

    assert {:ok, %{client_payload: client_payload}} =
             NoiseServer.process_client_finish(server_state, client_finish)

    assert {:ok, decoded_payload} = ClientPayload.decode(client_payload)
    assert decoded_payload.username == 15_551_234_567
    assert decoded_payload.device == 3
    assert decoded_payload.passive == true
    assert decoded_payload.pull == true
    assert decoded_payload.user_agent.locale_country_iso31661_alpha2 == "GB"
  end

  test "an invalid server hello returns the socket to disconnected and records the error" do
    client_noise_key_pair = x25519_key_pair(131)
    root_key_pair = x25519_key_pair(132)
    trusted_cert = %{serial: 0, public_key: root_key_pair.public}

    assert {:ok, pid} =
             Socket.start_link(
               config: Config.new(),
               auth_state:
                 deterministic_state(230)
                 |> Map.put(:noise_key, client_noise_key_pair)
                 |> Map.put(:routing_info, nil),
               noise_opts: [trusted_cert: trusted_cert],
               transport: {ScriptedTransport, %{test_pid: self()}}
             )

    assert :ok = Socket.connect(pid)
    Kernel.send(pid, {:scripted_transport, :connected})
    assert_receive {:transport_sent, _client_hello}

    invalid_server_hello = HandshakeMessage.encode(%HandshakeMessage{})
    framed_invalid = NoiseServer.frame_handshake_response(invalid_server_hello)

    Kernel.send(pid, {:scripted_transport, {:binary, framed_invalid}})

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

    assert_receive {:transport_sent, passive_iq_frame}

    {server_transport, passive_iq_node} =
      decode_client_transport_frame(server_transport, passive_iq_frame)

    assert %BinaryNode{
             tag: "iq",
             attrs: %{"xmlns" => "passive", "type" => "set"}
           } = passive_iq_node

    assert %BinaryNode{tag: "active"} = BinaryNodeUtil.child(passive_iq_node, "active")

    passive_result = %BinaryNode{
      tag: "iq",
      attrs: %{"id" => passive_iq_node.attrs["id"], "type" => "result"},
      content: nil
    }

    {server_transport, passive_result_frame} =
      server_transport_frame(server_transport, passive_result)

    Kernel.send(pid, {:scripted_transport, {:binary, passive_result_frame}})

    assert_receive {:processed_events, %{connection_update: %{connection: :open}}}
    assert_eventually(fn -> Socket.state(pid) == :connected end)

    assert_receive {:transport_sent, unified_session_frame}

    {_, unified_session_node} =
      decode_client_transport_frame(server_transport, unified_session_frame)

    assert %BinaryNode{tag: "ib"} = unified_session_node

    assert %BinaryNode{tag: "unified_session"} =
             BinaryNodeUtil.child(unified_session_node, "unified_session")
  end

  test "socket clock and message tag injection make passive iq and unified session deterministic" do
    test_pid = self()
    {:ok, event_emitter} = EventEmitter.start_link(buffer_timeout_ms: 50)

    _unsubscribe =
      EventEmitter.process(event_emitter, &Kernel.send(test_pid, {:processed_events, &1}))

    {:ok, pid, server_transport} =
      start_authenticated_socket(
        event_emitter: event_emitter,
        config: Config.new(keep_alive_interval_ms: 5_000),
        clock_ms_fun: fn -> 1_710_000_123_000 end,
        message_tag_fun: fn -> "passive-tag-1" end
      )

    success_node =
      %BinaryNode{
        tag: "success",
        attrs: %{"t" => "1710000000", "lid" => "12345678901234@lid"}
      }

    {server_transport, success_frame} = server_transport_frame(server_transport, success_node)
    Kernel.send(pid, {:scripted_transport, {:binary, success_frame}})

    assert_receive {:transport_sent, passive_iq_frame}

    {server_transport, passive_iq_node} =
      decode_client_transport_frame(server_transport, passive_iq_frame)

    assert passive_iq_node.attrs["id"] == "passive-tag-1"

    passive_result = %BinaryNode{
      tag: "iq",
      attrs: %{"id" => passive_iq_node.attrs["id"], "type" => "result"},
      content: nil
    }

    {server_transport, passive_result_frame} =
      server_transport_frame(server_transport, passive_result)

    Kernel.send(pid, {:scripted_transport, {:binary, passive_result_frame}})

    assert_receive {:processed_events, %{connection_update: %{connection: :open}}}
    assert_receive {:transport_sent, unified_session_frame}

    {_, unified_session_node} =
      decode_client_transport_frame(server_transport, unified_session_frame)

    assert %BinaryNode{attrs: %{"id" => "489600000"}} =
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

  test "raw inbound message, receipt, ack, and notification nodes are surfaced as socket_node events" do
    test_pid = self()
    {:ok, event_emitter} = EventEmitter.start_link(buffer_timeout_ms: 50)

    _unsubscribe =
      EventEmitter.process(event_emitter, &Kernel.send(test_pid, {:processed_events, &1}))

    {:ok, pid, server_transport} =
      start_connected_socket(
        event_emitter: event_emitter,
        config: Config.new(keep_alive_interval_ms: 5_000)
      )

    message_node =
      %BinaryNode{
        tag: "message",
        attrs: %{"id" => "raw-msg-1", "from" => "15551234567@s.whatsapp.net", "t" => "1710000900"},
        content: []
      }

    {server_transport, message_frame} = server_transport_frame(server_transport, message_node)
    Kernel.send(pid, {:scripted_transport, {:binary, message_frame}})

    assert_receive {:processed_events,
                    %{
                      socket_node: %{
                        state: :connected,
                        node: %BinaryNode{tag: "message", attrs: %{"id" => "raw-msg-1"}}
                      }
                    }}

    receipt_node =
      %BinaryNode{
        tag: "receipt",
        attrs: %{"id" => "raw-receipt-1", "from" => "15551234567@s.whatsapp.net"},
        content: nil
      }

    {server_transport, receipt_frame} = server_transport_frame(server_transport, receipt_node)
    Kernel.send(pid, {:scripted_transport, {:binary, receipt_frame}})

    assert_receive {:processed_events,
                    %{
                      socket_node: %{
                        state: :connected,
                        node: %BinaryNode{tag: "receipt", attrs: %{"id" => "raw-receipt-1"}}
                      }
                    }}

    ack_node =
      %BinaryNode{
        tag: "ack",
        attrs: %{
          "id" => "raw-ack-1",
          "class" => "message",
          "from" => "15551234567@s.whatsapp.net"
        },
        content: nil
      }

    {server_transport, ack_frame} = server_transport_frame(server_transport, ack_node)
    Kernel.send(pid, {:scripted_transport, {:binary, ack_frame}})

    assert_receive {:processed_events,
                    %{
                      socket_node: %{
                        state: :connected,
                        node: %BinaryNode{tag: "ack", attrs: %{"id" => "raw-ack-1"}}
                      }
                    }}

    notification_node =
      %BinaryNode{
        tag: "notification",
        attrs: %{"type" => "picture", "from" => "12345-67890@g.us"},
        content: [%BinaryNode{tag: "set", attrs: %{"id" => "pic-raw-1"}, content: nil}]
      }

    {_, notification_frame} = server_transport_frame(server_transport, notification_node)
    Kernel.send(pid, {:scripted_transport, {:binary, notification_frame}})

    assert_receive {:processed_events,
                    %{
                      socket_node: %{
                        state: :connected,
                        node: %BinaryNode{tag: "notification", attrs: %{"type" => "picture"}}
                      }
                    }}
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
        config: Config.new(keep_alive_interval_ms: 5_000),
        date_time_fun: fn -> ~U[2026-03-16 12:00:00Z] end
      )

    Kernel.send(pid, {:scripted_transport, {:closed, :tcp_closed}})

    assert_eventually(fn -> Socket.state(pid) == :disconnected end)

    assert_receive {:processed_events,
                    %{
                      connection_update: %{
                        connection: :close,
                        last_disconnect: %{
                          error: %{reason: :tcp_closed, status_code: 428},
                          date: ~U[2026-03-16 12:00:00Z]
                        }
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

  test "send_wam_buffer/2 sends a w:stats iq with the encoded payload" do
    test_pid = self()
    {:ok, event_emitter} = EventEmitter.start_link(buffer_timeout_ms: 50)

    _unsubscribe =
      EventEmitter.process(event_emitter, &Kernel.send(test_pid, {:processed_events, &1}))

    {:ok, pid, server_transport} =
      start_connected_socket(
        event_emitter: event_emitter,
        config: Config.new(keep_alive_interval_ms: 5_000),
        clock_ms_fun: fn -> 1_710_000_123_000 end,
        message_tag_fun: fn -> "wam-tag-1" end
      )

    query_task = Task.async(fn -> Socket.send_wam_buffer(pid, <<1, 2, 3, 4>>) end)

    assert_receive {:transport_sent, wam_frame}

    {server_transport, wam_node} = decode_client_transport_frame(server_transport, wam_frame)

    assert %BinaryNode{
             tag: "iq",
             attrs: %{"id" => "wam-tag-1", "to" => "s.whatsapp.net", "xmlns" => "w:stats"}
           } = wam_node

    assert %BinaryNode{
             tag: "add",
             attrs: %{"t" => "1710000123"},
             content: {:binary, <<1, 2, 3, 4>>}
           } = BinaryNodeUtil.child(wam_node, "add")

    result_node =
      %BinaryNode{
        tag: "iq",
        attrs: %{"id" => "wam-tag-1", "type" => "result", "from" => "s.whatsapp.net"},
        content: nil
      }

    {_, result_frame} = server_transport_frame(server_transport, result_node)
    Kernel.send(pid, {:scripted_transport, {:binary, result_frame}})

    assert {:ok, ^result_node} = Task.await(query_task)
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
    {_server_transport, frame} = server_transport_frame(server_transport, pair_device_node)
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

  test "pair-device honors the configurable QR refresh timers" do
    test_pid = self()
    {:ok, event_emitter} = EventEmitter.start_link(buffer_timeout_ms: 50)

    _unsubscribe =
      EventEmitter.process(event_emitter, &Kernel.send(test_pid, {:processed_events, &1}))

    auth_state = pairing_auth_state()

    {:ok, pid, server_transport} =
      start_authenticated_socket(
        event_emitter: event_emitter,
        config:
          Config.new(
            keep_alive_interval_ms: 5_000,
            pairing_qr_initial_timeout_ms: 10,
            pairing_qr_refresh_timeout_ms: 10
          ),
        auth_state: auth_state
      )

    pair_device_node = pair_device_stanza("pair-device-2", ["ref-1", "ref-2"])
    {_server_transport, frame} = server_transport_frame(server_transport, pair_device_node)
    Kernel.send(pid, {:scripted_transport, {:binary, frame}})

    assert_receive {:transport_sent, _ack_frame}
    assert_receive {:processed_events, %{connection_update: %{qr: first_qr}}}
    assert first_qr == QR.generate("ref-1", auth_state)

    assert_receive {:processed_events, %{connection_update: %{qr: second_qr}}}, 100
    assert second_qr == QR.generate("ref-2", auth_state)
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

  test "phone pairing notifications wait for the companion finish response before emitting registered creds updates" do
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

    assert_receive {:transport_sent, finish_frame}

    {server_transport, finish_node} =
      decode_client_transport_frame(server_transport, finish_frame)

    assert %BinaryNode{
             tag: "iq",
             attrs: %{"to" => "s.whatsapp.net", "type" => "set", "xmlns" => "md"}
           } = finish_node

    assert %BinaryNode{tag: "link_code_companion_reg", attrs: %{"stage" => "companion_finish"}} =
             BinaryNodeUtil.child(finish_node, "link_code_companion_reg")

    refute_receive {:processed_events, %{creds_update: %{registered: true}}}, 50

    result_node = %BinaryNode{
      tag: "iq",
      attrs: %{"id" => finish_node.attrs["id"], "to" => "s.whatsapp.net", "type" => "result"},
      content: nil
    }

    {_server_transport, result_frame} = server_transport_frame(server_transport, result_node)
    Kernel.send(pid, {:scripted_transport, {:binary, result_frame}})

    assert_receive {:processed_events,
                    %{creds_update: %{registered: true, adv_secret_key: adv_secret_key}}}

    assert {:ok, decoded_adv_secret_key} = Base.decode64(adv_secret_key)
    assert byte_size(decoded_adv_secret_key) == 32
  end

  test "success waits for pre-key upload, passive iq, and digest validation before opening" do
    test_pid = self()
    {:ok, event_emitter} = EventEmitter.start_link(buffer_timeout_ms: 50)
    {:ok, signal_store_pid} = BaileysEx.Signal.Store.Memory.start_link()
    {:ok, task_supervisor} = Task.Supervisor.start_link()

    _unsubscribe =
      EventEmitter.process(event_emitter, &Kernel.send(test_pid, {:processed_events, &1}))

    auth_state =
      deterministic_state(240)
      |> Map.put(:me, %{id: "15551234567@s.whatsapp.net", name: "~"})
      |> Map.put(:next_pre_key_id, 2)
      |> Map.put(:first_unuploaded_pre_key_id, 2)

    {:ok, pid, server_transport} =
      start_authenticated_socket(
        event_emitter: event_emitter,
        config: Config.new(keep_alive_interval_ms: 5_000),
        auth_state: auth_state,
        signal_store: %SignalStore{
          module: BaileysEx.Signal.Store.Memory,
          ref: BaileysEx.Signal.Store.Memory.wrap(signal_store_pid)
        },
        task_supervisor: task_supervisor
      )

    success_node = %BinaryNode{
      tag: "success",
      attrs: %{"t" => "1_710_000_000", "lid" => "12345678901234@lid"}
    }

    {server_transport, success_frame} = server_transport_frame(server_transport, success_node)
    Kernel.send(pid, {:scripted_transport, {:binary, success_frame}})

    assert_receive {:transport_sent, count_frame}
    {server_transport, count_node} = decode_client_transport_frame(server_transport, count_frame)

    assert %BinaryNode{
             tag: "iq",
             attrs: %{"xmlns" => "encrypt", "type" => "get"},
             content: [%BinaryNode{tag: "count"}]
           } = count_node

    refute_receive {:processed_events, %{connection_update: %{connection: :open}}}, 50

    count_result = %BinaryNode{
      tag: "iq",
      attrs: %{"id" => count_node.attrs["id"], "type" => "result"},
      content: [%BinaryNode{tag: "count", attrs: %{"value" => "10"}, content: nil}]
    }

    {server_transport, count_result_frame} =
      server_transport_frame(server_transport, count_result)

    Kernel.send(pid, {:scripted_transport, {:binary, count_result_frame}})

    assert_receive {:processed_events,
                    %{creds_update: %{next_pre_key_id: 7, first_unuploaded_pre_key_id: 7}}}

    assert_receive {:transport_sent, upload_frame}

    {server_transport, upload_node} =
      decode_client_transport_frame(server_transport, upload_frame)

    assert %BinaryNode{
             tag: "iq",
             attrs: %{"xmlns" => "encrypt", "type" => "set"},
             content: [%BinaryNode{tag: "registration"} | _rest]
           } = upload_node

    upload_result = %BinaryNode{
      tag: "iq",
      attrs: %{"id" => upload_node.attrs["id"], "type" => "result"},
      content: nil
    }

    {server_transport, upload_result_frame} =
      server_transport_frame(server_transport, upload_result)

    Kernel.send(pid, {:scripted_transport, {:binary, upload_result_frame}})

    assert_receive {:transport_sent, passive_frame}

    {server_transport, passive_node} =
      decode_client_transport_frame(server_transport, passive_frame)

    assert %BinaryNode{
             tag: "iq",
             attrs: %{"xmlns" => "passive", "type" => "set"},
             content: [%BinaryNode{tag: "active"}]
           } = passive_node

    refute_receive {:processed_events, %{connection_update: %{connection: :open}}}, 50

    passive_result = %BinaryNode{
      tag: "iq",
      attrs: %{"id" => passive_node.attrs["id"], "type" => "result"},
      content: nil
    }

    {server_transport, passive_result_frame} =
      server_transport_frame(server_transport, passive_result)

    Kernel.send(pid, {:scripted_transport, {:binary, passive_result_frame}})

    assert_receive {:transport_sent, digest_frame}

    {server_transport, digest_node} =
      decode_client_transport_frame(server_transport, digest_frame)

    assert %BinaryNode{
             tag: "iq",
             attrs: %{"xmlns" => "encrypt", "type" => "get"},
             content: [%BinaryNode{tag: "digest"}]
           } = digest_node

    digest_result = %BinaryNode{
      tag: "iq",
      attrs: %{"id" => digest_node.attrs["id"], "type" => "result"},
      content: [%BinaryNode{tag: "digest", attrs: %{}, content: nil}]
    }

    {server_transport, digest_result_frame} =
      server_transport_frame(server_transport, digest_result)

    Kernel.send(pid, {:scripted_transport, {:binary, digest_result_frame}})

    assert_receive {:processed_events, %{connection_update: %{connection: :open}}}
    assert_receive {:transport_sent, unified_session_frame}

    {_server_transport, unified_session_node} =
      decode_client_transport_frame(server_transport, unified_session_frame)

    assert %BinaryNode{tag: "ib"} = unified_session_node
  end

  test "stream error closes with the mapped disconnect reason" do
    test_pid = self()
    {:ok, event_emitter} = EventEmitter.start_link(buffer_timeout_ms: 50)

    _unsubscribe =
      EventEmitter.process(event_emitter, &Kernel.send(test_pid, {:processed_events, &1}))

    {:ok, pid, server_transport} =
      start_authenticated_socket(
        event_emitter: event_emitter,
        config: Config.new(keep_alive_interval_ms: 5_000),
        auth_state: pairing_auth_state()
      )

    node = %BinaryNode{
      tag: "stream:error",
      attrs: %{},
      content: [%BinaryNode{tag: "conflict", attrs: %{}, content: nil}]
    }

    {server_transport, frame} = server_transport_frame(server_transport, node)
    Kernel.send(pid, {:scripted_transport, {:binary, frame}})

    assert_receive {:processed_events,
                    %{
                      connection_update: %{
                        connection: :close,
                        last_disconnect: %{
                          error: %{reason: :connection_replaced, status_code: 440},
                          date: %DateTime{}
                        }
                      }
                    }}

    assert_eventually(fn -> Socket.snapshot(pid).last_error == :connection_replaced end)
    assert server_transport.read_counter >= 0
  end

  test "failure nodes close with the mapped disconnect reason" do
    test_pid = self()
    {:ok, event_emitter} = EventEmitter.start_link(buffer_timeout_ms: 50)

    _unsubscribe =
      EventEmitter.process(event_emitter, &Kernel.send(test_pid, {:processed_events, &1}))

    {:ok, pid, server_transport} =
      start_authenticated_socket(
        event_emitter: event_emitter,
        config: Config.new(keep_alive_interval_ms: 5_000),
        auth_state: pairing_auth_state()
      )

    node = %BinaryNode{tag: "failure", attrs: %{"reason" => "401"}, content: nil}
    {server_transport, frame} = server_transport_frame(server_transport, node)
    Kernel.send(pid, {:scripted_transport, {:binary, frame}})

    assert_receive {:processed_events,
                    %{
                      connection_update: %{
                        connection: :close,
                        last_disconnect: %{
                          error: %{reason: :logged_out, status_code: 401},
                          date: %DateTime{}
                        }
                      }
                    }}

    assert_eventually(fn -> Socket.snapshot(pid).last_error == :logged_out end)
    assert server_transport.read_counter >= 0
  end

  test "downgrade_webclient closes with a multidevice mismatch reason" do
    test_pid = self()
    {:ok, event_emitter} = EventEmitter.start_link(buffer_timeout_ms: 50)

    _unsubscribe =
      EventEmitter.process(event_emitter, &Kernel.send(test_pid, {:processed_events, &1}))

    {:ok, pid, server_transport} =
      start_authenticated_socket(
        event_emitter: event_emitter,
        config: Config.new(keep_alive_interval_ms: 5_000),
        auth_state: pairing_auth_state()
      )

    node = %BinaryNode{
      tag: "ib",
      attrs: %{},
      content: [%BinaryNode{tag: "downgrade_webclient", attrs: %{}, content: nil}]
    }

    {server_transport, frame} = server_transport_frame(server_transport, node)
    Kernel.send(pid, {:scripted_transport, {:binary, frame}})

    assert_receive {:processed_events,
                    %{
                      connection_update: %{
                        connection: :close,
                        last_disconnect: %{
                          error: %{reason: :multidevice_mismatch, status_code: 411},
                          date: %DateTime{}
                        }
                      }
                    }}

    assert_eventually(fn -> Socket.snapshot(pid).last_error == :multidevice_mismatch end)
    assert server_transport.read_counter >= 0
  end

  defp start_connected_socket(opts) do
    {:ok, pid, server_transport} = start_authenticated_socket(opts)

    success_node = %BinaryNode{tag: "success", attrs: %{"t" => "1_710_000_000"}}
    {server_transport, success_frame} = server_transport_frame(server_transport, success_node)
    Kernel.send(pid, {:scripted_transport, {:binary, success_frame}})

    assert_receive {:transport_sent, passive_iq_frame}

    {server_transport, passive_iq_node} =
      decode_client_transport_frame(server_transport, passive_iq_frame)

    passive_result = %BinaryNode{
      tag: "iq",
      attrs: %{"id" => passive_iq_node.attrs["id"], "type" => "result"},
      content: nil
    }

    {server_transport, passive_result_frame} =
      server_transport_frame(server_transport, passive_result)

    Kernel.send(pid, {:scripted_transport, {:binary, passive_result_frame}})

    assert_eventually(fn -> Socket.state(pid) == :connected end)

    assert_receive {:transport_sent, unified_session_frame}

    {server_transport, _unified_session_node} =
      decode_client_transport_frame(server_transport, unified_session_frame)

    {:ok, pid, server_transport}
  end

  defp start_authenticated_socket(opts) do
    client_noise_key_pair = x25519_key_pair(141)
    root_key_pair = x25519_key_pair(142)
    intermediate_key_pair = x25519_key_pair(143)
    server_static_key_pair = x25519_key_pair(144)
    trusted_cert = %{serial: 0, public_key: root_key_pair.public}

    config = Keyword.get(opts, :config, Config.new())
    event_emitter = Keyword.fetch!(opts, :event_emitter)

    auth_state =
      merge_maps(
        deterministic_state(250)
        |> Map.put(:noise_key, client_noise_key_pair)
        |> Map.put(:routing_info, nil),
        Keyword.get(opts, :auth_state, %{})
      )

    start_link_opts =
      [
        config: config,
        auth_state: auth_state,
        noise_opts: [trusted_cert: trusted_cert],
        event_emitter: event_emitter,
        signal_store: Keyword.get(opts, :signal_store),
        task_supervisor: Keyword.get(opts, :task_supervisor),
        transport: {ScriptedTransport, %{test_pid: self()}}
      ]
      |> maybe_put_opt(:clock_ms_fun, opts[:clock_ms_fun])
      |> maybe_put_opt(:date_time_fun, opts[:date_time_fun])
      |> maybe_put_opt(:monotonic_ms_fun, opts[:monotonic_ms_fun])
      |> maybe_put_opt(:message_tag_fun, opts[:message_tag_fun])

    assert {:ok, pid} = Socket.start_link(start_link_opts)

    assert :ok = Socket.connect(pid)
    Kernel.send(pid, {:scripted_transport, :connected})
    assert_receive {:transport_sent, framed_client_hello}

    client_hello = NoiseServer.strip_handshake_frame(framed_client_hello)

    assert {:ok, server_hello, server_state} =
             NoiseServer.build_server_hello(client_hello,
               root_key_pair: root_key_pair,
               intermediate_key_pair: intermediate_key_pair,
               server_static_key_pair: server_static_key_pair,
               issuer_serial: trusted_cert.serial
             )

    framed_server_hello = NoiseServer.frame_handshake_response(server_hello)
    Kernel.send(pid, {:scripted_transport, {:binary, framed_server_hello}})
    assert_receive {:transport_sent, framed_client_finish}

    client_finish = NoiseServer.strip_handshake_frame(framed_client_finish)

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
    account_signature_key = x25519_key_pair(150)

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
      noise_key: x25519_key_pair(151),
      signed_identity_key: x25519_key_pair(152),
      adv_secret_key: fixed_bytes(32, 153),
      signal_identities: [],
      creds: %{routing_info: nil}
    }
  end

  defp phone_pairing_auth_state do
    state = deterministic_state(260)

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
    primary_identity_key = x25519_key_pair(154)
    code_pairing_key = x25519_key_pair(155)
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

  defp deterministic_state(seed) do
    signed_identity_key = x25519_key_pair(seed + 2)

    {:ok, signed_pre_key} =
      Curve.signed_key_pair(signed_identity_key, seed + 3, key_pair: x25519_key_pair(seed + 4))

    State.new(
      noise_key: x25519_key_pair(seed),
      pairing_ephemeral_key: x25519_key_pair(seed + 1),
      signed_identity_key: signed_identity_key,
      signed_pre_key: signed_pre_key,
      registration_id: seed + 1_000,
      adv_secret_key: Base.encode64(fixed_bytes(32, seed + 5))
    )
  end

  defp x25519_key_pair(seed),
    do: Crypto.generate_key_pair(:x25519, private_key: <<seed::unsigned-big-256>>)

  defp fixed_bytes(size, value), do: :binary.copy(<<rem(value, 256)>>, size)

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)
end
