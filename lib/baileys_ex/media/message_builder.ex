defmodule BaileysEx.Media.MessageBuilder do
  @moduledoc """
  Prepare media message content for message building and relay.

  This is the synchronous Elixir counterpart to Baileys' media preparation
  pipeline: encrypt the media, upload it, and enrich the content map with the
  metadata needed by `BaileysEx.Message.Builder`.
  """

  alias BaileysEx.Media.Crypto
  alias BaileysEx.Media.Thumbnail
  alias BaileysEx.Media.Upload

  @extension_mimetypes %{
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".png" => "image/png",
    ".webp" => "image/webp",
    ".mp4" => "video/mp4",
    ".ogg" => "audio/ogg",
    ".opus" => "audio/ogg",
    ".mp3" => "audio/mpeg"
  }

  @doc """
  Encrypt and upload media for a message content map, populating the proto
  fields needed for relay (url, direct_path, media_key, file hashes, etc.).

  Returns the content map unchanged if media is already uploaded
  (`:media_upload` key present).
  """
  @spec prepare(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def prepare(content, opts \\ [])

  def prepare(%{media_upload: _media_upload} = content, _opts), do: {:ok, content}

  def prepare(%{} = content, opts) do
    case media_entry(content) do
      nil ->
        {:ok, content}

      {field, input} ->
        with_media_file(input, field, opts, fn path ->
          do_prepare(content, field, path, opts)
        end)
    end
  end

  defp do_prepare(content, field, path, opts) do
    media_type = effective_media_type(field, content)
    thumbnail_module = Keyword.get(opts, :thumbnail_module, Thumbnail)

    with {:ok, encrypted} <-
           Crypto.encrypt(File.stream!(path, 64 * 1024), media_type, tmp_dir: opts[:tmp_dir]) do
      try do
        with {:ok, upload_result} <-
               upload_media(encrypted.encrypted_path, media_type, encrypted.file_enc_sha256, opts) do
          media_upload =
            %{
              media_url: upload_result.media_url,
              direct_path: upload_result.direct_path,
              meta_hmac: Map.get(upload_result, :meta_hmac),
              ts: Map.get(upload_result, :ts),
              fbid: Map.get(upload_result, :fbid),
              media_key: encrypted.media_key,
              file_sha256: encrypted.file_sha256,
              file_enc_sha256: encrypted.file_enc_sha256,
              file_length: encrypted.file_length,
              media_key_timestamp: now_unix(opts)
            }
            |> Map.merge(derivative_metadata(field, content, path, thumbnail_module, opts))

          {:ok,
           content
           |> Map.put(:media_upload, media_upload)
           |> maybe_put_mimetype(field, path)
           |> maybe_put_file_name(field, path)}
        end
      after
        maybe_remove_file(encrypted.encrypted_path)
      end
    end
  end

  defp upload_media(encrypted_path, media_type, file_enc_sha256, opts) do
    case opts[:media_upload_fun] do
      fun when is_function(fun, 3) ->
        fun.(encrypted_path, media_type, file_enc_sha256: file_enc_sha256)

      _ ->
        case opts[:media_queryable] || opts[:query_fun] || opts[:socket] do
          nil ->
            {:error, :media_upload_not_configured}

          queryable ->
            Upload.upload(queryable, encrypted_path, media_type,
              file_enc_sha256: file_enc_sha256,
              store_ref: opts[:store_ref],
              request_fun: opts[:request_fun],
              req_options: opts[:req_options]
            )
        end
    end
  end

  defp derivative_metadata(:image, _content, path, thumbnail_module, opts) do
    path
    |> File.read!()
    |> thumbnail_module.image_thumbnail(thumbnail_opts(opts))
    |> derivative_or_empty()
  end

  defp derivative_metadata(:video, _content, path, thumbnail_module, opts) do
    thumbnail_module
    |> maybe_call(:video_thumbnail, [path, thumbnail_opts(opts)])
    |> derivative_or_empty()
  end

  defp derivative_metadata(:audio, %{ptt: true}, path, thumbnail_module, opts) do
    case maybe_call(thumbnail_module, :audio_waveform, [path, thumbnail_opts(opts)]) do
      {:ok, waveform} when is_binary(waveform) -> %{waveform: waveform}
      _ -> %{}
    end
  end

  defp derivative_metadata(:sticker, _content, path, thumbnail_module, _opts) do
    case File.read(path) do
      {:ok, binary} ->
        case maybe_call(thumbnail_module, :image_dimensions, [binary]) do
          {:ok, {width, height}} -> %{width: width, height: height}
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp derivative_metadata(_field, _content, _path, _thumbnail_module, _opts), do: %{}

  defp derivative_or_empty({:ok, %{jpeg_thumbnail: _thumb} = derivative}), do: derivative
  defp derivative_or_empty(_result), do: %{}

  defp maybe_call(module, function, args) do
    apply(module, function, args)
  rescue
    _error -> {:error, :derivative_failed}
  end

  defp maybe_put_mimetype(content, field, path) do
    Map.put_new(content, :mimetype, infer_mimetype(field, path))
  end

  defp maybe_put_file_name(content, :document, path),
    do: Map.put_new(content, :file_name, Path.basename(path))

  defp maybe_put_file_name(content, _field, _path), do: content

  defp infer_mimetype(:sticker, path), do: fallback_mimetype(path, "image/webp")

  defp infer_mimetype(:document, path),
    do: fallback_mimetype(path, "application/octet-stream")

  defp infer_mimetype(_field, path), do: fallback_mimetype(path, MIME.from_path(path))

  defp thumbnail_opts(opts) do
    Keyword.take(opts, [
      :image_module,
      :ffmpeg_path,
      :cmd_runner,
      :cmd_opts,
      :tmp_dir,
      :width,
      :time
    ])
  end

  defp effective_media_type(field, _content), do: field

  defp media_entry(content) do
    Enum.find_value([:image, :video, :audio, :document, :sticker], fn field ->
      if Map.has_key?(content, field), do: {field, Map.fetch!(content, field)}
    end)
  end

  defp with_media_file({:file, path}, _field, _opts, fun) when is_binary(path), do: fun.(path)

  defp with_media_file({:binary, binary}, field, opts, fun) when is_binary(binary) do
    with_temp_file(binary, field, opts, fun)
  end

  defp with_media_file(path, _field, _opts, fun) when is_binary(path) do
    if File.exists?(path) do
      fun.(path)
    else
      {:error, :media_file_not_found}
    end
  end

  defp with_media_file(_input, _field, _opts, _fun), do: {:error, :invalid_media_input}

  defp with_temp_file(binary, field, opts, fun) do
    tmp_dir = Keyword.get(opts, :tmp_dir, System.tmp_dir!())
    path = Path.join(tmp_dir, "#{field}-#{System.unique_integer([:positive])}.bin")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, binary)

    try do
      fun.(path)
    after
      File.rm(path)
    end
  end

  defp now_unix(opts) do
    case opts[:now_unix_fun] do
      fun when is_function(fun, 0) -> fun.()
      _ -> System.os_time(:second)
    end
  end

  defp fallback_mimetype(path, default),
    do: Map.get(@extension_mimetypes, String.downcase(Path.extname(path)), default)

  defp maybe_remove_file(path), do: File.rm(path)
end
