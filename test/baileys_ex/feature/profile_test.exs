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

  test "update_picture/5 generates picture bytes and omits target for self updates" do
    parent = self()

    picture_generator = fn image_data, dimensions ->
      send(parent, {:picture_generator, image_data, dimensions})
      {:ok, %{img: "<<jpeg-binary>>"}}
    end

    query_fun = fn node, timeout ->
      send(parent, {:query, node, timeout})
      {:ok, %BinaryNode{tag: "iq", attrs: %{"type" => "result"}, content: nil}}
    end

    assert {:ok, %BinaryNode{tag: "iq", attrs: %{"type" => "result"}}} =
             Profile.update_picture(
               query_fun,
               "15551234567@s.whatsapp.net",
               "<<source-image>>",
               %{width: 96, height: 96},
               me: %{id: "15551234567@s.whatsapp.net"},
               picture_generator: picture_generator,
               query_timeout: 4_321
             )

    assert_receive {:picture_generator, "<<source-image>>", %{width: 96, height: 96}}

    assert_receive {:query,
                    %BinaryNode{
                      tag: "iq",
                      attrs: %{
                        "to" => "s.whatsapp.net",
                        "type" => "set",
                        "xmlns" => "w:profile:picture"
                      },
                      content: [
                        %BinaryNode{
                          tag: "picture",
                          attrs: %{"type" => "image"},
                          content: "<<jpeg-binary>>"
                        }
                      ]
                    }, 4_321}
  end

  test "update_picture/5 rejects a missing jid before generating image bytes" do
    assert {:error, :missing_jid} =
             Profile.update_picture(
               fn _node, _timeout -> flunk("query should not run when jid is missing") end,
               "",
               "<<source-image>>",
               nil,
               picture_generator: fn _image, _dimensions ->
                 flunk("picture generator should not run when jid is missing")
               end
             )
  end

  test "remove_picture/3 targets other users and groups with an empty set IQ" do
    parent = self()

    query_fun = fn node, timeout ->
      send(parent, {:query, node, timeout})
      {:ok, %BinaryNode{tag: "iq", attrs: %{"type" => "result"}, content: nil}}
    end

    assert {:ok, %BinaryNode{tag: "iq", attrs: %{"type" => "result"}}} =
             Profile.remove_picture(query_fun, "120363001234567890@g.us", query_timeout: 777)

    assert_receive {:query,
                    %BinaryNode{
                      tag: "iq",
                      attrs: %{
                        "target" => "120363001234567890@g.us",
                        "to" => "s.whatsapp.net",
                        "type" => "set",
                        "xmlns" => "w:profile:picture"
                      },
                      content: nil
                    }, 777}
  end

  test "remove_picture/3 rejects a missing jid" do
    assert {:error, :missing_jid} =
             Profile.remove_picture(
               fn _node, _timeout -> flunk("query should not run when jid is missing") end,
               ""
             )
  end

  test "update_name/2 maps to the Baileys pushName app-state patch" do
    parent = self()

    push_fun = fn patch ->
      send(parent, {:patch, patch})
      {:ok, patch}
    end

    assert {:ok, %{index: ["setting_pushName"], type: :critical_block, operation: :set}} =
             Profile.update_name(push_fun, "Ada Lovelace")

    assert_receive {:patch,
                    %{
                      sync_action: %{push_name_setting: %{name: "Ada Lovelace"}, timestamp: ts},
                      api_version: 1
                    }}

    assert is_integer(ts)
  end

  test "update_status/3 sends the Baileys status IQ with UTF-8 content" do
    parent = self()

    query_fun = fn node, timeout ->
      send(parent, {:query, node, timeout})
      {:ok, %BinaryNode{tag: "iq", attrs: %{"type" => "result"}, content: nil}}
    end

    assert {:ok, %BinaryNode{tag: "iq", attrs: %{"type" => "result"}}} =
             Profile.update_status(query_fun, "On call", query_timeout: 654)

    assert_receive {:query,
                    %BinaryNode{
                      tag: "iq",
                      attrs: %{
                        "to" => "s.whatsapp.net",
                        "type" => "set",
                        "xmlns" => "status"
                      },
                      content: [
                        %BinaryNode{tag: "status", attrs: %{}, content: "On call"}
                      ]
                    }, 654}
  end

  test "fetch_status/3 builds a USync status query and parses the result" do
    parent = self()
    set_at = DateTime.from_unix!(1_710_000_000)

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
                         tag: "status",
                         attrs: %{"t" => "1710000000"},
                         content: "Busy"
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
            [%{id: "15551234567@s.whatsapp.net", status: %{status: "Busy", set_at: ^set_at}}]} =
             Profile.fetch_status(query_fun, ["15551234567@s.whatsapp.net"],
               query_timeout: 543,
               sid: "status-sid"
             )

    assert_receive {:query,
                    %BinaryNode{
                      tag: "iq",
                      attrs: %{"to" => "s.whatsapp.net", "type" => "get", "xmlns" => "usync"},
                      content: [
                        %BinaryNode{
                          tag: "usync",
                          attrs: %{
                            "context" => "interactive",
                            "mode" => "query",
                            "sid" => "status-sid",
                            "last" => "true",
                            "index" => "0"
                          },
                          content: [
                            %BinaryNode{
                              tag: "query",
                              attrs: %{},
                              content: [%BinaryNode{tag: "status", attrs: %{}, content: nil}]
                            },
                            %BinaryNode{
                              tag: "list",
                              attrs: %{},
                              content: [
                                %BinaryNode{
                                  tag: "user",
                                  attrs: %{"jid" => "15551234567@s.whatsapp.net"},
                                  content: []
                                }
                              ]
                            }
                          ]
                        }
                      ]
                    }, 543}
  end

  test "get_business_profile/3 parses the Baileys business profile shape" do
    parent = self()

    query_fun = fn node, timeout ->
      send(parent, {:query, node, timeout})

      {:ok,
       %BinaryNode{
         tag: "iq",
         attrs: %{"type" => "result"},
         content: [
           %BinaryNode{
             tag: "business_profile",
             attrs: %{},
             content: [
               %BinaryNode{
                 tag: "profile",
                 attrs: %{"jid" => "15551234567@s.whatsapp.net"},
                 content: [
                   %BinaryNode{tag: "address", attrs: %{}, content: "123 Main Street"},
                   %BinaryNode{tag: "description", attrs: %{}, content: "Bakery"},
                   %BinaryNode{tag: "website", attrs: %{}, content: "https://example.test"},
                   %BinaryNode{tag: "email", attrs: %{}, content: "hello@example.test"},
                   %BinaryNode{
                     tag: "categories",
                     attrs: %{},
                     content: [%BinaryNode{tag: "category", attrs: %{}, content: "Food"}]
                   },
                   %BinaryNode{
                     tag: "business_hours",
                     attrs: %{"timezone" => "America/Los_Angeles"},
                     content: [
                       %BinaryNode{
                         tag: "business_hours_config",
                         attrs: %{"day_of_week" => "1", "mode" => "open"},
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
            %{
              wid: "15551234567@s.whatsapp.net",
              address: "123 Main Street",
              description: "Bakery",
              website: ["https://example.test"],
              email: "hello@example.test",
              category: "Food",
              business_hours: %{
                timezone: "America/Los_Angeles",
                business_config: [%{"day_of_week" => "1", "mode" => "open"}]
              }
            }} =
             Profile.get_business_profile(query_fun, "15551234567@s.whatsapp.net",
               query_timeout: 765
             )

    assert_receive {:query,
                    %BinaryNode{
                      tag: "iq",
                      attrs: %{
                        "to" => "s.whatsapp.net",
                        "xmlns" => "w:biz",
                        "type" => "get"
                      },
                      content: [
                        %BinaryNode{
                          tag: "business_profile",
                          attrs: %{"v" => "244"},
                          content: [
                            %BinaryNode{
                              tag: "profile",
                              attrs: %{"jid" => "15551234567@s.whatsapp.net"},
                              content: nil
                            }
                          ]
                        }
                      ]
                    }, 765}
  end
end
