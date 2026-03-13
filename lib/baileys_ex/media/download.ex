defmodule BaileysEx.Media.Download do
  @moduledoc """
  Download and decrypt WhatsApp CDN media referenced by media message structs.
  """

  alias BaileysEx.Media.Crypto
  alias BaileysEx.Protocol.Proto.Message

  @mmg_host "https://mmg.whatsapp.net"

  @spec download(struct() | map(), keyword()) :: {:ok, binary()} | {:error, term()}
  @doc """
  Download and decrypt media referenced by a WhatsApp media message.
  """
  def download(media_message, opts \\ []) do
    with {:ok, media_type} <- media_type(media_message, opts),
         {:ok, url} <- media_url(media_message),
         {:ok, encrypted} <- fetch_media(url, opts),
         media_key when is_binary(media_key) <- Map.get(media_message, :media_key),
         {:ok, plaintext} <- Crypto.decrypt(encrypted, media_key, media_type) do
      {:ok, plaintext}
    else
      nil -> {:error, :missing_media_key}
      {:error, _reason} = error -> error
    end
  end

  @spec download_to_file(struct() | map(), Path.t(), keyword()) ::
          {:ok, Path.t()} | {:error, term()}
  @doc """
  Download and decrypt media directly to a file path.
  """
  def download_to_file(media_message, path, opts \\ []) do
    with {:ok, plaintext} <- download(media_message, opts) do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, plaintext)
      {:ok, path}
    end
  end

  defp media_type(%Message.ImageMessage{}, _opts), do: {:ok, :image}
  defp media_type(%Message.VideoMessage{}, _opts), do: {:ok, :video}
  defp media_type(%Message.AudioMessage{}, _opts), do: {:ok, :audio}
  defp media_type(%Message.DocumentMessage{}, _opts), do: {:ok, :document}
  defp media_type(%Message.StickerMessage{}, _opts), do: {:ok, :sticker}

  defp media_type(_media_message, opts) do
    case opts[:media_type] do
      nil -> {:error, :unknown_media_type}
      media_type -> {:ok, media_type}
    end
  end

  defp media_url(%{url: url, direct_path: direct_path})
       when is_binary(url) and byte_size(url) > 0 and is_binary(direct_path) and
              byte_size(direct_path) > 0 do
    if String.starts_with?(url, @mmg_host) do
      {:ok, url}
    else
      {:ok, @mmg_host <> direct_path}
    end
  end

  defp media_url(%{url: url}) when is_binary(url) and byte_size(url) > 0 do
    if String.starts_with?(url, @mmg_host) do
      {:ok, url}
    else
      {:error, :missing_media_url}
    end
  end

  defp media_url(%{direct_path: direct_path})
       when is_binary(direct_path) and byte_size(direct_path) > 0,
       do: {:ok, @mmg_host <> direct_path}

  defp media_url(_media_message), do: {:error, :missing_media_url}

  defp fetch_media(url, opts) do
    request_fun = opts[:request_fun] || (&Req.get/1)
    req_options = opts[:req_options] || []
    headers = merge_headers(req_options[:headers], [{"origin", "https://web.whatsapp.com"}])

    case request_fun.(Keyword.merge(req_options, url: url, headers: headers)) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) -> {:ok, body}
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
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
end
