defmodule BaileysEx.Message.NotificationHandlerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias BaileysEx.BinaryNode
  alias BaileysEx.Connection.EventEmitter
  alias BaileysEx.Message.Builder
  alias BaileysEx.Protocol.Proto.Message

  test "process_node/2 emits synthetic group create notifications and group upserts" do
    {:ok, emitter} = EventEmitter.start_link()
    parent = self()
    unsubscribe = EventEmitter.process(emitter, &send(parent, {:events, &1}))

    node = %BinaryNode{
      tag: "notification",
      attrs: %{
        "id" => "notif-create-1",
        "type" => "w:gp2",
        "from" => "120363001234567890@g.us",
        "participant" => "15551234567@s.whatsapp.net",
        "t" => "1710000700"
      },
      content: [
        %BinaryNode{
          tag: "create",
          attrs: %{
            "id" => "120363001234567890@g.us",
            "subject" => "Phase 8",
            "creation" => "1710000699",
            "creator" => "15551234567@s.whatsapp.net"
          },
          content: nil
        }
      ]
    }

    assert :ok =
             apply(BaileysEx.Message.NotificationHandler, :process_node, [
               node,
               %{event_emitter: emitter}
             ])

    assert_receive {:events,
                    %{
                      chats_upsert: [
                        %{
                          id: "120363001234567890@g.us",
                          name: "Phase 8",
                          conversation_timestamp: 1_710_000_699
                        }
                      ]
                    }}

    assert_receive {:events,
                    %{
                      groups_upsert: [
                        %{
                          id: "120363001234567890@g.us",
                          subject: "Phase 8",
                          author: "15551234567@s.whatsapp.net"
                        }
                      ]
                    }}

    assert_receive {:events,
                    %{
                      messages_upsert: %{
                        type: :append,
                        messages: [
                          %{
                            message_stub_type: :GROUP_CREATE,
                            message_stub_parameters: ["Phase 8"]
                          }
                        ]
                      }
                    }}

    unsubscribe.()
  end

  test "process_node/2 handles picture and account_sync notifications" do
    {:ok, emitter} = EventEmitter.start_link()
    parent = self()
    unsubscribe = EventEmitter.process(emitter, &send(parent, {:events, &1}))

    picture_node = %BinaryNode{
      tag: "notification",
      attrs: %{
        "id" => "notif-picture-1",
        "type" => "picture",
        "from" => "120363001234567890@g.us",
        "t" => "1710000701"
      },
      content: [
        %BinaryNode{
          tag: "set",
          attrs: %{"author" => "15551234567@s.whatsapp.net", "id" => "picture-1"},
          content: nil
        }
      ]
    }

    assert :ok =
             apply(BaileysEx.Message.NotificationHandler, :process_node, [
               picture_node,
               %{event_emitter: emitter}
             ])

    assert_receive {:events,
                    %{contacts_update: [%{id: "120363001234567890@g.us", img_url: :changed}]}}

    assert_receive {:events,
                    %{
                      messages_upsert: %{
                        messages: [
                          %{
                            message_stub_type: :GROUP_CHANGE_ICON,
                            message_stub_parameters: ["picture-1"],
                            participant: "15551234567@s.whatsapp.net"
                          }
                        ]
                      }
                    }}

    disappearing_node = %BinaryNode{
      tag: "notification",
      attrs: %{"type" => "account_sync", "from" => "s.whatsapp.net"},
      content: [
        %BinaryNode{
          tag: "disappearing_mode",
          attrs: %{"duration" => "86400", "t" => "1710000702"},
          content: nil
        }
      ]
    }

    assert :ok =
             apply(BaileysEx.Message.NotificationHandler, :process_node, [
               disappearing_node,
               %{event_emitter: emitter}
             ])

    assert_receive {:events,
                    %{
                      creds_update: %{
                        account_settings: %{
                          default_disappearing_mode: %{
                            ephemeral_expiration: 86_400,
                            ephemeral_setting_timestamp: 1_710_000_702
                          }
                        }
                      }
                    }}

    blocklist_node = %BinaryNode{
      tag: "notification",
      attrs: %{"type" => "account_sync", "from" => "s.whatsapp.net"},
      content: [
        %BinaryNode{
          tag: "blocklist",
          attrs: %{},
          content: [
            %BinaryNode{
              tag: "item",
              attrs: %{"jid" => "15551234567@s.whatsapp.net", "action" => "block"}
            },
            %BinaryNode{
              tag: "item",
              attrs: %{"jid" => "15557654321@s.whatsapp.net", "action" => "unblock"}
            }
          ]
        }
      ]
    }

    assert :ok =
             apply(BaileysEx.Message.NotificationHandler, :process_node, [
               blocklist_node,
               %{event_emitter: emitter}
             ])

    assert_receive {:events,
                    %{blocklist_update: %{blocklist: ["15551234567@s.whatsapp.net"], type: :add}}}

    assert_receive {:events,
                    %{
                      blocklist_update: %{
                        blocklist: ["15557654321@s.whatsapp.net"],
                        type: :remove
                      }
                    }}

    unsubscribe.()
  end

  test "process_node/2 emits media retry updates" do
    {:ok, emitter} = EventEmitter.start_link()
    parent = self()
    unsubscribe = EventEmitter.process(emitter, &send(parent, {:events, &1}))
    ciphertext = <<1, 2, 3, 4, 5>>
    iv = <<6, 7, 8, 9>>

    node = %BinaryNode{
      tag: "notification",
      attrs: %{
        "type" => "mediaretry",
        "id" => "media-1"
      },
      content: [
        %BinaryNode{
          tag: "encrypt",
          attrs: %{},
          content: [
            %BinaryNode{tag: "enc_p", attrs: %{}, content: {:binary, ciphertext}},
            %BinaryNode{tag: "enc_iv", attrs: %{}, content: {:binary, iv}}
          ]
        },
        %BinaryNode{
          tag: "rmr",
          attrs: %{
            "jid" => "15551234567@s.whatsapp.net",
            "from_me" => "false",
            "participant" => "15551234567:1@s.whatsapp.net"
          },
          content: nil
        }
      ]
    }

    assert :ok =
             apply(BaileysEx.Message.NotificationHandler, :process_node, [
               node,
               %{event_emitter: emitter}
             ])

    assert_receive {:events,
                    %{
                      messages_media_update: [
                        %{
                          key: %{
                            id: "media-1",
                            remote_jid: "15551234567@s.whatsapp.net",
                            from_me: false,
                            participant: "15551234567:1@s.whatsapp.net"
                          },
                          media: %{ciphertext: ^ciphertext, iv: ^iv}
                        }
                      ]
                    }}

    unsubscribe.()
  end

  test "process_node/2 emits newsletter updates for reaction, participant, settings, and plaintext messages" do
    {:ok, emitter} = EventEmitter.start_link()
    parent = self()
    unsubscribe = EventEmitter.process(emitter, &send(parent, {:events, &1}))

    reaction_node = %BinaryNode{
      tag: "notification",
      attrs: %{
        "type" => "newsletter",
        "from" => "12345@newsletter",
        "participant" => "15551234567@s.whatsapp.net"
      },
      content: [
        %BinaryNode{
          tag: "reaction",
          attrs: %{"message_id" => "server-1"},
          content: [%BinaryNode{tag: "reaction", attrs: %{}, content: "👍"}]
        }
      ]
    }

    assert :ok =
             apply(BaileysEx.Message.NotificationHandler, :process_node, [
               reaction_node,
               %{event_emitter: emitter}
             ])

    assert_receive {:events,
                    %{
                      newsletter_reaction: %{
                        id: "12345@newsletter",
                        server_id: "server-1",
                        reaction: %{code: "👍", count: 1}
                      }
                    }}

    participant_node = %BinaryNode{
      tag: "notification",
      attrs: %{
        "type" => "newsletter",
        "from" => "12345@newsletter",
        "participant" => "15551234567@s.whatsapp.net"
      },
      content: [
        %BinaryNode{
          tag: "participant",
          attrs: %{
            "jid" => "17770000000@s.whatsapp.net",
            "action" => "add",
            "role" => "SUBSCRIBER"
          },
          content: nil
        }
      ]
    }

    assert :ok =
             apply(BaileysEx.Message.NotificationHandler, :process_node, [
               participant_node,
               %{event_emitter: emitter}
             ])

    assert_receive {:events,
                    %{
                      newsletter_participants_update: %{
                        id: "12345@newsletter",
                        user: "17770000000@s.whatsapp.net"
                      }
                    }}

    settings_node = %BinaryNode{
      tag: "notification",
      attrs: %{"type" => "newsletter", "from" => "12345@newsletter"},
      content: [
        %BinaryNode{
          tag: "update",
          attrs: %{},
          content: [
            %BinaryNode{
              tag: "settings",
              attrs: %{},
              content: [
                %BinaryNode{tag: "name", attrs: %{}, content: "Digest"},
                %BinaryNode{tag: "description", attrs: %{}, content: "Weekly"}
              ]
            }
          ]
        }
      ]
    }

    assert :ok =
             apply(BaileysEx.Message.NotificationHandler, :process_node, [
               settings_node,
               %{event_emitter: emitter}
             ])

    assert_receive {:events,
                    %{
                      newsletter_settings_update: %{
                        id: "12345@newsletter",
                        update: %{name: "Digest", description: "Weekly"}
                      }
                    }}

    plaintext_message = Builder.build(%{text: "newsletter post"})

    message_node = %BinaryNode{
      tag: "notification",
      attrs: %{"type" => "newsletter", "from" => "12345@newsletter"},
      content: [
        %BinaryNode{
          tag: "message",
          attrs: %{
            "message_id" => "newsletter-msg-1",
            "server_id" => "newsletter-msg-1",
            "t" => "1710000703"
          },
          content: [
            %BinaryNode{tag: "plaintext", attrs: %{}, content: Message.encode(plaintext_message)}
          ]
        }
      ]
    }

    assert :ok =
             apply(BaileysEx.Message.NotificationHandler, :process_node, [
               message_node,
               %{event_emitter: emitter}
             ])

    assert_receive {:events,
                    %{
                      messages_upsert: %{
                        messages: [
                          %{
                            key: %{
                              remote_jid: "12345@newsletter",
                              id: "newsletter-msg-1",
                              from_me: false
                            }
                          }
                        ]
                      }
                    }}

    unsubscribe.()
  end

  test "process_node/2 emits mex newsletter updates" do
    {:ok, emitter} = EventEmitter.start_link()
    parent = self()
    unsubscribe = EventEmitter.process(emitter, &send(parent, {:events, &1}))

    update_payload =
      JSON.encode!(%{
        operation: "NotificationNewsletterUpdate",
        updates: [%{jid: "12345@newsletter", settings: %{name: "Updated"}}]
      })

    update_node = %BinaryNode{
      tag: "notification",
      attrs: %{"type" => "mex", "from" => "12345@newsletter"},
      content: [%BinaryNode{tag: "mex", attrs: %{}, content: update_payload}]
    }

    assert :ok =
             apply(BaileysEx.Message.NotificationHandler, :process_node, [
               update_node,
               %{event_emitter: emitter}
             ])

    assert_receive {:events,
                    %{
                      newsletter_settings_update: %{
                        id: "12345@newsletter",
                        update: %{"name" => "Updated"}
                      }
                    }}

    promote_payload =
      JSON.encode!(%{
        operation: "NotificationNewsletterAdminPromote",
        updates: [%{jid: "12345@newsletter", user: "17770000000@s.whatsapp.net"}]
      })

    promote_node = %BinaryNode{
      tag: "notification",
      attrs: %{"type" => "mex", "from" => "15551234567@s.whatsapp.net"},
      content: [%BinaryNode{tag: "mex", attrs: %{}, content: promote_payload}]
    }

    assert :ok =
             apply(BaileysEx.Message.NotificationHandler, :process_node, [
               promote_node,
               %{event_emitter: emitter}
             ])

    assert_receive {:events,
                    %{
                      newsletter_participants_update: %{
                        id: "12345@newsletter",
                        user: "17770000000@s.whatsapp.net",
                        new_role: "ADMIN"
                      }
                    }}

    unsubscribe.()
  end

  test "process_node/2 recognizes passive notification types and stores privacy tokens via callback" do
    token_parent = self()

    for node <- [
          %BinaryNode{
            tag: "notification",
            attrs: %{"type" => "encrypt", "from" => "s.whatsapp.net"},
            content: [%BinaryNode{tag: "identity", attrs: %{}, content: nil}]
          },
          %BinaryNode{
            tag: "notification",
            attrs: %{"type" => "devices", "from" => "s.whatsapp.net"},
            content: [
              %BinaryNode{
                tag: "devices",
                attrs: %{"jid" => "15551234567@s.whatsapp.net"},
                content: nil
              }
            ]
          },
          %BinaryNode{
            tag: "notification",
            attrs: %{"type" => "server_sync", "from" => "s.whatsapp.net"},
            content: [
              %BinaryNode{tag: "collection", attrs: %{"name" => "regular_high"}, content: nil}
            ]
          },
          %BinaryNode{
            tag: "notification",
            attrs: %{"type" => "link_code_companion_reg", "from" => "s.whatsapp.net"},
            content: [%BinaryNode{tag: "link_code_companion_reg", attrs: %{}, content: nil}]
          }
        ] do
      assert :ok =
               apply(BaileysEx.Message.NotificationHandler, :process_node, [
                 node,
                 %{}
               ])
    end

    privacy_token_node = %BinaryNode{
      tag: "notification",
      attrs: %{"type" => "privacy_token", "from" => "15551234567@s.whatsapp.net"},
      content: [
        %BinaryNode{
          tag: "tokens",
          attrs: %{},
          content: [
            %BinaryNode{
              tag: "token",
              attrs: %{"type" => "trusted_contact", "t" => "1710000704"},
              content: {:binary, "token-1"}
            }
          ]
        }
      ]
    }

    assert :ok =
             apply(BaileysEx.Message.NotificationHandler, :process_node, [
               privacy_token_node,
               %{
                 store_privacy_token_fun: fn jid, token, timestamp ->
                   send(token_parent, {:privacy_token, jid, token, timestamp})
                   :ok
                 end
               }
             ])

    assert_receive {:privacy_token, "15551234567@s.whatsapp.net", "token-1", "1710000704"}
  end

  test "process_node/2 swallows server_sync resync failures and returns :ok" do
    node = %BinaryNode{
      tag: "notification",
      attrs: %{"type" => "server_sync", "from" => "s.whatsapp.net"},
      content: [
        %BinaryNode{tag: "collection", attrs: %{"name" => "regular_high"}, content: nil}
      ]
    }

    log =
      capture_log(fn ->
        assert :ok =
                 apply(BaileysEx.Message.NotificationHandler, :process_node, [
                   node,
                   %{resync_app_state_fun: fn "regular_high" -> {:error, :decrypt_failed} end}
                 ])
      end)

    assert log =~ "server_sync resync failed"
    assert log =~ ":decrypt_failed"
  end
end
