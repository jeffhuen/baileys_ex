defmodule BaileysEx.Feature.TcTokenTest do
  use ExUnit.Case, async: true

  alias BaileysEx.BinaryNode
  alias BaileysEx.Feature.TcToken
  alias BaileysEx.Signal.Store

  test "build_content/3 appends the stored trusted-contact token" do
    {:ok, store} = Store.start_link()

    assert nil == TcToken.build_content(store, "15551234567@s.whatsapp.net")
    assert nil == TcToken.build_node(store, "15551234567@s.whatsapp.net")

    assert :ok =
             Store.set(store, %{
               tctoken: %{"15551234567@s.whatsapp.net" => %{token: "tc-token"}}
             })

    base_content = [%BinaryNode{tag: "picture", attrs: %{"type" => "preview"}, content: nil}]

    assert [
             %BinaryNode{tag: "picture", attrs: %{"type" => "preview"}},
             %BinaryNode{tag: "tctoken", attrs: %{}, content: {:binary, "tc-token"}}
           ] = TcToken.build_content(store, "15551234567@s.whatsapp.net", base_content)

    assert %BinaryNode{tag: "tctoken", attrs: %{}, content: {:binary, "tc-token"}} =
             TcToken.build_node(store, "15551234567@s.whatsapp.net")
  end

  test "build_node/2 only returns tokens stored for the exact destination jid" do
    {:ok, store} = Store.start_link()

    assert :ok =
             Store.set(store, %{
               tctoken: %{"167946206842976@lid" => %{token: "lid-token"}}
             })

    assert nil == TcToken.build_node(store, "85262028964@s.whatsapp.net")
    assert %BinaryNode{tag: "tctoken", attrs: %{}, content: {:binary, "lid-token"}} =
             TcToken.build_node(store, "167946206842976@lid")
  end

  test "build_node/2 wraps trusted-contact token bytes as binary content" do
    {:ok, store} = Store.start_link()
    token = <<251, 143, 27, 54, 184, 204, 66, 64>>

    assert :ok =
             Store.set(store, %{
               tctoken: %{"15551234567@s.whatsapp.net" => %{token: token}}
             })

    assert %BinaryNode{tag: "tctoken", attrs: %{}, content: {:binary, ^token}} =
             TcToken.build_node(store, "15551234567@s.whatsapp.net")
  end

  test "get_privacy_tokens/3 builds Baileys privacy token queries with normalized jids" do
    parent = self()

    query_fun = fn node, timeout ->
      send(parent, {:query, node, timeout})
      {:ok, %BinaryNode{tag: "iq", attrs: %{"type" => "result"}, content: nil}}
    end

    assert {:ok, %BinaryNode{tag: "iq", attrs: %{"type" => "result"}}} =
             TcToken.get_privacy_tokens(query_fun, ["15551234567:2@c.us"],
               timestamp_fun: fn -> 1_710_000_804 end
             )

    assert_receive {:query,
                    %BinaryNode{
                      tag: "iq",
                      attrs: %{
                        "to" => "s.whatsapp.net",
                        "type" => "set",
                        "xmlns" => "privacy"
                      },
                      content: [
                        %BinaryNode{
                          tag: "tokens",
                          attrs: %{},
                          content: [
                            %BinaryNode{
                              tag: "token",
                              attrs: %{
                                "jid" => "15551234567@s.whatsapp.net",
                                "t" => "1710000804",
                                "type" => "trusted_contact"
                              },
                              content: nil
                            }
                          ]
                        }
                      ]
                    }, 60_000}
  end

  test "get_privacy_tokens/3 includes every normalized jid in request order" do
    parent = self()

    query_fun = fn node, timeout ->
      send(parent, {:query, node, timeout})
      {:ok, %BinaryNode{tag: "iq", attrs: %{"type" => "result"}, content: nil}}
    end

    assert {:ok, %BinaryNode{tag: "iq", attrs: %{"type" => "result"}}} =
             TcToken.get_privacy_tokens(
               query_fun,
               ["15551234567:2@c.us", "15557654321@s.whatsapp.net"],
               timestamp_fun: fn -> 1_710_000_900 end
             )

    assert_receive {:query,
                    %BinaryNode{
                      content: [
                        %BinaryNode{
                          tag: "tokens",
                          content: [
                            %BinaryNode{attrs: %{"jid" => "15551234567@s.whatsapp.net"}},
                            %BinaryNode{attrs: %{"jid" => "15557654321@s.whatsapp.net"}}
                          ]
                        }
                      ]
                    }, 60_000}
  end

  test "handle_notification/2 stores trusted-contact tokens via callback and signal store" do
    {:ok, store} = Store.start_link()
    parent = self()

    notification = %BinaryNode{
      tag: "notification",
      attrs: %{"type" => "privacy_token", "from" => "15551234567:4@c.us"},
      content: [
        %BinaryNode{
          tag: "tokens",
          attrs: %{},
          content: [
            %BinaryNode{
              tag: "token",
              attrs: %{"type" => "trusted_contact", "t" => "1710000704"},
              content: {:binary, "token-1"}
            },
            %BinaryNode{
              tag: "token",
              attrs: %{"type" => "ignored", "t" => "1710000705"},
              content: {:binary, "token-2"}
            }
          ]
        }
      ]
    }

    assert :ok =
             TcToken.handle_notification(notification,
               signal_store: store,
               store_privacy_token_fun: fn jid, token, timestamp ->
                 send(parent, {:stored, jid, token, timestamp})
                 :ok
               end
             )

    assert_receive {:stored, "15551234567@s.whatsapp.net", "token-1", "1710000704"}

    assert %{"15551234567@s.whatsapp.net" => %{token: "token-1", timestamp: "1710000704"}} =
             Store.get(store, :tctoken, ["15551234567@s.whatsapp.net"])
  end

  test "build_content/3 fails open when the signal store is unavailable" do
    {:ok, store} = Store.start_link()
    base_content = [%BinaryNode{tag: "picture", attrs: %{"type" => "preview"}, content: nil}]

    assert %BaileysEx.Signal.Store.Memory.Ref{pid: pid} = store.ref
    Process.unlink(pid)
    Process.exit(pid, :kill)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

    assert base_content ==
             TcToken.build_content(store, "15551234567@s.whatsapp.net", base_content)

    assert nil == TcToken.build_content(store, "15551234567@s.whatsapp.net")
    assert nil == TcToken.build_node(store, "15551234567@s.whatsapp.net")
  end
end
