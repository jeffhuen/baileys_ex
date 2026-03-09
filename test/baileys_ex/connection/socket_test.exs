defmodule BaileysEx.Connection.SocketTest do
  use ExUnit.Case, async: true

  import Kernel, except: [send: 2]

  alias BaileysEx.Crypto
  alias BaileysEx.Connection.Config
  alias BaileysEx.Connection.Socket
  alias BaileysEx.Protocol.Proto.HandshakeMessage
  alias BaileysEx.Protocol.Proto.HandshakeMessage.ClientHello
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
    refute_received {:transport_sent, _payload}

    Kernel.send(pid, {:scripted_transport, :connected})

    assert_receive {:transport_sent, client_hello}

    assert {:ok,
            %HandshakeMessage{
              client_hello: %ClientHello{ephemeral: client_ephemeral}
            }} = HandshakeMessage.decode(client_hello)

    assert is_binary(client_ephemeral)
    assert_eventually(fn -> Socket.state(pid) == :noise_handshake end)
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
