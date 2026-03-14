defmodule BaileysEx.TestHelpers.FakeThumbnail do
  @moduledoc false

  def image_thumbnail(_binary, _opts) do
    {:ok, %{jpeg_thumbnail: "thumb-jpeg", width: 13, height: 7}}
  end

  def video_thumbnail(_path, _opts) do
    {:ok, %{jpeg_thumbnail: "video-thumb", width: 32, height: 18}}
  end

  def audio_waveform(_path, _opts) do
    {:ok, :binary.copy(<<42>>, 64)}
  end

  def image_dimensions(_binary) do
    {:ok, {9, 9}}
  end
end
