defmodule BaileysEx.Protocol.WMex do
  @moduledoc """
  WMex (WhatsApp MEX) query helpers.

  Reference: `dev/reference/Baileys-master/src/Socket/mex.ts`
  """

  alias BaileysEx.BinaryNode
  alias BaileysEx.Protocol.BinaryNode, as: BinaryNodeUtil
  alias BaileysEx.Protocol.JID

  @spec build_query(String.t(), map(), String.t()) :: BinaryNode.t()
  def build_query(query_id, variables, message_id)
      when is_binary(query_id) and is_map(variables) and is_binary(message_id) do
    %BinaryNode{
      tag: "iq",
      attrs: %{
        "id" => message_id,
        "type" => "get",
        "to" => JID.s_whatsapp_net(),
        "xmlns" => "w:mex"
      },
      content: [
        %BinaryNode{
          tag: "query",
          attrs: %{"query_id" => query_id},
          content: {:binary, JSON.encode!(%{variables: variables})}
        }
      ]
    }
  end

  @spec extract_result(BinaryNode.t(), String.t() | nil) :: {:ok, term()} | {:error, term()}
  def extract_result(%BinaryNode{} = response_node, data_path \\ nil) do
    case BinaryNodeUtil.child(response_node, "result") do
      nil ->
        {:error, {:missing_result, response_node}}

      %BinaryNode{} = result_node ->
        extract_result_payload(response_node, result_node, data_path)
    end
  end

  defp extract_result_payload(response_node, result_node, data_path) do
    case result_payload(result_node) do
      nil ->
        {:error, {:missing_result_payload, response_node}}

      payload ->
        decode_result_payload(response_node, payload, data_path)
    end
  end

  defp decode_result_payload(response_node, payload, data_path) do
    with {:ok, decoded} <- JSON.decode(payload) do
      extract_decoded_result(response_node, decoded, data_path)
    end
  end

  defp extract_decoded_result(response_node, decoded, data_path) do
    case extract_graphql_error(decoded) do
      nil ->
        case result_data(decoded, data_path) do
          {:ok, data} ->
            {:ok, data}

          :error ->
            {:error, {:unexpected_response, action_name(data_path), response_node}}
        end

      error ->
        {:error, {:graphql, error}}
    end
  end

  defp result_payload(%BinaryNode{content: {:binary, payload}}) when is_binary(payload),
    do: payload

  defp result_payload(%BinaryNode{content: payload}) when is_binary(payload), do: payload
  defp result_payload(%BinaryNode{}), do: nil

  defp extract_graphql_error(%{"errors" => [first_error | _] = errors}) do
    messages = Enum.map_join(errors, ", ", &Map.get(&1, "message", "Unknown error"))

    %{
      code: get_in(first_error, ["extensions", "error_code"]) || 400,
      message: "GraphQL server error: #{messages}",
      details: first_error
    }
  end

  defp extract_graphql_error(_decoded), do: nil

  defp result_data(%{"data" => data}, nil), do: {:ok, data}
  defp result_data(%{"data" => data}, ""), do: {:ok, data}

  defp result_data(%{"data" => data}, data_path) when is_binary(data_path) do
    case Map.fetch(data || %{}, data_path) do
      {:ok, value} -> {:ok, value}
      :error -> :error
    end
  end

  defp result_data(_decoded, _data_path), do: :error

  defp action_name(nil), do: "query"

  defp action_name(data_path) when is_binary(data_path) do
    data_path
    |> String.trim_leading("xwa2_")
    |> String.replace("_", " ")
  end
end
