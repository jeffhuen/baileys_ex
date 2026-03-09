defmodule BaileysEx.Connection.SocketTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Connection.Config
  alias BaileysEx.Connection.Socket

  defmodule SuccessfulTransport do
    import Kernel, except: [send: 2]

    @behaviour BaileysEx.Connection.Transport

    @impl true
    def connect(config, opts), do: {:ok, %{config: config, opts: opts}}

    @impl true
    def disconnect(_transport_state), do: :ok

    @impl true
    def send(%{opts: %{test_pid: test_pid}}, payload) do
      send(test_pid, {:transport_sent, payload})
      :ok
    end
  end

  defmodule FailingTransport do
    import Kernel, except: [send: 2]

    @behaviour BaileysEx.Connection.Transport

    @impl true
    def connect(_config, opts), do: {:error, Map.fetch!(opts, :reason)}

    @impl true
    def disconnect(_transport_state), do: :ok

    @impl true
    def send(_transport_state, _payload), do: {:error, :not_connected}
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

  test "connect/1 moves the socket into noise_handshake when transport startup succeeds" do
    assert {:ok, pid} =
             Socket.start_link(
               config: Config.new(),
               auth_state: %{creds: %{}},
               transport: {SuccessfulTransport, %{test_pid: self()}}
             )

    assert :ok = Socket.connect(pid)

    assert_eventually(fn ->
      Socket.state(pid) == :noise_handshake and Socket.snapshot(pid).transport_connected?
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
