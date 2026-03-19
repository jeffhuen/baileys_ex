defmodule BaileysEx.Media.Thumbnail do
  @moduledoc """
  Generate media derivatives used by WhatsApp media messages.

  Image thumbnails use the optional `Image` package when it is available.
  Video thumbnails and audio waveforms use `ffmpeg` when it is available.
  Missing runtime tools return explicit dependency errors instead of crashing.
  """

  @default_width 32
  @default_time "00:00:01"
  @waveform_samples 64

  @type derivative_error ::
          :invalid_audio_payload
          | :unsupported_image_format
          | {:ffmpeg_failed, term()}
          | {:image_processing_failed, term()}
          | {:missing_dependency, :ffmpeg | :image}

  @type thumbnail_result :: %{
          jpeg_thumbnail: binary(),
          width: pos_integer(),
          height: pos_integer()
        }

  @doc """
  Generate a JPEG thumbnail for an image binary.

  Returns the generated thumbnail bytes along with the original image
  dimensions, matching the metadata Baileys uses later in message building.
  """
  @spec image_thumbnail(binary(), keyword()) ::
          {:ok, thumbnail_result()} | {:error, derivative_error()}
  def image_thumbnail(image_data, opts \\ []) when is_binary(image_data) do
    width = Keyword.get(opts, :width, @default_width)

    with {:ok, {original_width, original_height}} <- image_dimensions(image_data),
         {:ok, image_module} <- image_module(opts),
         {:ok, image} <- image_from_binary(image_module, image_data),
         {:ok, thumbnail} <- image_resize(image_module, image, width),
         {:ok, jpeg_thumbnail} <- image_write(image_module, thumbnail) do
      {:ok,
       %{
         jpeg_thumbnail: jpeg_thumbnail,
         width: original_width,
         height: original_height
       }}
    end
  end

  @doc """
  Generate a JPEG thumbnail from a video file.

  This shells out to `ffmpeg` and returns the generated thumbnail bytes along
  with the thumbnail dimensions.
  """
  @spec video_thumbnail(Path.t(), keyword()) ::
          {:ok, thumbnail_result()} | {:error, derivative_error()}
  def video_thumbnail(video_path, opts \\ []) when is_binary(video_path) do
    width = Keyword.get(opts, :width, @default_width)
    time = Keyword.get(opts, :time, @default_time)

    with {:ok, ffmpeg} <- ffmpeg_executable(opts),
         {:ok, jpeg_thumbnail} <-
           run_command(
             ffmpeg,
             [
               "-ss",
               time,
               "-i",
               video_path,
               "-y",
               "-vf",
               "scale=#{width}:-1",
               "-vframes",
               "1",
               "-f",
               "image2pipe",
               "-vcodec",
               "mjpeg",
               "pipe:1"
             ],
             opts
           ),
         {:ok, {thumb_width, thumb_height}} <- image_dimensions(jpeg_thumbnail) do
      {:ok,
       %{
         jpeg_thumbnail: jpeg_thumbnail,
         width: thumb_width,
         height: thumb_height
       }}
    end
  end

  @doc """
  Generate a 64-sample WhatsApp-style waveform from an audio file or binary.

  The returned waveform is a 64-byte binary with values in the `0..100` range.
  """
  @spec audio_waveform(binary() | Path.t(), keyword()) ::
          {:ok, binary()} | {:error, derivative_error()}
  def audio_waveform(audio_input, opts \\ [])

  def audio_waveform(audio_path, opts) when is_binary(audio_path) do
    case File.exists?(audio_path) do
      true ->
        audio_waveform_from_path(audio_path, opts)

      false ->
        with_temp_audio_file(audio_path, opts, fn path ->
          audio_waveform_from_path(path, opts)
        end)
    end
  end

  @doc """
  Extract image dimensions from PNG, JPEG, or WebP binary data.
  """
  @spec image_dimensions(binary()) ::
          {:ok, {pos_integer(), pos_integer()}} | {:error, :unsupported_image_format}
  def image_dimensions(image_data) when is_binary(image_data) do
    case parse_dimensions(image_data) do
      {width, height} when width > 0 and height > 0 -> {:ok, {width, height}}
      _ -> {:error, :unsupported_image_format}
    end
  end

  defp audio_waveform_from_path(audio_path, opts) do
    with {:ok, ffmpeg} <- ffmpeg_executable(opts),
         {:ok, pcm} <-
           run_command(
             ffmpeg,
             [
               "-i",
               audio_path,
               "-vn",
               "-ac",
               "1",
               "-f",
               "s16le",
               "-acodec",
               "pcm_s16le",
               "pipe:1"
             ],
             opts
           ) do
      normalize_waveform(pcm, Keyword.get(opts, :samples, @waveform_samples))
    end
  end

  defp image_module(opts) do
    case Keyword.get(opts, :image_module, :auto) do
      nil ->
        {:error, {:missing_dependency, :image}}

      :auto ->
        if Code.ensure_loaded?(Image) and function_exported?(Image, :from_binary, 1) do
          {:ok, Image}
        else
          {:error, {:missing_dependency, :image}}
        end

      image_module when is_atom(image_module) ->
        {:ok, image_module}
    end
  end

  defp image_from_binary(image_module, image_data) do
    case image_module.from_binary(image_data) do
      {:ok, image} -> {:ok, image}
      {:error, reason} -> {:error, {:image_processing_failed, reason}}
      other -> {:error, {:image_processing_failed, other}}
    end
  rescue
    error -> {:error, {:image_processing_failed, error}}
  end

  defp image_resize(image_module, image, width) do
    args =
      case function_exported?(image_module, :thumbnail, 3) do
        true -> [image, width, [crop: :none]]
        false -> [image, width]
      end

    case apply(image_module, :thumbnail, args) do
      {:ok, thumbnail} -> {:ok, thumbnail}
      {:error, reason} -> {:error, {:image_processing_failed, reason}}
      other -> {:error, {:image_processing_failed, other}}
    end
  rescue
    error -> {:error, {:image_processing_failed, error}}
  end

  defp image_write(image_module, image) do
    case image_module.write(image, :memory, suffix: ".jpg", quality: 50) do
      {:ok, jpeg_thumbnail} when is_binary(jpeg_thumbnail) -> {:ok, jpeg_thumbnail}
      {:error, reason} -> {:error, {:image_processing_failed, reason}}
      other -> {:error, {:image_processing_failed, other}}
    end
  rescue
    error -> {:error, {:image_processing_failed, error}}
  end

  defp ffmpeg_executable(opts) do
    case Keyword.fetch(opts, :ffmpeg_path) do
      {:ok, nil} ->
        {:error, {:missing_dependency, :ffmpeg}}

      {:ok, path} when is_binary(path) and byte_size(path) > 0 ->
        {:ok, path}

      :error ->
        case System.find_executable("ffmpeg") do
          nil -> {:error, {:missing_dependency, :ffmpeg}}
          path -> {:ok, path}
        end
    end
  end

  defp run_command(executable, args, opts) do
    runner = Keyword.get(opts, :cmd_runner, &default_cmd_runner/3)
    cmd_opts = Keyword.get(opts, :cmd_opts, [])
    runner.(executable, args, cmd_opts)
  end

  defp default_cmd_runner(executable, args, opts) do
    {output, status} =
      System.cmd(
        executable,
        ["-hide_banner", "-loglevel", "error" | args],
        Keyword.merge([stderr_to_stdout: true], opts)
      )

    case status do
      0 -> {:ok, output}
      _ -> {:error, {:ffmpeg_failed, output}}
    end
  rescue
    error -> {:error, {:ffmpeg_failed, error}}
  end

  defp with_temp_audio_file(audio_binary, opts, fun) when is_binary(audio_binary) do
    tmp_dir = Keyword.get(opts, :tmp_dir, System.tmp_dir!())
    path = Path.join(tmp_dir, "waveform-#{System.unique_integer([:positive])}.bin")

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, audio_binary)

    try do
      fun.(path)
    after
      File.rm(path)
    end
  end

  defp normalize_waveform(<<>>, _samples), do: {:error, :invalid_audio_payload}

  defp normalize_waveform(pcm, samples) when is_binary(pcm) and samples > 0 do
    total_samples = div(byte_size(pcm), 2)

    if total_samples == 0 do
      {:error, :invalid_audio_payload}
    else
      block_size = max(div(total_samples, samples), 1)
      values = decode_pcm_samples(pcm, [])
      normalized = waveform_values(values, samples, block_size)
      {:ok, :erlang.list_to_binary(normalized)}
    end
  end

  defp decode_pcm_samples(<<sample::little-signed-16, rest::binary>>, acc) do
    decode_pcm_samples(rest, [abs(sample) / 32_767 | acc])
  end

  defp decode_pcm_samples(<<_trailing::binary>>, acc), do: Enum.reverse(acc)
  defp decode_pcm_samples(<<>>, acc), do: Enum.reverse(acc)

  defp waveform_values(values, samples, block_size) do
    filtered =
      for index <- 0..(samples - 1) do
        start = index * block_size
        average_sample(values, start, block_size)
      end

    max_value = Enum.max(filtered, fn -> 0.0 end)

    Enum.map(filtered, fn
      _value when max_value == 0.0 -> 0
      value -> min(100, trunc(Float.floor(100 * value / max_value)))
    end)
  end

  defp average_sample(values, start, block_size) do
    block =
      values
      |> Enum.drop(start)
      |> Enum.take(block_size)

    case block do
      [] -> 0.0
      _ -> Enum.sum(block) / length(block)
    end
  end

  defp parse_dimensions(
         <<137, 80, 78, 71, 13, 10, 26, 10, _length::32, "IHDR", width::32-big, height::32-big,
           _rest::binary>>
       ) do
    {width, height}
  end

  defp parse_dimensions(<<"RIFF", _size::little-32, "WEBP", rest::binary>>) do
    parse_webp_dimensions(rest)
  end

  defp parse_dimensions(<<0xFF, 0xD8, rest::binary>>) do
    parse_jpeg_dimensions(rest)
  end

  defp parse_dimensions(_image_data), do: :unsupported

  defp parse_webp_dimensions(
         <<"VP8X", _chunk_size::little-32, _flags, _reserved::binary-size(3),
           width_minus_one::little-size(24), height_minus_one::little-size(24), _rest::binary>>
       ) do
    {width_minus_one + 1, height_minus_one + 1}
  end

  defp parse_webp_dimensions(
         <<"VP8L", _chunk_size::little-32, 0x2F, data::binary-size(4), _rest::binary>>
       ) do
    <<bits::little-32>> = data
    width = 1 + Bitwise.band(bits, 0x3FFF)
    height = 1 + Bitwise.band(Bitwise.bsr(bits, 14), 0x3FFF)
    {width, height}
  end

  defp parse_webp_dimensions(
         <<"VP8 ", _chunk_size::little-32, _frame_tag::binary-size(3), 0x9D, 0x01, 0x2A,
           width_bits::little-16, height_bits::little-16, _rest::binary>>
       ) do
    {Bitwise.band(width_bits, 0x3FFF), Bitwise.band(height_bits, 0x3FFF)}
  end

  defp parse_webp_dimensions(_rest), do: :unsupported

  defp parse_jpeg_dimensions(<<0xFF, marker, rest::binary>>)
       when marker in [
              0xC0,
              0xC1,
              0xC2,
              0xC3,
              0xC5,
              0xC6,
              0xC7,
              0xC9,
              0xCA,
              0xCB,
              0xCD,
              0xCE,
              0xCF
            ] do
    case rest do
      <<_segment_length::16-big, _precision, height::16-big, width::16-big, _tail::binary>> ->
        {width, height}

      _ ->
        :unsupported
    end
  end

  defp parse_jpeg_dimensions(<<0xFF, marker, rest::binary>>) when marker in 0xD0..0xD9 do
    parse_jpeg_dimensions(rest)
  end

  defp parse_jpeg_dimensions(<<0xFF, 0x00, rest::binary>>) do
    parse_jpeg_dimensions(rest)
  end

  defp parse_jpeg_dimensions(<<0xFF, _marker, segment_length::16-big, rest::binary>>)
       when segment_length >= 2 and byte_size(rest) >= segment_length - 2 do
    <<_segment::binary-size(segment_length - 2), tail::binary>> = rest
    parse_jpeg_dimensions(tail)
  end

  defp parse_jpeg_dimensions(<<_byte, rest::binary>>) do
    parse_jpeg_dimensions(rest)
  end

  defp parse_jpeg_dimensions(<<>>), do: :unsupported
end
