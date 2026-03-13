defmodule BaileysEx.Media.ThumbnailTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Media.Thumbnail

  defmodule FakeImage do
    @moduledoc false

    def from_binary(binary) do
      send(Process.get(:thumbnail_test_pid), {:image_from_binary, binary})
      {:ok, %{source: binary}}
    end

    def thumbnail(image, width, opts \\ []) do
      send(Process.get(:thumbnail_test_pid), {:image_thumbnail, image, width, opts})
      {:ok, Map.put(image, :thumb_width, width)}
    end

    def write(image, :memory, opts) do
      send(Process.get(:thumbnail_test_pid), {:image_write, image, opts})
      {:ok, jpeg_binary(4, 3)}
    end

    def width(_image), do: 99
    def height(_image), do: 77

    defp jpeg_binary(width, height) do
      IO.iodata_to_binary([
        <<0xFF, 0xD8>>,
        <<0xFF, 0xE0, 0x00, 0x10, "JFIF", 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00,
          0x00>>,
        <<0xFF, 0xC0, 0x00, 0x11, 0x08, height::16-big, width::16-big, 0x03, 0x01, 0x11, 0x00,
          0x02, 0x11, 0x00, 0x03, 0x11, 0x00>>,
        <<0xFF, 0xDA, 0x00, 0x0C, 0x03, 0x01, 0x00, 0x02, 0x00, 0x03, 0x00, 0x00, 0x3F, 0x00>>,
        <<0x00>>,
        <<0xFF, 0xD9>>
      ])
    end
  end

  setup do
    Process.put(:thumbnail_test_pid, self())
    :ok
  end

  test "image_dimensions/1 parses PNG, JPEG, and WebP headers" do
    assert {:ok, {3, 2}} = Thumbnail.image_dimensions(png_binary(3, 2))
    assert {:ok, {9, 7}} = Thumbnail.image_dimensions(jpeg_binary(9, 7))
    assert {:ok, {11, 5}} = Thumbnail.image_dimensions(webp_binary(11, 5))
  end

  test "image_dimensions/1 rejects unsupported binaries" do
    assert {:error, :unsupported_image_format} = Thumbnail.image_dimensions("not-an-image")
  end

  test "image_thumbnail/2 returns an explicit missing dependency error" do
    assert {:error, {:missing_dependency, :image}} =
             Thumbnail.image_thumbnail(png_binary(2, 2), image_module: nil)
  end

  test "image_thumbnail/2 uses the image adapter and preserves original dimensions" do
    source = png_binary(13, 7)

    assert {:ok, %{jpeg_thumbnail: thumb, width: 13, height: 7}} =
             Thumbnail.image_thumbnail(source, image_module: FakeImage, width: 32)

    assert {:ok, {4, 3}} = Thumbnail.image_dimensions(thumb)
    assert_receive {:image_from_binary, ^source}
    assert_receive {:image_thumbnail, %{source: ^source}, 32, opts}
    assert opts[:crop] == :none
    assert_receive {:image_write, %{source: ^source, thumb_width: 32}, write_opts}
    assert write_opts[:suffix] == ".jpg"
    assert write_opts[:quality] == 50
  end

  test "video_thumbnail/2 shells out through ffmpeg and returns JPEG bytes" do
    parent = self()
    expected = jpeg_binary(8, 6)

    runner = fn executable, args, opts ->
      send(parent, {:ffmpeg_video, executable, args, opts})
      {:ok, expected}
    end

    assert {:ok, %{jpeg_thumbnail: ^expected, width: 8, height: 6}} =
             Thumbnail.video_thumbnail("/tmp/input.mp4",
               ffmpeg_path: "ffmpeg",
               cmd_runner: runner,
               width: 48,
               time: "00:00:02"
             )

    assert_receive {:ffmpeg_video, "ffmpeg", args, _opts}

    assert args == [
             "-ss",
             "00:00:02",
             "-i",
             "/tmp/input.mp4",
             "-y",
             "-vf",
             "scale=48:-1",
             "-vframes",
             "1",
             "-f",
             "image2pipe",
             "-vcodec",
             "mjpeg",
             "pipe:1"
           ]
  end

  test "video_thumbnail/2 returns an explicit missing dependency error" do
    assert {:error, {:missing_dependency, :ffmpeg}} =
             Thumbnail.video_thumbnail("/tmp/input.mp4", ffmpeg_path: nil)
  end

  @tag :tmp_dir
  test "audio_waveform/2 shells out through ffmpeg and normalizes 64 samples",
       %{tmp_dir: tmp_dir} do
    parent = self()
    audio_path = Path.join(tmp_dir, "input.opus")
    File.write!(audio_path, "fake-opus")

    pcm =
      [List.duplicate(0, 64), List.duplicate(32_767, 64)]
      |> List.flatten()
      |> Enum.map(&<<&1::little-signed-16>>)
      |> IO.iodata_to_binary()

    runner = fn executable, args, opts ->
      send(parent, {:ffmpeg_audio, executable, args, opts})
      {:ok, pcm}
    end

    assert {:ok, waveform} =
             Thumbnail.audio_waveform(audio_path,
               ffmpeg_path: "ffmpeg",
               cmd_runner: runner
             )

    assert byte_size(waveform) == 64
    assert waveform == :binary.copy(<<0>>, 32) <> :binary.copy(<<100>>, 32)

    assert_receive {:ffmpeg_audio, "ffmpeg", args, _opts}

    assert args == [
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
           ]
  end

  test "audio_waveform/2 returns an explicit missing dependency error" do
    assert {:error, {:missing_dependency, :ffmpeg}} =
             Thumbnail.audio_waveform("/tmp/input.opus", ffmpeg_path: nil)
  end

  defp png_binary(width, height) do
    IO.iodata_to_binary([
      <<137, 80, 78, 71, 13, 10, 26, 10>>,
      <<0, 0, 0, 13, "IHDR", width::32-big, height::32-big, 8, 2, 0, 0, 0, 0, 0, 0, 0>>,
      <<0, 0, 0, 0, "IEND", 0, 0, 0, 0>>
    ])
  end

  defp jpeg_binary(width, height) do
    IO.iodata_to_binary([
      <<0xFF, 0xD8>>,
      <<0xFF, 0xE0, 0x00, 0x10, "JFIF", 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00,
        0x00>>,
      <<0xFF, 0xC0, 0x00, 0x11, 0x08, height::16-big, width::16-big, 0x03, 0x01, 0x11, 0x00, 0x02,
        0x11, 0x00, 0x03, 0x11, 0x00>>,
      <<0xFF, 0xDA, 0x00, 0x0C, 0x03, 0x01, 0x00, 0x02, 0x00, 0x03, 0x00, 0x00, 0x3F, 0x00>>,
      <<0x00>>,
      <<0xFF, 0xD9>>
    ])
  end

  defp webp_binary(width, height) do
    payload =
      <<0, 0, 0, 0, width - 1::little-size(24), height - 1::little-size(24)>>

    riff_size = 4 + 8 + byte_size(payload)

    IO.iodata_to_binary([
      <<"RIFF">>,
      <<riff_size::little-32>>,
      <<"WEBPVP8X">>,
      <<byte_size(payload)::little-32>>,
      payload
    ])
  end
end
