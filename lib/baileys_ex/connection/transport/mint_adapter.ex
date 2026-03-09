defmodule BaileysEx.Connection.Transport.MintAdapter do
  @moduledoc false

  @spec http_connect(atom(), String.t(), pos_integer(), keyword()) ::
          {:ok, Mint.HTTP.t()} | {:error, term()}
  def http_connect(scheme, host, port, opts) do
    Mint.HTTP.connect(scheme, host, port, Keyword.take(opts, http_connect_keys()))
  end

  @spec websocket_upgrade(atom(), Mint.HTTP.t(), String.t(), Mint.Types.headers(), keyword()) ::
          {:ok, Mint.HTTP.t(), Mint.Types.request_ref()} | {:error, Mint.HTTP.t(), term()}
  def websocket_upgrade(scheme, conn, path, headers, opts) do
    Mint.WebSocket.upgrade(
      scheme,
      conn,
      path,
      headers,
      Keyword.take(opts, websocket_upgrade_keys())
    )
  end

  @spec websocket_stream(Mint.HTTP.t(), term()) ::
          {:ok, Mint.HTTP.t(), [Mint.Types.response()]}
          | {:error, Mint.HTTP.t(), term(), [Mint.Types.response()]}
          | :unknown
  def websocket_stream(conn, message), do: Mint.WebSocket.stream(conn, message)

  @spec websocket_new(
          Mint.HTTP.t(),
          Mint.Types.request_ref(),
          Mint.Types.status(),
          Mint.Types.headers()
        ) ::
          {:ok, Mint.HTTP.t(), Mint.WebSocket.t()} | {:error, Mint.HTTP.t(), term()}
  def websocket_new(conn, request_ref, status, headers) do
    Mint.WebSocket.new(conn, request_ref, status, headers)
  end

  @spec websocket_decode(Mint.WebSocket.t(), binary()) ::
          {:ok, Mint.WebSocket.t(), [Mint.WebSocket.frame() | {:error, term()}]}
          | {:error, Mint.WebSocket.t(), term()}
  def websocket_decode(websocket, data), do: Mint.WebSocket.decode(websocket, data)

  @spec websocket_encode(
          Mint.WebSocket.t(),
          Mint.WebSocket.shorthand_frame() | Mint.WebSocket.frame()
        ) ::
          {:ok, Mint.WebSocket.t(), binary()} | {:error, Mint.WebSocket.t(), term()}
  def websocket_encode(websocket, frame), do: Mint.WebSocket.encode(websocket, frame)

  @spec websocket_stream_request_body(Mint.HTTP.t(), Mint.Types.request_ref(), iodata()) ::
          {:ok, Mint.HTTP.t()} | {:error, Mint.HTTP.t(), term()}
  def websocket_stream_request_body(conn, request_ref, data) do
    Mint.WebSocket.stream_request_body(conn, request_ref, data)
  end

  @spec http_close(Mint.HTTP.t()) :: {:ok, Mint.HTTP.t()}
  def http_close(conn), do: Mint.HTTP.close(conn)

  defp http_connect_keys do
    [:timeout, :mode, :protocols, :proxy, :transport_opts, :hostname, :log]
  end

  defp websocket_upgrade_keys do
    [:mode, :extensions]
  end
end
