defmodule BaileysEx.Feature.TcTokenTest do
  use ExUnit.Case, async: true

  alias BaileysEx.BinaryNode
  alias BaileysEx.Feature.TcToken
  alias BaileysEx.Signal.LIDMappingStore
  alias BaileysEx.Signal.Store

  test "build_content/3 appends the stored trusted-contact token" do
    {:ok, store} = Store.start_link()

    assert nil == TcToken.build_content(store, "15551234567@s.whatsapp.net")
    assert nil == TcToken.build_node(store, "15551234567@s.whatsapp.net")

    assert :ok =
             Store.set(store, %{
               tctoken: %{
                 "15551234567@s.whatsapp.net" => %{token: "tc-token", timestamp: "4102444800"}
               }
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
               tctoken: %{
                 "167946206842976@lid" => %{token: "lid-token", timestamp: "4102444800"}
               }
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
               tctoken: %{
                 "15551234567@s.whatsapp.net" => %{token: token, timestamp: "4102444800"}
               }
             })

    assert %BinaryNode{tag: "tctoken", attrs: %{}, content: {:binary, ^token}} =
             TcToken.build_node(store, "15551234567@s.whatsapp.net")
  end

  test "build_node/3 drops expired peer tokens and preserves sender timestamp state" do
    {:ok, store} = Store.start_link()

    assert :ok =
             Store.set(store, %{
               tctoken: %{
                 "15551234567@s.whatsapp.net" => %{
                   token: "expired-token",
                   timestamp: "1",
                   sender_timestamp: 9_900_000
                 }
               }
             })

    assert nil == TcToken.build_node(store, "15551234567@s.whatsapp.net", now: 10_000_000)

    assert %{
             "15551234567@s.whatsapp.net" => %{token: "", sender_timestamp: 9_900_000}
           } = Store.get(store, :tctoken, ["15551234567@s.whatsapp.net"])
  end

  test "build_node/3 resolves stored peer tokens through known LID mappings" do
    {:ok, store} = Store.start_link()

    assert :ok =
             LIDMappingStore.store_lid_pn_mappings(store, [
               %{pn: "15551234567@s.whatsapp.net", lid: "167946206842976@lid"}
             ])

    assert :ok =
             Store.set(store, %{
               tctoken: %{
                 "167946206842976@lid" => %{token: "lid-token", timestamp: "9999999"}
               }
             })

    assert %BinaryNode{tag: "tctoken", attrs: %{}, content: {:binary, "lid-token"}} =
             TcToken.build_node(store, "15551234567@s.whatsapp.net", now: 10_000_000)
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

  test "store_from_iq_result/3 stores returned trusted-contact tokens and preserves sender timestamp" do
    {:ok, store} = Store.start_link()

    assert :ok =
             Store.set(store, %{
               tctoken: %{
                 "15551234567@s.whatsapp.net" => %{
                   token: "old-token",
                   timestamp: "100",
                   sender_timestamp: 1_710_000_804
                 }
               }
             })

    result = %BinaryNode{
      tag: "iq",
      attrs: %{"type" => "result"},
      content: [
        %BinaryNode{
          tag: "tokens",
          attrs: %{},
          content: [
            %BinaryNode{
              tag: "token",
              attrs: %{"type" => "trusted_contact", "t" => "1710000900"},
              content: {:binary, "fresh-token"}
            }
          ]
        }
      ]
    }

    assert :ok =
             TcToken.store_from_iq_result(result, "15551234567@s.whatsapp.net",
               signal_store: store
             )

    assert %{
             "15551234567@s.whatsapp.net" => %{
               token: "fresh-token",
               timestamp: "1710000900",
               sender_timestamp: 1_710_000_804
             }
           } = Store.get(store, :tctoken, ["15551234567@s.whatsapp.net"])
  end

  test "reissue_after_identity_change/4 reuses stored sender timestamp and stores returned token" do
    {:ok, store} = Store.start_link()
    parent = self()

    assert :ok =
             Store.set(store, %{
               tctoken: %{
                 "15551234567@s.whatsapp.net" => %{
                   token: "",
                   timestamp: "100",
                   sender_timestamp: 1_710_000_804
                 }
               }
             })

    query_fun = fn node, timeout ->
      send(parent, {:query, node, timeout})

      {:ok,
       %BinaryNode{
         tag: "iq",
         attrs: %{"type" => "result"},
         content: [
           %BinaryNode{
             tag: "tokens",
             attrs: %{},
             content: [
               %BinaryNode{
                 tag: "token",
                 attrs: %{"type" => "trusted_contact", "t" => "1710000900"},
                 content: {:binary, "fresh-token"}
               }
             ]
           }
         ]
       }}
    end

    assert :ok =
             TcToken.reissue_after_identity_change(
               query_fun,
               store,
               "15551234567@s.whatsapp.net",
               now: 1_710_000_900
             )

    assert_receive {:query,
                    %BinaryNode{
                      attrs: %{"xmlns" => "privacy", "type" => "set"},
                      content: [
                        %BinaryNode{
                          tag: "tokens",
                          content: [
                            %BinaryNode{
                              attrs: %{
                                "jid" => "15551234567@s.whatsapp.net",
                                "t" => "1710000804",
                                "type" => "trusted_contact"
                              }
                            }
                          ]
                        }
                      ]
                    }, 60_000}

    assert %{
             "15551234567@s.whatsapp.net" => %{
               token: "fresh-token",
               timestamp: "1710000900",
               sender_timestamp: 1_710_000_804
             }
           } = Store.get(store, :tctoken, ["15551234567@s.whatsapp.net"])
  end

  test "issue_after_outgoing_message/4 sends a fresh token request and records sender timestamp" do
    {:ok, store} = Store.start_link()
    parent = self()

    query_fun = fn node, timeout ->
      send(parent, {:query, node, timeout})

      {:ok,
       %BinaryNode{
         tag: "iq",
         attrs: %{"type" => "result"},
         content: [
           %BinaryNode{
             tag: "tokens",
             attrs: %{},
             content: [
               %BinaryNode{
                 tag: "token",
                 attrs: %{"type" => "trusted_contact", "t" => "1710001000"},
                 content: {:binary, "issued-token"}
               }
             ]
           }
         ]
       }}
    end

    assert :ok =
             TcToken.issue_after_outgoing_message(
               query_fun,
               store,
               "15551234567@s.whatsapp.net",
               now: 1_710_000_900,
               timestamp_fun: fn -> 1_710_000_900 end
             )

    assert_receive {:query,
                    %BinaryNode{
                      attrs: %{"xmlns" => "privacy", "type" => "set"},
                      content: [
                        %BinaryNode{
                          tag: "tokens",
                          content: [
                            %BinaryNode{
                              attrs: %{
                                "jid" => "15551234567@s.whatsapp.net",
                                "t" => "1710000900",
                                "type" => "trusted_contact"
                              }
                            }
                          ]
                        }
                      ]
                    }, 60_000}

    assert %{
             "15551234567@s.whatsapp.net" => %{
               token: "issued-token",
               timestamp: "1710001000",
               sender_timestamp: 1_710_000_900
             }
           } = Store.get(store, :tctoken, ["15551234567@s.whatsapp.net"])
  end

  test "issue_after_outgoing_message/4 skips when sender timestamp is in the current bucket" do
    {:ok, store} = Store.start_link()
    parent = self()

    assert :ok =
             Store.set(store, %{
               tctoken: %{
                 "15551234567@s.whatsapp.net" => %{
                   token: "existing-token",
                   timestamp: "1710000800",
                   sender_timestamp: 1_710_000_804
                 }
               }
             })

    query_fun = fn node, timeout ->
      send(parent, {:unexpected_query, node, timeout})
      {:error, :unexpected}
    end

    assert :ok =
             TcToken.issue_after_outgoing_message(
               query_fun,
               store,
               "15551234567@s.whatsapp.net",
               now: 1_710_000_900,
               timestamp_fun: fn -> 1_710_000_900 end
             )

    refute_received {:unexpected_query, _node, _timeout}

    assert %{
             "15551234567@s.whatsapp.net" => %{
               token: "existing-token",
               timestamp: "1710000800",
               sender_timestamp: 1_710_000_804
             }
           } = Store.get(store, :tctoken, ["15551234567@s.whatsapp.net"])
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

  test "handle_notification/2 ignores non-regular senders and timestamp-less tokens" do
    {:ok, store} = Store.start_link()

    non_regular_notification = %BinaryNode{
      tag: "notification",
      attrs: %{"type" => "privacy_token", "from" => "0@c.us"},
      content: [
        %BinaryNode{
          tag: "tokens",
          attrs: %{},
          content: [
            %BinaryNode{
              tag: "token",
              attrs: %{"type" => "trusted_contact", "t" => "1710000704"},
              content: {:binary, "psa-token"}
            }
          ]
        }
      ]
    }

    timestampless_notification = %BinaryNode{
      tag: "notification",
      attrs: %{"type" => "privacy_token", "from" => "15551234567@c.us"},
      content: [
        %BinaryNode{
          tag: "tokens",
          attrs: %{},
          content: [
            %BinaryNode{
              tag: "token",
              attrs: %{"type" => "trusted_contact"},
              content: {:binary, "timestampless-token"}
            }
          ]
        }
      ]
    }

    assert :ok = TcToken.handle_notification(non_regular_notification, signal_store: store)
    assert :ok = TcToken.handle_notification(timestampless_notification, signal_store: store)

    assert Store.get(store, :tctoken, ["0@s.whatsapp.net", "15551234567@s.whatsapp.net"]) == %{}
  end

  test "handle_notification/2 keeps newer trusted-contact tokens and ignores older ones" do
    {:ok, store} = Store.start_link()

    assert :ok =
             Store.set(store, %{
               tctoken: %{
                 "15551234567@s.whatsapp.net" => %{token: "newer-token", timestamp: "200"}
               }
             })

    older_notification = %BinaryNode{
      tag: "notification",
      attrs: %{"type" => "privacy_token", "from" => "15551234567@c.us"},
      content: [
        %BinaryNode{
          tag: "tokens",
          attrs: %{},
          content: [
            %BinaryNode{
              tag: "token",
              attrs: %{"type" => "trusted_contact", "t" => "100"},
              content: {:binary, "older-token"}
            }
          ]
        }
      ]
    }

    newer_notification = %BinaryNode{
      tag: "notification",
      attrs: %{"type" => "privacy_token", "from" => "15551234567@c.us"},
      content: [
        %BinaryNode{
          tag: "tokens",
          attrs: %{},
          content: [
            %BinaryNode{
              tag: "token",
              attrs: %{"type" => "trusted_contact", "t" => "300"},
              content: {:binary, "newest-token"}
            }
          ]
        }
      ]
    }

    assert :ok = TcToken.handle_notification(older_notification, signal_store: store)

    assert %{"15551234567@s.whatsapp.net" => %{token: "newer-token", timestamp: "200"}} =
             Store.get(store, :tctoken, ["15551234567@s.whatsapp.net"])

    assert :ok = TcToken.handle_notification(newer_notification, signal_store: store)

    assert %{"15551234567@s.whatsapp.net" => %{token: "newest-token", timestamp: "300"}} =
             Store.get(store, :tctoken, ["15551234567@s.whatsapp.net"])
  end

  test "handle_notification/2 stores trusted-contact tokens under known LID mapping" do
    {:ok, store} = Store.start_link()

    assert :ok =
             LIDMappingStore.store_lid_pn_mappings(store, [
               %{pn: "15551234567@s.whatsapp.net", lid: "167946206842976@lid"}
             ])

    notification = %BinaryNode{
      tag: "notification",
      attrs: %{"type" => "privacy_token", "from" => "15551234567@c.us"},
      content: [
        %BinaryNode{
          tag: "tokens",
          attrs: %{},
          content: [
            %BinaryNode{
              tag: "token",
              attrs: %{"type" => "trusted_contact", "t" => "1710000704"},
              content: {:binary, "lid-token"}
            }
          ]
        }
      ]
    }

    assert :ok = TcToken.handle_notification(notification, signal_store: store)

    assert %{"167946206842976@lid" => %{token: "lid-token", timestamp: "1710000704"}} =
             Store.get(store, :tctoken, ["167946206842976@lid"])

    assert %{} = Store.get(store, :tctoken, ["15551234567@s.whatsapp.net"])
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
