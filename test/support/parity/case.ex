defmodule BaileysEx.Parity.Case do
  @moduledoc false

  use ExUnit.CaseTemplate

  alias BaileysEx.BinaryNode
  alias BaileysEx.Parity.NodeBridge

  using opts do
    quote do
      use ExUnit.Case, unquote(opts)
      @moduletag :parity

      import BaileysEx.Parity.Case,
        only: [normalize_binary_node: 1, run_baileys_reference!: 2]
    end
  end

  @spec run_baileys_reference!(String.t(), map()) :: map()
  def run_baileys_reference!(operation, input), do: NodeBridge.run!(operation, input)

  @spec normalize_binary_node(BinaryNode.t()) :: map()
  def normalize_binary_node(%BinaryNode{tag: tag, attrs: attrs, content: content}) do
    %{
      "tag" => tag,
      "attrs" => attrs || %{},
      "content" => normalize_binary_content(content)
    }
  end

  defp normalize_binary_content(nil), do: nil
  defp normalize_binary_content(content) when is_binary(content), do: content

  defp normalize_binary_content({:binary, content}) when is_binary(content) do
    %{
      "type" => "binary",
      "base64" => Base.encode64(content)
    }
  end

  defp normalize_binary_content(content) when is_list(content) do
    Enum.map(content, &normalize_binary_node/1)
  end
end
