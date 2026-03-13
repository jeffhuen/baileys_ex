defmodule BaileysEx.Media.Upload do
  @moduledoc """
  WhatsApp media connection lookup and CDN upload helpers.
  """

  alias BaileysEx.BinaryNode
  alias BaileysEx.Connection.Socket
  alias BaileysEx.Media.Types
  alias BaileysEx.Protocol.BinaryNode, as: BinaryNodeUtil

  @s_whatsapp_net "s.whatsapp.net"

  @type media_host :: %{
          hostname: String.t(),
          max_content_length_bytes: non_neg_integer() | nil
        }

  @type media_conn :: %{
          auth: String.t(),
          ttl: non_neg_integer(),
          fetch_date: DateTime.t(),
          hosts: [media_host()]
        }

  @type upload_result :: %{
          media_url: String.t() | nil,
          direct_path: String.t() | nil,
          meta_hmac: String.t() | nil,
          ts: integer() | nil,
          fbid: integer() | nil
        }

  @spec refresh_media_conn(GenServer.server() | function(), keyword()) ::
          {:ok, media_conn()} | {:error, term()}
  @doc """
  Request a fresh `media_conn` record from WhatsApp's `w:m` namespace.
  """
  def refresh_media_conn(queryable, opts \\ []) do
    timeout = Keyword.get(opts, :query_timeout, 60_000)
    now_fun = Keyword.get(opts, :now_fun, &DateTime.utc_now/0)

    with {:ok, %BinaryNode{} = response} <- query(queryable, media_conn_node(), timeout),
         %BinaryNode{} = media_conn <- BinaryNodeUtil.child(response, "media_conn") do
      {:ok,
       %{
         auth: media_conn.attrs["auth"],
         ttl: parse_int(media_conn.attrs["ttl"]) || 0,
         fetch_date: now_fun.(),
         hosts: parse_hosts(media_conn)
       }}
    else
      nil -> {:error, :missing_media_conn}
      {:error, _reason} = error -> error
    end
  end

  @spec upload(GenServer.server() | function(), String.t(), Types.media_type(), keyword()) ::
          {:ok, upload_result()} | {:error, term()}
  @doc """
  Upload an encrypted media file to the WhatsApp CDN.
  """
  def upload(queryable, encrypted_path, media_type, opts \\ [])
      when is_binary(encrypted_path) do
    request_fun = opts[:request_fun] || (&Req.post/1)

    with {:ok, media_conn} <- refresh_media_conn(queryable, opts),
         {:ok, host} <- first_host(media_conn.hosts),
         {:ok, token} <- encoded_sha256_token(opts[:file_enc_sha256]),
         path when is_binary(path) <- Types.path(media_type),
         {:ok, response} <-
           request_fun.(
             request_options(
               encrypted_path,
               "https://#{host.hostname}#{path}/#{token}?auth=#{URI.encode_www_form(media_conn.auth)}&token=#{token}",
               opts[:req_options] || []
             )
           ) do
      parse_upload_response(response)
    else
      nil -> {:error, :unsupported_media_type}
      {:error, _reason} = error -> error
    end
  end

  @spec encode_token(String.t()) :: String.t()
  @doc """
  Encode a base64 media hash into WhatsApp's URL-safe token form.
  """
  def encode_token(base64) when is_binary(base64) do
    base64
    |> String.replace("+", "-")
    |> String.replace("/", "_")
    |> String.replace(~r/=+$/, "")
    |> URI.encode_www_form()
  end

  defp media_conn_node do
    %BinaryNode{
      tag: "iq",
      attrs: %{"type" => "set", "xmlns" => "w:m", "to" => @s_whatsapp_net},
      content: [%BinaryNode{tag: "media_conn", attrs: %{}}]
    }
  end

  defp parse_hosts(media_conn) do
    media_conn
    |> BinaryNodeUtil.children("host")
    |> Enum.map(fn host ->
      %{
        hostname: host.attrs["hostname"],
        max_content_length_bytes: parse_int(host.attrs["maxContentLengthBytes"])
      }
    end)
  end

  defp query(queryable, %BinaryNode{} = node, timeout) when is_function(queryable, 2),
    do: queryable.(node, timeout)

  defp query(queryable, %BinaryNode{} = node, _timeout) when is_function(queryable, 1),
    do: queryable.(node)

  defp query(queryable, %BinaryNode{} = node, timeout),
    do: Socket.query(queryable, node, timeout)

  defp first_host([host | _]), do: {:ok, host}
  defp first_host([]), do: {:error, :missing_upload_host}

  defp encoded_sha256_token(file_enc_sha256) when is_binary(file_enc_sha256) do
    {:ok, file_enc_sha256 |> Base.encode64() |> encode_token()}
  end

  defp encoded_sha256_token(_file_enc_sha256), do: {:error, :missing_file_enc_sha256}

  defp request_options(encrypted_path, url, req_options) do
    headers =
      merge_headers(req_options[:headers], [
        {"content-type", "application/octet-stream"},
        {"origin", "https://web.whatsapp.com"}
      ])

    req_options
    |> Keyword.drop([:headers])
    |> Keyword.merge(
      url: url,
      body: File.stream!(encrypted_path, 64 * 1024),
      headers: headers
    )
  end

  defp merge_headers(existing, required) do
    normalized =
      existing
      |> List.wrap()
      |> Enum.map(fn {key, value} -> {String.downcase(to_string(key)), value} end)

    normalized_keys = MapSet.new(Enum.map(normalized, &elem(&1, 0)))

    normalized ++
      Enum.reject(required, fn {key, _value} ->
        MapSet.member?(normalized_keys, key)
      end)
  end

  defp parse_upload_response(%Req.Response{status: status, body: body})
       when status in 200..299 do
    with {:ok, parsed} <- normalize_body(body) do
      {:ok,
       %{
         media_url: parsed["url"],
         direct_path: parsed["direct_path"],
         meta_hmac: parsed["meta_hmac"],
         ts: parse_int(parsed["ts"]),
         fbid: parse_int(parsed["fbid"])
       }}
    end
  end

  defp parse_upload_response(%Req.Response{status: status, body: body}),
    do: {:error, {:http_error, status, body}}

  defp normalize_body(body) when is_map(body), do: {:ok, body}

  defp normalize_body(body) when is_binary(body) do
    JSON.decode(body)
  end

  defp parse_int(nil), do: nil
  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end
end
