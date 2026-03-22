defmodule BaileysEx.Feature.BotDirectory do
  @moduledoc """
  WhatsApp bot-directory queries aligned with Baileys `getBotListV2`.
  """

  alias BaileysEx.BinaryNode
  import BaileysEx.Connection.TransportAdapter, only: [query: 3]
  alias BaileysEx.Protocol.BinaryNode, as: BinaryNodeUtil

  @s_whatsapp_net "s.whatsapp.net"
  @timeout 60_000

  @doc """
  Fetch the v2 bot directory and return bot entries from the `all` section.
  """
  @spec list(term(), keyword()) ::
          {:ok, [%{jid: String.t(), persona_id: String.t()}]} | {:error, term()}
  def list(queryable, opts \\ []) do
    node = %BinaryNode{
      tag: "iq",
      attrs: %{"xmlns" => "bot", "to" => @s_whatsapp_net, "type" => "get"},
      content: [%BinaryNode{tag: "bot", attrs: %{"v" => "2"}, content: nil}]
    }

    with {:ok, %BinaryNode{} = response} <-
           query(queryable, node, Keyword.get(opts, :query_timeout, @timeout)) do
      {:ok, parse_bot_list(response)}
    end
  end

  defp parse_bot_list(response) do
    response
    |> BinaryNodeUtil.child("bot")
    |> BinaryNodeUtil.children("section")
    |> Enum.reduce([], fn
      %BinaryNode{attrs: %{"type" => "all"}} = section, acc ->
        bots =
          Enum.map(BinaryNodeUtil.children(section, "bot"), fn bot ->
            %{jid: bot.attrs["jid"], persona_id: bot.attrs["persona_id"]}
          end)

        acc ++ bots

      _section, acc ->
        acc
    end)
  end
end
