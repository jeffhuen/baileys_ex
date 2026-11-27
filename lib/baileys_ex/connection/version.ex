defmodule BaileysEx.Connection.Version do
  @moduledoc """
  Baileys-style helpers for discovering the latest published web versions.
  """

  alias BaileysEx.Connection.Config
  alias BaileysEx.Media.HTTP

  @baileys_defaults_url "https://raw.githubusercontent.com/WhiskeySockets/Baileys/master/src/Defaults/index.ts"
  @wa_web_service_worker_url "https://web.whatsapp.com/sw.js"
  @wa_web_default_headers [
    {"sec-fetch-site", "none"},
    {"user-agent",
     "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"}
  ]

  @type fetch_response :: %{required(:status) => pos_integer(), required(:body) => binary()}
  @type fetch_fun :: (String.t(), keyword() -> {:ok, fetch_response()} | {:error, term()})
  @type version_result :: %{
          required(:version) => [non_neg_integer()],
          required(:is_latest) => boolean(),
          optional(:error) => term()
        }

  @spec fetch_latest_baileys_version(keyword()) :: version_result()
  def fetch_latest_baileys_version(opts \\ []) do
    fetch_latest_version(
      Keyword.merge([url: @baileys_defaults_url], opts),
      &parse_baileys_defaults/1
    )
  end

  @spec fetch_latest_wa_web_version(keyword()) :: version_result()
  def fetch_latest_wa_web_version(opts \\ []) do
    opts =
      opts
      |> Keyword.put_new(:url, @wa_web_service_worker_url)
      |> Keyword.put_new(:headers, @wa_web_default_headers)

    fetch_latest_version(opts, &parse_wa_web_service_worker/1)
  end

  defp fetch_latest_version(opts, parser) when is_list(opts) and is_function(parser, 1) do
    default_version = Keyword.get(opts, :default_version, Config.new().version)
    fetch_fun = Keyword.get(opts, :fetch_fun, &default_fetch/2)
    url = Keyword.fetch!(opts, :url)

    case fetch_fun.(url, opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        case parser.(body) do
          {:ok, version} ->
            %{version: version, is_latest: true}

          {:error, reason} ->
            %{version: default_version, is_latest: false, error: reason}
        end

      {:ok, %{status: status} = response} ->
        %{
          version: default_version,
          is_latest: false,
          error: {:http_error, status, response[:body]}
        }

      {:error, reason} ->
        %{version: default_version, is_latest: false, error: reason}
    end
  end

  defp default_fetch(url, opts) do
    req_options = Keyword.get(opts, :req_options, [])

    with :ok <- validate_request_url(url, req_options) do
      default_headers =
        opts
        |> Keyword.get(:headers, [])
        |> Enum.map(fn {key, value} -> {key, to_string(value)} end)

      headers = HTTP.merge_headers(req_options[:headers], default_headers)

      request_opts =
        req_options
        |> Keyword.drop([:headers, :url, :into, :decode_body, :compressed, :method])
        |> Keyword.merge(
          method: :get,
          url: url,
          headers: headers,
          raw: true,
          compressed: false,
          decode_body: false,
          into: nil
        )

      case Req.get(request_opts) do
        {:ok, %Req.Response{status: status, body: body}} when is_binary(body) ->
          {:ok, %{status: status, body: body}}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:ok, %{status: status, body: IO.iodata_to_binary(body)}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp validate_request_url(url, req_options) when is_binary(url) do
    uri =
      case req_options[:base_url] do
        base_url when is_binary(base_url) -> URI.merge(URI.parse(base_url), URI.parse(url))
        _ -> URI.parse(url)
      end

    case uri do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and byte_size(host) > 0 ->
        :ok

      _ ->
        {:error, :invalid_url}
    end
  end

  defp validate_request_url(_url, _req_options), do: {:error, :invalid_url}

  defp parse_baileys_defaults(body) when is_binary(body) do
    case Regex.run(~r/const version = \[(\d+),\s*(\d+),\s*(\d+)\]/, body, capture: :all_but_first) do
      [major, minor, patch] ->
        {:ok, Enum.map([major, minor, patch], &String.to_integer/1)}

      _ ->
        {:error, :unable_to_parse_baileys_version}
    end
  end

  defp parse_wa_web_service_worker(body) when is_binary(body) do
    case Regex.run(~r/\\?"client_revision\\?":\s*(\d+)/, body, capture: :all_but_first) do
      [client_revision] ->
        {:ok, [2, 3000, String.to_integer(client_revision)]}

      _ ->
        {:error, :unable_to_parse_wa_web_version}
    end
  end
end
