defmodule BaileysEx.Feature.ProfileTest do
  use ExUnit.Case, async: true

  alias BaileysEx.BinaryNode
  alias BaileysEx.Feature.Profile
  alias BaileysEx.Signal.Store

  test "picture_url/4 appends the stored tc token and returns the picture url" do
    {:ok, store} = Store.start_link()

    assert :ok =
             Store.set(store, %{
               tctoken: %{"15551234567@s.whatsapp.net" => %{token: "tc-token"}}
             })

    parent = self()

    query_fun = fn node, timeout ->
      send(parent, {:query, node, timeout})

      {:ok,
       %BinaryNode{
         tag: "iq",
         attrs: %{"type" => "result"},
         content: [
           %BinaryNode{
             tag: "picture",
             attrs: %{"url" => "https://cdn.example.test/profile.jpg"},
             content: nil
           }
         ]
       }}
    end

    assert {:ok, "https://cdn.example.test/profile.jpg"} =
             Profile.picture_url(query_fun, "15551234567@s.whatsapp.net", :image,
               signal_store: store,
               query_timeout: 12_345
             )

    assert_receive {:query,
                    %BinaryNode{
                      tag: "iq",
                      attrs: %{
                        "target" => "15551234567@s.whatsapp.net",
                        "to" => "s.whatsapp.net",
                        "type" => "get",
                        "xmlns" => "w:profile:picture"
                      },
                      content: [
                        %BinaryNode{
                          tag: "picture",
                          attrs: %{"type" => "image", "query" => "url"},
                          content: nil
                        },
                        %BinaryNode{tag: "tctoken", attrs: %{}, content: "tc-token"}
                      ]
                    }, 12_345}
  end

  test "picture_url/4 normalizes the target jid and omits tc tokens when none exist" do
    parent = self()

    query_fun = fn node, timeout ->
      send(parent, {:query, node, timeout})
      {:ok, %BinaryNode{tag: "iq", attrs: %{"type" => "result"}, content: nil}}
    end

    assert {:ok, nil} = Profile.picture_url(query_fun, "15551234567:2@c.us")

    assert_receive {:query,
                    %BinaryNode{
                      tag: "iq",
                      attrs: %{
                        "target" => "15551234567@s.whatsapp.net",
                        "to" => "s.whatsapp.net",
                        "type" => "get",
                        "xmlns" => "w:profile:picture"
                      },
                      content: [
                        %BinaryNode{
                          tag: "picture",
                          attrs: %{"type" => "preview", "query" => "url"},
                          content: nil
                        }
                      ]
                    }, 60_000}
  end

  test "picture_url/4 propagates query errors" do
    assert {:error, :closed} =
             Profile.picture_url(
               fn _node, _timeout -> {:error, :closed} end,
               "15551234567@s.whatsapp.net"
             )
  end
end
