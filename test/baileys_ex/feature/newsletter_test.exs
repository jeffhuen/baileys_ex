defmodule BaileysEx.Feature.NewsletterTest do
  use ExUnit.Case, async: true

  alias BaileysEx.BinaryNode
  alias BaileysEx.Feature.Newsletter

  @create_query_id "8823471724422422"
  @update_metadata_query_id "24250201037901610"
  @metadata_query_id "6563316087068696"
  @subscribers_query_id "9783111038412085"
  @follow_query_id "7871414976211147"
  @unfollow_query_id "7238632346214362"
  @mute_query_id "29766401636284406"
  @unmute_query_id "9864994326891137"
  @admin_count_query_id "7130823597031706"
  @change_owner_query_id "7341777602580933"
  @demote_query_id "6551828931592903"
  @delete_query_id "30062808666639665"

  test "wmex-backed newsletter operations build the Baileys queries and parse responses" do
    parent = self()

    query_fun = fn node, timeout ->
      send(parent, {:query, node, timeout})

      case {node.tag, node.attrs["xmlns"], node.attrs["type"]} do
        {"iq", "w:mex", "get"} ->
          [
            %BinaryNode{
              tag: "query",
              attrs: %{"query_id" => query_id},
              content: {:binary, payload}
            }
          ] =
            node.content

          variables = JSON.decode!(payload)["variables"]
          send(parent, {:wmex_query, query_id, variables, node.attrs["id"]})

          {:ok, wmex_response(query_id)}
      end
    end

    assert {:ok, newsletter} =
             Newsletter.create(query_fun, "Phase 11", "Launch note",
               message_tag_fun: fn -> "newsletter-tag-1" end
             )

    assert newsletter.id == "12345@newsletter"
    assert newsletter.name == "Phase 11"
    assert newsletter.description == "Launch note"
    assert newsletter.creation_time == 1_710_000_000
    assert newsletter.subscribers == 42
    assert newsletter.mute_state == "OFF"

    assert {:ok, metadata} =
             Newsletter.metadata(query_fun, :jid, "12345@newsletter",
               message_tag_fun: fn -> "newsletter-tag-2" end
             )

    assert metadata == %{
             "id" => "12345@newsletter",
             "name" => "Phase 11",
             "description" => "Launch note",
             "creation_time" => 1_710_000_000,
             "subscribers" => 42,
             "verification" => "VERIFIED",
             "mute_state" => "OFF",
             "picture" => %{"id" => "pic-1", "directPath" => "/newsletter/pic-1"}
           }

    assert {:ok, %{subscribers: 42}} =
             Newsletter.subscribers(query_fun, "12345@newsletter",
               message_tag_fun: fn -> "newsletter-tag-3" end
             )

    assert {:ok, 3} =
             Newsletter.admin_count(query_fun, "12345@newsletter",
               message_tag_fun: fn -> "newsletter-tag-4" end
             )

    assert {:ok, %{id: "12345@newsletter"}} =
             Newsletter.follow(query_fun, "12345@newsletter",
               message_tag_fun: fn -> "newsletter-tag-5" end
             )

    assert {:ok, %{id: "12345@newsletter"}} =
             Newsletter.unfollow(query_fun, "12345@newsletter",
               message_tag_fun: fn -> "newsletter-tag-6" end
             )

    assert {:ok, %{id: "12345@newsletter"}} =
             Newsletter.mute(query_fun, "12345@newsletter",
               message_tag_fun: fn -> "newsletter-tag-7" end
             )

    assert {:ok, %{id: "12345@newsletter"}} =
             Newsletter.unmute(query_fun, "12345@newsletter",
               message_tag_fun: fn -> "newsletter-tag-8" end
             )

    assert {:ok, %{id: "12345@newsletter"}} =
             Newsletter.update(query_fun, "12345@newsletter", %{name: "Updated"},
               message_tag_fun: fn -> "newsletter-tag-9" end
             )

    assert {:ok, %{id: "12345@newsletter"}} =
             Newsletter.update_name(query_fun, "12345@newsletter", "Renamed",
               message_tag_fun: fn -> "newsletter-tag-10" end
             )

    assert {:ok, %{id: "12345@newsletter"}} =
             Newsletter.update_description(query_fun, "12345@newsletter", "New body",
               message_tag_fun: fn -> "newsletter-tag-11" end
             )

    assert {:ok, %{id: "12345@newsletter"}} =
             Newsletter.update_picture(query_fun, "12345@newsletter", :image_bytes,
               picture_generator: fn :image_bytes, _dimensions -> {:ok, %{img: <<1, 2, 3>>}} end,
               message_tag_fun: fn -> "newsletter-tag-12" end
             )

    assert {:ok, %{id: "12345@newsletter"}} =
             Newsletter.remove_picture(query_fun, "12345@newsletter",
               message_tag_fun: fn -> "newsletter-tag-13" end
             )

    assert :ok =
             Newsletter.change_owner(query_fun, "12345@newsletter", "15550001111@s.whatsapp.net",
               message_tag_fun: fn -> "newsletter-tag-14" end
             )

    assert :ok =
             Newsletter.demote(query_fun, "12345@newsletter", "15550002222@s.whatsapp.net",
               message_tag_fun: fn -> "newsletter-tag-15" end
             )

    assert :ok =
             Newsletter.delete(query_fun, "12345@newsletter",
               message_tag_fun: fn -> "newsletter-tag-16" end
             )

    assert_receive {:wmex_query, @create_query_id,
                    %{
                      "input" => %{"name" => "Phase 11", "description" => "Launch note"}
                    }, "newsletter-tag-1"}

    assert_receive {:wmex_query, @metadata_query_id,
                    %{
                      "fetch_creation_time" => true,
                      "fetch_full_image" => true,
                      "fetch_viewer_metadata" => true,
                      "input" => %{"key" => "12345@newsletter", "type" => "JID"}
                    }, "newsletter-tag-2"}

    assert_receive {:wmex_query, @subscribers_query_id, %{"newsletter_id" => "12345@newsletter"},
                    "newsletter-tag-3"}

    assert_receive {:wmex_query, @admin_count_query_id, %{"newsletter_id" => "12345@newsletter"},
                    "newsletter-tag-4"}

    assert_receive {:wmex_query, @follow_query_id, %{"newsletter_id" => "12345@newsletter"},
                    "newsletter-tag-5"}

    assert_receive {:wmex_query, @unfollow_query_id, %{"newsletter_id" => "12345@newsletter"},
                    "newsletter-tag-6"}

    assert_receive {:wmex_query, @mute_query_id, %{"newsletter_id" => "12345@newsletter"},
                    "newsletter-tag-7"}

    assert_receive {:wmex_query, @unmute_query_id, %{"newsletter_id" => "12345@newsletter"},
                    "newsletter-tag-8"}

    assert_receive {:wmex_query, @update_metadata_query_id,
                    %{
                      "newsletter_id" => "12345@newsletter",
                      "updates" => %{"name" => "Updated", "settings" => nil}
                    }, "newsletter-tag-9"}

    assert_receive {:wmex_query, @update_metadata_query_id,
                    %{
                      "newsletter_id" => "12345@newsletter",
                      "updates" => %{"name" => "Renamed", "settings" => nil}
                    }, "newsletter-tag-10"}

    assert_receive {:wmex_query, @update_metadata_query_id,
                    %{
                      "newsletter_id" => "12345@newsletter",
                      "updates" => %{"description" => "New body", "settings" => nil}
                    }, "newsletter-tag-11"}

    assert_receive {:wmex_query, @update_metadata_query_id,
                    %{
                      "newsletter_id" => "12345@newsletter",
                      "updates" => %{"picture" => "AQID", "settings" => nil}
                    }, "newsletter-tag-12"}

    assert_receive {:wmex_query, @update_metadata_query_id,
                    %{
                      "newsletter_id" => "12345@newsletter",
                      "updates" => %{"picture" => "", "settings" => nil}
                    }, "newsletter-tag-13"}

    assert_receive {:wmex_query, @change_owner_query_id,
                    %{
                      "newsletter_id" => "12345@newsletter",
                      "user_id" => "15550001111@s.whatsapp.net"
                    }, "newsletter-tag-14"}

    assert_receive {:wmex_query, @demote_query_id,
                    %{
                      "newsletter_id" => "12345@newsletter",
                      "user_id" => "15550002222@s.whatsapp.net"
                    }, "newsletter-tag-15"}

    assert_receive {:wmex_query, @delete_query_id, %{"newsletter_id" => "12345@newsletter"},
                    "newsletter-tag-16"}
  end

  test "fetch_messages and subscribe_updates use the newsletter IQ transport" do
    parent = self()

    query_fun = fn node, timeout ->
      send(parent, {:query, node, timeout})

      response =
        case node.content do
          [%BinaryNode{tag: "message_updates"}] ->
            %BinaryNode{
              tag: "iq",
              attrs: %{"type" => "result"},
              content: [%BinaryNode{tag: "message_updates", attrs: %{"count" => "2"}}]
            }

          [%BinaryNode{tag: "live_updates"}] ->
            %BinaryNode{
              tag: "iq",
              attrs: %{"type" => "result"},
              content: [%BinaryNode{tag: "live_updates", attrs: %{"duration" => "180"}}]
            }
        end

      {:ok, response}
    end

    assert {:ok, %BinaryNode{}} =
             Newsletter.fetch_messages(query_fun, "12345@newsletter", 2,
               since: 1_710_000_000,
               after: 77,
               message_tag_fun: fn -> "newsletter-fetch-1" end
             )

    assert {:ok, %{duration: "180"}} =
             Newsletter.subscribe_updates(query_fun, "12345@newsletter",
               message_tag_fun: fn -> "newsletter-live-1" end
             )

    assert_receive {:query,
                    %BinaryNode{
                      tag: "iq",
                      attrs: %{
                        "id" => "newsletter-fetch-1",
                        "type" => "get",
                        "xmlns" => "newsletter",
                        "to" => "12345@newsletter"
                      },
                      content: [
                        %BinaryNode{
                          tag: "message_updates",
                          attrs: %{
                            "count" => "2",
                            "since" => "1710000000",
                            "after" => "77"
                          }
                        }
                      ]
                    }, 60_000}

    assert_receive {:query,
                    %BinaryNode{
                      tag: "iq",
                      attrs: %{
                        "id" => "newsletter-live-1",
                        "type" => "set",
                        "xmlns" => "newsletter",
                        "to" => "12345@newsletter"
                      },
                      content: [%BinaryNode{tag: "live_updates", attrs: %{}, content: []}]
                    }, 60_000}
  end

  test "react_message builds the Baileys reaction stanza, including delete semantics" do
    parent = self()

    query_fun = fn node, timeout ->
      send(parent, {:query, node, timeout})
      {:ok, %BinaryNode{tag: "message", attrs: %{}, content: nil}}
    end

    assert :ok =
             Newsletter.react_message(query_fun, "12345@newsletter", "server-msg-1", "🔥",
               message_tag_fun: fn -> "newsletter-react-1" end
             )

    assert :ok =
             Newsletter.react_message(query_fun, "12345@newsletter", "server-msg-2", nil,
               message_tag_fun: fn -> "newsletter-react-2" end
             )

    assert_receive {:query,
                    %BinaryNode{
                      tag: "message",
                      attrs: %{
                        "to" => "12345@newsletter",
                        "type" => "reaction",
                        "server_id" => "server-msg-1",
                        "id" => "newsletter-react-1"
                      },
                      content: [%BinaryNode{tag: "reaction", attrs: %{"code" => "🔥"}}]
                    }, 60_000}

    assert_receive {:query,
                    %BinaryNode{
                      tag: "message",
                      attrs: %{
                        "to" => "12345@newsletter",
                        "type" => "reaction",
                        "server_id" => "server-msg-2",
                        "id" => "newsletter-react-2",
                        "edit" => "7"
                      },
                      content: [%BinaryNode{tag: "reaction", attrs: %{}}]
                    }, 60_000}
  end

  defp wmex_response(@create_query_id) do
    wmex_response_node(%{
      "data" => %{
        "xwa2_newsletter_create" => %{
          "id" => "12345@newsletter",
          "thread_metadata" => %{
            "creation_time" => "1710000000",
            "description" => %{"text" => "Launch note"},
            "invite" => "invite-code",
            "name" => %{"text" => "Phase 11"},
            "picture" => %{"id" => "pic-1", "direct_path" => "/newsletter/pic-1"},
            "subscribers_count" => "42",
            "verification" => "VERIFIED"
          },
          "viewer_metadata" => %{"mute" => "OFF"}
        }
      }
    })
  end

  defp wmex_response(@update_metadata_query_id) do
    wmex_response_node(%{
      "data" => %{"xwa2_newsletter_update" => %{"id" => "12345@newsletter"}}
    })
  end

  defp wmex_response(@metadata_query_id) do
    wmex_response_node(%{
      "data" => %{
        "xwa2_newsletter" => %{
          "result" => %{
            "id" => "12345@newsletter",
            "name" => "Phase 11",
            "description" => "Launch note",
            "creation_time" => 1_710_000_000,
            "subscribers" => 42,
            "verification" => "VERIFIED",
            "mute_state" => "OFF",
            "picture" => %{"id" => "pic-1", "directPath" => "/newsletter/pic-1"}
          }
        }
      }
    })
  end

  defp wmex_response(@subscribers_query_id) do
    wmex_response_node(%{
      "data" => %{"xwa2_newsletter_subscribers" => %{"subscribers" => 42}}
    })
  end

  defp wmex_response(@admin_count_query_id) do
    wmex_response_node(%{
      "data" => %{"xwa2_newsletter_admin" => %{"admin_count" => 3}}
    })
  end

  defp wmex_response(query_id)
       when query_id in [
              @follow_query_id,
              @unfollow_query_id,
              @mute_query_id,
              @unmute_query_id,
              @change_owner_query_id,
              @demote_query_id,
              @delete_query_id
            ] do
    path =
      case query_id do
        @follow_query_id -> "xwa2_newsletter_follow"
        @unfollow_query_id -> "xwa2_newsletter_unfollow"
        @mute_query_id -> "xwa2_newsletter_mute_v2"
        @unmute_query_id -> "xwa2_newsletter_unmute_v2"
        @change_owner_query_id -> "xwa2_newsletter_change_owner"
        @demote_query_id -> "xwa2_newsletter_demote"
        @delete_query_id -> "xwa2_newsletter_delete_v2"
      end

    wmex_response_node(%{"data" => %{path => %{"id" => "12345@newsletter"}}})
  end

  defp wmex_response_node(payload) do
    %BinaryNode{
      tag: "iq",
      attrs: %{"type" => "result"},
      content: [%BinaryNode{tag: "result", attrs: %{}, content: JSON.encode!(payload)}]
    }
  end
end
