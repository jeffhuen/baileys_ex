defmodule BaileysEx.Feature.Profile do
  @moduledoc """
  Profile-picture queries aligned with the implemented Baileys profile surface.
  """

  alias BaileysEx.BinaryNode
  alias BaileysEx.Connection.Socket
  alias BaileysEx.Feature.TcToken
  alias BaileysEx.Protocol.BinaryNode, as: BinaryNodeUtil
  alias BaileysEx.Protocol.JID

  @s_whatsapp_net "s.whatsapp.net"
  @timeout 60_000

  @type picture_type :: :preview | :image

  @doc """
  Fetch the profile-picture URL for a user or group.
  """
  @spec picture_url(term(), String.t(), picture_type(), keyword()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def picture_url(queryable, jid, type \\ :preview, opts \\ [])
      when is_binary(jid) and type in [:preview, :image] and is_list(opts) do
    base_content = [
      %BinaryNode{tag: "picture", attrs: %{"type" => Atom.to_string(type), "query" => "url"}}
    ]

    node = %BinaryNode{
      tag: "iq",
      attrs: %{
        "target" => JID.normalized_user(jid),
        "to" => @s_whatsapp_net,
        "type" => "get",
        "xmlns" => "w:profile:picture"
      },
      content: TcToken.build_content(opts[:signal_store], jid, base_content)
    }

    with {:ok, %BinaryNode{} = response} <-
           query(queryable, node, Keyword.get(opts, :query_timeout, @timeout)) do
      {:ok, response |> BinaryNodeUtil.child("picture") |> maybe_url()}
    end
  end

  defp maybe_url(%BinaryNode{attrs: attrs}), do: attrs["url"]
  defp maybe_url(nil), do: nil

  defp query(queryable, %BinaryNode{} = node, timeout) when is_function(queryable, 2),
    do: queryable.(node, timeout)

  defp query(queryable, %BinaryNode{} = node, _timeout) when is_function(queryable, 1),
    do: queryable.(node)

  defp query({module, server}, %BinaryNode{} = node, timeout) when is_atom(module),
    do: module.query(server, node, timeout)

  defp query(queryable, %BinaryNode{} = node, timeout),
    do: Socket.query(queryable, node, timeout)
end
