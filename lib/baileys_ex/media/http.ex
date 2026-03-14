defmodule BaileysEx.Media.HTTP do
  @moduledoc """
  Shared HTTP request helpers for media upload and download flows.
  """

  @doc """
  Merge required headers into an existing header list without overwriting
  caller-supplied values for the same header name.
  """
  @spec merge_headers(keyword() | [{String.t() | atom(), term()}], [{String.t(), term()}]) ::
          [{String.t(), term()}]
  def merge_headers(existing, required) do
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
