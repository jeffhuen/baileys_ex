defmodule BaileysEx.Media.Upload do
  @moduledoc """
  WhatsApp media connection lookup and CDN upload helpers.
  """

  alias BaileysEx.BinaryNode
  alias BaileysEx.Connection.Store
  import BaileysEx.Connection.TransportAdapter, only: [query: 3]
  alias BaileysEx.Media.HTTP
  alias BaileysEx.Media.Types
  alias BaileysEx.Protocol.BinaryNode, as: BinaryNodeUtil
  alias BaileysEx.Telemetry

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
    force? = Keyword.get(opts, :force, false)
    store_ref = opts[:store_ref]
    now = now_fun.()

    case cached_media_conn(store_ref, now, force?) do
      {:ok, media_conn} ->
        {:ok, media_conn}

      :miss ->
        with {:ok, %BinaryNode{} = response} <- query(queryable, media_conn_node(), timeout),
             %BinaryNode{} = media_conn <- BinaryNodeUtil.child(response, "media_conn") do
          media_conn = %{
            auth: media_conn.attrs["auth"],
            ttl: parse_int(media_conn.attrs["ttl"]) || 0,
            fetch_date: now,
            hosts: parse_hosts(media_conn)
          }

          persist_media_conn(store_ref, media_conn)
          {:ok, media_conn}
        else
          nil -> {:error, :missing_media_conn}
          {:error, _reason} = error -> error
        end
    end
  end

  @spec upload(GenServer.server() | function(), String.t(), Types.media_type(), keyword()) ::
          {:ok, upload_result()} | {:error, term()}
  @doc """
  Upload an encrypted media file to the WhatsApp CDN.
  """
  def upload(queryable, encrypted_path, media_type, opts \\ [])
      when is_binary(encrypted_path) do
    Telemetry.span(
      [:media, :upload],
      %{media_type: media_type, path: encrypted_path},
      fn ->
        request_fun = opts[:request_fun] || (&Req.post/1)

        with {:ok, media_conn} <- refresh_media_conn(queryable, opts),
             {:ok, token} <- encoded_sha256_token(opts[:file_enc_sha256]),
             path when is_binary(path) <- Types.path(media_type) do
          upload_hosts(
            media_conn.hosts,
            upload_state(queryable, media_conn, encrypted_path, path, token, request_fun, opts),
            nil
          )
        else
          nil -> {:error, :unsupported_media_type}
          {:error, _reason} = error -> error
        end
      end
    )
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

  defp encoded_sha256_token(file_enc_sha256) when is_binary(file_enc_sha256) do
    {:ok, file_enc_sha256 |> Base.encode64() |> encode_token()}
  end

  defp encoded_sha256_token(_file_enc_sha256), do: {:error, :missing_file_enc_sha256}

  defp request_options(encrypted_path, url, req_options) do
    headers =
      HTTP.merge_headers(req_options[:headers], [
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

  defp upload_hosts([], _state, nil), do: {:error, :missing_upload_host}
  defp upload_hosts([], _state, last_error), do: {:error, last_error}

  defp upload_hosts([host | rest], state, _last_error) do
    case request_upload(host, state) do
      {:ok, %{media_url: media_url, direct_path: direct_path} = parsed}
      when is_binary(media_url) or is_binary(direct_path) ->
        {:ok, parsed}

      {:ok, _parsed} ->
        upload_hosts(rest, refresh_upload_state(state), :invalid_upload_response)

      {:error, reason} ->
        upload_hosts(rest, state, reason)
    end
  end

  defp upload_state(queryable, media_conn, encrypted_path, path, token, request_fun, opts) do
    %{
      queryable: queryable,
      media_conn: media_conn,
      encrypted_path: encrypted_path,
      path: path,
      token: token,
      request_fun: request_fun,
      opts: opts
    }
  end

  defp request_upload(host, state) do
    url = upload_url(host, state.media_conn, state.path, state.token)
    req_options = request_options(state.encrypted_path, url, state.opts[:req_options] || [])

    case state.request_fun.(req_options) do
      {:ok, %Req.Response{} = response} -> parse_upload_response(response)
      {:error, reason} -> {:error, reason}
    end
  end

  defp refresh_upload_state(state) do
    refreshed_media_conn =
      case refresh_media_conn(state.queryable, Keyword.put(state.opts, :force, true)) do
        {:ok, refreshed} -> refreshed
        _ -> state.media_conn
      end

    %{state | media_conn: refreshed_media_conn}
  end

  defp upload_url(host, media_conn, path, token) do
    "https://#{host.hostname}#{path}/#{token}?auth=#{URI.encode_www_form(media_conn.auth)}&token=#{token}"
  end

  defp cached_media_conn(nil, _now, _force?), do: :miss
  defp cached_media_conn(_store_ref, _now, true), do: :miss

  defp cached_media_conn(%Store.Ref{} = store_ref, now, false) do
    case Store.get(store_ref, :media_conn) do
      %{fetch_date: %DateTime{} = fetch_date, ttl: ttl} = media_conn when is_integer(ttl) ->
        if DateTime.diff(now, fetch_date, :second) < ttl do
          {:ok, media_conn}
        else
          :miss
        end

      _ ->
        :miss
    end
  end

  defp persist_media_conn(nil, _media_conn), do: :ok

  defp persist_media_conn(%Store.Ref{} = store_ref, media_conn),
    do: Store.put(store_ref, :media_conn, media_conn)

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
