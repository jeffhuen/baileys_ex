defmodule BaileysEx.Feature.PrivacyTest do
  use ExUnit.Case, async: true

  alias BaileysEx.BinaryNode
  alias BaileysEx.Connection.Store
  alias BaileysEx.Feature.Privacy

  test "fetch_settings/3 returns cached settings when force is false" do
    {:ok, store} = Store.start_link()
    :ok = Store.put(store, :privacy_settings, %{"last" => "contacts", "online" => "all"})

    assert {:ok, %{"last" => "contacts", "online" => "all"}} =
             Privacy.fetch_settings(
               fn _node, _timeout -> flunk("cached privacy settings should skip querying") end,
               false,
               store: Store.wrap(store)
             )
  end

  test "fetch_settings/2 accepts opts directly and uses the cached store value" do
    {:ok, store} = Store.start_link()
    :ok = Store.put(store, :privacy_settings, %{"last" => "contacts", "online" => "all"})

    assert {:ok, %{"last" => "contacts", "online" => "all"}} =
             Privacy.fetch_settings(
               fn _node, _timeout -> flunk("cached privacy settings should skip querying") end,
               store: Store.wrap(store)
             )
  end

  test "fetch_settings/3 queries privacy settings, parses categories, and refreshes the store" do
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
             tag: "privacy",
             attrs: %{},
             content: [
               %BinaryNode{tag: "category", attrs: %{"name" => "last", "value" => "contacts"}},
               %BinaryNode{
                 tag: "category",
                 attrs: %{"name" => "online", "value" => "match_last_seen"}
               }
             ]
           }
         ]
       }}
    end

    assert {:ok, %{"last" => "contacts", "online" => "match_last_seen"}} =
             Privacy.fetch_settings(query_fun, true, store: Store.wrap(store))

    assert_receive {:query,
                    %BinaryNode{
                      tag: "iq",
                      attrs: %{"xmlns" => "privacy", "to" => "s.whatsapp.net", "type" => "get"},
                      content: [%BinaryNode{tag: "privacy", attrs: %{}, content: nil}]
                    }, 60_000}

    assert Store.get(Store.wrap(store), :privacy_settings) == %{
             "last" => "contacts",
             "online" => "match_last_seen"
           }
  end

  test "fetch_settings/2 accepts a force boolean without opts" do
    parent = self()

    query_fun = fn node, timeout ->
      send(parent, {:query, node, timeout})

      {:ok,
       %BinaryNode{
         tag: "iq",
         attrs: %{"type" => "result"},
         content: [
           %BinaryNode{
             tag: "privacy",
             attrs: %{},
             content: [
               %BinaryNode{tag: "category", attrs: %{"name" => "last", "value" => "contacts"}}
             ]
           }
         ]
       }}
    end

    assert {:ok, %{"last" => "contacts"}} = Privacy.fetch_settings(query_fun, true)

    assert_receive {:query,
                    %BinaryNode{
                      tag: "iq",
                      attrs: %{"xmlns" => "privacy", "to" => "s.whatsapp.net", "type" => "get"}
                    }, 60_000}
  end

  test "fetch_settings/3 falls back to config_code and config_value attrs" do
    parent = self()

    query_fun = fn node, timeout ->
      send(parent, {:query, node, timeout})

      {:ok,
       %BinaryNode{
         tag: "iq",
         attrs: %{"type" => "result"},
         content: [
           %BinaryNode{
             tag: "privacy",
             attrs: %{},
             content: [
               %BinaryNode{
                 tag: "category",
                 attrs: %{"config_code" => "last", "config_value" => "contacts"}
               },
               %BinaryNode{
                 tag: "category",
                 attrs: %{"name" => "online", "value" => "match_last_seen"}
               }
             ]
           }
         ]
       }}
    end

    assert {:ok, %{"last" => "contacts", "online" => "match_last_seen"}} =
             Privacy.fetch_settings(query_fun, true)

    assert_receive {:query,
                    %BinaryNode{
                      tag: "iq",
                      attrs: %{"xmlns" => "privacy", "to" => "s.whatsapp.net", "type" => "get"}
                    }, 60_000}
  end

  test "privacy category updates use the exact Baileys category names" do
    updates = [
      {&Privacy.update_last_seen/2, :contacts, "last", "contacts"},
      {&Privacy.update_online/2, :match_last_seen, "online", "match_last_seen"},
      {&Privacy.update_profile_picture/2, :contact_blacklist, "profile", "contact_blacklist"},
      {&Privacy.update_status/2, :none, "status", "none"},
      {&Privacy.update_read_receipts/2, :none, "readreceipts", "none"},
      {&Privacy.update_call_add/2, :known, "calladd", "known"},
      {&Privacy.update_messages/2, :contacts, "messages", "contacts"},
      {&Privacy.update_group_add/2, :contact_blacklist, "groupadd", "contact_blacklist"}
    ]

    Enum.each(updates, fn {fun, value, category, expected_value} ->
      parent = self()

      query_fun = fn node, timeout ->
        send(parent, {:query, category, node, timeout})
        {:ok, %BinaryNode{tag: "iq", attrs: %{"type" => "result"}, content: nil}}
      end

      assert {:ok, %BinaryNode{tag: "iq", attrs: %{"type" => "result"}}} = fun.(query_fun, value)

      assert_receive {:query, ^category,
                      %BinaryNode{
                        tag: "iq",
                        attrs: %{"xmlns" => "privacy", "to" => "s.whatsapp.net", "type" => "set"},
                        content: [
                          %BinaryNode{
                            tag: "privacy",
                            attrs: %{},
                            content: [
                              %BinaryNode{
                                tag: "category",
                                attrs: %{"name" => ^category, "value" => ^expected_value},
                                content: nil
                              }
                            ]
                          }
                        ]
                      }, 60_000}
    end)
  end

  test "update_default_disappearing_mode/3 builds the disappearing-mode iq" do
    parent = self()

    query_fun = fn node, timeout ->
      send(parent, {:query, node, timeout})
      {:ok, %BinaryNode{tag: "iq", attrs: %{"type" => "result"}, content: nil}}
    end

    assert {:ok, %BinaryNode{tag: "iq", attrs: %{"type" => "result"}}} =
             Privacy.update_default_disappearing_mode(query_fun, 86_400)

    assert_receive {:query,
                    %BinaryNode{
                      tag: "iq",
                      attrs: %{
                        "xmlns" => "disappearing_mode",
                        "to" => "s.whatsapp.net",
                        "type" => "set"
                      },
                      content: [
                        %BinaryNode{
                          tag: "disappearing_mode",
                          attrs: %{"duration" => "86400"},
                          content: nil
                        }
                      ]
                    }, 60_000}
  end

  test "fetch_disappearing_duration/3 builds a USync disappearing-mode query and returns the parsed list" do
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
                     attrs: %{"jid" => "15551234567@s.whatsapp.net"},
                     content: [
                       %BinaryNode{
                         tag: "disappearing_mode",
                         attrs: %{"duration" => "86400", "t" => "1710000000"},
                         content: nil
                       }
                     ]
                   },
                   %BinaryNode{
                     tag: "user",
                     attrs: %{"jid" => "15557654321@g.us"},
                     content: [
                       %BinaryNode{
                         tag: "disappearing_mode",
                         attrs: %{"duration" => "0", "t" => "1710000123"},
                         content: nil
                       }
                     ]
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
              %{
                id: "15551234567@s.whatsapp.net",
                disappearing_mode: %{duration: 86_400, set_at: ~U[2024-03-09 16:00:00Z]}
              },
              %{
                id: "15557654321@g.us",
                disappearing_mode: %{duration: 0, set_at: ~U[2024-03-09 16:02:03Z]}
              }
            ]} =
             Privacy.fetch_disappearing_duration(
               query_fun,
               ["15551234567@s.whatsapp.net", "15557654321@g.us"],
               sid: "privacy-sid-1"
             )

    assert_receive {:query,
                    %BinaryNode{
                      tag: "iq",
                      attrs: %{"xmlns" => "usync", "to" => "s.whatsapp.net", "type" => "get"},
                      content: [
                        %BinaryNode{
                          tag: "usync",
                          attrs: %{
                            "context" => "interactive",
                            "mode" => "query",
                            "sid" => "privacy-sid-1",
                            "last" => "true",
                            "index" => "0"
                          },
                          content: [
                            %BinaryNode{
                              tag: "query",
                              content: [%BinaryNode{tag: "disappearing_mode", attrs: %{}}]
                            },
                            %BinaryNode{
                              tag: "list",
                              content: [
                                %BinaryNode{
                                  tag: "user",
                                  attrs: %{"jid" => "15551234567@s.whatsapp.net"}
                                },
                                %BinaryNode{
                                  tag: "user",
                                  attrs: %{"jid" => "15557654321@g.us"}
                                }
                              ]
                            }
                          ]
                        }
                      ]
                    }, 60_000}
  end

  test "fetch_blocklist/2 returns blocklist entries in server order and refreshes the store" do
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
             tag: "list",
             attrs: %{},
             content: [
               %BinaryNode{tag: "item", attrs: %{"jid" => "15551234567@s.whatsapp.net"}},
               %BinaryNode{tag: "item", attrs: %{"jid" => "15557654321@s.whatsapp.net"}}
             ]
           }
         ]
       }}
    end

    assert {:ok, ["15551234567@s.whatsapp.net", "15557654321@s.whatsapp.net"]} =
             Privacy.fetch_blocklist(query_fun, store: Store.wrap(store))

    assert_receive {:query,
                    %BinaryNode{
                      tag: "iq",
                      attrs: %{"xmlns" => "blocklist", "to" => "s.whatsapp.net", "type" => "get"},
                      content: nil
                    }, 60_000}

    assert Store.get(Store.wrap(store), :blocklist) == [
             "15551234567@s.whatsapp.net",
             "15557654321@s.whatsapp.net"
           ]
  end

  test "update_block_status/3 sends the exact blocklist item action" do
    parent = self()

    query_fun = fn node, timeout ->
      send(parent, {:query, node, timeout})
      {:ok, %BinaryNode{tag: "iq", attrs: %{"type" => "result"}, content: nil}}
    end

    assert {:ok, %BinaryNode{tag: "iq", attrs: %{"type" => "result"}}} =
             Privacy.update_block_status(query_fun, "15551234567@s.whatsapp.net", :block)

    assert_receive {:query,
                    %BinaryNode{
                      tag: "iq",
                      attrs: %{"xmlns" => "blocklist", "to" => "s.whatsapp.net", "type" => "set"},
                      content: [
                        %BinaryNode{
                          tag: "item",
                          attrs: %{"action" => "block", "jid" => "15551234567@s.whatsapp.net"},
                          content: nil
                        }
                      ]
                    }, 60_000}
  end

  test "update_disable_link_previews_privacy/2 uses the Baileys app-state patch path" do
    parent = self()

    push_fun = fn patch ->
      send(parent, {:patch, patch})
      {:ok, patch}
    end

    assert {:ok, %{index: ["setting_disableLinkPreviews"], type: :regular}} =
             Privacy.update_disable_link_previews_privacy(push_fun, true)

    assert_receive {:patch,
                    %{
                      sync_action: %{
                        privacy_setting_disable_link_previews_action: %{
                          is_previews_disabled: true
                        }
                      },
                      api_version: 8,
                      operation: :set
                    }}
  end

  test "fetch_settings propagates query errors across overloads and fetch_blocklist/2 does too" do
    assert {:error, :timeout} =
             Privacy.fetch_settings(fn _node, _timeout -> {:error, :timeout} end, true)

    assert {:error, :closed} =
             Privacy.fetch_blocklist(fn _node, _timeout -> {:error, :closed} end)
  end
end
