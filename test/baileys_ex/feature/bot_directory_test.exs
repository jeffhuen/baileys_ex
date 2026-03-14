defmodule BaileysEx.Feature.BotDirectoryTest do
  use ExUnit.Case, async: true

  alias BaileysEx.BinaryNode
  alias BaileysEx.Feature.BotDirectory

  test "list/2 fetches and parses v2 bot directory entries from all sections only" do
    parent = self()

    query_fun = fn node, timeout ->
      send(parent, {:query, node, timeout})

      {:ok,
       %BinaryNode{
         tag: "iq",
         attrs: %{"type" => "result"},
         content: [
           %BinaryNode{
             tag: "bot",
             attrs: %{},
             content: [
               %BinaryNode{
                 tag: "section",
                 attrs: %{"type" => "featured"},
                 content: [
                   %BinaryNode{
                     tag: "bot",
                     attrs: %{"jid" => "featured@c.us", "persona_id" => "featured-persona"}
                   }
                 ]
               },
               %BinaryNode{
                 tag: "section",
                 attrs: %{"type" => "all"},
                 content: [
                   %BinaryNode{
                     tag: "bot",
                     attrs: %{"jid" => "13135551234@c.us", "persona_id" => "persona-1"}
                   },
                   %BinaryNode{
                     tag: "bot",
                     attrs: %{"jid" => "13135555678@c.us", "persona_id" => "persona-2"}
                   }
                 ]
               }
             ]
           }
         ]
       }}
    end

    assert {:ok,
            [
              %{jid: "13135551234@c.us", persona_id: "persona-1"},
              %{jid: "13135555678@c.us", persona_id: "persona-2"}
            ]} = BotDirectory.list(query_fun)

    assert_receive {:query,
                    %BinaryNode{
                      tag: "iq",
                      attrs: %{"xmlns" => "bot", "to" => "s.whatsapp.net", "type" => "get"},
                      content: [%BinaryNode{tag: "bot", attrs: %{"v" => "2"}}]
                    }, 60_000}
  end

  test "list/2 returns an empty list when the bot node is absent or empty" do
    query_fun = fn _node, _timeout ->
      {:ok, %BinaryNode{tag: "iq", attrs: %{"type" => "result"}, content: nil}}
    end

    assert {:ok, []} = BotDirectory.list(query_fun)
  end

  test "list/2 propagates query errors" do
    assert {:error, :timeout} =
             BotDirectory.list(fn _node, _timeout -> {:error, :timeout} end)
  end
end
