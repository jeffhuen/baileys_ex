defmodule BaileysEx.Feature.PhoneValidationTest do
  use ExUnit.Case, async: true

  alias BaileysEx.BinaryNode
  alias BaileysEx.Feature.PhoneValidation

  test "on_whatsapp/3 builds a deterministic contact USync query and returns only registered numbers" do
    parent = self()

    query_fun = fn node, timeout ->
      send(parent, {:query, node, timeout})

      {:ok,
       %BinaryNode{
         tag: "iq",
         attrs: %{"type" => "result"},
         content: [
           %BinaryNode{
             tag: "usync",
             attrs: %{},
             content: [
               %BinaryNode{
                 tag: "list",
                 attrs: %{},
                 content: [
                   %BinaryNode{
                     tag: "user",
                     attrs: %{"jid" => "15550001111@s.whatsapp.net"},
                     content: [%BinaryNode{tag: "contact", attrs: %{"type" => "in"}}]
                   },
                   %BinaryNode{
                     tag: "user",
                     attrs: %{"jid" => "15550002222@s.whatsapp.net"},
                     content: [%BinaryNode{tag: "contact", attrs: %{"type" => "out"}}]
                   }
                 ]
               }
             ]
           }
         ]
       }}
    end

    assert {:ok, [%{exists: true, jid: "15550001111@s.whatsapp.net"}]} =
             PhoneValidation.on_whatsapp(query_fun, ["15550001111", "+15550002222"], sid: "sid-1")

    assert_receive {:query, %BinaryNode{} = node, 60_000}

    assert %BinaryNode{
             tag: "iq",
             attrs: %{
               "to" => "s.whatsapp.net",
               "xmlns" => "usync",
               "type" => "get"
             },
             content: [
               %BinaryNode{
                 tag: "usync",
                 attrs: %{
                   "context" => "interactive",
                   "mode" => "query",
                   "sid" => "sid-1",
                   "last" => "true",
                   "index" => "0"
                 },
                 content: [
                   %BinaryNode{
                     tag: "query",
                     attrs: %{},
                     content: [%BinaryNode{tag: "contact", attrs: %{}, content: nil}]
                   },
                   %BinaryNode{
                     tag: "list",
                     attrs: %{},
                     content: [
                       %BinaryNode{
                         tag: "user",
                         attrs: %{},
                         content: [%BinaryNode{tag: "contact", content: "+15550001111"}]
                       },
                       %BinaryNode{
                         tag: "user",
                         attrs: %{},
                         content: [%BinaryNode{tag: "contact", content: "+15550002222"}]
                       }
                     ]
                   }
                 ]
               }
             ]
           } = node
  end

  test "on_whatsapp/2 skips LID inputs and avoids issuing an empty query" do
    assert {:ok, []} =
             PhoneValidation.on_whatsapp(fn _, _ -> flunk("should not query") end, ["12345@lid"])
  end

  test "on_whatsapp/3 propagates query errors" do
    assert {:error, :timeout} =
             PhoneValidation.on_whatsapp(
               fn _node, _timeout -> {:error, :timeout} end,
               ["15550001111"],
               sid: "sid-2"
             )
  end
end
