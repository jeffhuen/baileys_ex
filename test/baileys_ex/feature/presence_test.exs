defmodule BaileysEx.Feature.PresenceTest do
  use ExUnit.Case, async: true

  alias BaileysEx.BinaryNode
  alias BaileysEx.Connection.EventEmitter
  alias BaileysEx.Feature.Presence
  alias BaileysEx.Signal.Store

  test "send_update/4 mirrors Baileys presence and chatstate node shapes" do
    parent = self()

    sendable = fn node ->
      send(parent, {:node, node})
      :ok
    end

    assert :ok = Presence.send_update(sendable, :available, nil, name: "Jeff@Bot")

    assert_receive {:node,
                    %BinaryNode{
                      tag: "presence",
                      attrs: %{"type" => "available", "name" => "JeffBot"},
                      content: nil
                    }}

    assert :ok =
             Presence.send_update(sendable, :composing, "15551234567@s.whatsapp.net",
               me_id: "15550001111@s.whatsapp.net"
             )

    assert_receive {:node,
                    %BinaryNode{
                      tag: "chatstate",
                      attrs: %{
                        "from" => "15550001111@s.whatsapp.net",
                        "to" => "15551234567@s.whatsapp.net"
                      },
                      content: [%BinaryNode{tag: "composing", attrs: %{}, content: nil}]
                    }}

    assert :ok =
             Presence.send_update(sendable, :recording, "15551234567@lid",
               me_id: "15550001111@s.whatsapp.net",
               me_lid: "15550001111@lid"
             )

    assert_receive {:node,
                    %BinaryNode{
                      tag: "chatstate",
                      attrs: %{"from" => "15550001111@lid", "to" => "15551234567@lid"},
                      content: [
                        %BinaryNode{
                          tag: "composing",
                          attrs: %{"media" => "audio"},
                          content: nil
                        }
                      ]
                    }}

    assert :ok =
             Presence.send_update(sendable, :paused, "15551234567@s.whatsapp.net",
               me_id: "15550001111@s.whatsapp.net"
             )

    assert_receive {:node,
                    %BinaryNode{
                      tag: "chatstate",
                      attrs: %{
                        "from" => "15550001111@s.whatsapp.net",
                        "to" => "15551234567@s.whatsapp.net"
                      },
                      content: [%BinaryNode{tag: "paused", attrs: %{}, content: nil}]
                    }}

    assert :ok = Presence.send_update(sendable, :unavailable, nil, name: "Jeff@Bot")

    assert_receive {:node,
                    %BinaryNode{
                      tag: "presence",
                      attrs: %{"type" => "unavailable", "name" => "JeffBot"},
                      content: nil
                    }}
  end

  test "send_update/4 ignores available presence requests when the raw sendable lacks a name" do
    sendable = fn node ->
      send(self(), {:node, node})
      :ok
    end

    assert :ok = Presence.send_update(sendable, :available)
    refute_received {:node, _node}
  end

  test "send_update/4 requires me_lid for lid chatstate updates" do
    sendable = fn node ->
      send(self(), {:node, node})
      :ok
    end

    assert {:error, :missing_from_jid} =
             Presence.send_update(sendable, :composing, "15551234567@lid",
               me_id: "15550001111@s.whatsapp.net"
             )

    refute_received {:node, _node}
  end

  test "subscribe/3 adds a tc token and generated message tag" do
    {:ok, store} = Store.start_link()

    assert :ok =
             Store.set(store, %{
               tctoken: %{"15551234567@s.whatsapp.net" => %{token: "tc-token"}}
             })

    parent = self()

    sendable = fn node ->
      send(parent, {:node, node})
      :ok
    end

    assert :ok =
             Presence.subscribe(sendable, "15551234567@s.whatsapp.net",
               signal_store: store,
               message_tag_fun: fn -> "presence-sub-1" end
             )

    assert_receive {:node,
                    %BinaryNode{
                      tag: "presence",
                      attrs: %{
                        "to" => "15551234567@s.whatsapp.net",
                        "id" => "presence-sub-1",
                        "type" => "subscribe"
                      },
                      content: [%BinaryNode{tag: "tctoken", attrs: %{}, content: "tc-token"}]
                    }}
  end

  test "handle_update/2 parses presence and chatstate updates and emits presence_update" do
    {:ok, emitter} = EventEmitter.start_link()
    parent = self()
    unsubscribe = EventEmitter.process(emitter, &send(parent, {:events, &1}))

    assert {:ok,
            %{
              id: "15551234567@s.whatsapp.net",
              presences: %{
                "15551234567@s.whatsapp.net" => %{
                  last_known_presence: :unavailable,
                  last_seen: 1_710_000_700
                }
              }
            }} =
             Presence.handle_update(
               %BinaryNode{
                 tag: "presence",
                 attrs: %{
                   "from" => "15551234567@s.whatsapp.net",
                   "type" => "unavailable",
                   "last" => "1710000700"
                 },
                 content: nil
               },
               event_emitter: emitter
             )

    assert_receive {:events,
                    %{
                      presence_update: %{
                        id: "15551234567@s.whatsapp.net",
                        presences: %{
                          "15551234567@s.whatsapp.net" => %{
                            last_known_presence: :unavailable,
                            last_seen: 1_710_000_700
                          }
                        }
                      }
                    }}

    assert {:ok,
            %{
              id: "15551234567@s.whatsapp.net",
              presences: %{
                "15551234567@s.whatsapp.net" => %{last_known_presence: :available}
              }
            }} =
             Presence.handle_update(%BinaryNode{
               tag: "presence",
               attrs: %{
                 "from" => "15551234567@s.whatsapp.net",
                 "type" => "available"
               },
               content: nil
             })

    assert {:ok,
            %{
              id: "120363001234567890@g.us",
              presences: %{
                "15557654321@s.whatsapp.net" => %{last_known_presence: :recording}
              }
            }} =
             Presence.handle_update(%BinaryNode{
               tag: "chatstate",
               attrs: %{
                 "from" => "120363001234567890@g.us",
                 "participant" => "15557654321@s.whatsapp.net"
               },
               content: [
                 %BinaryNode{
                   tag: "composing",
                   attrs: %{"media" => "audio"},
                   content: nil
                 }
               ]
             })

    assert {:ok,
            %{
              presences: %{"15557654321@s.whatsapp.net" => %{last_known_presence: :available}}
            }} =
             Presence.handle_update(%BinaryNode{
               tag: "chatstate",
               attrs: %{
                 "from" => "120363001234567890@g.us",
                 "participant" => "15557654321@s.whatsapp.net"
               },
               content: [%BinaryNode{tag: "paused", attrs: %{}, content: nil}]
             })

    assert {:ok,
            %{
              presences: %{"15557654321@s.whatsapp.net" => %{last_known_presence: :recording}}
            }} =
             Presence.handle_update(%BinaryNode{
               tag: "chatstate",
               attrs: %{
                 "from" => "120363001234567890@g.us",
                 "participant" => "15557654321@s.whatsapp.net"
               },
               content: [%BinaryNode{tag: "paused", attrs: %{"media" => "audio"}, content: nil}]
             })

    assert :ignore =
             Presence.handle_update(
               %BinaryNode{
                 tag: "presence",
                 attrs: %{"from" => "15551234567@s.whatsapp.net", "type" => "available"},
                 content: nil
               },
               should_ignore_jid_fun: fn _jid -> true end
             )

    assert :ignore =
             Presence.handle_update(%BinaryNode{
               tag: "notification",
               attrs: %{"type" => "privacy_token"},
               content: nil
             })

    assert :ok = unsubscribe.()
  end
end
