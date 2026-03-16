defmodule BaileysEx.Connection.Transport.StubAdapter do
  @moduledoc """
  Offline adapter for `MintWebSocket` that never touches the network.

  Pass `adapter: BaileysEx.Connection.Transport.StubAdapter` in the transport
  options to run `BaileysEx.connect/2` without a real WhatsApp connection.
  The connection will fail cleanly with `{:error, :stub_transport}`, allowing
  consumers to test event bridging, auth persistence, and other adapter logic
  without network access.

  ## Usage

      {:ok, conn} = BaileysEx.connect(auth_state,
        transport: {BaileysEx.Connection.Transport.MintWebSocket,
                    [adapter: BaileysEx.Connection.Transport.StubAdapter]}
      )

  The connection will emit `{:error, :stub_transport}` during the WebSocket
  upgrade phase, which the socket state machine handles as a connection failure.
  """

  @spec http_connect(atom(), String.t(), pos_integer(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def http_connect(_scheme, _host, _port, _opts) do
    {:ok, :stub_conn}
  end

  @spec websocket_upgrade(atom(), term(), String.t(), list(), keyword()) ::
          {:ok, term(), term()} | {:error, term(), term()}
  def websocket_upgrade(_scheme, conn, _path, _headers, _opts) do
    {:error, conn, :stub_transport}
  end

  @spec websocket_stream(term(), term()) :: :unknown
  def websocket_stream(_conn, _message), do: :unknown

  @spec websocket_new(term(), term(), term(), term()) :: {:error, term(), :stub_transport}
  def websocket_new(_conn, _request_ref, _status, _headers) do
    {:error, :stub_conn, :stub_transport}
  end

  @spec websocket_decode(term(), binary()) :: {:ok, term(), []}
  def websocket_decode(websocket, _data), do: {:ok, websocket, []}

  @spec websocket_encode(term(), term()) :: {:ok, term(), <<>>}
  def websocket_encode(websocket, _frame), do: {:ok, websocket, <<>>}

  @spec websocket_stream_request_body(term(), term(), iodata()) :: {:ok, term()}
  def websocket_stream_request_body(conn, _request_ref, _data), do: {:ok, conn}

  @spec http_close(term()) :: {:ok, term()}
  def http_close(conn), do: {:ok, conn}
end
