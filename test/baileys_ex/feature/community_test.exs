defmodule BaileysEx.Feature.CommunityTest do
  use ExUnit.Case, async: true

  alias BaileysEx.BinaryNode
  alias BaileysEx.Feature.Community

  test "create and create_group build the Baileys community create queries and fetch created metadata" do
    parent = self()

    query_fun = fn node, timeout ->
      send(parent, {:query, node, timeout})

      response =
        case {node.attrs["to"], node.content} do
          {"@g.us", [%BinaryNode{tag: "create", content: content}]} ->
            if Enum.any?(content, &match?(%BinaryNode{tag: "linked_parent"}, &1)) do
              {:ok, created_group_result_node("2233445566")}
            else
              {:ok, created_group_result_node("1234567890")}
            end

          {"1234567890@g.us", [%BinaryNode{tag: "query", attrs: %{"request" => "interactive"}}]} ->
            {:ok, group_result_node("1234567890", "Phase 11 Community")}

          {"2233445566@g.us", [%BinaryNode{tag: "query", attrs: %{"request" => "interactive"}}]} ->
            {:ok,
             group_result_node("2233445566", "Phase 11 General", linked_parent: "1234567890@g.us")}
        end

      response
    end

    assert {:ok, metadata} =
             Community.create(query_fun, "Phase 11 Community", "Launch description",
               message_id_fun: fn -> "DESCID1234567890" end
             )

    assert metadata.id == "1234567890@g.us"
    assert metadata.subject == "Phase 11 Community"

    assert {:ok, subgroup_metadata} =
             Community.create_group(
               query_fun,
               "Phase 11 General",
               ["15550001111@s.whatsapp.net"],
               "1234567890@g.us",
               message_id_fun: fn -> "sub-group-key-1" end
             )

    assert subgroup_metadata.id == "2233445566@g.us"
    assert subgroup_metadata.linked_parent == "1234567890@g.us"

    assert_receive {:query,
                    %BinaryNode{
                      tag: "iq",
                      attrs: %{"to" => "@g.us", "type" => "set", "xmlns" => "w:g2"},
                      content: [
                        %BinaryNode{
                          tag: "create",
                          attrs: %{"subject" => "Phase 11 Community"},
                          content: [
                            %BinaryNode{
                              tag: "description",
                              attrs: %{"id" => "DESCID123456"},
                              content: [
                                %BinaryNode{
                                  tag: "body",
                                  attrs: %{},
                                  content: "Launch description"
                                }
                              ]
                            },
                            %BinaryNode{
                              tag: "parent",
                              attrs: %{
                                "default_membership_approval_mode" => "request_required"
                              }
                            },
                            %BinaryNode{tag: "allow_non_admin_sub_group_creation", attrs: %{}},
                            %BinaryNode{tag: "create_general_chat", attrs: %{}}
                          ]
                        }
                      ]
                    }, 60_000}

    assert_receive {:query,
                    %BinaryNode{
                      tag: "iq",
                      attrs: %{"to" => "1234567890@g.us", "type" => "get", "xmlns" => "w:g2"},
                      content: [
                        %BinaryNode{
                          tag: "query",
                          attrs: %{"request" => "interactive"}
                        }
                      ]
                    }, 60_000}

    assert_receive {:query,
                    %BinaryNode{
                      tag: "iq",
                      attrs: %{"to" => "@g.us", "type" => "set", "xmlns" => "w:g2"},
                      content: [
                        %BinaryNode{
                          tag: "create",
                          attrs: %{"subject" => "Phase 11 General", "key" => "sub-group-key-1"},
                          content: [
                            %BinaryNode{
                              tag: "participant",
                              attrs: %{"jid" => "15550001111@s.whatsapp.net"}
                            },
                            %BinaryNode{
                              tag: "linked_parent",
                              attrs: %{"jid" => "1234567890@g.us"}
                            }
                          ]
                        }
                      ]
                    }, 60_000}

    assert_receive {:query,
                    %BinaryNode{
                      tag: "iq",
                      attrs: %{"to" => "2233445566@g.us", "type" => "get", "xmlns" => "w:g2"},
                      content: [
                        %BinaryNode{
                          tag: "query",
                          attrs: %{"request" => "interactive"}
                        }
                      ]
                    }, 60_000}
  end

  test "linked-group helpers match communities.ts and auto-detect subgroup parents" do
    parent = self()

    query_fun = fn node, timeout ->
      send(parent, {:query, node, timeout})

      case {node.attrs["to"], node.attrs["type"], node.content} do
        {"1234567890@g.us", "set", [%BinaryNode{tag: "links"}]} ->
          {:ok, %BinaryNode{tag: "iq", attrs: %{"type" => "result"}, content: nil}}

        {"1234567890@g.us", "set", [%BinaryNode{tag: "unlink"}]} ->
          {:ok, %BinaryNode{tag: "iq", attrs: %{"type" => "result"}, content: nil}}

        {"2233445566@g.us", "get",
         [%BinaryNode{tag: "query", attrs: %{"request" => "interactive"}}]} ->
          {:ok,
           group_result_node("2233445566", "Phase 11 General", linked_parent: "1234567890@g.us")}

        {"1234567890@g.us", "get", [%BinaryNode{tag: "sub_groups"}]} ->
          {:ok, sub_groups_result_node()}

        {"1234567890@g.us", "get",
         [%BinaryNode{tag: "query", attrs: %{"request" => "interactive"}}]} ->
          {:ok, group_result_node("1234567890", "Phase 11 Community")}
      end
    end

    assert :ok = Community.link_group(query_fun, "2233445566@g.us", "1234567890@g.us")
    assert :ok = Community.unlink_group(query_fun, "2233445566@g.us", "1234567890@g.us")

    assert {:ok,
            %{
              community_jid: "1234567890@g.us",
              is_community: false,
              linked_groups: [
                %{
                  id: "2233445566@g.us",
                  subject: "Phase 11 General",
                  creation: 1_710_000_100,
                  owner: "15550001111@s.whatsapp.net",
                  size: 33
                }
              ]
            }} = Community.fetch_linked_groups(query_fun, "2233445566@g.us")

    assert {:ok, %{community_jid: "1234567890@g.us", is_community: true, linked_groups: [_]}} =
             Community.fetch_linked_groups(query_fun, "1234567890@g.us")

    assert_receive {:query,
                    %BinaryNode{
                      attrs: %{"to" => "1234567890@g.us", "type" => "set", "xmlns" => "w:g2"},
                      content: [
                        %BinaryNode{
                          tag: "links",
                          attrs: %{},
                          content: [
                            %BinaryNode{
                              tag: "link",
                              attrs: %{"link_type" => "sub_group"},
                              content: [
                                %BinaryNode{
                                  tag: "group",
                                  attrs: %{"jid" => "2233445566@g.us"}
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
                          tag: "unlink",
                          attrs: %{"unlink_type" => "sub_group"},
                          content: [
                            %BinaryNode{
                              tag: "group",
                              attrs: %{"jid" => "2233445566@g.us"}
                            }
                          ]
                        }
                      ]
                    }, 60_000}
  end

  test "participant, invite, metadata, settings, and dirty update flows match Baileys community nodes" do
    parent = self()

    query_fun = fn node, timeout ->
      send(parent, {:query, node, timeout})

      response =
        case {node.attrs["to"], node.attrs["type"], node.content} do
          {"1234567890@g.us", "get", [%BinaryNode{tag: "membership_approval_requests"}]} ->
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

          {"1234567890@g.us", "set",
           [%BinaryNode{tag: "membership_requests_action", content: [%BinaryNode{tag: "reject"}]}]} ->
            %BinaryNode{
              tag: "iq",
              attrs: %{"type" => "result"},
              content: [
                %BinaryNode{
                  tag: "membership_requests_action",
                  attrs: %{},
                  content: [
                    %BinaryNode{
                      tag: "reject",
                      attrs: %{},
                      content: [
                        %BinaryNode{
                          tag: "participant",
                          attrs: %{"jid" => "15550001111@s.whatsapp.net", "error" => "403"}
                        }
                      ]
                    }
                  ]
                }
              ]
            }

          {"1234567890@g.us", "set", [%BinaryNode{tag: action}]}
          when action in ["add", "remove", "promote", "demote"] ->
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

          {"1234567890@g.us", "get", [%BinaryNode{tag: "invite"}]} ->
            %BinaryNode{
              tag: "iq",
              attrs: %{"type" => "result"},
              content: [%BinaryNode{tag: "invite", attrs: %{"code" => "WXYZ"}}]
            }

          {"1234567890@g.us", "set", [%BinaryNode{tag: "invite"}]} ->
            %BinaryNode{
              tag: "iq",
              attrs: %{"type" => "result"},
              content: [%BinaryNode{tag: "invite", attrs: %{"code" => "RSTU"}}]
            }

          {"@g.us", "set", [%BinaryNode{tag: "invite", attrs: %{"code" => "ABCD"}}]} ->
            %BinaryNode{
              tag: "iq",
              attrs: %{"type" => "result"},
              content: [%BinaryNode{tag: "community", attrs: %{"jid" => "1234567890@g.us"}}]
            }

          {"@g.us", "get", [%BinaryNode{tag: "invite", attrs: %{"code" => "JOIN"}}]} ->
            invite_info_result_node()

          {"1234567890@g.us", "get",
           [%BinaryNode{tag: "query", attrs: %{"request" => "interactive"}}]} ->
            {:ok, community_result_node("1234567890")}

          {"@g.us", "get", [%BinaryNode{tag: "participating"}]} ->
            {:ok, participating_result_node()}

          {"@g.us", "set", [%BinaryNode{tag: "leave"}]} ->
            %BinaryNode{tag: "iq", attrs: %{"type" => "result"}, content: nil}

          {"1234567890@g.us", "set", [_]} ->
            %BinaryNode{tag: "iq", attrs: %{"type" => "result"}, content: nil}
        end

      case response do
        {:ok, %BinaryNode{} = result} -> {:ok, result}
        %BinaryNode{} = result -> {:ok, result}
      end
    end

    sendable = fn node ->
      send(parent, {:send_node, node})
      :ok
    end

    emit_fun = fn groups ->
      send(parent, {:groups_update, groups})
      :ok
    end

    assert {:ok, [%{"jid" => "15550001111@s.whatsapp.net", "t" => "1710000000"}]} =
             Community.request_participants_list(query_fun, "1234567890@g.us")

    assert {:ok, [%{jid: "15550001111@s.whatsapp.net", status: "403"}]} =
             Community.request_participants_update(
               query_fun,
               "1234567890@g.us",
               ["15550001111@s.whatsapp.net"],
               :reject
             )

    assert {:ok, [%{jid: "15550001111@s.whatsapp.net", status: "200"}]} =
             Community.participants_update(
               query_fun,
               "1234567890@g.us",
               ["15550001111@s.whatsapp.net"],
               :add
             )

    assert {:ok, [%{jid: "15550001111@s.whatsapp.net", status: "200"}]} =
             Community.participants_update(
               query_fun,
               "1234567890@g.us",
               ["15550001111@s.whatsapp.net"],
               :remove
             )

    assert {:ok, [%{jid: "15550001111@s.whatsapp.net", status: "200"}]} =
             Community.participants_update(
               query_fun,
               "1234567890@g.us",
               ["15550001111@s.whatsapp.net"],
               :promote
             )

    assert {:ok, [%{jid: "15550001111@s.whatsapp.net", status: "200"}]} =
             Community.participants_update(
               query_fun,
               "1234567890@g.us",
               ["15550001111@s.whatsapp.net"],
               :demote
             )

    assert {:ok, "WXYZ"} = Community.invite_code(query_fun, "1234567890@g.us")
    assert {:ok, "RSTU"} = Community.revoke_invite(query_fun, "1234567890@g.us")
    assert {:ok, "1234567890@g.us"} = Community.accept_invite(query_fun, "ABCD")
    assert {:ok, invite_info} = Community.get_invite_info(query_fun, "JOIN")
    assert invite_info.id == "9988776655@g.us"

    assert {:ok, metadata} = Community.metadata(query_fun, "1234567890@g.us")
    assert metadata.id == "1234567890@g.us"
    assert metadata.is_community == true
    assert metadata.is_community_announce == true
    assert metadata.addressing_mode == :lid

    assert {:ok, participating} = Community.fetch_all_participating(query_fun, emit_fun: emit_fun)
    assert Map.keys(participating) == ["1234567890@g.us"]

    assert :ok = Community.update_subject(query_fun, "1234567890@g.us", "Updated")
    assert :ok = Community.leave(query_fun, "1234567890@g.us")
    assert :ok = Community.toggle_ephemeral(query_fun, "1234567890@g.us", 86_400)
    assert :ok = Community.toggle_ephemeral(query_fun, "1234567890@g.us", 0)
    assert :ok = Community.setting_update(query_fun, "1234567890@g.us", :announcement)
    assert :ok = Community.member_add_mode(query_fun, "1234567890@g.us", :all_member_add)
    assert :ok = Community.join_approval_mode(query_fun, "1234567890@g.us", :on)

    assert {:ok, _communities} =
             Community.handle_dirty_update(
               query_fun,
               %{type: "communities", timestamp: 1_710_000_000},
               emit_fun: emit_fun,
               sendable: sendable,
               message_tag_fun: fn -> "community-dirty-1" end
             )

    assert_receive {:groups_update,
                    [
                      %{
                        id: "1234567890@g.us",
                        subject: "Phase 11 Community",
                        is_community: true,
                        is_community_announce: true
                      }
                    ]}

    assert_receive {:send_node,
                    %BinaryNode{
                      tag: "iq",
                      attrs: %{
                        "to" => "s.whatsapp.net",
                        "type" => "set",
                        "xmlns" => "urn:xmpp:whatsapp:dirty",
                        "id" => "community-dirty-1"
                      },
                      content: [
                        %BinaryNode{
                          tag: "clean",
                          attrs: %{"type" => "groups", "timestamp" => "1710000000"}
                        }
                      ]
                    }}

    assert_receive {:query,
                    %BinaryNode{
                      attrs: %{"to" => "1234567890@g.us", "type" => "set", "xmlns" => "w:g2"},
                      content: [
                        %BinaryNode{
                          tag: "remove",
                          attrs: %{"linked_groups" => "true"}
                        }
                      ]
                    }, 60_000}

    assert_receive {:query,
                    %BinaryNode{
                      attrs: %{"to" => "1234567890@g.us", "type" => "set", "xmlns" => "w:g2"},
                      content: [
                        %BinaryNode{
                          tag: "membership_approval_mode",
                          content: [
                            %BinaryNode{
                              tag: "community_join",
                              attrs: %{"state" => "on"}
                            }
                          ]
                        }
                      ]
                    }, 60_000}
  end

  test "update_description and invite v4 side effects follow the Baileys community flow" do
    parent = self()

    query_fun = fn node, timeout ->
      send(parent, {:query, node, timeout})

      case {node.attrs["to"], node.content} do
        {"1234567890@g.us", [%BinaryNode{tag: "query", attrs: %{"request" => "interactive"}}]} ->
          {:ok, community_result_node("1234567890")}

        {"1234567890@g.us", [%BinaryNode{tag: "description"}]} ->
          {:ok, %BinaryNode{tag: "iq", attrs: %{"type" => "result"}, content: nil}}

        {"1234567890@g.us", [%BinaryNode{tag: "accept"}]} ->
          {:ok, %BinaryNode{tag: "iq", attrs: %{"from" => "1234567890@g.us"}, content: nil}}
      end
    end

    assert :ok =
             Community.update_description(query_fun, "1234567890@g.us", "Updated description",
               message_id_fun: fn -> "community-desc-1" end
             )

    assert :ok = Community.update_description(query_fun, "1234567890@g.us", "")

    assert {:ok, "1234567890@g.us"} =
             Community.accept_invite_v4(
               query_fun,
               %{id: "invite-msg-3", remote_jid: "15550001111@s.whatsapp.net"},
               %{
                 group_jid: "1234567890@g.us",
                 invite_code: "CODE",
                 invite_expiration: 1_710_000_000
               },
               me: %{id: "15550003333:5@s.whatsapp.net", name: "~"},
               message_id_fun: fn me_id ->
                 send(parent, {:message_id_seed, me_id})
                 "seeded-community-msg-1"
               end,
               timestamp_fun: fn -> 1_710_222_333 end,
               message_update_fun: &send(parent, {:messages_update, &1}),
               upsert_message_fun: &send(parent, {:messages_upsert, &1})
             )

    assert_receive {:query,
                    %BinaryNode{
                      content: [
                        %BinaryNode{
                          tag: "description",
                          attrs: %{"id" => "community-desc-1", "prev" => "desc-123"}
                        }
                      ]
                    }, 60_000}

    assert_receive {:query,
                    %BinaryNode{
                      content: [
                        %BinaryNode{
                          tag: "description",
                          attrs: %{"delete" => "true", "prev" => "desc-123"},
                          content: nil
                        }
                      ]
                    }, 60_000}

    assert_receive {:messages_update,
                    [
                      %{
                        key: %{id: "invite-msg-3", remote_jid: "15550001111@s.whatsapp.net"},
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

    assert_receive {:message_id_seed, "15550003333:5@s.whatsapp.net"}

    assert_receive {:messages_upsert,
                    %{
                      key: %{
                        id: "seeded-community-msg-1",
                        participant: "15550001111@s.whatsapp.net",
                        remote_jid: "1234567890@g.us"
                      },
                      message_stub_type: :GROUP_PARTICIPANT_ADD,
                      message_timestamp: 1_710_222_333
                    }}
  end

  test "create and update_description swallow follow-up metadata failures like Baileys parseGroupResult" do
    query_fun = fn
      %BinaryNode{attrs: %{"to" => "@g.us"}, content: [%BinaryNode{tag: "create"}]}, _timeout ->
        {:ok, created_group_result_node("1234567890")}

      %BinaryNode{
        attrs: %{"to" => "1234567890@g.us"},
        content: [%BinaryNode{tag: "query", attrs: %{"request" => "interactive"}}]
      },
      _timeout ->
        {:error, :metadata_timeout}
    end

    assert {:ok, nil} = Community.create(query_fun, "Phase 11 Community", "Body")
  end

  defp created_group_result_node(id) do
    %BinaryNode{
      tag: "iq",
      attrs: %{"type" => "result"},
      content: [%BinaryNode{tag: "group", attrs: %{"id" => id}}]
    }
  end

  defp participating_result_node do
    %BinaryNode{
      tag: "iq",
      attrs: %{"type" => "result"},
      content: [
        %BinaryNode{
          tag: "communities",
          attrs: %{},
          content: [community_result_node("1234567890").content |> List.first()]
        }
      ]
    }
  end

  defp invite_info_result_node do
    %BinaryNode{
      tag: "iq",
      attrs: %{"type" => "result"},
      content: [community_result_node("9988776655").content |> List.first()]
    }
  end

  defp sub_groups_result_node do
    %BinaryNode{
      tag: "iq",
      attrs: %{"type" => "result"},
      content: [
        %BinaryNode{
          tag: "sub_groups",
          attrs: %{},
          content: [
            %BinaryNode{
              tag: "group",
              attrs: %{
                "id" => "2233445566",
                "subject" => "Phase 11 General",
                "creation" => "1710000100",
                "creator" => "15550001111:9@c.us",
                "size" => "33"
              }
            }
          ]
        }
      ]
    }
  end

  defp community_result_node(id) do
    %BinaryNode{
      tag: "iq",
      attrs: %{"type" => "result"},
      content: [
        %BinaryNode{
          tag: "community",
          attrs: %{
            "id" => id,
            "subject" => "Phase 11 Community",
            "s_o" => "15550009999@s.whatsapp.net",
            "s_t" => "1710000000",
            "creation" => "1709999999",
            "creator" => "15550001111:2@c.us"
          },
          content: [
            %BinaryNode{
              tag: "description",
              attrs: %{"id" => "desc-123"},
              content: [%BinaryNode{tag: "body", attrs: %{}, content: "Community body"}]
            },
            %BinaryNode{tag: "parent", attrs: %{}},
            %BinaryNode{tag: "default_sub_community", attrs: %{}},
            %BinaryNode{tag: "membership_approval_mode", attrs: %{}},
            %BinaryNode{
              tag: "member_add_mode",
              attrs: %{},
              content: "all_member_add"
            },
            %BinaryNode{tag: "announcement", attrs: %{}},
            %BinaryNode{tag: "locked", attrs: %{}},
            %BinaryNode{tag: "linked_parent", attrs: %{"jid" => "5550001111@g.us"}},
            %BinaryNode{tag: "ephemeral", attrs: %{"expiration" => "86400"}},
            %BinaryNode{tag: "addressing_mode", attrs: %{}, content: "lid"},
            %BinaryNode{
              tag: "participant",
              attrs: %{"jid" => "15550001111@s.whatsapp.net", "type" => "admin"}
            },
            %BinaryNode{
              tag: "participant",
              attrs: %{"jid" => "15550002222@s.whatsapp.net"}
            }
          ]
        }
      ]
    }
  end

  defp group_result_node(id, subject, opts \\ []) do
    content =
      case opts[:linked_parent] do
        nil -> []
        linked_parent -> [%BinaryNode{tag: "linked_parent", attrs: %{"jid" => linked_parent}}]
      end

    %BinaryNode{
      tag: "iq",
      attrs: %{"type" => "result"},
      content: [
        %BinaryNode{
          tag: "group",
          attrs: %{
            "id" => id,
            "subject" => subject,
            "s_t" => "1710000000",
            "size" => "1",
            "creation" => "1709999999"
          },
          content: [
            %BinaryNode{tag: "participant", attrs: %{"jid" => "15550001111@s.whatsapp.net"}}
            | content
          ]
        }
      ]
    }
  end
end
