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

    normalized_keys = Map.new(normalized, fn {key, _value} -> {key, true} end)

    normalized ++
      Enum.reject(required, fn {key, _value} ->
        Map.has_key?(normalized_keys, key)
      end)
  end
end
