defmodule BaileysEx.Feature.GroupTest do
  use ExUnit.Case, async: true

  alias BaileysEx.BinaryNode
  alias BaileysEx.Feature.Group
  alias BaileysEx.Signal.Repository
  alias BaileysEx.TestHelpers.MessageSignalHelpers

  test "create/3 builds the group create IQ and parses metadata" do
    parent = self()

    query_fun = fn node, timeout ->
      send(parent, {:query, node, timeout})
      {:ok, group_result_node("1234567890")}
    end

    assert {:ok, metadata} =
             Group.create(query_fun, "Phase 10", [
               "15550001111@s.whatsapp.net",
               "15550002222@s.whatsapp.net"
             ])

    assert metadata.id == "1234567890@g.us"
    assert metadata.subject == "Phase 10"
    assert metadata.announce == false
    assert metadata.restrict == false

    assert [%{id: "15550001111@s.whatsapp.net"}, %{id: "15550002222@s.whatsapp.net"}] =
             metadata.participants

    assert_receive {:query,
                    %BinaryNode{
                      tag: "iq",
                      attrs: %{"to" => "@g.us", "type" => "set", "xmlns" => "w:g2"},
                      content: [
                        %BinaryNode{
                          tag: "create",
                          attrs: %{"subject" => "Phase 10", "key" => key},
                          content: [
                            %BinaryNode{
                              tag: "participant",
                              attrs: %{"jid" => "15550001111@s.whatsapp.net"}
                            },
                            %BinaryNode{
                              tag: "participant",
                              attrs: %{"jid" => "15550002222@s.whatsapp.net"}
                            }
                          ]
                        }
                      ]
                    }, 60_000}

    assert is_binary(key)
    assert key != ""
  end

  test "participant and join-request operations mirror groups.ts node shapes" do
    parent = self()

    query_fun = fn node, timeout ->
      send(parent, {:query, node, timeout})

      response =
        case node.content do
          [%BinaryNode{tag: "membership_approval_requests"}] ->
            %BinaryNode{
              tag: "iq",
              attrs: %{"type" => "result"},
              content: [
                %BinaryNode{
                  tag: "membership_approval_requests",
                  attrs: %{},
                  content: [
                    %BinaryNode{
                      tag: "membership_approval_request",
                      attrs: %{"jid" => "15550001111@s.whatsapp.net", "t" => "1710000000"}
                    }
                  ]
                }
              ]
            }

          [%BinaryNode{tag: "membership_requests_action", content: [%BinaryNode{tag: "approve"}]}] ->
            %BinaryNode{
              tag: "iq",
              attrs: %{"type" => "result"},
              content: [
                %BinaryNode{
                  tag: "membership_requests_action",
                  attrs: %{},
                  content: [
                    %BinaryNode{
                      tag: "approve",
                      attrs: %{},
                      content: [
                        %BinaryNode{
                          tag: "participant",
                          attrs: %{"jid" => "15550001111@s.whatsapp.net"}
                        }
                      ]
                    }
                  ]
                }
              ]
            }

          [%BinaryNode{tag: action}] when action in ["add", "remove", "promote", "demote"] ->
            %BinaryNode{
              tag: "iq",
              attrs: %{"type" => "result"},
              content: [
                %BinaryNode{
                  tag: action,
                  attrs: %{},
                  content: [
                    %BinaryNode{
                      tag: "participant",
                      attrs: %{"jid" => "15550001111@s.whatsapp.net"}
                    }
                  ]
                }
              ]
            }
        end

      {:ok, response}
    end

    assert {:ok, [%{"jid" => "15550001111@s.whatsapp.net", "t" => "1710000000"}]} =
             Group.request_participants_list(query_fun, "1234567890@g.us")

    assert {:ok, [%{jid: "15550001111@s.whatsapp.net", status: "200"}]} =
             Group.request_participants_update(
               query_fun,
               "1234567890@g.us",
               ["15550001111@s.whatsapp.net"],
               :approve
             )

    assert {:ok, [%{jid: "15550001111@s.whatsapp.net", status: "200"}]} =
             Group.add_participants(query_fun, "1234567890@g.us", ["15550001111@s.whatsapp.net"])

    assert {:ok, [%{jid: "15550001111@s.whatsapp.net", status: "200"}]} =
             Group.remove_participants(query_fun, "1234567890@g.us", [
               "15550001111@s.whatsapp.net"
             ])

    assert {:ok, [%{jid: "15550001111@s.whatsapp.net", status: "200"}]} =
             Group.promote_participants(query_fun, "1234567890@g.us", [
               "15550001111@s.whatsapp.net"
             ])

    assert {:ok, [%{jid: "15550001111@s.whatsapp.net", status: "200"}]} =
             Group.demote_participants(query_fun, "1234567890@g.us", [
               "15550001111@s.whatsapp.net"
             ])

    assert_receive {:query,
                    %BinaryNode{
                      attrs: %{"to" => "1234567890@g.us", "type" => "get", "xmlns" => "w:g2"},
                      content: [%BinaryNode{tag: "membership_approval_requests"}]
                    }, 60_000}

    assert_receive {:query,
                    %BinaryNode{
                      attrs: %{"to" => "1234567890@g.us", "type" => "set", "xmlns" => "w:g2"},
                      content: [
                        %BinaryNode{
                          tag: "membership_requests_action",
                          content: [
                            %BinaryNode{
                              tag: "approve",
                              content: [
                                %BinaryNode{
                                  tag: "participant",
                                  attrs: %{"jid" => "15550001111@s.whatsapp.net"}
                                }
                              ]
                            }
                          ]
                        }
                      ]
                    }, 60_000}

    assert_receive {:query,
                    %BinaryNode{
                      attrs: %{"to" => "1234567890@g.us", "type" => "set", "xmlns" => "w:g2"},
                      content: [
                        %BinaryNode{
                          tag: "add",
                          attrs: %{},
                          content: [
                            %BinaryNode{
                              tag: "participant",
                              attrs: %{"jid" => "15550001111@s.whatsapp.net"}
                            }
                          ]
                        }
                      ]
                    }, 60_000}

    assert_receive {:query,
                    %BinaryNode{
                      attrs: %{"to" => "1234567890@g.us", "type" => "set", "xmlns" => "w:g2"},
                      content: [
                        %BinaryNode{
                          tag: "remove",
                          attrs: %{},
                          content: [
                            %BinaryNode{
                              tag: "participant",
                              attrs: %{"jid" => "15550001111@s.whatsapp.net"}
                            }
                          ]
                        }
                      ]
                    }, 60_000}

    assert_receive {:query,
                    %BinaryNode{
                      attrs: %{"to" => "1234567890@g.us", "type" => "set", "xmlns" => "w:g2"},
                      content: [
                        %BinaryNode{
                          tag: "promote",
                          attrs: %{},
                          content: [
                            %BinaryNode{
                              tag: "participant",
                              attrs: %{"jid" => "15550001111@s.whatsapp.net"}
                            }
                          ]
                        }
                      ]
                    }, 60_000}

    assert_receive {:query,
                    %BinaryNode{
                      attrs: %{"to" => "1234567890@g.us", "type" => "set", "xmlns" => "w:g2"},
                      content: [
                        %BinaryNode{
                          tag: "demote",
                          attrs: %{},
                          content: [
                            %BinaryNode{
                              tag: "participant",
                              attrs: %{"jid" => "15550001111@s.whatsapp.net"}
                            }
                          ]
                        }
                      ]
                    }, 60_000}
  end

  test "invite, metadata, settings, ephemeral, and participating queries match Baileys shapes" do
    parent = self()

    query_fun = fn node, timeout ->
      send(parent, {:query, node, timeout})

      response =
        case node.content do
          [%BinaryNode{tag: "invite", attrs: %{"code" => "ABCD"}}] ->
            %BinaryNode{
              tag: "iq",
              attrs: %{"type" => "result"},
              content: [%BinaryNode{tag: "group", attrs: %{"jid" => "1234567890@g.us"}}]
            }

          [%BinaryNode{tag: "invite"}] ->
            if node.attrs["type"] == "get" do
              %BinaryNode{
                tag: "iq",
                attrs: %{"type" => "result"},
                content: [%BinaryNode{tag: "invite", attrs: %{"code" => "WXYZ"}}]
              }
            else
              %BinaryNode{
                tag: "iq",
                attrs: %{"type" => "result"},
                content: [%BinaryNode{tag: "invite", attrs: %{"code" => "RSTU"}}]
              }
            end

          [%BinaryNode{tag: "participating"}] ->
            {:ok, participating_result_node()}

          _ ->
            {:ok, group_result_node("1234567890")}
        end

      case response do
        {:ok, %BinaryNode{} = result} -> {:ok, result}
        %BinaryNode{} = result -> {:ok, result}
      end
    end

    assert {:ok, "WXYZ"} = Group.invite_code(query_fun, "1234567890@g.us")
    assert {:ok, "RSTU"} = Group.revoke_invite(query_fun, "1234567890@g.us")
    assert {:ok, "1234567890@g.us"} = Group.accept_invite(query_fun, "ABCD")
    assert {:ok, metadata} = Group.get_metadata(query_fun, "1234567890@g.us")
    assert metadata.id == "1234567890@g.us"

    assert {:ok, participating} = Group.fetch_all_participating(query_fun)
    assert Map.keys(participating) == ["1234567890@g.us"]

    assert :ok = Group.update_subject(query_fun, "1234567890@g.us", "Updated")
    assert :ok = Group.update_description(query_fun, "1234567890@g.us", "Body")
    assert :ok = Group.update_description(query_fun, "1234567890@g.us", nil)
    assert :ok = Group.leave(query_fun, "1234567890@g.us")
    assert :ok = Group.toggle_ephemeral(query_fun, "1234567890@g.us", 86_400)
    assert :ok = Group.toggle_ephemeral(query_fun, "1234567890@g.us", 0)
    assert :ok = Group.setting_update(query_fun, "1234567890@g.us", :announcement)
    assert :ok = Group.member_add_mode(query_fun, "1234567890@g.us", :all_member_add)
    assert :ok = Group.join_approval_mode(query_fun, "1234567890@g.us", :on)

    assert {:ok, "1234567890@g.us"} =
             Group.accept_invite_v4(
               query_fun,
               %{id: "invite-msg-1", remote_jid: "15550001111@s.whatsapp.net"},
               %{
                 group_jid: "1234567890@g.us",
                 invite_code: "CODE",
                 invite_expiration: 1_710_000_000
               },
               me: %{id: "15550003333@s.whatsapp.net", name: "~"},
               message_id_fun: fn -> "stub-msg-1" end,
               timestamp_fun: fn -> 1_710_222_333 end,
               message_update_fun: &send(parent, {:messages_update, &1}),
               upsert_message_fun: &send(parent, {:messages_upsert, &1})
             )

    assert_receive {:messages_update,
                    [
                      %{
                        key: %{id: "invite-msg-1", remote_jid: "15550001111@s.whatsapp.net"},
                        update: %{
                          message: %{
                            group_invite_message: %{
                              invite_code: "",
                              invite_expiration: 0
                            }
                          }
                        }
                      }
                    ]}

    assert_receive {:messages_upsert,
                    %{
                      key: %{
                        id: "stub-msg-1",
                        participant: "15550001111@s.whatsapp.net",
                        remote_jid: "1234567890@g.us"
                      },
                      message_stub_type: :GROUP_PARTICIPANT_ADD,
                      message_timestamp: 1_710_222_333
                    }}

    assert :ok =
             Group.revoke_invite_v4(query_fun, "1234567890@g.us", "15550001111@s.whatsapp.net")
  end

  test "group helpers propagate query errors" do
    assert {:error, :timeout} =
             Group.get_metadata(fn _node, _timeout -> {:error, :timeout} end, "1234567890@g.us")
  end

  test "extract_group_metadata/1 normalizes owners, preserves explicit zero size, and filters PN/LID fields like Baileys" do
    result =
      %BinaryNode{
        tag: "iq",
        attrs: %{"type" => "result"},
        content: [
          %BinaryNode{
            tag: "group",
            attrs: %{
              "id" => "1234567890",
              "subject" => "Phase 10",
              "addressing_mode" => "lid",
              "s_t" => "1710000000",
              "size" => "0",
              "creation" => "1709999999",
              "creator" => "15550001111:2@c.us",
              "creator_pn" => "15550002222:9@c.us",
              "creator_country_code" => "1"
            },
            content: [
              %BinaryNode{
                tag: "participant",
                attrs: %{
                  "jid" => "abc123@lid",
                  "phone_number" => "15550001111@s.whatsapp.net",
                  "lid" => "ignored@lid",
                  "type" => "admin"
                }
              },
              %BinaryNode{
                tag: "participant",
                attrs: %{
                  "jid" => "15550002222@s.whatsapp.net",
                  "phone_number" => "15550002222@s.whatsapp.net",
                  "lid" => "abc222@lid"
                }
              },
              %BinaryNode{
                tag: "participant",
                attrs: %{
                  "jid" => "abc333@lid",
                  "phone_number" => "not-a-pn",
                  "lid" => "abc333@lid"
                }
              },
              %BinaryNode{
                tag: "participant",
                attrs: %{
                  "jid" => "15550004444@s.whatsapp.net",
                  "phone_number" => "15550004444@s.whatsapp.net",
                  "lid" => "not-a-lid"
                }
              }
            ]
          }
        ]
      }

    metadata = Group.extract_group_metadata(result)

    assert metadata.owner == "15550001111@s.whatsapp.net"
    assert metadata.owner_pn == "15550002222@s.whatsapp.net"
    assert metadata.owner_country_code == "1"
    assert metadata.addressing_mode == :lid
    assert metadata.size == 0

    assert [
             %{
               id: "abc123@lid",
               phone_number: "15550001111@s.whatsapp.net",
               lid: nil,
               admin: "admin"
             },
             %{
               id: "15550002222@s.whatsapp.net",
               phone_number: nil,
               lid: "abc222@lid",
               admin: nil
             },
             %{
               id: "abc333@lid",
               phone_number: nil,
               lid: nil,
               admin: nil
             },
             %{
               id: "15550004444@s.whatsapp.net",
               phone_number: nil,
               lid: nil,
               admin: nil
             }
           ] = metadata.participants
  end

  test "create/4 accepts an injected message id and update_description/4 reuses it for deterministic attrs" do
    parent = self()

    query_fun = fn node, timeout ->
      send(parent, {:query, node, timeout})
      {:ok, group_result_node("1234567890")}
    end

    assert {:ok, _metadata} =
             Group.create(query_fun, "Phase 10", ["15550001111@s.whatsapp.net"],
               message_id_fun: fn -> "stub-create-id" end
             )

    assert_receive {:query,
                    %BinaryNode{
                      content: [
                        %BinaryNode{
                          tag: "create",
                          attrs: %{"subject" => "Phase 10", "key" => "stub-create-id"}
                        }
                      ]
                    }, 60_000}

    assert :ok =
             Group.update_description(query_fun, "1234567890@g.us", "Body",
               message_id_fun: fn -> "stub-description-id" end
             )

    assert_receive {:query,
                    %BinaryNode{
                      content: [
                        %BinaryNode{
                          tag: "query",
                          attrs: %{"request" => "interactive"}
                        }
                      ]
                    }, 60_000}

    assert_receive {:query,
                    %BinaryNode{
                      content: [
                        %BinaryNode{
                          tag: "description",
                          attrs: %{"id" => "stub-description-id"}
                        }
                      ]
                    }, 60_000}
  end

  test "handle_dirty_update/3 sends a Baileys-style dirty clean IQ with id and optional timestamp" do
    parent = self()

    query_fun = fn node, timeout ->
      send(parent, {:query, node, timeout})
      {:ok, participating_result_node()}
    end

    sendable = fn node ->
      send(parent, {:send_node, node})
      :ok
    end

    assert {:ok, _groups} =
             Group.handle_dirty_update(query_fun, %{type: "groups", timestamp: 1_710_000_000},
               sendable: sendable,
               message_tag_fun: fn -> "dirty-id-1" end
             )

    assert_receive {:send_node,
                    %BinaryNode{
                      tag: "iq",
                      attrs: %{
                        "to" => "s.whatsapp.net",
                        "type" => "set",
                        "xmlns" => "urn:xmpp:whatsapp:dirty",
                        "id" => "dirty-id-1"
                      },
                      content: [
                        %BinaryNode{
                          tag: "clean",
                          attrs: %{"type" => "groups", "timestamp" => "1710000000"}
                        }
                      ]
                    }}
  end

  test "update_member_label/4 relays a group protocol message with member-tag metadata" do
    parent = self()
    {repo, store} = MessageSignalHelpers.new_repo()
    session = MessageSignalHelpers.session_fixture()

    assert {:ok, repo} =
             Repository.inject_e2e_session(repo, %{
               jid: "15551234567:0@s.whatsapp.net",
               session: session
             })

    context = %{
      signal_repository: repo,
      signal_store: store,
      me_id: "15550001111@s.whatsapp.net",
      send_node_fun: fn node ->
        send(parent, {:relay_node, node})
        :ok
      end,
      device_lookup_fun: fn context, jids, _opts ->
        send(parent, {:device_lookup, jids})
        {:ok, %{signal_repository: context.signal_repository}, ["15551234567:0@s.whatsapp.net"]}
      end
    }

    assert {:ok,
            %{
              id: "3EB0LABELID",
              timestamp: 1_710_444_555_000,
              message: %{
                protocol_message: %{
                  type: :GROUP_MEMBER_LABEL_CHANGE,
                  member_label: %{
                    label: "vip-member-label-that-is-defin",
                    label_timestamp: 1_710_444_555
                  }
                }
              }
            }, %{signal_repository: %Repository{}}} =
             Group.update_member_label(
               context,
               "120363001234567890@g.us",
               "vip-member-label-that-is-definitely-longer-than-thirty",
               group_participants: ["15551234567@s.whatsapp.net"],
               message_id_fun: fn _me_id -> "3EB0LABELID" end,
               timestamp_fun: fn -> 1_710_444_555_000 end,
               label_timestamp_fun: fn -> 1_710_444_555 end
             )

    assert_receive {:device_lookup, ["15551234567@s.whatsapp.net"]}

    assert_receive {:relay_node,
                    %BinaryNode{
                      tag: "message",
                      attrs: %{
                        "to" => "120363001234567890@g.us",
                        "type" => "protocol",
                        "id" => "3EB0LABELID"
                      },
                      content: content
                    }}

    assert Enum.any?(
             content,
             &match?(
               %BinaryNode{
                 tag: "meta",
                 attrs: %{"tag_reason" => "user_update", "appdata" => "member_tag"}
               },
               &1
             )
           )

    assert Enum.any?(content, &match?(%BinaryNode{tag: "enc", attrs: %{"type" => "skmsg"}}, &1))
    assert Enum.any?(content, &match?(%BinaryNode{tag: "participants"}, &1))
  end

  test "update_member_label/4 rejects invalid group JIDs" do
    assert {:error, :invalid_group_jid} =
             Group.update_member_label(%{}, "not-a-group", "vip")
  end

  defp participating_result_node do
    %BinaryNode{
      tag: "iq",
      attrs: %{"type" => "result"},
      content: [
        %BinaryNode{
          tag: "groups",
          attrs: %{},
          content: [
            group_result_node("1234567890").content |> List.first()
          ]
        }
      ]
    }
  end

  defp group_result_node(id) do
    %BinaryNode{
      tag: "iq",
      attrs: %{"type" => "result"},
      content: [
        %BinaryNode{
          tag: "group",
          attrs: %{
            "id" => id,
            "subject" => "Phase 10",
            "s_t" => "1710000000",
            "size" => "2",
            "creation" => "1709999999"
          },
          content: [
            %BinaryNode{tag: "participant", attrs: %{"jid" => "15550001111@s.whatsapp.net"}},
            %BinaryNode{tag: "participant", attrs: %{"jid" => "15550002222@s.whatsapp.net"}}
          ]
        }
      ]
    }
  end
end
