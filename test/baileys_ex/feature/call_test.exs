defmodule BaileysEx.Feature.CallTest do
  use ExUnit.Case, async: true

  alias BaileysEx.BinaryNode
  alias BaileysEx.Connection.EventEmitter
  alias BaileysEx.Connection.Store
  alias BaileysEx.Feature.Call

  test "reject_call/4 sends the Baileys reject call stanza" do
    parent = self()

    query_fun = fn node, timeout ->
      send(parent, {:query, node, timeout})
      {:ok, %BinaryNode{tag: "call", attrs: %{"type" => "result"}, content: nil}}
    end

    assert {:ok, %BinaryNode{tag: "call", attrs: %{"type" => "result"}}} =
             Call.reject_call(
               query_fun,
               "call-1",
               "15551234567@s.whatsapp.net",
               me: %{id: "15550001111@s.whatsapp.net"},
               query_timeout: 456
             )

    assert_receive {:query,
                    %BinaryNode{
                      tag: "call",
                      attrs: %{
                        "from" => "15550001111@s.whatsapp.net",
                        "to" => "15551234567@s.whatsapp.net"
                      },
                      content: [
                        %BinaryNode{
                          tag: "reject",
                          attrs: %{
                            "call-id" => "call-1",
                            "call-creator" => "15551234567@s.whatsapp.net",
                            "count" => "0"
                          },
                          content: nil
                        }
                      ]
                    }, 456}
  end

  test "reject_call/4 preserves the device-suffixed current user id" do
    parent = self()

    query_fun = fn node, timeout ->
      send(parent, {:query, node, timeout})
      {:ok, %BinaryNode{tag: "call", attrs: %{"type" => "result"}, content: nil}}
    end

    assert {:ok, %BinaryNode{tag: "call", attrs: %{"type" => "result"}}} =
             Call.reject_call(
               query_fun,
               "call-2",
               "15551234567@s.whatsapp.net",
               me: %{id: "15550001111:5@s.whatsapp.net"}
             )

    assert_receive {:query,
                    %BinaryNode{
                      tag: "call",
                      attrs: %{
                        "from" => "15550001111:5@s.whatsapp.net",
                        "to" => "15551234567@s.whatsapp.net"
                      }
                    }, 60_000}
  end

  test "create_call_link/3 constructs the Baileys call/link_create query and returns the token" do
    parent = self()

    query_fun = fn node, timeout ->
      send(parent, {:query, node, timeout})

      {:ok,
       %BinaryNode{
         tag: "call",
         attrs: %{"type" => "result"},
         content: [
           %BinaryNode{tag: "link_create", attrs: %{"token" => "call-token"}, content: nil}
         ]
       }}
    end

    assert {:ok, "call-token"} =
             Call.create_call_link(query_fun, :video,
               query_id: "call-tag-1",
               event: %{start_time: 1_710_000_000},
               timeout_ms: 987
             )

    assert_receive {:query,
                    %BinaryNode{
                      tag: "call",
                      attrs: %{"id" => "call-tag-1", "to" => "@call"},
                      content: [
                        %BinaryNode{
                          tag: "link_create",
                          attrs: %{"media" => "video"},
                          content: [
                            %BinaryNode{
                              tag: "event",
                              attrs: %{"start_time" => "1710000000"},
                              content: nil
                            }
                          ]
                        }
                      ]
                    }, 987}
  end

  test "handle_node/2 emits call events, caches offer metadata, and sends ack nodes" do
    {:ok, emitter} = EventEmitter.start_link()
    parent = self()
    _unsubscribe = EventEmitter.process(emitter, &send(parent, {:events, &1}))

    {:ok, store} = Store.start_link(auth_state: %{})
    store_ref = Store.wrap(store)

    offer_node = %BinaryNode{
      tag: "call",
      attrs: %{"id" => "call-node-1", "from" => "15551234567@s.whatsapp.net", "t" => "1710000000"},
      content: [
        %BinaryNode{
          tag: "offer",
          attrs: %{
            "call-id" => "call-1",
            "from" => "15551234567@s.whatsapp.net",
            "caller_pn" => "15551234567@s.whatsapp.net",
            "type" => "group",
            "group-jid" => "120363001234567890@g.us"
          },
          content: [%BinaryNode{tag: "video", attrs: %{}, content: nil}]
        }
      ]
    }

    assert {:ok,
            %{
              id: "call-1",
              status: :offer,
              is_video: true,
              is_group: true,
              group_jid: "120363001234567890@g.us"
            }} =
             Call.handle_node(offer_node,
               event_emitter: emitter,
               store_ref: store_ref,
               send_node_fun: fn node ->
                 send(parent, {:ack, node})
                 :ok
               end
             )

    assert_receive {:events,
                    %{
                      call: [
                        %{
                          id: "call-1",
                          status: :offer,
                          caller_pn: "15551234567@s.whatsapp.net",
                          is_video: true,
                          is_group: true,
                          group_jid: "120363001234567890@g.us"
                        }
                      ]
                    }}

    assert_receive {:ack,
                    %BinaryNode{
                      tag: "ack",
                      attrs: %{
                        "id" => "call-node-1",
                        "to" => "15551234567@s.whatsapp.net",
                        "class" => "call"
                      }
                    }}

    terminate_node = %BinaryNode{
      tag: "call",
      attrs: %{
        "id" => "call-node-2",
        "from" => "15551234567@s.whatsapp.net",
        "t" => "1710000001",
        "offline" => "1"
      },
      content: [
        %BinaryNode{
          tag: "terminate",
          attrs: %{
            "call-id" => "call-1",
            "call-creator" => "15551234567@s.whatsapp.net",
            "reason" => "timeout"
          },
          content: nil
        }
      ]
    }

    assert {:ok,
            %{
              id: "call-1",
              status: :timeout,
              is_video: true,
              is_group: true,
              caller_pn: "15551234567@s.whatsapp.net",
              offline: true
            }} =
             Call.handle_node(terminate_node,
               event_emitter: emitter,
               store_ref: store_ref,
               send_node_fun: fn node ->
                 send(parent, {:ack, node})
                 :ok
               end
             )

    assert_receive {:events,
                    %{
                      call: [
                        %{
                          id: "call-1",
                          status: :timeout,
                          caller_pn: "15551234567@s.whatsapp.net",
                          is_video: true,
                          is_group: true,
                          offline: true
                        }
                      ]
                    }}

    assert_receive {:ack,
                    %BinaryNode{
                      tag: "ack",
                      attrs: %{
                        "id" => "call-node-2",
                        "to" => "15551234567@s.whatsapp.net",
                        "class" => "call"
                      }
                    }}
  end
end
