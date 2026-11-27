defmodule BaileysEx.Media.HTTP do
  @moduledoc """
  Shared HTTP request helpers for media upload and download flows.
  """

  @doc """
  Merge required headers into an existing header list without overwriting
  caller-supplied values for the same header name.
  """
  @spec merge_headers(
          nil | map() | keyword() | [{String.t() | atom(), term()}],
          nil | map() | keyword() | [{String.t() | atom(), term()}]
        ) :: [{String.t(), term()}]
  def merge_headers(existing, required) do
    normalized = normalize_headers(existing)
    normalized_keys = Map.new(normalized, fn {key, _value} -> {key, true} end)

    defaults =
      required
      |> normalize_headers()
      |> Enum.reject(fn {key, _value} -> Map.has_key?(normalized_keys, key) end)

    normalized ++ defaults
  end

  defp normalize_headers(headers) do
    headers
    |> normalize_header_entries()
    |> Enum.map(fn {key, value} -> {normalize_header_name(key), value} end)
  end

  defp normalize_header_entries(nil), do: []
  defp normalize_header_entries(entries) when is_map(entries), do: Map.to_list(entries)
  defp normalize_header_entries(entries) when is_list(entries), do: entries

  defp normalize_header_name(key) when is_atom(key) do
    key
    |> Atom.to_string()
    |> String.replace("_", "-")
    |> String.downcase()
  end

  defp normalize_header_name(key) when is_binary(key) do
    String.downcase(key)
  end
end
