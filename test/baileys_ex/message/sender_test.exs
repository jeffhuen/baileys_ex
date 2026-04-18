defmodule BaileysEx.Message.SenderTest do
  use ExUnit.Case, async: true

  alias BaileysEx.BinaryNode
  alias BaileysEx.Connection.Store, as: RuntimeStore
  alias BaileysEx.JID
  alias BaileysEx.Message.Builder
  alias BaileysEx.Message.Retry
  alias BaileysEx.Message.Sender
  alias BaileysEx.Message.Wire
  alias BaileysEx.Protocol.Proto.Message
  alias BaileysEx.Signal.Address
  alias BaileysEx.Signal.LIDMappingStore
  alias BaileysEx.Signal.Repository
  alias BaileysEx.Signal.Store
  alias BaileysEx.TestHelpers.FakeThumbnail
  alias BaileysEx.TestHelpers.MessageSignalHelpers
  alias BaileysEx.TestHelpers.TelemetryHelpers

  test "send/4 performs direct-device fanout with DSM, device identity, and trusted-contact token" do
    jid = %JID{user: "15551234567", server: "s.whatsapp.net"}
    parent = self()

    {repo, store} = MessageSignalHelpers.new_repo()
    session = MessageSignalHelpers.session_fixture()

    repo =
      repo
      |> inject_session!("15550001111@s.whatsapp.net", session)
      |> inject_session!("12345@lid", session)
      |> inject_session!("12345:2@lid", session)
      |> inject_session!("15550001111:2@s.whatsapp.net", session)

    assert :ok =
             Store.set(store, %{
               :"device-list" => %{
                 "15551234567" => ["0", "2"],
                 "15550001111" => ["0", "1", "2"]
               }
             })

    assert :ok =
             LIDMappingStore.store_lid_pn_mappings(store, [
               %{pn: "15551234567@s.whatsapp.net", lid: "12345@lid"}
             ])

    assert :ok =
             Store.set(store, %{tctoken: %{"15551234567@s.whatsapp.net" => %{token: "tc-token"}}})

    context = %{
      signal_repository: repo,
      signal_store: store,
      me_id: "15550001111:1@s.whatsapp.net",
      device_identity: <<1, 2, 3>>,
      send_node_fun: fn node ->
        send(parent, {:relay_node, node})
        :ok
      end
    }

    assert {:ok,
            %{
              id: "3EB0FIXEDID",
              jid: ^jid,
              message: %Message{
                extended_text_message: %Message.ExtendedTextMessage{text: "hello"}
              },
              timestamp: 1_710_000_000_000
            },
            %{signal_repository: updated_repo}} =
             Sender.send(context, jid, %{text: "hello"},
               message_id_fun: fn _me_id -> "3EB0FIXEDID" end,
               timestamp_fun: fn -> 1_710_000_000_000 end
             )

    {:ok, recipient_zero_address} = Address.from_jid("12345@lid")
    recipient_zero_key = Repository.Adapter.session_key(recipient_zero_address)

    assert %{^recipient_zero_key => %{history: history}} = updated_repo.adapter_state
    assert Enum.any?(history, fn {action, _payload} -> action == :encrypted end)

    assert_receive {:relay_node,
                    %BinaryNode{
                      tag: "message",
                      attrs: %{
                        "to" => "15551234567@s.whatsapp.net",
                        "type" => "text",
                        "id" => "3EB0FIXEDID"
                      },
                      content: content
                    }}

    assert %BinaryNode{tag: "participants", content: participants} =
             Enum.find(content, &match?(%BinaryNode{tag: "participants"}, &1))

    assert 4 == length(participants)

    assert Enum.any?(
             content,
             &match?(%BinaryNode{tag: "device-identity", content: {:binary, <<1, 2, 3>>}}, &1)
           )

    assert Enum.any?(
             content,
             &match?(%BinaryNode{tag: "tctoken", content: {:binary, "tc-token"}}, &1)
           )

    assert Enum.any?(participants, fn
             %BinaryNode{
               tag: "to",
               attrs: %{"jid" => "15550001111@s.whatsapp.net"},
               content: [%BinaryNode{tag: "enc", attrs: %{"type" => "pkmsg", "v" => "2"} = attrs}]
             }
             when not is_map_key(attrs, "phash") ->
               true

             _ ->
               false
           end)

    assert Enum.any?(participants, fn
             %BinaryNode{
               tag: "to",
               attrs: %{"jid" => "15550001111:2@s.whatsapp.net"},
               content: [%BinaryNode{tag: "enc", attrs: %{"type" => "pkmsg", "v" => "2"} = attrs}]
             }
             when not is_map_key(attrs, "phash") ->
               true

             _ ->
               false
           end)

    assert Enum.any?(participants, fn
             %BinaryNode{
               tag: "to",
               attrs: %{"jid" => "15551234567@s.whatsapp.net"},
               content: [%BinaryNode{tag: "enc", attrs: %{"type" => "pkmsg", "v" => "2"} = attrs}]
             }
             when not is_map_key(attrs, "phash") ->
               true

             _ ->
               false
           end)

    assert Enum.any?(participants, fn
             %BinaryNode{
               tag: "to",
               attrs: %{"jid" => "15551234567:2@s.whatsapp.net"},
               content: [%BinaryNode{tag: "enc", attrs: %{"type" => "pkmsg", "v" => "2"} = attrs}]
             }
             when not is_map_key(attrs, "phash") ->
               true

             _ ->
               false
           end)
  end

  test "send/4 skips the exact sender lid device when direct fanout returns lid-addressed own devices" do
    jid = %JID{user: "15551234567", server: "s.whatsapp.net"}
    parent = self()

    {repo, store} = MessageSignalHelpers.new_repo()
    session = MessageSignalHelpers.session_fixture()

    repo =
      repo
      |> inject_session!("15551234567@s.whatsapp.net", session)
      |> inject_session!("99999:2@lid", session)

    context = %{
      signal_repository: repo,
      signal_store: store,
      me_id: "15550001111:1@s.whatsapp.net",
      me_lid: "99999:1@lid",
      device_lookup_fun: fn lookup_context, jids, _opts ->
        case jids do
          ["15551234567@s.whatsapp.net"] ->
            {:ok, lookup_context, ["15551234567@s.whatsapp.net"]}

          ["15550001111@s.whatsapp.net"] ->
            {:ok, lookup_context, ["99999:1@lid", "99999:2@lid"]}
        end
      end,
      send_node_fun: fn node ->
        send(parent, {:relay_node, node})
        :ok
      end
    }

    assert {:ok, %{id: "3EB0SKIPLID"}, _updated_context} =
             Sender.send(context, jid, %{text: "hello"},
               message_id_fun: fn _me_id -> "3EB0SKIPLID" end
             )

    assert_receive {:relay_node,
                    %BinaryNode{
                      tag: "message",
                      attrs: %{"id" => "3EB0SKIPLID"},
                      content: content
                    }}

    assert %BinaryNode{tag: "participants", content: participants} =
             Enum.find(content, &match?(%BinaryNode{tag: "participants"}, &1))

    participant_jids = Enum.map(participants, & &1.attrs["jid"])

    refute "99999:1@lid" in participant_jids
    assert "99999:2@lid" in participant_jids
    assert "15551234567@s.whatsapp.net" in participant_jids
  end

  test "send/4 wraps same-account recipient devices in device sent messages" do
    jid = %JID{user: "15550001111", server: "s.whatsapp.net"}
    parent = self()

    {repo, store} = MessageSignalHelpers.new_repo()
    session = MessageSignalHelpers.session_fixture()

    repo =
      repo
      |> inject_session!("15550001111:0@s.whatsapp.net", session)
      |> inject_session!("15550001111:2@s.whatsapp.net", session)

    assert :ok =
             Store.set(store, %{
               :"device-list" => %{"15550001111" => ["0", "1", "2"]}
             })

    context = %{
      signal_repository: repo,
      signal_store: store,
      me_id: "15550001111:1@s.whatsapp.net",
      send_node_fun: fn node ->
        send(parent, {:relay_node, node})
        :ok
      end
    }

    assert {:ok, %{id: "3EB0SELFCHAT"}, %{signal_repository: updated_repo}} =
             Sender.send(context, jid, %{text: "self hello"},
               message_id_fun: fn _me_id -> "3EB0SELFCHAT" end
             )

    assert_receive {:relay_node,
                    %BinaryNode{
                      tag: "message",
                      attrs: %{"to" => "15550001111@s.whatsapp.net", "id" => "3EB0SELFCHAT"},
                      content: content
                    }}

    assert %BinaryNode{tag: "participants", content: participants} =
             Enum.find(content, &match?(%BinaryNode{tag: "participants"}, &1))

    assert Enum.map(participants, & &1.attrs["jid"]) |> Enum.sort() == [
             "15550001111:2@s.whatsapp.net",
             "15550001111@s.whatsapp.net"
           ]

    assert %{
             "15550001111.0" => %{history: [{:encrypted, device_zero_bytes} | _]},
             "15550001111.2" => %{history: [{:encrypted, device_two_bytes} | _]}
           } = updated_repo.adapter_state

    assert {:ok,
            %Message{
              device_sent_message: %Message.DeviceSentMessage{
                destination_jid: "15550001111@s.whatsapp.net",
                message: %Message{
                  extended_text_message: %Message.ExtendedTextMessage{text: "self hello"}
                }
              }
            }} = Wire.decode(device_zero_bytes)

    assert {:ok,
            %Message{
              device_sent_message: %Message.DeviceSentMessage{
                destination_jid: "15550001111@s.whatsapp.net"
              }
            }} = Wire.decode(device_two_bytes)
  end

  @tag :tmp_dir
  test "send/4 prepares uploaded image media before relay", %{tmp_dir: tmp_dir} do
    jid = %JID{user: "15551234567", server: "s.whatsapp.net"}
    parent = self()
    image_path = Path.join(tmp_dir, "photo.jpg")
    File.write!(image_path, "fake-image-binary")

    {repo, store} = MessageSignalHelpers.new_repo()
    session = MessageSignalHelpers.session_fixture()

    repo =
      repo
      |> inject_session!("15551234567:0@s.whatsapp.net", session)
      |> inject_session!("15550001111:2@s.whatsapp.net", session)

    assert :ok =
             Store.set(store, %{
               :"device-list" => %{"15551234567" => ["0"], "15550001111" => ["1", "2"]}
             })

    context = %{
      signal_repository: repo,
      signal_store: store,
      me_id: "15550001111:1@s.whatsapp.net",
      send_node_fun: fn node ->
        send(parent, {:relay_node, node})
        :ok
      end
    }

    assert {:ok, %{message: %Message{image_message: image_message}}, _updated_context} =
             Sender.send(context, jid, %{image: {:file, image_path}, caption: "media hello"},
               media_upload_fun: fn _encrypted_path, :image, _upload_opts ->
                 {:ok,
                  %{
                    media_url: "https://mmg.whatsapp.net/mms/image/abc",
                    direct_path: "/mms/image/abc"
                  }}
               end,
               thumbnail_module: FakeThumbnail,
               tmp_dir: tmp_dir,
               message_id_fun: fn _me_id -> "3EB0MEDIAID" end
             )

    assert image_message.caption == "media hello"
    assert image_message.direct_path == "/mms/image/abc"
    assert image_message.url == "https://mmg.whatsapp.net/mms/image/abc"
    assert image_message.jpeg_thumbnail == "thumb-jpeg"

    assert_receive {:relay_node,
                    %BinaryNode{
                      tag: "message",
                      attrs: %{
                        "to" => "15551234567@s.whatsapp.net",
                        "type" => "media",
                        "id" => "3EB0MEDIAID"
                      }
                    }}
  end

  test "send/4 performs group sender-key fanout and persists sender-key memory" do
    parent = self()
    group_jid = %JID{user: "120363001234567890", server: "g.us"}

    {repo, store} = MessageSignalHelpers.new_repo()
    session = MessageSignalHelpers.session_fixture()

    repo =
      repo
      |> inject_session!("15551234567:0@s.whatsapp.net", session)
      |> inject_session!("15557654321:0@s.whatsapp.net", session)

    context = %{
      signal_repository: repo,
      signal_store: store,
      me_id: "15550001111@s.whatsapp.net",
      device_identity: <<9, 9, 9>>,
      send_node_fun: fn node ->
        send(parent, {:relay_node, node})
        :ok
      end,
      query_fun: fn _node ->
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
                           tag: "devices",
                           attrs: %{},
                           content: [
                             %BinaryNode{
                               tag: "device-list",
                               attrs: %{},
                               content: [%BinaryNode{tag: "device", attrs: %{"id" => "0"}}]
                             }
                           ]
                         }
                       ]
                     },
                     %BinaryNode{
                       tag: "user",
                       attrs: %{"jid" => "15557654321@s.whatsapp.net"},
                       content: [
                         %BinaryNode{
                           tag: "devices",
                           attrs: %{},
                           content: [
                             %BinaryNode{
                               tag: "device-list",
                               attrs: %{},
                               content: [%BinaryNode{tag: "device", attrs: %{"id" => "0"}}]
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
         }}
      end
    }

    assert {:ok, _sent, updated_context} =
             Sender.send(context, group_jid, %{text: "group hello"},
               message_id_fun: fn _me_id -> "3EB0GROUPID" end,
               timestamp_fun: fn -> 1_710_000_000_000 end,
               group_participants: ["15551234567@s.whatsapp.net", "15557654321@s.whatsapp.net"]
             )

    assert_receive {:relay_node,
                    %BinaryNode{
                      tag: "message",
                      attrs: %{"to" => "120363001234567890@g.us"},
                      content: content
                    }}

    assert Enum.any?(content, &match?(%BinaryNode{tag: "enc", attrs: %{"type" => "skmsg"}}, &1))
    assert Enum.any?(content, &match?(%BinaryNode{tag: "participants"}, &1))

    assert %{"120363001234567890@g.us" => sender_key_memory} =
             Store.get(store, :"sender-key-memory", ["120363001234567890@g.us"])

    assert Map.has_key?(sender_key_memory, "15551234567@s.whatsapp.net")
    assert Map.has_key?(sender_key_memory, "15557654321@s.whatsapp.net")
    assert %{"15551234567" => ["0"]} = Store.get(store, :"device-list", ["15551234567"])
    assert %{"15557654321" => ["0"]} = Store.get(store, :"device-list", ["15557654321"])
    assert %{signal_repository: %Repository{}} = updated_context
  end

  test "send/4 emits telemetry for direct message relay" do
    jid = %JID{user: "15551234567", server: "s.whatsapp.net"}
    parent = self()

    telemetry_id =
      TelemetryHelpers.attach_events(self(), [
        [:baileys_ex, :message, :send, :start],
        [:baileys_ex, :message, :send, :stop]
      ])

    on_exit(fn -> TelemetryHelpers.detach(telemetry_id) end)

    {repo, store} = MessageSignalHelpers.new_repo()
    session = MessageSignalHelpers.session_fixture()

    repo =
      repo
      |> inject_session!("15551234567:0@s.whatsapp.net", session)
      |> inject_session!("15550001111:2@s.whatsapp.net", session)

    assert :ok =
             Store.set(store, %{
               :"device-list" => %{"15551234567" => ["0"], "15550001111" => ["1", "2"]}
             })

    context = %{
      signal_repository: repo,
      signal_store: store,
      me_id: "15550001111:1@s.whatsapp.net",
      send_node_fun: fn node ->
        send(parent, {:relay_node, node})
        :ok
      end
    }

    assert {:ok, %{id: "3EB0TELEMETRY"}, _updated_context} =
             Sender.send(context, jid, %{text: "hello"},
               message_id_fun: fn _me_id -> "3EB0TELEMETRY" end
             )

    assert_receive {:telemetry, [:baileys_ex, :message, :send, :start],
                    %{system_time: system_time},
                    %{jid: "15551234567@s.whatsapp.net", mode: :direct}}

    assert is_integer(system_time)

    assert_receive {:telemetry, [:baileys_ex, :message, :send, :stop], %{duration: duration},
                    %{
                      jid: "15551234567@s.whatsapp.net",
                      mode: :direct,
                      message_id: "3EB0TELEMETRY",
                      status: :ok
                    }}

    assert is_integer(duration)
  end

  test "send_status/3 uses status broadcast fanout and generates a Baileys message id" do
    parent = self()
    status_jid = %JID{user: "status", server: "broadcast"}

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
      query_fun: fn _node ->
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
                           tag: "devices",
                           attrs: %{},
                           content: [
                             %BinaryNode{
                               tag: "device-list",
                               attrs: %{},
                               content: [%BinaryNode{tag: "device", attrs: %{"id" => "0"}}]
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
         }}
      end
    }

    assert {:ok, %{id: id, jid: ^status_jid}, _updated_context} =
             Sender.send_status(context, %{text: "status hello"},
               status_jid_list: ["15551234567@s.whatsapp.net"]
             )

    assert id =~ ~r/^3EB0[0-9A-F]{18}$/

    assert_receive {:relay_node,
                    %BinaryNode{
                      tag: "message",
                      attrs: %{"to" => "status@broadcast", "id" => ^id}
                    }}
  end

  test "send/4 delegates device discovery to the configured device module" do
    jid = %JID{user: "15551234567", server: "s.whatsapp.net"}
    parent = self()

    {repo, store} = MessageSignalHelpers.new_repo()
    session = MessageSignalHelpers.session_fixture()
    repo = inject_session!(repo, "15551234567:9@s.whatsapp.net", session)

    device_module = fn _context, jids, _opts ->
      send(parent, {:device_lookup, jids})

      case jids do
        ["15551234567@s.whatsapp.net"] ->
          {:ok, %{}, ["15551234567:9@s.whatsapp.net"]}

        ["15550001111@s.whatsapp.net"] ->
          {:ok, %{}, []}
      end
    end

    context = %{
      signal_repository: repo,
      signal_store: store,
      me_id: "15550001111:1@s.whatsapp.net",
      send_node_fun: fn _node -> :ok end
    }

    assert {:ok, _sent, _context} =
             Sender.send(context, jid, %{text: "hello"}, device_lookup_fun: device_module)

    assert_receive {:device_lookup, ["15551234567@s.whatsapp.net"]}
    assert_receive {:device_lookup, ["15550001111@s.whatsapp.net"]}
  end

  test "send/4 attaches reporting tokens to applicable message types and skips reaction relays" do
    jid = %JID{user: "15551234567", server: "s.whatsapp.net"}
    parent = self()

    {repo, store} = MessageSignalHelpers.new_repo()
    session = MessageSignalHelpers.session_fixture()
    repo = inject_session!(repo, "15551234567:0@s.whatsapp.net", session)

    assert :ok =
             Store.set(store, %{:"device-list" => %{"15551234567" => ["0"], "15550001111" => []}})

    context = %{
      signal_repository: repo,
      signal_store: store,
      me_id: "15550001111@s.whatsapp.net",
      send_node_fun: fn node ->
        send(parent, {:relay_node, node})
        :ok
      end
    }

    assert {:ok, _sent, _context} =
             Sender.send(context, jid, %{
               poll: %{
                 name: "Phase 8 Review",
                 values: ["yes", "no"],
                 selectable_count: 1,
                 message_secret: <<33::256>>
               }
             })

    assert_receive {:relay_node, %BinaryNode{content: event_content}}
    assert Enum.any?(event_content, &match?(%BinaryNode{tag: "reporting"}, &1))

    assert {:ok, _sent, _context} =
             Sender.send(context, jid, %{
               react: %{
                 key: %{id: "message-1", remote_jid: "15551234567@s.whatsapp.net"},
                 text: "🔥"
               }
             })

    assert_receive {:relay_node, %BinaryNode{content: reaction_content}}
    refute Enum.any?(reaction_content, &match?(%BinaryNode{tag: "reporting"}, &1))
  end

  test "send/4 appends tc tokens after reporting nodes and before additional nodes" do
    jid = %JID{user: "15551234567", server: "s.whatsapp.net"}
    parent = self()

    {repo, store} = MessageSignalHelpers.new_repo()
    session = MessageSignalHelpers.session_fixture()
    repo = inject_session!(repo, "15551234567:0@s.whatsapp.net", session)

    assert :ok =
             Store.set(store, %{
               :"device-list" => %{"15551234567" => ["0"], "15550001111" => []},
               tctoken: %{"15551234567@s.whatsapp.net" => %{token: "tc-token"}}
             })

    context = %{
      signal_repository: repo,
      signal_store: store,
      me_id: "15550001111@s.whatsapp.net",
      send_node_fun: fn node ->
        send(parent, {:relay_node, node})
        :ok
      end
    }

    additional_node = %BinaryNode{tag: "meta", attrs: %{"marker" => "after"}, content: nil}

    assert {:ok, _sent, _context} =
             Sender.send(
               context,
               jid,
               %{
                 poll: %{
                   name: "Phase 10 Review",
                   values: ["yes", "no"],
                   selectable_count: 1,
                   message_secret: <<44::256>>
                 }
               },
               additional_nodes: [additional_node]
             )

    assert_receive {:relay_node, %BinaryNode{content: content}}

    tags = Enum.map(content, & &1.tag)
    reporting_index = Enum.find_index(tags, &(&1 == "reporting"))
    tc_token_index = Enum.find_index(tags, &(&1 == "tctoken"))
    additional_index = Enum.find_index(tags, &(&1 == "meta"))

    assert is_integer(reporting_index)
    assert is_integer(tc_token_index)
    assert is_integer(additional_index)
    assert reporting_index < tc_token_index
    assert tc_token_index < additional_index
  end

  test "send/4 skips trusted-contact tokens for retry-resend relays" do
    jid = %JID{user: "15551234567", server: "s.whatsapp.net"}
    parent = self()

    {repo, store} = MessageSignalHelpers.new_repo()
    session = MessageSignalHelpers.session_fixture()
    repo = inject_session!(repo, "15551234567:0@s.whatsapp.net", session)

    assert :ok =
             Store.set(store, %{
               :"device-list" => %{"15551234567" => ["0"], "15550001111" => []},
               tctoken: %{"15551234567@s.whatsapp.net" => %{token: "tc-token"}}
             })

    context = %{
      signal_repository: repo,
      signal_store: store,
      me_id: "15550001111@s.whatsapp.net",
      send_node_fun: fn node ->
        send(parent, {:relay_node, node})
        :ok
      end
    }

    assert {:ok, _sent, _context} =
             Sender.send(
               context,
               jid,
               %{text: "retry hello"},
               participant: %{jid: "15551234567:0@s.whatsapp.net"}
             )

    assert_receive {:relay_node, %BinaryNode{content: content}}
    refute Enum.any?(content, &match?(%BinaryNode{tag: "tctoken"}, &1))
  end

  test "send/4 caches recently sent messages when runtime retry cache is enabled" do
    jid = %JID{user: "15551234567", server: "s.whatsapp.net"}
    parent = self()

    {repo, store} = MessageSignalHelpers.new_repo()
    {:ok, runtime_store} = RuntimeStore.start_link()
    runtime_store_ref = RuntimeStore.wrap(runtime_store)
    session = MessageSignalHelpers.session_fixture()

    repo =
      repo
      |> inject_session!("15551234567:0@s.whatsapp.net", session)
      |> inject_session!("15550001111:2@s.whatsapp.net", session)

    assert :ok =
             Store.set(store, %{
               :"device-list" => %{"15551234567" => ["0"], "15550001111" => ["1", "2"]}
             })

    context = %{
      enable_recent_message_cache: true,
      signal_repository: repo,
      signal_store: store,
      store_ref: runtime_store_ref,
      me_id: "15550001111:1@s.whatsapp.net",
      send_node_fun: fn node ->
        send(parent, {:relay_node, node})
        :ok
      end
    }

    assert {:ok, %{id: "3EB0RECENT1"}, _updated_context} =
             Sender.send(context, jid, %{text: "cache me"},
               message_id_fun: fn _me_id -> "3EB0RECENT1" end
             )

    assert %{
             message: %Message{
               extended_text_message: %Message.ExtendedTextMessage{text: "cache me"}
             }
           } =
             Retry.get_recent_message(
               runtime_store_ref,
               "15551234567@s.whatsapp.net",
               "3EB0RECENT1"
             )
  end

  test "send_proto/4 performs participant-targeted retry resends" do
    jid = %JID{user: "15551234567", server: "s.whatsapp.net"}
    parent = self()

    {repo, store} = MessageSignalHelpers.new_repo()
    session = MessageSignalHelpers.session_fixture()

    repo = inject_session!(repo, "15551234567:2@s.whatsapp.net", session)

    context = %{
      signal_repository: repo,
      signal_store: store,
      me_id: "15550001111:1@s.whatsapp.net",
      send_node_fun: fn node ->
        send(parent, {:relay_node, node})
        :ok
      end
    }

    message = Builder.build(%{text: "retry replay"})

    assert {:ok, %{id: "3EB0RETRY1"}, _updated_context} =
             Sender.send_proto(context, jid, message,
               message_id_fun: fn _me_id -> "3EB0RETRY1" end,
               participant: %{jid: "15551234567:2@s.whatsapp.net", count: 2}
             )

    assert_receive {:relay_node,
                    %BinaryNode{
                      tag: "message",
                      attrs: %{
                        "id" => "3EB0RETRY1",
                        "to" => "15551234567:2@s.whatsapp.net",
                        "type" => "text",
                        "device_fanout" => "false"
                      },
                      content: [
                        %BinaryNode{
                          tag: "enc",
                          attrs: %{"type" => type, "count" => "2", "v" => "2"}
                        }
                      ]
                    }}

    assert type in ["msg", "pkmsg"]
  end

  describe "cached_group_metadata resolution" do
    test "resolves group participants from cached_group_metadata callback" do
      parent = self()
      group_jid = %JID{user: "120363001234567890", server: "g.us"}

      {repo, store} = MessageSignalHelpers.new_repo()
      session = MessageSignalHelpers.session_fixture()

      repo =
        repo
        |> inject_session!("15551234567:0@s.whatsapp.net", session)
        |> inject_session!("15557654321:0@s.whatsapp.net", session)

      context = %{
        signal_repository: repo,
        signal_store: store,
        me_id: "15550001111@s.whatsapp.net",
        device_identity: <<9, 9, 9>>,
        send_node_fun: fn node ->
          send(parent, {:relay_node, node})
          :ok
        end,
        cached_group_metadata: fn jid ->
          send(parent, {:cached_group_metadata, jid})

          {:ok,
           %{
             participants: [
               %{id: "15551234567@s.whatsapp.net"},
               %{id: "15557654321@s.whatsapp.net"}
             ]
           }}
        end,
        query_fun: fn _node ->
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
                             tag: "devices",
                             attrs: %{},
                             content: [
                               %BinaryNode{
                                 tag: "device-list",
                                 attrs: %{},
                                 content: [%BinaryNode{tag: "device", attrs: %{"id" => "0"}}]
                               }
                             ]
                           }
                         ]
                       },
                       %BinaryNode{
                         tag: "user",
                         attrs: %{"jid" => "15557654321@s.whatsapp.net"},
                         content: [
                           %BinaryNode{
                             tag: "devices",
                             attrs: %{},
                             content: [
                               %BinaryNode{
                                 tag: "device-list",
                                 attrs: %{},
                                 content: [%BinaryNode{tag: "device", attrs: %{"id" => "0"}}]
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
           }}
        end
      }

      assert {:ok, _sent, _updated_context} =
               Sender.send(context, group_jid, %{text: "auto-resolve hello"},
                 message_id_fun: fn _me_id -> "3EB0CACHED1" end,
                 timestamp_fun: fn -> 1_710_000_000_000 end
               )

      # Verify cached metadata was consulted
      assert_receive {:cached_group_metadata, "120363001234567890@g.us"}

      assert_receive {:relay_node,
                      %BinaryNode{
                        tag: "message",
                        attrs: %{"to" => "120363001234567890@g.us"},
                        content: content
                      }}

      assert Enum.any?(
               content,
               &match?(%BinaryNode{tag: "enc", attrs: %{"type" => "skmsg"}}, &1)
             )
    end

    test "falls back to live group_metadata_fun when cache returns nil" do
      parent = self()
      group_jid = %JID{user: "120363001234567890", server: "g.us"}

      {repo, store} = MessageSignalHelpers.new_repo()
      session = MessageSignalHelpers.session_fixture()

      repo =
        repo
        |> inject_session!("15551234567:0@s.whatsapp.net", session)

      context = %{
        signal_repository: repo,
        signal_store: store,
        me_id: "15550001111@s.whatsapp.net",
        send_node_fun: fn node ->
          send(parent, {:relay_node, node})
          :ok
        end,
        cached_group_metadata: fn _jid ->
          send(parent, {:cached_miss, true})
          nil
        end,
        group_metadata_fun: fn jid ->
          send(parent, {:live_group_metadata, jid})

          {:ok,
           %{
             participants: [%{id: "15551234567@s.whatsapp.net"}]
           }}
        end,
        query_fun: fn _node ->
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
                             tag: "devices",
                             attrs: %{},
                             content: [
                               %BinaryNode{
                                 tag: "device-list",
                                 attrs: %{},
                                 content: [%BinaryNode{tag: "device", attrs: %{"id" => "0"}}]
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
           }}
        end
      }

      assert {:ok, _sent, _updated_context} =
               Sender.send(context, group_jid, %{text: "fallback hello"},
                 message_id_fun: fn _me_id -> "3EB0FALLBK1" end,
                 timestamp_fun: fn -> 1_710_000_000_000 end
               )

      # Verify cache was tried first
      assert_receive {:cached_miss, true}
      # Verify live fallback was called
      assert_receive {:live_group_metadata, "120363001234567890@g.us"}

      assert_receive {:relay_node,
                      %BinaryNode{
                        tag: "message",
                        attrs: %{"to" => "120363001234567890@g.us"}
                      }}
    end

    test "explicit group_participants wins over cached_group_metadata" do
      parent = self()
      group_jid = %JID{user: "120363001234567890", server: "g.us"}

      {repo, store} = MessageSignalHelpers.new_repo()
      session = MessageSignalHelpers.session_fixture()

      repo =
        repo
        |> inject_session!("15551234567:0@s.whatsapp.net", session)

      context = %{
        signal_repository: repo,
        signal_store: store,
        me_id: "15550001111@s.whatsapp.net",
        send_node_fun: fn node ->
          send(parent, {:relay_node, node})
          :ok
        end,
        cached_group_metadata: fn _jid ->
          send(parent, {:cached_should_not_be_called, true})
          {:ok, %{participants: [%{id: "15559999999@s.whatsapp.net"}]}}
        end,
        query_fun: fn _node ->
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
                             tag: "devices",
                             attrs: %{},
                             content: [
                               %BinaryNode{
                                 tag: "device-list",
                                 attrs: %{},
                                 content: [%BinaryNode{tag: "device", attrs: %{"id" => "0"}}]
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
           }}
        end
      }

      assert {:ok, _sent, _updated_context} =
               Sender.send(context, group_jid, %{text: "explicit hello"},
                 message_id_fun: fn _me_id -> "3EB0EXPLIC1" end,
                 timestamp_fun: fn -> 1_710_000_000_000 end,
                 group_participants: ["15551234567@s.whatsapp.net"]
               )

      # Cached metadata should NOT have been called
      refute_receive {:cached_should_not_be_called, _}

      assert_receive {:relay_node,
                      %BinaryNode{
                        tag: "message",
                        attrs: %{"to" => "120363001234567890@g.us"}
                      }}
    end

    test "accepts plain map from cache (Baileys contract: GroupMetadata | undefined)" do
      parent = self()
      group_jid = %JID{user: "120363001234567890", server: "g.us"}

      {repo, store} = MessageSignalHelpers.new_repo()
      session = MessageSignalHelpers.session_fixture()

      repo =
        repo
        |> inject_session!("15551234567:0@s.whatsapp.net", session)

      context = %{
        signal_repository: repo,
        signal_store: store,
        me_id: "15550001111@s.whatsapp.net",
        device_identity: <<9, 9, 9>>,
        send_node_fun: fn node ->
          send(parent, {:relay_node, node})
          :ok
        end,
        # Returns plain map (Baileys style), NOT {:ok, map}
        cached_group_metadata: fn _jid ->
          %{participants: [%{id: "15551234567@s.whatsapp.net"}]}
        end,
        query_fun: fn _node ->
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
                             tag: "devices",
                             attrs: %{},
                             content: [
                               %BinaryNode{
                                 tag: "device-list",
                                 attrs: %{},
                                 content: [%BinaryNode{tag: "device", attrs: %{"id" => "0"}}]
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
           }}
        end
      }

      assert {:ok, _sent, _context} =
               Sender.send(context, group_jid, %{text: "plain map cache"},
                 message_id_fun: fn _me_id -> "3EB0PLAINMAP" end,
                 timestamp_fun: fn -> 1_710_000_000_000 end
               )

      assert_receive {:relay_node,
                      %BinaryNode{tag: "message", attrs: %{"to" => "120363001234567890@g.us"}}}
    end

    test "returns error when no cache, no live fallback, and no explicit participants" do
      group_jid = %JID{user: "120363001234567890", server: "g.us"}

      {repo, store} = MessageSignalHelpers.new_repo()

      context = %{
        signal_repository: repo,
        signal_store: store,
        me_id: "15550001111@s.whatsapp.net",
        send_node_fun: fn _node -> :ok end
      }

      assert {:error, :group_participants_not_found} =
               Sender.send(context, group_jid, %{text: "should fail"},
                 message_id_fun: fn _me_id -> "3EB0NOPTCPNT" end
               )
    end
  end

  defp inject_session!(repo, jid, session) do
    assert {:ok, next_repo} = Repository.inject_e2e_session(repo, %{jid: jid, session: session})
    next_repo
  end
end
