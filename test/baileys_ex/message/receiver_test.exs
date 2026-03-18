defmodule BaileysEx.Message.ReceiverTest do
  use ExUnit.Case, async: true

  alias BaileysEx.BinaryNode
  alias BaileysEx.Connection.EventEmitter
  alias BaileysEx.Connection.Store, as: ConnectionStore
  alias BaileysEx.Message.Builder
  alias BaileysEx.Message.Retry
  alias BaileysEx.Message.Receiver
  alias BaileysEx.Protocol.Proto.Conversation
  alias BaileysEx.Protocol.Proto.HistorySync, as: HistorySyncProto
  alias BaileysEx.Protocol.Proto.HistorySyncMsg
  alias BaileysEx.Protocol.Proto.Wire
  alias BaileysEx.Protocol.Proto.Message
  alias BaileysEx.Protocol.Proto.MessageContextInfo
  alias BaileysEx.Protocol.Proto.MessageKey
  alias BaileysEx.Protocol.Proto.PhoneNumberToLIDMapping
  alias BaileysEx.Protocol.Proto.WebMessageInfo
  alias BaileysEx.Signal.Store
  alias BaileysEx.Signal.Repository
  alias BaileysEx.TestHelpers.MessageSignalHelpers
  alias BaileysEx.TestHelpers.TelemetryHelpers

  test "process_node/3 decrypts a direct message node and emits messages_upsert" do
    assert {:ok, emitter} = EventEmitter.start_link()

    parent = self()
    unsubscribe = EventEmitter.process(emitter, &send(parent, {:events, &1}))

    {repo, _store} = MessageSignalHelpers.new_repo()
    session = MessageSignalHelpers.session_fixture()

    assert {:ok, repo} =
             Repository.inject_e2e_session(repo, %{
               jid: "15551234567:1@s.whatsapp.net",
               session: session
             })

    plaintext = Builder.build(%{text: "hello from peer"}) |> Message.encode()

    assert {:ok, repo, %{ciphertext: ciphertext}} =
             Repository.encrypt_message(repo, %{
               jid: "15551234567:1@s.whatsapp.net",
               data: plaintext
             })

    node = %BinaryNode{
      tag: "message",
      attrs: %{
        "id" => "msg-1",
        "from" => "15551234567@s.whatsapp.net",
        "participant" => "15551234567:1@s.whatsapp.net",
        "t" => "1710000000"
      },
      content: [
        %BinaryNode{tag: "enc", attrs: %{"type" => "pkmsg"}, content: {:binary, ciphertext}}
      ]
    }

    context = %{
      signal_repository: repo,
      event_emitter: emitter,
      me_id: "15550001111@s.whatsapp.net",
      me_lid: "15550001111@lid",
      send_receipt_fun: fn receipt_node ->
        send(parent, {:receipt, receipt_node})
        :ok
      end
    }

    assert {:ok,
            %{
              message: %Message{
                extended_text_message: %Message.ExtendedTextMessage{text: "hello from peer"}
              }
            }, %{signal_repository: %Repository{}}} = Receiver.process_node(node, context)

    assert_receive {:events,
                    %{
                      messages_upsert: %{
                        type: :notify,
                        messages: [
                          %{
                            message: %Message{
                              extended_text_message: %Message.ExtendedTextMessage{
                                text: "hello from peer"
                              }
                            }
                          }
                        ]
                      }
                    }}

    assert_receive {:receipt,
                    %BinaryNode{
                      tag: "receipt",
                      attrs: %{
                        "id" => "msg-1",
                        "to" => "15551234567@s.whatsapp.net",
                        "participant" => "15551234567:1@s.whatsapp.net"
                      }
                    }}

    unsubscribe.()
  end

  test "process_node/3 stores PN to LID mappings from lid-addressed direct messages" do
    assert {:ok, emitter} = EventEmitter.start_link()

    parent = self()
    unsubscribe = EventEmitter.process(emitter, &send(parent, {:events, &1}))

    {repo, store} = MessageSignalHelpers.new_repo()
    session = MessageSignalHelpers.session_fixture()

    assert :ok = Store.set(store, %{:"device-list" => %{"15551234567" => ["0"]}})

    assert {:ok, repo} =
             Repository.inject_e2e_session(repo, %{
               jid: "15551234567:0@s.whatsapp.net",
               session: session
             })

    node = %BinaryNode{
      tag: "message",
      attrs: %{
        "id" => "msg-lid-map-1",
        "from" => "12345@lid",
        "sender_pn" => "15551234567@s.whatsapp.net",
        "addressing_mode" => "lid",
        "t" => "1710000001"
      },
      content: [
        %BinaryNode{
          tag: "plaintext",
          attrs: %{},
          content: Message.encode(Builder.build(%{text: "hello from lid peer"}))
        }
      ]
    }

    context = %{
      signal_repository: repo,
      event_emitter: emitter,
      me_id: "15550001111@s.whatsapp.net",
      me_lid: "15550001111@lid"
    }

    assert {:ok, _message, %{signal_repository: updated_repo}} =
             Receiver.process_node(node, context)

    assert {:ok, ^updated_repo, "12345@lid"} =
             Repository.get_lid_for_pn(updated_repo, "15551234567@s.whatsapp.net")

    assert {:ok, %{exists: true}} = Repository.validate_session(updated_repo, "12345:0@lid")

    unsubscribe.()
  end

  test "process_node/3 copies notify into push_name and emits contacts_update for peer messages" do
    assert {:ok, emitter} = EventEmitter.start_link()

    parent = self()
    unsubscribe = EventEmitter.process(emitter, &send(parent, {:events, &1}))

    {repo, _store} = MessageSignalHelpers.new_repo()

    node = %BinaryNode{
      tag: "message",
      attrs: %{
        "id" => "msg-push-name-peer",
        "from" => "15551234567@s.whatsapp.net",
        "participant" => "15551234567:1@s.whatsapp.net",
        "notify" => "Peer Push Name",
        "t" => "1710000002"
      },
      content: [
        %BinaryNode{
          tag: "plaintext",
          attrs: %{},
          content: Message.encode(Builder.build(%{text: "hello from peer"}))
        }
      ]
    }

    context = %{
      signal_repository: repo,
      event_emitter: emitter,
      me_id: "15550001111@s.whatsapp.net",
      me_lid: "15550001111@lid"
    }

    assert {:ok, %{push_name: "Peer Push Name"}, _context} = Receiver.process_node(node, context)

    assert_receive {:events,
                    %{
                      messages_upsert: %{
                        type: :notify,
                        messages: [%{push_name: "Peer Push Name"}]
                      }
                    }}

    assert_receive {:events,
                    %{
                      contacts_update: [
                        %{id: "15551234567@s.whatsapp.net", notify: "Peer Push Name"}
                      ]
                    }}

    unsubscribe.()
  end

  test "process_node/3 sends peer_msg receipts for peer-category messages" do
    assert {:ok, emitter} = EventEmitter.start_link()

    parent = self()
    unsubscribe = EventEmitter.process(emitter, &send(parent, {:events, &1}))

    {repo, _store} = MessageSignalHelpers.new_repo()

    node = %BinaryNode{
      tag: "message",
      attrs: %{
        "id" => "msg-peer-receipt-1",
        "from" => "15551234567@s.whatsapp.net",
        "category" => "peer",
        "t" => "1710000004"
      },
      content: [
        %BinaryNode{
          tag: "plaintext",
          attrs: %{},
          content:
            Message.encode(%Message{
              protocol_message: %Message.ProtocolMessage{
                type: :APP_STATE_SYNC_KEY_SHARE,
                app_state_sync_key_share: %Message.AppStateSyncKeyShare{keys: []}
              }
            })
        }
      ]
    }

    context = %{
      signal_repository: repo,
      event_emitter: emitter,
      me_id: "15550001111@s.whatsapp.net",
      me_lid: "15550001111@lid",
      send_receipt_fun: fn receipt_node ->
        send(parent, {:receipt, receipt_node})
        :ok
      end
    }

    assert {:ok, %{key: %{id: "msg-peer-receipt-1"}}, _context} =
             Receiver.process_node(node, context)

    assert_receive {:receipt,
                    %BinaryNode{
                      tag: "receipt",
                      attrs: %{
                        "id" => "msg-peer-receipt-1",
                        "to" => "15551234567@s.whatsapp.net",
                        "type" => "peer_msg"
                      }
                    }}

    unsubscribe.()
  end

  test "process_node/3 emits creds_update when a self message carries a new notify push name" do
    assert {:ok, emitter} = EventEmitter.start_link()

    parent = self()
    unsubscribe = EventEmitter.process(emitter, &send(parent, {:events, &1}))

    {repo, _store} = MessageSignalHelpers.new_repo()
    {:ok, runtime_store} = ConnectionStore.start_link(auth_state: %{me: %{name: "Old Name"}})
    runtime_store_ref = ConnectionStore.wrap(runtime_store)

    node = %BinaryNode{
      tag: "message",
      attrs: %{
        "id" => "msg-push-name-self",
        "from" => "15550001111@s.whatsapp.net",
        "recipient" => "15551234567@s.whatsapp.net",
        "notify" => "New Name",
        "t" => "1710000003"
      },
      content: [
        %BinaryNode{
          tag: "plaintext",
          attrs: %{},
          content: Message.encode(Builder.build(%{text: "hello from me"}))
        }
      ]
    }

    context = %{
      signal_repository: repo,
      event_emitter: emitter,
      me_id: "15550001111@s.whatsapp.net",
      me_lid: "15550001111@lid",
      store_ref: runtime_store_ref
    }

    assert {:ok, %{push_name: "New Name"}, _context} = Receiver.process_node(node, context)

    assert_receive {:events,
                    %{
                      messages_upsert: %{
                        type: :notify,
                        messages: [%{push_name: "New Name", key: %{from_me: true}}]
                      }
                    }}

    assert_receive {:events, %{creds_update: %{me: %{name: "New Name"}}}}

    refute_receive {:events, %{contacts_update: _contacts}}

    unsubscribe.()
  end

  test "process_node/3 decrypts a group skmsg node" do
    assert {:ok, emitter} = EventEmitter.start_link()

    parent = self()
    unsubscribe = EventEmitter.process(emitter, &send(parent, {:events, &1}))

    {sender_repo, _store} = MessageSignalHelpers.new_repo()
    {recipient_repo, _recipient_store} = MessageSignalHelpers.new_repo()

    plaintext = Builder.build(%{text: "hello group"}) |> Message.encode()

    assert {:ok, _sender_repo,
            %{ciphertext: ciphertext, sender_key_distribution_message: distribution}} =
             Repository.encrypt_group_message(sender_repo, %{
               group: "120363001234567890@g.us",
               me_id: "15551234567@s.whatsapp.net",
               data: plaintext
             })

    assert {:ok, recipient_repo} =
             Repository.process_sender_key_distribution_message(recipient_repo, %{
               author_jid: "15551234567@s.whatsapp.net",
               item: %{
                 group_id: "120363001234567890@g.us",
                 axolotl_sender_key_distribution_message: distribution
               }
             })

    node = %BinaryNode{
      tag: "message",
      attrs: %{
        "id" => "group-msg-1",
        "from" => "120363001234567890@g.us",
        "participant" => "15551234567@s.whatsapp.net",
        "t" => "1710000001"
      },
      content: [
        %BinaryNode{tag: "enc", attrs: %{"type" => "skmsg"}, content: {:binary, ciphertext}}
      ]
    }

    context = %{
      signal_repository: recipient_repo,
      event_emitter: emitter,
      me_id: "15550001111@s.whatsapp.net",
      me_lid: "15550001111@lid",
      send_receipt_fun: fn receipt_node ->
        send(parent, {:receipt, receipt_node})
        :ok
      end
    }

    assert {:ok,
            %{
              key: %{
                remote_jid: "120363001234567890@g.us",
                participant: "15551234567@s.whatsapp.net"
              }
            }, %{signal_repository: %Repository{}}} = Receiver.process_node(node, context)

    assert_receive {:events,
                    %{
                      messages_upsert: %{
                        messages: [%{key: %{remote_jid: "120363001234567890@g.us"}}]
                      }
                    }}

    assert_receive {:receipt,
                    %BinaryNode{
                      tag: "receipt",
                      attrs: %{
                        "id" => "group-msg-1",
                        "to" => "120363001234567890@g.us",
                        "participant" => "15551234567@s.whatsapp.net"
                      }
                    }}

    unsubscribe.()
  end

  test "process_node/3 ingests sender key distribution messages for subsequent group skmsg nodes" do
    assert {:ok, emitter} = EventEmitter.start_link()

    {sender_repo, _sender_store} = MessageSignalHelpers.new_repo()
    {recipient_repo, _recipient_store} = MessageSignalHelpers.new_repo()
    session = MessageSignalHelpers.session_fixture()

    sender_device_jid = "15551234567:1@s.whatsapp.net"
    group_jid = "120363001234567890@g.us"

    assert {:ok, recipient_repo} =
             Repository.inject_e2e_session(recipient_repo, %{
               jid: sender_device_jid,
               session: session
             })

    plaintext = Builder.build(%{text: "hello after distribution"}) |> Message.encode()

    assert {:ok, _sender_repo,
            %{ciphertext: group_ciphertext, sender_key_distribution_message: distribution}} =
             Repository.encrypt_group_message(sender_repo, %{
               group: group_jid,
               me_id: sender_device_jid,
               data: plaintext
             })

    distribution_plaintext =
      %Message{
        sender_key_distribution_message: %Message.SenderKeyDistributionMessage{
          group_id: group_jid,
          axolotl_sender_key_distribution_message: distribution
        }
      }
      |> Message.encode()

    assert {:ok, recipient_repo, %{ciphertext: distribution_ciphertext}} =
             Repository.encrypt_message(recipient_repo, %{
               jid: sender_device_jid,
               data: distribution_plaintext
             })

    distribution_node = %BinaryNode{
      tag: "message",
      attrs: %{
        "id" => "dist-1",
        "from" => "15551234567@s.whatsapp.net",
        "participant" => sender_device_jid,
        "t" => "1710000001"
      },
      content: [
        %BinaryNode{
          tag: "enc",
          attrs: %{"type" => "pkmsg"},
          content: {:binary, distribution_ciphertext}
        }
      ]
    }

    context = %{
      signal_repository: recipient_repo,
      event_emitter: emitter,
      me_id: "15550001111@s.whatsapp.net",
      me_lid: "15550001111@lid"
    }

    assert {:ok,
            %{
              message: %Message{
                sender_key_distribution_message: %Message.SenderKeyDistributionMessage{
                  group_id: ^group_jid
                }
              }
            }, %{signal_repository: recipient_repo}} =
             Receiver.process_node(distribution_node, context)

    group_node = %BinaryNode{
      tag: "message",
      attrs: %{
        "id" => "group-msg-2",
        "from" => group_jid,
        "participant" => sender_device_jid,
        "t" => "1710000002"
      },
      content: [
        %BinaryNode{tag: "enc", attrs: %{"type" => "skmsg"}, content: {:binary, group_ciphertext}}
      ]
    }

    assert {:ok,
            %{
              message: %Message{
                extended_text_message: %Message.ExtendedTextMessage{
                  text: "hello after distribution"
                }
              }
            }, %{signal_repository: %Repository{}}} =
             Receiver.process_node(group_node, %{context | signal_repository: recipient_repo})
  end

  test "process_node/3 caches recently received messages when runtime retry cache is enabled" do
    assert {:ok, emitter} = EventEmitter.start_link()

    {repo, _store} = MessageSignalHelpers.new_repo()
    {:ok, runtime_store} = ConnectionStore.start_link()
    runtime_store_ref = ConnectionStore.wrap(runtime_store)
    session = MessageSignalHelpers.session_fixture()

    assert {:ok, repo} =
             Repository.inject_e2e_session(repo, %{
               jid: "15551234567:1@s.whatsapp.net",
               session: session
             })

    plaintext = Builder.build(%{text: "cache received"}) |> Message.encode()

    assert {:ok, repo, %{ciphertext: ciphertext}} =
             Repository.encrypt_message(repo, %{
               jid: "15551234567:1@s.whatsapp.net",
               data: plaintext
             })

    node = %BinaryNode{
      tag: "message",
      attrs: %{
        "id" => "msg-cache-recv",
        "from" => "15551234567@s.whatsapp.net",
        "participant" => "15551234567:1@s.whatsapp.net",
        "t" => "1710000003"
      },
      content: [
        %BinaryNode{tag: "enc", attrs: %{"type" => "pkmsg"}, content: {:binary, ciphertext}}
      ]
    }

    context = %{
      enable_recent_message_cache: true,
      signal_repository: repo,
      event_emitter: emitter,
      me_id: "15550001111@s.whatsapp.net",
      me_lid: "15550001111@lid",
      store_ref: runtime_store_ref
    }

    assert {:ok, _message, _context} = Receiver.process_node(node, context)

    assert %{
             message: %Message{
               extended_text_message: %Message.ExtendedTextMessage{text: "cache received"}
             }
           } =
             Retry.get_recent_message(
               runtime_store_ref,
               "15551234567@s.whatsapp.net",
               "msg-cache-recv"
             )
  end

  test "process_node/3 emits receive telemetry" do
    assert {:ok, emitter} = EventEmitter.start_link()

    telemetry_id =
      TelemetryHelpers.attach_events(self(), [
        [:baileys_ex, :message, :receive]
      ])

    on_exit(fn -> TelemetryHelpers.detach(telemetry_id) end)

    {repo, _store} = MessageSignalHelpers.new_repo()
    session = MessageSignalHelpers.session_fixture()

    assert {:ok, repo} =
             Repository.inject_e2e_session(repo, %{
               jid: "15551234567:1@s.whatsapp.net",
               session: session
             })

    plaintext = Builder.build(%{text: "telemetry receive"}) |> Message.encode()

    assert {:ok, repo, %{ciphertext: ciphertext}} =
             Repository.encrypt_message(repo, %{
               jid: "15551234567:1@s.whatsapp.net",
               data: plaintext
             })

    node = %BinaryNode{
      tag: "message",
      attrs: %{
        "id" => "msg-telemetry",
        "from" => "15551234567@s.whatsapp.net",
        "participant" => "15551234567:1@s.whatsapp.net",
        "t" => "1710000002"
      },
      content: [
        %BinaryNode{tag: "enc", attrs: %{"type" => "pkmsg"}, content: {:binary, ciphertext}}
      ]
    }

    context = %{
      signal_repository: repo,
      event_emitter: emitter,
      me_id: "15550001111@s.whatsapp.net",
      me_lid: "15550001111@lid"
    }

    assert {:ok, _message, _context} = Receiver.process_node(node, context)

    assert_receive {:telemetry, [:baileys_ex, :message, :receive], %{count: 1},
                    %{
                      message_id: "msg-telemetry",
                      remote_jid: "15551234567@s.whatsapp.net"
                    }}
  end

  test "process_node/3 emits protocol-message side effects for revoke, edit, ephemeral settings, and app-state sync key shares" do
    {:ok, emitter} = EventEmitter.start_link()
    parent = self()
    unsubscribe = EventEmitter.process(emitter, &send(parent, {:events, &1}))

    {repo, store} = MessageSignalHelpers.new_repo()
    key_id = <<1, 2, 3, 4, 5, 6, 7, 8>>
    key_data = <<29::256>>

    proto_message = %Message{
      protocol_message: %Message.ProtocolMessage{
        type: :APP_STATE_SYNC_KEY_SHARE,
        app_state_sync_key_share: %Message.AppStateSyncKeyShare{
          keys: [
            %Message.AppStateSyncKey{
              key_id: %Message.AppStateSyncKeyId{key_id: key_id},
              key_data: %Message.AppStateSyncKeyData{key_data: key_data}
            }
          ]
        }
      }
    }

    node = %BinaryNode{
      tag: "message",
      attrs: %{
        "id" => "proto-app-state-1",
        "from" => "15551234567@s.whatsapp.net",
        "t" => "1710000500"
      },
      content: [%BinaryNode{tag: "plaintext", attrs: %{}, content: Message.encode(proto_message)}]
    }

    context = %{
      signal_repository: repo,
      signal_store: store,
      event_emitter: emitter,
      me_id: "15550001111@s.whatsapp.net",
      me_lid: "15550001111@lid"
    }

    assert {:ok, %{message: %Message{}}, %{signal_repository: %Repository{}}} =
             Receiver.process_node(node, context)

    key_id_b64 = Base.encode64(key_id)
    assert %{^key_id_b64 => ^key_data} = Store.get(store, :"app-state-sync-key", [key_id_b64])

    assert_receive {:events, %{creds_update: %{my_app_state_key_id: ^key_id_b64}}}

    revoke_message = %Message{
      protocol_message: %Message.ProtocolMessage{
        type: :REVOKE,
        key: %MessageKey{id: "target-1"}
      }
    }

    revoke_node = %BinaryNode{
      tag: "message",
      attrs: %{
        "id" => "proto-revoke-1",
        "from" => "15551234567@s.whatsapp.net",
        "t" => "1710000501"
      },
      content: [
        %BinaryNode{tag: "plaintext", attrs: %{}, content: Message.encode(revoke_message)}
      ]
    }

    assert {:ok, _message, _context} = Receiver.process_node(revoke_node, context)

    assert_receive {:events,
                    %{
                      messages_update: [
                        %{
                          key: %{id: "target-1"},
                          update: %{message: nil, message_stub_type: :REVOKE}
                        }
                      ]
                    }}

    edit_message = %Message{
      protocol_message: %Message.ProtocolMessage{
        type: :MESSAGE_EDIT,
        key: %MessageKey{id: "target-2"},
        edited_message: Builder.build(%{text: "edited body"}),
        timestamp_ms: 1_710_000_502_000
      }
    }

    edit_node = %BinaryNode{
      tag: "message",
      attrs: %{
        "id" => "proto-edit-1",
        "from" => "15551234567@s.whatsapp.net",
        "t" => "1710000502"
      },
      content: [%BinaryNode{tag: "plaintext", attrs: %{}, content: Message.encode(edit_message)}]
    }

    assert {:ok, _message, _context} = Receiver.process_node(edit_node, context)

    assert_receive {:events,
                    %{
                      messages_update: [
                        %{
                          key: %{id: "target-2"},
                          update: %{
                            message: %{
                              edited_message: %{
                                message: %Message{
                                  extended_text_message: %Message.ExtendedTextMessage{
                                    text: "edited body"
                                  }
                                }
                              }
                            },
                            message_timestamp: 1_710_000_502
                          }
                        }
                      ]
                    }}

    ephemeral_message = %Message{
      protocol_message: %Message.ProtocolMessage{
        type: :EPHEMERAL_SETTING,
        ephemeral_expiration: 604_800
      }
    }

    ephemeral_node = %BinaryNode{
      tag: "message",
      attrs: %{
        "id" => "proto-ephemeral-1",
        "from" => "15551234567@s.whatsapp.net",
        "t" => "1710000503"
      },
      content: [
        %BinaryNode{tag: "plaintext", attrs: %{}, content: Message.encode(ephemeral_message)}
      ]
    }

    assert {:ok, _message, _context} = Receiver.process_node(ephemeral_node, context)

    assert_receive {:events,
                    %{
                      chats_update: [
                        %{
                          id: "15551234567@s.whatsapp.net",
                          ephemeral_expiration: 604_800,
                          ephemeral_setting_timestamp: 1_710_000_503
                        }
                      ]
                    }}

    unsubscribe.()
  end

  test "process_node/3 emits history-sync events and persists processed history metadata" do
    {:ok, emitter} = EventEmitter.start_link()
    parent = self()
    unsubscribe = EventEmitter.process(emitter, &send(parent, {:events, &1}))

    {repo, _store} = MessageSignalHelpers.new_repo()

    {:ok, runtime_store} =
      ConnectionStore.start_link(auth_state: %{processed_history_messages: []})

    runtime_store_ref = ConnectionStore.wrap(runtime_store)

    history_message = %Message{
      protocol_message: %Message.ProtocolMessage{
        type: :HISTORY_SYNC_NOTIFICATION,
        history_sync_notification: %Message.HistorySyncNotification{
          sync_type: :INITIAL_BOOTSTRAP,
          progress: 77,
          peer_data_request_session_id: "pdo-session-1"
        }
      }
    }

    node = %BaileysEx.BinaryNode{
      tag: "message",
      attrs: %{
        "id" => "hist-1",
        "from" => "15551234567@s.whatsapp.net",
        "t" => "1710000600"
      },
      content: [
        %BaileysEx.BinaryNode{
          tag: "plaintext",
          attrs: %{},
          content: Message.encode(history_message)
        }
      ]
    }

    context = %{
      signal_repository: repo,
      event_emitter: emitter,
      me_id: "15550001111@s.whatsapp.net",
      me_lid: "15550001111@lid",
      store_ref: runtime_store_ref,
      send_receipt_fun: fn receipt_node ->
        send(parent, {:receipt, receipt_node})
        :ok
      end,
      history_sync_fun: fn notification, received_message, _context ->
        assert notification.sync_type == :INITIAL_BOOTSTRAP
        assert received_message.key.id == "hist-1"

        {:ok,
         %{
           chats: [%{id: "chat-1"}],
           contacts: [%{id: "15551234567@s.whatsapp.net"}],
           messages: [%{key: %{id: "hist-msg-1"}}],
           lid_pn_mappings: [%{lid: "12345@lid", pn: "15551234567@s.whatsapp.net"}],
           progress: notification.progress,
           sync_type: notification.sync_type,
           peer_data_request_session_id: notification.peer_data_request_session_id
         }}
      end
    }

    assert {:ok, _message, _context} = Receiver.process_node(node, context)

    assert_receive {:events, %{creds_update: %{processed_history_messages: [processed]}}}
    assert processed.key.id == "hist-1"
    assert processed.message_timestamp == 1_710_000_600

    assert_receive {:events,
                    %{
                      messaging_history_set: %{
                        chats: [%{id: "chat-1"}],
                        contacts: [%{id: "15551234567@s.whatsapp.net"}],
                        messages: [%{key: %{id: "hist-msg-1"}}],
                        lid_pn_mappings: [%{lid: "12345@lid", pn: "15551234567@s.whatsapp.net"}],
                        is_latest: true,
                        progress: 77,
                        sync_type: :INITIAL_BOOTSTRAP,
                        peer_data_request_session_id: "pdo-session-1"
                      }
                    }}

    assert_receive {:receipt,
                    %BinaryNode{
                      tag: "receipt",
                      attrs: %{
                        "id" => "hist-1",
                        "to" => "15551234567@s.whatsapp.net"
                      }
                    }}

    assert_receive {:receipt,
                    %BinaryNode{
                      tag: "receipt",
                      attrs: %{
                        "id" => "hist-1",
                        "to" => "15551234567@s.whatsapp.net",
                        "type" => "hist_sync"
                      }
                    }}

    unsubscribe.()
  end

  test "process_node/3 falls back to the history-sync module when no custom callback is configured" do
    {:ok, emitter} = EventEmitter.start_link()
    parent = self()
    unsubscribe = EventEmitter.process(emitter, &send(parent, {:events, &1}))

    {repo, _store} = MessageSignalHelpers.new_repo()

    {:ok, runtime_store} =
      ConnectionStore.start_link(auth_state: %{processed_history_messages: []})

    notification_payload =
      %HistorySyncProto{
        sync_type: :INITIAL_BOOTSTRAP,
        progress: 55,
        phone_number_to_lid_mappings: [
          %PhoneNumberToLIDMapping{
            pn_jid: "15551234567@s.whatsapp.net",
            lid_jid: "12345@lid"
          }
        ],
        conversations: [
          %Conversation{
            id: "12345@lid",
            display_name: "History Chat",
            messages: [
              %HistorySyncMsg{
                message: %WebMessageInfo{
                  key: %MessageKey{
                    remote_jid: "12345@lid",
                    id: "hist-inline-1",
                    from_me: false
                  },
                  message: Builder.build(%{text: "inline history"}),
                  message_timestamp: 1_710_000_640
                }
              }
            ]
          }
        ]
      }
      |> HistorySyncProto.encode()

    history_message = %Message{
      protocol_message: %Message.ProtocolMessage{
        type: :HISTORY_SYNC_NOTIFICATION,
        history_sync_notification:
          %Message.HistorySyncNotification{
            sync_type: :INITIAL_BOOTSTRAP,
            progress: 55,
            peer_data_request_session_id: "pdo-inline"
          }
          |> Map.put(:initial_hist_bootstrap_inline_payload, notification_payload)
      }
    }

    node = %BinaryNode{
      tag: "message",
      attrs: %{
        "id" => "hist-inline",
        "from" => "15551234567@s.whatsapp.net",
        "t" => "1710000639"
      },
      content: [
        %BinaryNode{
          tag: "plaintext",
          attrs: %{},
          content: Message.encode(history_message)
        }
      ]
    }

    context = %{
      signal_repository: repo,
      event_emitter: emitter,
      me_id: "15550001111@s.whatsapp.net",
      me_lid: "15550001111@lid",
      store_ref: ConnectionStore.wrap(runtime_store),
      inflate_fun: fn payload -> {:ok, payload} end
    }

    assert {:ok, _message, _context} = Receiver.process_node(node, context)

    assert_receive {:events,
                    %{
                      messaging_history_set: %{
                        chats: [%{id: "12345@lid"}],
                        contacts: [%{id: "12345@lid", name: "History Chat"}],
                        messages: [%{key: %{id: "hist-inline-1"}}],
                        lid_pn_mappings: [
                          %{lid: "12345@lid", pn: "15551234567@s.whatsapp.net"}
                        ],
                        is_latest: true,
                        progress: 55,
                        sync_type: :INITIAL_BOOTSTRAP,
                        peer_data_request_session_id: "pdo-inline"
                      }
                    }}

    unsubscribe.()
  end

  test "process_node/3 emits PDO placeholder resend upserts using cached message metadata" do
    {:ok, emitter} = EventEmitter.start_link()
    parent = self()
    unsubscribe = EventEmitter.process(emitter, &send(parent, {:events, &1}))

    {repo, _store} = MessageSignalHelpers.new_repo()
    {:ok, runtime_store} = ConnectionStore.start_link()
    runtime_store_ref = ConnectionStore.wrap(runtime_store)

    :ok =
      Retry.put_placeholder_resend(runtime_store_ref, "pdo-msg-1", %{
        key: %{
          remote_jid: "15551234567@s.whatsapp.net",
          remote_jid_alt: "12345@lid",
          participant: "15551234567:1@s.whatsapp.net",
          participant_alt: "12345:1@lid",
          from_me: false,
          id: "pdo-msg-1"
        },
        message_timestamp: 1_710_000_601,
        push_name: "Phone Cache"
      })

    web_message_info =
      %WebMessageInfo{
        key: %MessageKey{
          remote_jid: "15551234567@s.whatsapp.net",
          from_me: false,
          id: "pdo-msg-1",
          participant: "15551234567:1@s.whatsapp.net"
        },
        message: Builder.build(%{text: "restored"}),
        message_timestamp: 1_710_000_602,
        push_name: "Phone Payload"
      }
      |> WebMessageInfo.encode()

    pdo_message = %Message{
      protocol_message: %Message.ProtocolMessage{
        type: :PEER_DATA_OPERATION_REQUEST_RESPONSE_MESSAGE,
        peer_data_operation_request_response_message:
          %Message.PeerDataOperationRequestResponseMessage{
            stanza_id: "request-123",
            peer_data_operation_result: [
              %Message.PeerDataOperationRequestResponseMessage.PeerDataOperationResult{
                placeholder_message_resend_response:
                  %Message.PeerDataOperationRequestResponseMessage.PeerDataOperationResult.PlaceholderMessageResendResponse{
                    web_message_info_bytes: web_message_info
                  }
              }
            ]
          }
      }
    }

    node = %BaileysEx.BinaryNode{
      tag: "message",
      attrs: %{
        "id" => "pdo-response-1",
        "from" => "15551234567@s.whatsapp.net",
        "t" => "1710000601"
      },
      content: [
        %BaileysEx.BinaryNode{tag: "plaintext", attrs: %{}, content: Message.encode(pdo_message)}
      ]
    }

    context = %{
      signal_repository: repo,
      event_emitter: emitter,
      me_id: "15550001111@s.whatsapp.net",
      me_lid: "15550001111@lid",
      store_ref: runtime_store_ref
    }

    assert {:ok, _message, _context} = Receiver.process_node(node, context)

    assert_receive {:events,
                    %{
                      messages_upsert: %{
                        type: :notify,
                        request_id: "request-123",
                        messages: [
                          %{
                            key: %{
                              id: "pdo-msg-1",
                              remote_jid_alt: "12345@lid",
                              participant_alt: "12345:1@lid"
                            },
                            message: %Message{
                              extended_text_message: %Message.ExtendedTextMessage{
                                text: "restored"
                              }
                            },
                            message_timestamp: 1_710_000_602,
                            push_name: "Phone Cache"
                          }
                        ]
                      }
                    }}

    assert Retry.get_placeholder_resend(runtime_store_ref, "pdo-msg-1") == nil

    unsubscribe.()
  end

  test "process_node/3 emits group member tag updates" do
    {:ok, emitter} = EventEmitter.start_link()
    parent = self()
    unsubscribe = EventEmitter.process(emitter, &send(parent, {:events, &1}))

    {repo, _store} = MessageSignalHelpers.new_repo()

    protocol_message = %Message{
      protocol_message: %Message.ProtocolMessage{
        type: :GROUP_MEMBER_LABEL_CHANGE,
        member_label: %Message.MemberLabel{label: "vip", label_timestamp: 1_710_000_603_000}
      }
    }

    node = %BaileysEx.BinaryNode{
      tag: "message",
      attrs: %{
        "id" => "label-1",
        "from" => "120363001234567890@g.us",
        "participant" => "15551234567:1@s.whatsapp.net",
        "participant_lid" => "12345:1@lid",
        "t" => "1710000603"
      },
      content: [
        %BaileysEx.BinaryNode{
          tag: "plaintext",
          attrs: %{},
          content: Message.encode(protocol_message)
        }
      ]
    }

    context = %{
      signal_repository: repo,
      event_emitter: emitter,
      me_id: "15550001111@s.whatsapp.net",
      me_lid: "15550001111@lid"
    }

    assert {:ok, _message, _context} = Receiver.process_node(node, context)

    assert_receive {:events,
                    %{
                      group_member_tag_update: %{
                        group_id: "120363001234567890@g.us",
                        participant: "15551234567@s.whatsapp.net",
                        participant_alt: "12345@lid",
                        label: "vip",
                        message_timestamp: 1_710_000_603
                      }
                    }}

    unsubscribe.()
  end

  test "process_node/3 stores LID migration mappings and migrates sessions" do
    {:ok, emitter} = EventEmitter.start_link()

    {repo, store} = MessageSignalHelpers.new_repo()
    session = MessageSignalHelpers.session_fixture()

    assert :ok = Store.set(store, %{:"device-list" => %{"15551234567" => ["0"]}})

    assert {:ok, repo} =
             Repository.inject_e2e_session(repo, %{
               jid: "15551234567:0@s.whatsapp.net",
               session: session
             })

    payload =
      %Message.LIDMigrationMappingSyncPayload{
        pn_to_lid_mappings: [
          %Message.LIDMigrationMapping{
            pn: 15_551_234_567,
            latest_lid: 12_345
          }
        ],
        chat_db_migration_timestamp: 1_710_000_604
      }
      |> Message.LIDMigrationMappingSyncPayload.encode()

    protocol_message = %Message{
      protocol_message: %Message.ProtocolMessage{
        type: :LID_MIGRATION_MAPPING_SYNC,
        lid_migration_mapping_sync_message: %Message.LIDMigrationMappingSyncMessage{
          encoded_mapping_payload: payload
        }
      }
    }

    node = %BaileysEx.BinaryNode{
      tag: "message",
      attrs: %{
        "id" => "lid-sync-1",
        "from" => "15551234567@s.whatsapp.net",
        "t" => "1710000604"
      },
      content: [
        %BaileysEx.BinaryNode{
          tag: "plaintext",
          attrs: %{},
          content: Message.encode(protocol_message)
        }
      ]
    }

    context = %{
      signal_repository: repo,
      event_emitter: emitter,
      me_id: "15550001111@s.whatsapp.net",
      me_lid: "15550001111@lid"
    }

    assert {:ok, _message, %{signal_repository: repo}} = Receiver.process_node(node, context)
    assert {:ok, %{exists: true}} = Repository.validate_session(repo, "12345:0@lid")

    assert {:ok, ^repo, "12345@lid"} =
             Repository.get_lid_for_pn(repo, "15551234567@s.whatsapp.net")
  end

  test "handle_bad_ack/2 emits ERROR status updates for ack class message nodes with errors" do
    {:ok, emitter} = EventEmitter.start_link()
    parent = self()
    unsubscribe = EventEmitter.process(emitter, &send(parent, {:events, &1}))

    ack = %BinaryNode{
      tag: "ack",
      attrs: %{
        "class" => "message",
        "from" => "15551234567@s.whatsapp.net",
        "id" => "ack-1",
        "participant" => "15551234567:1@s.whatsapp.net",
        "error" => "500"
      },
      content: nil
    }

    assert :ok = Receiver.handle_bad_ack(ack, emitter)

    assert_receive {:events,
                    %{
                      messages_update: [
                        %{
                          key: %{
                            remote_jid: "15551234567@s.whatsapp.net",
                            id: "ack-1",
                            from_me: true
                          },
                          update: %{status: :ERROR, message_stub_parameters: ["500"]}
                        }
                      ]
                    }}

    unsubscribe.()
  end

  test "process_node/3 extracts verified business names from verified_name children" do
    {:ok, emitter} = EventEmitter.start_link()

    {repo, _store} = MessageSignalHelpers.new_repo()

    proto_message = Builder.build(%{text: "verified"})

    node = %BinaryNode{
      tag: "message",
      attrs: %{
        "id" => "verified-1",
        "from" => "15551234567@s.whatsapp.net",
        "t" => "1710000605"
      },
      content: [
        %BinaryNode{tag: "verified_name", attrs: %{}, content: verified_name_cert("Acme Co")},
        %BinaryNode{tag: "plaintext", attrs: %{}, content: Message.encode(proto_message)}
      ]
    }

    context = %{
      signal_repository: repo,
      event_emitter: emitter,
      me_id: "15550001111@s.whatsapp.net",
      me_lid: "15550001111@lid"
    }

    assert {:ok, %{verified_biz_name: "Acme Co"}, _context} = Receiver.process_node(node, context)
  end

  test "process_node/3 normalizes hosted JIDs and emits reaction updates from the receiver perspective" do
    {:ok, emitter} = EventEmitter.start_link()
    parent = self()
    unsubscribe = EventEmitter.process(emitter, &send(parent, {:events, &1}))

    {repo, _store} = MessageSignalHelpers.new_repo()

    reaction_message = %Message{
      reaction_message: %Message.ReactionMessage{
        key: %MessageKey{
          remote_jid: "15550001111@hosted",
          from_me: false,
          id: "original-msg",
          participant: "15550001111:3@hosted"
        },
        text: "🔥",
        sender_timestamp_ms: 1_710_000_701_000
      }
    }

    node = %BinaryNode{
      tag: "message",
      attrs: %{
        "id" => "reaction-1",
        "from" => "15551234567@hosted",
        "participant" => "15551234567:1@hosted",
        "t" => "1710000701"
      },
      content: [
        %BinaryNode{tag: "plaintext", attrs: %{}, content: Message.encode(reaction_message)}
      ]
    }

    context = %{
      signal_repository: repo,
      event_emitter: emitter,
      me_id: "15550001111@s.whatsapp.net",
      me_lid: "15550001111@lid"
    }

    assert {:ok,
            %{
              key: %{
                remote_jid: "15551234567@s.whatsapp.net",
                participant: "15551234567@s.whatsapp.net"
              },
              message: %Message{
                reaction_message: %Message.ReactionMessage{
                  key: %MessageKey{
                    remote_jid: "15551234567@s.whatsapp.net",
                    participant: "15550001111@s.whatsapp.net",
                    from_me: true,
                    id: "original-msg"
                  }
                }
              }
            }, _context} = Receiver.process_node(node, context)

    assert_receive {:events,
                    %{
                      messages_reaction: [
                        %{
                          key: %{
                            remote_jid: "15551234567@s.whatsapp.net",
                            participant: "15550001111@s.whatsapp.net",
                            from_me: true,
                            id: "original-msg"
                          },
                          reaction: %{text: "🔥"}
                        }
                      ]
                    }}

    unsubscribe.()
  end

  test "process_node/3 decrypts poll updates and emits poll_updates on the source poll" do
    {:ok, emitter} = EventEmitter.start_link()
    parent = self()
    unsubscribe = EventEmitter.process(emitter, &send(parent, {:events, &1}))

    {repo, _store} = MessageSignalHelpers.new_repo()

    poll_secret = <<30::256>>

    poll_key = %MessageKey{
      remote_jid: "15551234567@s.whatsapp.net",
      id: "poll-source-1",
      from_me: false
    }

    vote = %Message.PollVoteMessage{selected_options: ["option-a", "option-b"]}

    {enc_payload, enc_iv} =
      encrypt_poll_value(
        vote,
        poll_secret,
        "poll-source-1",
        "15551234567@s.whatsapp.net",
        "15551234567@s.whatsapp.net"
      )

    poll_update = %Message{
      poll_update_message: %Message.PollUpdateMessage{
        poll_creation_message_key: poll_key,
        vote: %Message.PollEncValue{enc_payload: enc_payload, enc_iv: enc_iv},
        sender_timestamp_ms: 1_710_000_702_000
      }
    }

    node = %BinaryNode{
      tag: "message",
      attrs: %{
        "id" => "poll-update-1",
        "from" => "15551234567@s.whatsapp.net",
        "t" => "1710000702"
      },
      content: [%BinaryNode{tag: "plaintext", attrs: %{}, content: Message.encode(poll_update)}]
    }

    context = %{
      signal_repository: repo,
      event_emitter: emitter,
      me_id: "15550001111@s.whatsapp.net",
      me_lid: "15550001111@lid",
      get_message_fun: fn
        %{id: "poll-source-1"} ->
          %{
            key: poll_key,
            message: %Message{
              poll_creation_message: %Message.PollCreationMessage{name: "Lunch"},
              message_context_info: %MessageContextInfo{message_secret: poll_secret}
            }
          }

        _other ->
          nil
      end
    }

    assert {:ok, _message, _context} = Receiver.process_node(node, context)

    assert_receive {:events,
                    %{
                      messages_update: [
                        %{
                          key: %{id: "poll-source-1"},
                          update: %{
                            poll_updates: [
                              %{
                                poll_update_message_key: %{id: "poll-source-1"},
                                vote: %{selected_options: ["option-a", "option-b"]}
                              }
                            ]
                          }
                        }
                      ]
                    }}

    unsubscribe.()
  end

  test "process_node/3 decrypts event responses and updates the source event message" do
    {:ok, emitter} = EventEmitter.start_link()
    parent = self()
    unsubscribe = EventEmitter.process(emitter, &send(parent, {:events, &1}))

    {repo, _store} = MessageSignalHelpers.new_repo()

    assert {:ok, repo} =
             Repository.store_lid_pn_mappings(repo, [
               %{lid: "12345@lid", pn: "15551234567@s.whatsapp.net"}
             ])

    event_secret = <<31::256>>

    creation_key = %MessageKey{
      remote_jid: "12345@lid",
      id: "event-source-1",
      from_me: false
    }

    event_response = %Message.EventResponseMessage{
      response: :GOING,
      timestamp_ms: 1_710_000_703_000,
      extra_guest_count: 2
    }

    {enc_payload, enc_iv} =
      encrypt_event_response(
        event_response,
        event_secret,
        "event-source-1",
        "15551234567@s.whatsapp.net",
        "15551234567@s.whatsapp.net"
      )

    inbound_message = %Message{
      enc_event_response_message: %Message.EncEventResponseMessage{
        event_creation_message_key: creation_key,
        enc_payload: enc_payload,
        enc_iv: enc_iv
      }
    }

    node = %BinaryNode{
      tag: "message",
      attrs: %{
        "id" => "event-response-1",
        "from" => "12345@lid",
        "participant_pn" => "15551234567@s.whatsapp.net",
        "t" => "1710000703"
      },
      content: [
        %BinaryNode{tag: "plaintext", attrs: %{}, content: Message.encode(inbound_message)}
      ]
    }

    context = %{
      signal_repository: repo,
      event_emitter: emitter,
      me_id: "15550001111@s.whatsapp.net",
      me_lid: "15550001111@lid",
      get_message_fun: fn
        %{id: "event-source-1"} ->
          %{
            key: %{id: "event-source-1", remote_jid: "15551234567@s.whatsapp.net", from_me: false},
            message: %Message{
              event_message: %Message.EventMessage{name: "Town Hall"},
              message_context_info: %MessageContextInfo{message_secret: event_secret}
            }
          }

        _other ->
          nil
      end
    }

    assert {:ok, _message, _context} = Receiver.process_node(node, context)

    assert_receive {:events,
                    %{
                      messages_update: [
                        %{
                          key: %{id: "event-source-1"},
                          update: %{
                            event_responses: [
                              %{
                                event_response_message_key: %{id: "event-response-1"},
                                response: %{response: :GOING, extra_guest_count: 2}
                              }
                            ]
                          }
                        }
                      ]
                    }}

    unsubscribe.()
  end

  defp verified_name_cert(name) do
    details = Wire.encode_bytes(4, name)
    Wire.encode_bytes(1, details)
  end

  defp encrypt_poll_value(vote, secret, poll_message_id, poll_creator_jid, voter_jid) do
    encode_encrypted_vote(
      Message.PollVoteMessage.encode(vote),
      secret,
      [poll_message_id, poll_creator_jid, voter_jid, "Poll Vote", <<1>>],
      "#{poll_message_id}\0#{voter_jid}"
    )
  end

  defp encrypt_event_response(
         response,
         secret,
         event_message_id,
         event_creator_jid,
         responder_jid
       ) do
    encode_encrypted_vote(
      Message.EventResponseMessage.encode(response),
      secret,
      [event_message_id, event_creator_jid, responder_jid, "Event Response", <<1>>],
      "#{event_message_id}\0#{responder_jid}"
    )
  end

  defp encode_encrypted_vote(payload, secret, sign_parts, aad) do
    sign = IO.iodata_to_binary(sign_parts)
    key0 = :crypto.mac(:hmac, :sha256, <<0::256>>, secret)
    dec_key = :crypto.mac(:hmac, :sha256, key0, sign)
    iv = :binary.copy(<<32>>, 12)
    {:ok, ciphertext} = BaileysEx.Crypto.aes_gcm_encrypt(dec_key, iv, payload, aad)
    {ciphertext, iv}
  end
end
