defmodule BaileysEx.Message.SenderTest do
  use ExUnit.Case, async: true

  alias BaileysEx.BinaryNode
  alias BaileysEx.JID
  alias BaileysEx.Message.Sender
  alias BaileysEx.Protocol.Proto.Message
  alias BaileysEx.Signal.Repository
  alias BaileysEx.Signal.Store
  alias BaileysEx.TestHelpers.FakeThumbnail
  alias BaileysEx.TestHelpers.MessageSignalHelpers

  test "send/4 performs direct-device fanout with DSM, phash, device identity, and trusted-contact token" do
    jid = %JID{user: "15551234567", server: "s.whatsapp.net"}
    parent = self()

    {repo, store} = MessageSignalHelpers.new_repo()
    session = MessageSignalHelpers.session_fixture()

    repo =
      repo
      |> inject_session!("15551234567:0@s.whatsapp.net", session)
      |> inject_session!("15551234567:2@s.whatsapp.net", session)
      |> inject_session!("15550001111:2@s.whatsapp.net", session)

    assert :ok =
             Store.set(store, %{
               :"device-list" => %{"15551234567" => ["0", "2"], "15550001111" => ["1", "2"]}
             })

    assert :ok =
             Store.set(store, %{
               tctoken: %{"15551234567@s.whatsapp.net" => %{token: "tc-token"}}
             })

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
            }, %{signal_repository: updated_repo}} =
             Sender.send(context, jid, %{text: "hello"},
               message_id_fun: fn _me_id -> "3EB0FIXEDID" end,
               timestamp_fun: fn -> 1_710_000_000_000 end
             )

    assert %{"15551234567.0" => %{history: history}} = updated_repo.adapter_state
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

    assert 3 == length(participants)

    assert Enum.any?(
             content,
             &match?(%BinaryNode{tag: "device-identity", content: {:binary, <<1, 2, 3>>}}, &1)
           )

    assert Enum.any?(content, &match?(%BinaryNode{tag: "tctoken", content: "tc-token"}, &1))

    assert Enum.any?(participants, fn
             %BinaryNode{
               tag: "to",
               attrs: %{"jid" => "15550001111:2@s.whatsapp.net"},
               content: [%BinaryNode{tag: "enc", attrs: %{"type" => "pkmsg", "phash" => phash}}]
             }
             when is_binary(phash) ->
               true

             _ ->
               false
           end)
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

    assert Map.has_key?(sender_key_memory, "15551234567:0@s.whatsapp.net")
    assert Map.has_key?(sender_key_memory, "15557654321:0@s.whatsapp.net")
    assert %{"15551234567" => ["0"]} = Store.get(store, :"device-list", ["15551234567"])
    assert %{"15557654321" => ["0"]} = Store.get(store, :"device-list", ["15557654321"])
    assert %{signal_repository: %Repository{}} = updated_context
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

  defp inject_session!(repo, jid, session) do
    assert {:ok, next_repo} = Repository.inject_e2e_session(repo, %{jid: jid, session: session})
    next_repo
  end
end
