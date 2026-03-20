defmodule BaileysEx.Auth.PersistenceHelpers do
  @moduledoc false

  @spec merge_key_indexes(
          %{optional(atom()) => [String.t()]},
          %{optional(atom()) => [String.t()]}
        ) :: %{optional(atom()) => [String.t()]}
  def merge_key_indexes(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _type, left_ids, right_ids ->
      left_ids
      |> Kernel.++(right_ids)
      |> Enum.uniq()
      |> Enum.sort()
    end)
  end
end
