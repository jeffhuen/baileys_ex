defmodule BaileysEx.TestHelpers.LoopbackHTTPServer do
  @moduledoc false

  @doc """
  Starts a minimal single- or multi-request HTTP/1.1 loopback server on an ephemeral port
  for exercising real `Req` / `Finch` / `Mint` transport flows in tests without extra deps.
  """
  @spec start((map() ->
                 {pos_integer(), [{String.t(), String.t()}],
                  binary() | [binary()] | {:truncate_after, binary()}})) ::
          {:ok, %{port: pos_integer(), url: String.t(), stop: (-> :ok)}}
  def start(handler) when is_function(handler, 1) do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen_socket)
    server_pid = spawn_link(fn -> accept_loop(listen_socket, handler) end)

    stop = fn ->
      Process.unlink(server_pid)
      Process.exit(server_pid, :shutdown)
      :gen_tcp.close(listen_socket)
      :ok
    end

    {:ok, %{port: port, url: "http://127.0.0.1:#{port}", stop: stop}}
  end

  defp accept_loop(listen_socket, handler) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, socket} ->
        serve_connection(socket, handler)
        accept_loop(listen_socket, handler)

      {:error, :closed} ->
        :ok
    end
  end

  defp serve_connection(socket, handler) do
    case read_request(socket) do
      {:ok, request} ->
        {status, headers, body} = handler.(request)
        write_response(socket, status, headers, body)

      {:error, _reason} ->
        :ok
    end
  after
    :gen_tcp.close(socket)
  end

  defp read_request(socket) do
    with {:ok, raw_head, rest} <- read_until_headers_end(socket, <<>>),
         {:ok, method, path, headers} <- parse_request_head(raw_head),
         {:ok, body} <- read_body(socket, headers, rest) do
      {:ok, %{method: method, path: path, headers: headers, body: body}}
    end
  end

  defp read_until_headers_end(socket, acc) do
    case :binary.split(acc, "\r\n\r\n") do
      [head, rest] ->
        {:ok, head, rest}

      [_incomplete] ->
        case :gen_tcp.recv(socket, 0, 5_000) do
          {:ok, chunk} -> read_until_headers_end(socket, acc <> chunk)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp parse_request_head(raw_head) do
    case String.split(raw_head, "\r\n") do
      [request_line | header_lines] ->
        [method, path, _version] = String.split(request_line, " ", parts: 3)
        headers = Enum.reduce(header_lines, %{}, &parse_header_line/2)
        {:ok, method, path, headers}

      _ ->
        {:error, :invalid_request}
    end
  end

  defp parse_header_line(line, acc) do
    case String.split(line, ":", parts: 2) do
      [name, value] -> Map.put(acc, String.downcase(String.trim(name)), String.trim(value))
      _ -> acc
    end
  end

  defp read_body(socket, headers, rest) do
    cond do
      Map.get(headers, "transfer-encoding") == "chunked" ->
        read_chunked_body(socket, rest, [])

      is_binary(headers["content-length"]) ->
        content_length = String.to_integer(headers["content-length"])
        read_exact(socket, rest, content_length)

      true ->
        {:ok, rest}
    end
  end

  defp read_exact(_socket, buffer, length) when byte_size(buffer) >= length do
    {:ok, binary_part(buffer, 0, length)}
  end

  defp read_exact(socket, buffer, length) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, chunk} -> read_exact(socket, buffer <> chunk, length)
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_chunked_body(socket, buffer, chunks) do
    case :binary.split(buffer, "\r\n") do
      [size_hex, rest] ->
        {size, _} = Integer.parse(String.trim(size_hex), 16)

        if size == 0 do
          {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
        else
          read_chunk_payload(socket, rest, size, chunks)
        end

      [_incomplete] ->
        case :gen_tcp.recv(socket, 0, 5_000) do
          {:ok, chunk} -> read_chunked_body(socket, buffer <> chunk, chunks)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp read_chunk_payload(socket, buffer, size, chunks) when byte_size(buffer) >= size + 2 do
    <<payload::binary-size(^size), "\r\n", rest::binary>> = buffer
    read_chunked_body(socket, rest, [payload | chunks])
  end

  defp read_chunk_payload(socket, buffer, size, chunks) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, chunk} -> read_chunk_payload(socket, buffer <> chunk, size, chunks)
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_response(socket, status, headers, {:truncate_after, chunk}) when is_binary(chunk) do
    reason = status_text(status)

    header_lines =
      headers
      |> Enum.map_join("", fn {name, value} -> "#{name}: #{value}\r\n" end)

    head =
      "HTTP/1.1 #{status} #{reason}\r\n" <>
        "content-length: #{byte_size(chunk) + 1024}\r\n" <>
        "connection: close\r\n" <>
        header_lines <> "\r\n"

    :ok = :gen_tcp.send(socket, [head, chunk])
  end

  defp write_response(socket, status, headers, chunks) when is_list(chunks) do
    reason = status_text(status)

    header_lines =
      headers
      |> Enum.map_join("", fn {name, value} -> "#{name}: #{value}\r\n" end)

    head =
      "HTTP/1.1 #{status} #{reason}\r\n" <>
        "transfer-encoding: chunked\r\n" <>
        "connection: close\r\n" <>
        header_lines <> "\r\n"

    :ok = :gen_tcp.send(socket, head)

    Enum.each(chunks, fn chunk ->
      hex = Integer.to_string(byte_size(chunk), 16)
      :ok = :gen_tcp.send(socket, [hex, "\r\n", chunk, "\r\n"])
    end)

    :ok = :gen_tcp.send(socket, "0\r\n\r\n")
  end

  defp write_response(socket, status, headers, body) when is_binary(body) do
    reason = status_text(status)

    header_lines =
      headers
      |> Enum.map_join("", fn {name, value} -> "#{name}: #{value}\r\n" end)

    response = [
      "HTTP/1.1 #{status} #{reason}\r\n",
      "content-length: #{byte_size(body)}\r\n",
      "connection: close\r\n",
      header_lines,
      "\r\n",
      body
    ]

    :ok = :gen_tcp.send(socket, response)
  end

  defp status_text(200), do: "OK"
  defp status_text(206), do: "Partial Content"
  defp status_text(302), do: "Found"
  defp status_text(404), do: "Not Found"
  defp status_text(410), do: "Gone"
  defp status_text(500), do: "Internal Server Error"
  defp status_text(503), do: "Service Unavailable"
  defp status_text(_), do: "Status"
end
