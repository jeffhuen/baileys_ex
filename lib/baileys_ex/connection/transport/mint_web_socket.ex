defmodule BaileysEx.Connection.Transport.MintWebSocket do
  @moduledoc """
  Mint-backed WebSocket transport for the connection socket.

  Defaults the WebSocket HTTP transport to HTTP/1.1 so the WhatsApp socket
  matches Baileys' `ws` client behavior instead of attempting Mint's HTTP/2
  extended CONNECT path.
  """

  @behaviour BaileysEx.Connection.Transport

  alias BaileysEx.Connection.Config
  alias BaileysEx.Connection.Transport.MintAdapter

  @enforce_keys [:adapter, :conn, :request_ref]
  defstruct [
    :adapter,
    :conn,
    :request_ref,
    :websocket,
    :status,
    response_headers: [],
    phase: :upgrade_pending
  ]

  @type phase :: :upgrade_pending | :open

  @type t :: %__MODULE__{
          adapter: module(),
          conn: term(),
          request_ref: term(),
          websocket: term() | nil,
          status: non_neg_integer() | nil,
          response_headers: list(),
          phase: phase()
        }

  @impl true
  @spec connect(Config.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def connect(%Config{} = config, opts) do
    adapter = Keyword.get(opts, :adapter, MintAdapter)
    connect_opts = connect_opts(config, opts)

    with {:ok, {http_scheme, ws_scheme, host, port, path}} <-
           parse_ws_url(ws_url_with_routing_info(config.ws_url, Keyword.get(opts, :routing_info))),
         {:ok, conn} <- adapter.http_connect(http_scheme, host, port, connect_opts),
         {:ok, conn, request_ref} <-
           adapter.websocket_upgrade(ws_scheme, conn, path, [], connect_opts) do
      {:ok,
       %__MODULE__{
         adapter: adapter,
         conn: conn,
         request_ref: request_ref
       }}
    else
      {:error, _conn, reason} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  @spec handle_info(t(), term()) ::
          {:ok, t(), [BaileysEx.Connection.Transport.event()]}
          | {:error, t(), term()}
          | :unknown
  def handle_info(%__MODULE__{} = state, message) do
    case state.adapter.websocket_stream(state.conn, message) do
      {:ok, conn, responses} ->
        handle_responses(%{state | conn: conn}, responses, [])

      {:error, conn, reason, responses} ->
        case handle_responses(%{state | conn: conn}, responses, []) do
          {:ok, state, events} -> {:ok, state, events ++ [error: reason]}
          {:error, state, response_reason} -> {:error, state, response_reason}
        end

      :unknown ->
        :unknown
    end
  end

  @impl true
  @spec disconnect(t()) :: :ok
  def disconnect(%__MODULE__{adapter: adapter, conn: conn}) do
    _ = adapter.http_close(conn)
    :ok
  end

  @impl true
  @spec send_binary(t(), binary()) :: {:ok, t()} | {:error, t(), term()}
  def send_binary(%__MODULE__{phase: :open} = state, payload) when is_binary(payload) do
    case state.adapter.websocket_encode(state.websocket, {:binary, payload}) do
      {:ok, websocket, encoded_frame} ->
        case state.adapter.websocket_stream_request_body(
               state.conn,
               state.request_ref,
               encoded_frame
             ) do
          {:ok, conn} -> {:ok, %{state | conn: conn, websocket: websocket}}
          {:error, conn, reason} -> {:error, %{state | conn: conn, websocket: websocket}, reason}
        end

      {:error, websocket, reason} ->
        {:error, %{state | websocket: websocket}, reason}
    end
  end

  def send_binary(%__MODULE__{} = state, _payload), do: {:error, state, :not_connected}

  defp handle_responses(state, [], events), do: {:ok, state, Enum.reverse(events)}

  defp handle_responses(%__MODULE__{phase: :upgrade_pending} = state, [response | rest], events) do
    case response do
      {:status, request_ref, status} when request_ref == state.request_ref ->
        handle_responses(%{state | status: status}, rest, events)

      {:headers, request_ref, headers} when request_ref == state.request_ref ->
        handle_responses(%{state | response_headers: headers}, rest, events)

      {:done, request_ref} when request_ref == state.request_ref ->
        complete_upgrade(state, rest, events)

      _other ->
        handle_responses(state, rest, events)
    end
  end

  defp handle_responses(%__MODULE__{phase: :open} = state, [response | rest], events) do
    case response do
      {:data, request_ref, data} when request_ref == state.request_ref ->
        case state.adapter.websocket_decode(state.websocket, data) do
          {:ok, websocket, frames} ->
            events = Enum.reverse(map_frames_to_events(frames), events)
            handle_responses(%{state | websocket: websocket}, rest, events)

          {:error, websocket, reason} ->
            {:error, %{state | websocket: websocket}, reason}
        end

      _other ->
        handle_responses(state, rest, events)
    end
  end

  defp complete_upgrade(state, rest, events) do
    case state.adapter.websocket_new(
           state.conn,
           state.request_ref,
           state.status,
           state.response_headers
         ) do
      {:ok, conn, websocket} ->
        handle_upgraded(%{state | conn: conn, websocket: websocket, phase: :open}, rest, events)

      {:error, conn, reason} ->
        {:error, %{state | conn: conn}, reason}
    end
  end

  defp handle_upgraded(state, rest, events) do
    case flush_upgrade_buffer(state) do
      {:ok, state, buffered_events} ->
        handle_responses(
          state,
          rest,
          Enum.reverse(buffered_events, [:connected | events])
        )

      {:error, state, reason} ->
        {:error, state, reason}
    end
  end

  defp map_frames_to_events(frames) do
    Enum.flat_map(frames, fn
      {:binary, payload} -> [{:binary, payload}]
      {:close, code, reason} -> [{:closed, {code, reason}}]
      {:error, reason} -> [{:error, reason}]
      _frame -> []
    end)
  end

  defp flush_upgrade_buffer(%__MODULE__{} = state) do
    {conn, buffered_data} = state.adapter.http_take_buffer(state.conn)
    state = %{state | conn: conn}

    if buffered_data == <<>> do
      {:ok, state, []}
    else
      case state.adapter.websocket_decode(state.websocket, buffered_data) do
        {:ok, websocket, frames} ->
          {:ok, %{state | websocket: websocket}, map_frames_to_events(frames)}

        {:error, websocket, reason} ->
          {:error, %{state | websocket: websocket}, reason}
      end
    end
  end

  defp parse_ws_url(ws_url) when is_binary(ws_url) do
    uri = URI.parse(ws_url)

    with {:ok, ws_scheme} <- parse_ws_scheme(uri.scheme),
         {:ok, host} <- fetch_ws_host(uri.host) do
      http_scheme = if ws_scheme == :wss, do: :https, else: :http
      port = uri.port || default_port(ws_scheme)
      path = build_request_path(uri)
      {:ok, {http_scheme, ws_scheme, host, port, path}}
    end
  end

  defp build_request_path(%URI{path: nil, query: nil}), do: "/"
  defp build_request_path(%URI{path: "", query: nil}), do: "/"

  defp build_request_path(%URI{path: path, query: nil}) when is_binary(path), do: path

  defp build_request_path(%URI{path: nil, query: query}), do: "/?" <> query
  defp build_request_path(%URI{path: "", query: query}), do: "/?" <> query
  defp build_request_path(%URI{path: path, query: query}), do: path <> "?" <> query

  defp default_port(:wss), do: 443
  defp default_port(:ws), do: 80

  defp parse_ws_scheme("wss"), do: {:ok, :wss}
  defp parse_ws_scheme("ws"), do: {:ok, :ws}
  defp parse_ws_scheme(_scheme), do: {:error, {:invalid_ws_url, :unsupported_scheme}}

  defp fetch_ws_host(host) when is_binary(host) and byte_size(host) > 0, do: {:ok, host}
  defp fetch_ws_host(_host), do: {:error, {:invalid_ws_url, :missing_host}}

  defp ws_url_with_routing_info(ws_url, routing_info)
       when is_binary(ws_url) and is_binary(routing_info) and byte_size(routing_info) > 0 do
    uri = URI.parse(ws_url)
    ed = Base.url_encode64(routing_info, padding: false)

    query =
      [uri.query, "ED=#{ed}"]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("&")

    %{uri | query: query}
    |> URI.to_string()
  end

  defp ws_url_with_routing_info(ws_url, _routing_info), do: ws_url

  defp connect_opts(%Config{} = config, opts) do
    opts
    |> Keyword.drop([:adapter])
    |> Keyword.put_new(:timeout, config.connect_timeout_ms)
    |> Keyword.put_new(:transport_opts, cacerts: :public_key.cacerts_get())
    |> Keyword.put_new(:protocols, [:http1])
  end
end
