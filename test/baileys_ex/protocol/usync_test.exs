defmodule BaileysEx.Protocol.USyncTest do
  use ExUnit.Case, async: true

  alias BaileysEx.BinaryNode
  alias BaileysEx.Protocol.USync
  alias BaileysEx.Protocol.USync.User

  describe "to_node/2" do
    test "builds a Baileys-style usync iq node" do
      query =
        USync.new()
        |> USync.with_protocol(:devices)
        |> USync.with_protocol(:contact)
        |> USync.with_protocol(:lid)
        |> USync.with_protocol(:bot)
        |> USync.with_user(%User{phone: "+15551234567"})
        |> USync.with_user(%User{
          id: "15557654321@s.whatsapp.net",
          lid: "123456789@lid",
          persona_id: "persona-1"
        })

      assert {:ok,
              %BinaryNode{
                tag: "iq",
                attrs: %{"to" => "s.whatsapp.net", "type" => "get", "xmlns" => "usync"},
                content: [
                  %BinaryNode{
                    tag: "usync",
                    attrs: %{
                      "context" => "interactive",
                      "mode" => "query",
                      "sid" => "tag-1",
                      "last" => "true",
                      "index" => "0"
                    },
                    content: [
                      %BinaryNode{
                        tag: "query",
                        attrs: %{},
                        content: [
                          %BinaryNode{tag: "devices", attrs: %{"version" => "2"}},
                          %BinaryNode{tag: "contact", attrs: %{}},
                          %BinaryNode{tag: "lid", attrs: %{}},
                          %BinaryNode{
                            tag: "bot",
                            attrs: %{},
                            content: [
                              %BinaryNode{tag: "profile", attrs: %{"v" => "1"}}
                            ]
                          }
                        ]
                      },
                      %BinaryNode{
                        tag: "list",
                        attrs: %{},
                        content: [
                          %BinaryNode{
                            tag: "user",
                            attrs: %{},
                            content: [
                              %BinaryNode{tag: "contact", attrs: %{}, content: "+15551234567"}
                            ]
                          },
                          %BinaryNode{
                            tag: "user",
                            attrs: %{"jid" => "15557654321@s.whatsapp.net"},
                            content: [
                              %BinaryNode{tag: "lid", attrs: %{"jid" => "123456789@lid"}},
                              %BinaryNode{
                                tag: "bot",
                                attrs: %{},
                                content: [
                                  %BinaryNode{
                                    tag: "profile",
                                    attrs: %{"persona_id" => "persona-1"}
                                  }
                                ]
                              }
                            ]
                          }
                        ]
                      }
                    ]
                  }
                ]
              }} = USync.to_node(query, "tag-1")
    end

    test "returns an error when the query has no protocols" do
      query = USync.new() |> USync.with_user(%User{id: "15557654321@s.whatsapp.net"})

      assert {:error, {:missing_protocols, []}} = USync.to_node(query, "tag-1")
    end
  end

  describe "parse_result/2" do
    test "parses supported protocol results from the usync list and side_list" do
      query =
        USync.new()
        |> USync.with_protocol(:devices)
        |> USync.with_protocol(:contact)
        |> USync.with_protocol(:status)
        |> USync.with_protocol(:disappearing_mode)
        |> USync.with_protocol(:lid)
        |> USync.with_protocol(:bot)

      response = %BinaryNode{
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
                      %BinaryNode{tag: "contact", attrs: %{"type" => "in"}},
                      %BinaryNode{tag: "status", attrs: %{"t" => "1710000000"}, content: "busy"},
                      %BinaryNode{
                        tag: "disappearing_mode",
                        attrs: %{"duration" => "86400", "t" => "1710000001"}
                      },
                      %BinaryNode{
                        tag: "devices",
                        attrs: %{},
                        content: [
                          %BinaryNode{
                            tag: "device-list",
                            attrs: %{},
                            content: [
                              %BinaryNode{
                                tag: "device",
                                attrs: %{"id" => "0", "key-index" => "1"}
                              },
                              %BinaryNode{
                                tag: "device",
                                attrs: %{"id" => "2", "key-index" => "5", "is_hosted" => "true"}
                              }
                            ]
                          },
                          %BinaryNode{
                            tag: "key-index-list",
                            attrs: %{"ts" => "22", "expected_ts" => "23"},
                            content: {:binary, <<9, 8, 7>>}
                          }
                        ]
                      },
                      %BinaryNode{tag: "lid", attrs: %{"val" => "123456789@lid"}},
                      %BinaryNode{
                        tag: "bot",
                        attrs: %{},
                        content: [
                          %BinaryNode{
                            tag: "profile",
                            attrs: %{"persona_id" => "persona-1"},
                            content: [
                              %BinaryNode{tag: "name", attrs: %{}, content: "Helper"},
                              %BinaryNode{
                                tag: "attributes",
                                attrs: %{},
                                content: "friendly"
                              },
                              %BinaryNode{
                                tag: "description",
                                attrs: %{},
                                content: "Answers questions"
                              },
                              %BinaryNode{
                                tag: "category",
                                attrs: %{},
                                content: "assistant"
                              },
                              %BinaryNode{tag: "default", attrs: %{}, content: nil},
                              %BinaryNode{
                                tag: "prompts",
                                attrs: %{},
                                content: [
                                  %BinaryNode{
                                    tag: "prompt",
                                    attrs: %{},
                                    content: [
                                      %BinaryNode{tag: "emoji", attrs: %{}, content: "💡"},
                                      %BinaryNode{tag: "text", attrs: %{}, content: "Tips"}
                                    ]
                                  }
                                ]
                              },
                              %BinaryNode{
                                tag: "commands",
                                attrs: %{},
                                content: [
                                  %BinaryNode{
                                    tag: "description",
                                    attrs: %{},
                                    content: "Available commands"
                                  },
                                  %BinaryNode{
                                    tag: "command",
                                    attrs: %{},
                                    content: [
                                      %BinaryNode{tag: "name", attrs: %{}, content: "/help"},
                                      %BinaryNode{
                                        tag: "description",
                                        attrs: %{},
                                        content: "Show help"
                                      }
                                    ]
                                  }
                                ]
                              }
                            ]
                          }
                        ]
                      }
                    ]
                  }
                ]
              },
              %BinaryNode{
                tag: "side_list",
                attrs: %{},
                content: [
                  %BinaryNode{
                    tag: "user",
                    attrs: %{"jid" => "15559876543@s.whatsapp.net"},
                    content: [
                      %BinaryNode{tag: "contact", attrs: %{"type" => "in"}}
                    ]
                  }
                ]
              }
            ]
          }
        ]
      }

      assert {:ok,
              %{
                list: [
                  %{
                    id: "15551234567@s.whatsapp.net",
                    contact: true,
                    status: %{status: "busy", set_at: ~U[2024-03-09 16:00:00Z]},
                    disappearing_mode: %{duration: 86_400, set_at: ~U[2024-03-09 16:00:01Z]},
                    devices: %{
                      device_list: [
                        %{id: 0, key_index: 1, is_hosted: false},
                        %{id: 2, key_index: 5, is_hosted: true}
                      ],
                      key_index: %{
                        timestamp: 22,
                        signed_key_index: <<9, 8, 7>>,
                        expected_timestamp: 23
                      }
                    },
                    lid: "123456789@lid",
                    bot: %{
                      jid: "15551234567@s.whatsapp.net",
                      name: "Helper",
                      attributes: "friendly",
                      description: "Answers questions",
                      category: "assistant",
                      is_default: true,
                      prompts: ["💡 Tips"],
                      persona_id: "persona-1",
                      commands: [
                        %{name: "/help", description: "Show help"}
                      ],
                      commands_description: "Available commands"
                    }
                  }
                ],
                side_list: [
                  %{id: "15559876543@s.whatsapp.net", contact: true}
                ]
              }} = USync.parse_result(query, response)
    end

    test "defaults disappearing-mode timestamps to the unix epoch when t is absent" do
      query = USync.new() |> USync.with_protocol(:disappearing_mode)

      response = %BinaryNode{
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
                        attrs: %{"duration" => "86400"}
                      }
                    ]
                  }
                ]
              }
            ]
          }
        ]
      }

      assert {:ok,
              %{
                list: [
                  %{
                    id: "15551234567@s.whatsapp.net",
                    disappearing_mode: %{
                      duration: 86_400,
                      set_at: ~U[1970-01-01 00:00:00Z]
                    }
                  }
                ],
                side_list: []
              }} = USync.parse_result(query, response)
    end

    test "defaults status timestamps to the unix epoch when t is absent" do
      query = USync.new() |> USync.with_protocol(:status)

      response = %BinaryNode{
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
                      %BinaryNode{tag: "status", attrs: %{}, content: "busy"}
                    ]
                  }
                ]
              }
            ]
          }
        ]
      }

      assert {:ok,
              %{
                list: [
                  %{
                    id: "15551234567@s.whatsapp.net",
                    status: %{status: "busy", set_at: ~U[1970-01-01 00:00:00Z]}
                  }
                ],
                side_list: []
              }} = USync.parse_result(query, response)
    end

    test "surfaces user-level error nodes instead of silently swallowing them" do
      query = USync.new() |> USync.with_protocol(:contact)

      response = %BinaryNode{
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
                      %BinaryNode{tag: "contact", attrs: %{}, content: nil},
                      %BinaryNode{
                        tag: "error",
                        attrs: %{"code" => "500", "text" => "server-error"}
                      }
                    ]
                  }
                ]
              }
            ]
          }
        ]
      }

      assert {:error,
              {:protocol_error,
               %{code: 500, text: "server-error", node: %BinaryNode{tag: "error"}},
               "15551234567@s.whatsapp.net"}} = USync.parse_result(query, response)
    end
  end
end
