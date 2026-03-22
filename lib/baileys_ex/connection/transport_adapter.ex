defmodule BaileysEx.Connection.TransportAdapter do
  @moduledoc false

  alias BaileysEx.BinaryNode
  alias BaileysEx.Connection.Socket

  @spec query(term(), BinaryNode.t(), timeout()) :: {:ok, BinaryNode.t()} | {:error, term()}
  def query(queryable, %BinaryNode{} = node, timeout) when is_function(queryable, 2),
    do: queryable.(node, timeout)

  def query(queryable, %BinaryNode{} = node, _timeout) when is_function(queryable, 1),
    do: queryable.(node)

  def query({module, server}, %BinaryNode{} = node, timeout) when is_atom(module),
    do: module.query(server, node, timeout)

  def query(queryable, %BinaryNode{} = node, timeout), do: Socket.query(queryable, node, timeout)

  @spec send_node(term(), BinaryNode.t()) :: :ok | {:error, term()}
  def send_node(sendable, %BinaryNode{} = node) when is_function(sendable, 1), do: sendable.(node)

  def send_node({module, server}, %BinaryNode{} = node) when is_atom(module),
    do: module.send_node(server, node)

  def send_node(sendable, %BinaryNode{} = node), do: Socket.send_node(sendable, node)
end
