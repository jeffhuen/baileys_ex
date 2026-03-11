defmodule BaileysEx.Connection.Transport.MintWebSocketTest do
  use ExUnit.Case, async: true

  import Kernel, except: [send: 2]

  alias BaileysEx.Connection.Config
  alias BaileysEx.Connection.Transport.MintWebSocket

  defmodule FakeAdapter do
    import Kernel, except: [send: 2]

    def http_connect(scheme, host, port, opts) do
      Kernel.send(opts[:test_pid], {:http_connect, scheme, host, port})
      {:ok, :http_conn}
    end

    def websocket_upgrade(scheme, :http_conn, path, headers, opts) do
      Kernel.send(opts[:test_pid], {:websocket_upgrade, scheme, path, headers})
      {:ok, :http_conn, :ws_ref}
    end

    def websocket_stream(:http_conn, :upgrade_reply) do
      {:ok, :http_conn, [{:status, :ws_ref, 101}, {:headers, :ws_ref, []}, {:done, :ws_ref}]}
    end

    def websocket_stream(:upgraded_conn, :binary_reply) do
      {:ok, :upgraded_conn, [{:data, :ws_ref, "ws-binary"}]}
    end

    def websocket_stream(conn, _message), do: {:ok, conn, []}

    def websocket_new(:http_conn, :ws_ref, 101, []) do
      {:ok, :upgraded_conn, :websocket}
    end

    def websocket_decode(:websocket, "ws-binary") do
      {:ok, :websocket, [{:binary, "noise-frame"}]}
    end

    def websocket_encode(:websocket, {:binary, "payload"}) do
      {:ok, :websocket, "encoded-frame"}
    end

    def websocket_stream_request_body(:upgraded_conn, :ws_ref, "encoded-frame") do
      {:ok, :upgraded_conn}
    end

    def http_close(_conn), do: :ok
  end

  test "connect/2 opens the HTTP connection and issues the websocket upgrade" do
    assert {:ok, state} =
             MintWebSocket.connect(
               Config.new(ws_url: "wss://web.whatsapp.com/ws/chat"),
               adapter: FakeAdapter,
               test_pid: self()
             )

    assert_receive {:http_connect, :https, "web.whatsapp.com", 443}
    assert_receive {:websocket_upgrade, :wss, "/ws/chat", []}
    assert state != nil
  end

  test "connect/2 rejects unsupported websocket url schemes without touching the adapter" do
    assert {:error, {:invalid_ws_url, :unsupported_scheme}} =
             MintWebSocket.connect(
               Config.new(ws_url: "https://web.whatsapp.com/ws/chat"),
               adapter: FakeAdapter,
               test_pid: self()
             )

    refute_received {:http_connect, _, _, _}
  end

  test "connect/2 rejects websocket urls without a host without touching the adapter" do
    assert {:error, {:invalid_ws_url, :missing_host}} =
             MintWebSocket.connect(
               Config.new(ws_url: "wss:///ws/chat"),
               adapter: FakeAdapter,
               test_pid: self()
             )

    refute_received {:http_connect, _, _, _}
  end

  test "handle_info/2 emits :connected when the websocket upgrade completes" do
    {:ok, state} =
      MintWebSocket.connect(
        Config.new(ws_url: "wss://web.whatsapp.com/ws/chat"),
        adapter: FakeAdapter,
        test_pid: self()
      )

    assert {:ok, _state, [:connected]} = MintWebSocket.handle_info(state, :upgrade_reply)
  end

  test "handle_info/2 emits binary payload events once the websocket is open" do
    {:ok, state} =
      MintWebSocket.connect(
        Config.new(ws_url: "wss://web.whatsapp.com/ws/chat"),
        adapter: FakeAdapter,
        test_pid: self()
      )

    {:ok, state, [:connected]} = MintWebSocket.handle_info(state, :upgrade_reply)

    assert {:ok, _state, [binary: "noise-frame"]} =
             MintWebSocket.handle_info(state, :binary_reply)
  end

  test "send_binary/2 encodes and streams a websocket binary frame" do
    {:ok, state} =
      MintWebSocket.connect(
        Config.new(ws_url: "wss://web.whatsapp.com/ws/chat"),
        adapter: FakeAdapter,
        test_pid: self()
      )

    {:ok, state, [:connected]} = MintWebSocket.handle_info(state, :upgrade_reply)

    assert {:ok, _state} = MintWebSocket.send_binary(state, "payload")
  end
end
