defmodule BaileysEx.PublicApiTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias BaileysEx.Auth.FilePersistence
  alias BaileysEx.Auth.KeyStore
  alias BaileysEx.Auth.NativeFilePersistence
  alias BaileysEx.Auth.State, as: AuthState
  alias BaileysEx.BinaryNode
  alias BaileysEx.Connection.Config
  alias BaileysEx.Connection.EventEmitter
  alias BaileysEx.Connection.Supervisor
  alias BaileysEx.Crypto
  alias BaileysEx.Protocol.Proto.ADVSignedDeviceIdentity
  alias BaileysEx.Protocol.Proto.Message
  alias BaileysEx.Signal.Curve
  alias BaileysEx.Signal.Repository
  alias BaileysEx.Signal.Store
  alias BaileysEx.TestHelpers.MessageSignalHelpers
  alias BaileysEx.WAM

  defmodule FakeSocket do
    use GenServer

    alias BaileysEx.BinaryNode

    @spec start_link(keyword()) :: GenServer.on_start()
    def start_link(opts) do
      genserver_opts =
        case Keyword.fetch(opts, :name) do
          {:ok, name} -> [name: name]
          :error -> []
        end

      GenServer.start_link(__MODULE__, opts, genserver_opts)
    end

    @spec child_spec(keyword()) :: Supervisor.child_spec()
    def child_spec(opts) do
      %{
        id: __MODULE__,
        start: {__MODULE__, :start_link, [opts]},
        type: :worker,
        restart: :permanent,
        shutdown: 5_000
      }
    end

    def connect(server), do: GenServer.call(server, :connect)

    def request_pairing_code(server, phone_number, opts),
      do: GenServer.call(server, {:request_pairing_code, phone_number, opts})

    def send_presence_update(server, type),
      do: GenServer.call(server, {:send_presence_update, type})

    def query(server, %BinaryNode{} = node, timeout),
      do: GenServer.call(server, {:query, node, timeout}, timeout + 100)

    def send_node(server, %BinaryNode{} = node), do: GenServer.call(server, {:send_node, node})

    def send_wam_buffer(server, wam_buffer),
      do: GenServer.call(server, {:send_wam_buffer, wam_buffer})

    @impl true
    def init(opts) do
      {:ok,
       %{
         test_pid: Keyword.fetch!(opts, :test_pid),
         query_handler:
           Keyword.get(opts, :query_handler, fn _node, _timeout -> {:error, :unhandled} end)
       }}
    end

    @impl true
    def handle_call(:connect, _from, state) do
      send(state.test_pid, :fake_socket_connect)
      {:reply, :ok, state}
    end

    def handle_call({:request_pairing_code, phone_number, opts}, _from, state) do
      send(state.test_pid, {:fake_socket_pairing_code, phone_number, opts})
      {:reply, {:ok, "123-456"}, state}
    end

    def handle_call({:send_presence_update, type}, _from, state) do
      send(state.test_pid, {:fake_socket_presence_update, type})
      {:reply, :ok, state}
    end

    def handle_call({:query, node, timeout}, _from, state) do
      send(state.test_pid, {:fake_socket_query, node, timeout})
      {:reply, state.query_handler.(node, timeout), state}
    end

    def handle_call({:send_node, node}, _from, state) do
      send(state.test_pid, {:fake_socket_send_node, node})
      {:reply, :ok, state}
    end

    def handle_call({:send_wam_buffer, wam_buffer}, _from, state) do
      send(state.test_pid, {:fake_socket_send_wam_buffer, wam_buffer})

      {:reply,
       {:ok,
        %BinaryNode{
          tag: "iq",
          attrs: %{"type" => "result", "xmlns" => "w:stats"},
          content: nil
        }}, state}
    end

    @impl true
    def handle_info({:sync_creds_update, creds_update}, state) do
      send(state.test_pid, {:fake_socket_sync_creds_update, creds_update})
      {:noreply, state}
    end
  end

  defmodule StartupEmitSignalStore do
    @behaviour BaileysEx.Signal.Store

    alias BaileysEx.Connection.EventEmitter
    alias BaileysEx.Signal.Store.Memory, as: SignalStoreMemory

    def child_spec(opts) do
      %{
        id: __MODULE__,
        start: {__MODULE__, :start_link, [opts]},
        type: :worker,
        restart: :permanent,
        shutdown: 5_000
      }
    end

    @impl true
    def start_link(opts) do
      startup_events =
        Keyword.get(opts, :startup_events, [%{connection: :connecting}, %{qr: "startup-qr"}])

      event_emitter = Keyword.fetch!(opts, :event_emitter)

      case SignalStoreMemory.start_link(Keyword.drop(opts, [:event_emitter, :startup_events])) do
        {:ok, pid} ->
          Enum.each(startup_events, fn update ->
            :ok = EventEmitter.emit(event_emitter, :connection_update, update)
          end)

          {:ok, pid}

        {:error, _reason} = error ->
          error
      end
    end

    @impl true
    def wrap(pid), do: SignalStoreMemory.wrap(pid)

    @impl true
    def get(ref, type, ids), do: SignalStoreMemory.get(ref, type, ids)

    @impl true
    def set(ref, data), do: SignalStoreMemory.set(ref, data)

    @impl true
    def clear(ref), do: SignalStoreMemory.clear(ref)

    @impl true
    def transaction(ref, key, fun), do: SignalStoreMemory.transaction(ref, key, fun)

    @impl true
    def in_transaction?(ref), do: SignalStoreMemory.in_transaction?(ref)
  end

  test "connect/2 wires convenience callbacks and subscribe/2 emits friendly events" do
    parent = self()

    assert {:ok, connection} =
             BaileysEx.connect(%{creds: %{}},
               config: Config.new(fire_init_queries: false),
               socket_module: FakeSocket,
               test_pid: self(),
               on_connection: &send(parent, {:on_connection, &1}),
               on_qr: &send(parent, {:on_qr, &1})
             )

    assert_receive :fake_socket_connect

    assert {:ok, emitter} = BaileysEx.event_emitter(connection)

    unsubscribe =
      BaileysEx.subscribe(connection, fn event ->
        send(parent, {:public_event, event})
      end)

    assert :ok = EventEmitter.emit(emitter, :connection_update, %{connection: :open})
    assert :ok = EventEmitter.emit(emitter, :connection_update, %{qr: "phase-12-qr"})

    message = %{key: %{id: "message-1"}, message: %Message{conversation: "hello"}}

    assert :ok =
             EventEmitter.emit(emitter, :messages_upsert, %{type: :notify, messages: [message]})

    assert_receive {:on_connection, %{connection: :open}}
    assert_receive {:on_qr, "phase-12-qr"}
    assert_receive {:public_event, {:connection, %{connection: :open}}}
    assert_receive {:public_event, {:connection, %{qr: "phase-12-qr"}}}
    assert_receive {:public_event, {:message, ^message}}

    unsubscribe.()
    assert :ok = BaileysEx.disconnect(connection)
  end

  test "connect/2 delivers startup callback events emitted before the runtime returns" do
    parent = self()
    connection_name = {:phase12_startup_callbacks, System.unique_integer([:positive])}

    event_emitter =
      {:global, {BaileysEx.Connection.Supervisor, connection_name, EventEmitter}}

    assert {:ok, connection} =
             BaileysEx.connect(%{creds: %{}},
               name: connection_name,
               config: Config.new(fire_init_queries: false),
               socket_module: FakeSocket,
               signal_store_module: StartupEmitSignalStore,
               signal_store_opts: [event_emitter: event_emitter],
               test_pid: self(),
               on_connection: &send(parent, {:startup_on_connection, &1}),
               on_qr: &send(parent, {:startup_on_qr, &1})
             )

    assert_receive {:startup_on_connection, %{connection: :connecting}}
    assert_receive {:startup_on_qr, "startup-qr"}
    assert_receive :fake_socket_connect

    assert :ok = BaileysEx.disconnect(connection)
  end

  test "request_pairing_code/3 forwards only public pairing options" do
    assert {:ok, connection} =
             BaileysEx.connect(%{creds: %{}},
               config: Config.new(fire_init_queries: false),
               socket_module: FakeSocket,
               test_pid: self()
             )

    assert_receive :fake_socket_connect

    assert {:ok, "123-456"} =
             BaileysEx.request_pairing_code(connection, "15551234567",
               custom_pairing_code: "ABCDEFGH",
               pairing_iterations: 1
             )

    assert_receive {:fake_socket_pairing_code, "15551234567", [custom_pairing_code: "ABCDEFGH"]}

    assert :ok = BaileysEx.disconnect(connection)
  end

  test "subscribe/2 and subscribe_raw/2 return an error after disconnect" do
    assert {:ok, connection} =
             BaileysEx.connect(%{creds: %{}},
               config: Config.new(fire_init_queries: false),
               socket_module: FakeSocket,
               test_pid: self()
             )

    assert_receive :fake_socket_connect
    assert :ok = BaileysEx.disconnect(connection)

    assert {:error, :event_emitter_not_available} =
             BaileysEx.subscribe_raw(connection, fn _events -> :ok end)

    assert {:error, :event_emitter_not_available} =
             BaileysEx.subscribe(connection, fn _event -> :ok end)
  end

  test "send_message/4 and send_status/3 report when the signal repository is not ready" do
    assert {:ok, connection} =
             BaileysEx.connect(
               %{creds: %{me: %{id: "15550001111:1@s.whatsapp.net", name: "Bailey"}}},
               config: Config.new(fire_init_queries: false),
               socket_module: FakeSocket,
               test_pid: self()
             )

    assert_receive :fake_socket_connect

    assert {:error, :signal_repository_not_ready} =
             BaileysEx.send_message(connection, "15551234567@s.whatsapp.net", %{text: "hello"})

    assert {:error, :signal_repository_not_ready} =
             BaileysEx.send_status(connection, %{text: "status"})

    assert :ok = BaileysEx.disconnect(connection)
  end

  @tag :tmp_dir
  test "built-in persisted auth helpers wire Auth.KeyStore into the runtime across backends",
       %{tmp_dir: tmp_dir} do
    Enum.each(
      [
        {FilePersistence, :use_multi_file_auth_state, "compat", "Persisted"},
        {NativeFilePersistence, :use_native_file_auth_state, "native", "Persisted Native"}
      ],
      fn {persistence_module, helper_fun, subdir, expected_name} ->
        assert_runtime_persistence_contract(
          persistence_module,
          helper_fun,
          Path.join(tmp_dir, subdir),
          expected_name
        )
      end
    )
  end

  test "auth_state/1 returns the live socket auth state during creds_update callbacks" do
    initial_auth_state = %{creds: %{me: %{name: "Initial"}}}
    updated_auth_state = %{creds: %{me: %{name: "Live"}}}
    parent = self()

    assert {:ok, connection} =
             BaileysEx.connect(initial_auth_state,
               config: Config.new(fire_init_queries: false),
               socket_module: FakeSocket,
               test_pid: self()
             )

    assert_receive :fake_socket_connect
    assert {:ok, emitter} = BaileysEx.event_emitter(connection)

    unsubscribe =
      BaileysEx.subscribe_raw(connection, fn events ->
        if creds_update = events[:creds_update] do
          send(parent, {:seen_live_auth_state, BaileysEx.auth_state(connection), creds_update})
        end
      end)

    assert :ok = EventEmitter.emit(emitter, :creds_update, %{me: %{name: "Live"}})

    assert_receive {:seen_live_auth_state, {:ok, ^updated_auth_state}, %{me: %{name: "Live"}}}

    unsubscribe.()
    assert :ok = BaileysEx.disconnect(connection)
  end

  test "send_message/4 uses the default production Signal adapter when auth credentials are present" do
    bundles = %{
      "15551234567@s.whatsapp.net" => signal_bundle(200, 201, 202, 2_000, 5, 10),
      "15550001111:2@s.whatsapp.net" => signal_bundle(300, 301, 302, 3_000, 6, 11)
    }

    query_handler = fn
      %BinaryNode{
        attrs: %{"xmlns" => "encrypt", "type" => "get"},
        content: [%BinaryNode{tag: "key", content: users}]
      },
      _timeout ->
        {:ok,
         %BinaryNode{
           tag: "iq",
           attrs: %{"type" => "result"},
           content: [
             %BinaryNode{
               tag: "list",
               attrs: %{},
               content:
                 Enum.map(users, fn %BinaryNode{tag: "user", attrs: %{"jid" => jid}} ->
                   session_bundle_user_node(jid, Map.fetch!(bundles, jid))
                 end)
             }
           ]
         }}

      _node, _timeout ->
        {:error, :unexpected_query}
    end

    assert {:ok, connection} =
             BaileysEx.connect(
               signal_auth_state("15550001111:1@s.whatsapp.net"),
               config: Config.new(fire_init_queries: false),
               socket_module: FakeSocket,
               test_pid: self(),
               query_handler: query_handler
             )

    assert_receive :fake_socket_connect

    assert %Store{} = signal_store = Supervisor.signal_store(connection)

    assert :ok =
             Store.set(signal_store, %{
               :"device-list" => %{"15551234567" => ["0"], "15550001111" => ["1", "2"]}
             })

    assert {:ok, %{id: "3EB0DEFAULT"}} =
             BaileysEx.send_message(connection, "15551234567@s.whatsapp.net", %{text: "hello"},
               message_id_fun: fn _me_id -> "3EB0DEFAULT" end
             )

    assert_receive {:fake_socket_query,
                    %BinaryNode{
                      attrs: %{"xmlns" => "encrypt", "type" => "get"},
                      content: [
                        %BinaryNode{
                          tag: "key",
                          content: [
                            %BinaryNode{
                              tag: "user",
                              attrs: %{"jid" => "15551234567@s.whatsapp.net"}
                            },
                            %BinaryNode{
                              tag: "user",
                              attrs: %{"jid" => "15550001111:2@s.whatsapp.net"}
                            }
                          ]
                        }
                      ]
                    }, _timeout}

    assert_receive {:fake_socket_send_node,
                    %BinaryNode{
                      tag: "message",
                      attrs: %{"id" => "3EB0DEFAULT", "to" => "15551234567@s.whatsapp.net"},
                      content: content
                    }}

    assert %BinaryNode{tag: "participants", content: participants} =
             Enum.find(content, &match?(%BinaryNode{tag: "participants"}, &1))

    assert Enum.any?(participants, fn
             %BinaryNode{
               tag: "to",
               attrs: %{"jid" => "15551234567@s.whatsapp.net"},
               content: [%BinaryNode{tag: "enc", attrs: %{"type" => "pkmsg"}}]
             } ->
               true

             _ ->
               false
           end)

    assert :ok = BaileysEx.disconnect(connection)
  end

  test "send_presence_update/4 injects the connection me id for composing chatstate" do
    assert {:ok, connection} =
             BaileysEx.connect(
               signal_auth_state("15550001111:1@s.whatsapp.net"),
               config: Config.new(fire_init_queries: false),
               socket_module: FakeSocket,
               test_pid: self()
             )

    assert_receive :fake_socket_connect

    assert :ok =
             BaileysEx.send_presence_update(
               connection,
               :composing,
               "15551234567@s.whatsapp.net"
             )

    assert_receive {:fake_socket_send_node,
                    %BinaryNode{
                      tag: "chatstate",
                      attrs: %{
                        "from" => "15550001111:1@s.whatsapp.net",
                        "to" => "15551234567@s.whatsapp.net"
                      },
                      content: [%BinaryNode{tag: "composing", attrs: %{}, content: nil}]
                    }}

    assert :ok = BaileysEx.disconnect(connection)
  end

  test "send_message/4 and group_create/4 use the connection runtime" do
    {repo, _store} = MessageSignalHelpers.new_repo()
    session = MessageSignalHelpers.session_fixture()

    {:ok, repo} =
      Repository.inject_e2e_session(repo, %{
        jid: "15551234567:0@s.whatsapp.net",
        session: session
      })

    {:ok, repo} =
      Repository.inject_e2e_session(repo, %{
        jid: "15550001111:2@s.whatsapp.net",
        session: session
      })

    query_handler = fn _node, _timeout ->
      {:ok,
       %BinaryNode{
         tag: "iq",
         attrs: %{"type" => "result"},
         content: [
           %BinaryNode{
             tag: "group",
             attrs: %{
               "id" => "120363001234567890@g.us",
               "subject" => "Phase 12",
               "s_t" => "1710000000",
               "size" => "1",
               "creation" => "1710000000"
             }
           }
         ]
       }}
    end

    assert {:ok, connection} =
             BaileysEx.connect(
               %{creds: %{me: %{id: "15550001111:1@s.whatsapp.net", name: "Bailey"}}},
               config: Config.new(fire_init_queries: false),
               socket_module: FakeSocket,
               test_pid: self(),
               query_handler: query_handler,
               signal_repository_adapter: MessageSignalHelpers.FakeAdapter,
               signal_repository_adapter_state: repo.adapter_state
             )

    assert_receive :fake_socket_connect

    assert %Store{} = signal_store = Supervisor.signal_store(connection)

    assert :ok =
             Store.set(signal_store, %{
               :"device-list" => %{"15551234567" => ["0"], "15550001111" => ["1", "2"]}
             })

    assert {:ok, %{id: "3EB0PUBLIC"}} =
             BaileysEx.send_message(connection, "15551234567@s.whatsapp.net", %{text: "hello"},
               message_id_fun: fn _me_id -> "3EB0PUBLIC" end
             )

    assert_receive {:fake_socket_send_node,
                    %BinaryNode{
                      tag: "message",
                      attrs: %{"id" => "3EB0PUBLIC", "to" => "15551234567@s.whatsapp.net"}
                    }}

    assert {:ok, {FakeSocket, _socket_pid}} = BaileysEx.queryable(connection)

    assert {:ok, %{id: "120363001234567890@g.us", subject: "Phase 12"}} =
             BaileysEx.group_create(connection, "Phase 12", ["15551234567@s.whatsapp.net"])

    assert_receive {:fake_socket_query,
                    %BinaryNode{
                      tag: "iq",
                      attrs: %{"to" => "@g.us", "type" => "set", "xmlns" => "w:g2"}
                    }, _timeout}

    assert :ok = BaileysEx.disconnect(connection)
  end

  test "group_metadata/3 and community_metadata/3 forward query_timeout opts" do
    query_handler = fn node, timeout ->
      case {List.first(node.content || []), timeout} do
        {%BinaryNode{tag: "query", attrs: %{"request" => "interactive"}}, 123} ->
          {:ok,
           %BinaryNode{
             tag: "iq",
             attrs: %{"type" => "result"},
             content: [
               %BinaryNode{
                 tag: "group",
                 attrs: %{
                   "id" => "120363001234567890@g.us",
                   "subject" => "Phase 12",
                   "s_t" => "1710000000",
                   "size" => "1",
                   "creation" => "1710000000"
                 }
               }
             ]
           }}

        {%BinaryNode{tag: "query", attrs: %{"request" => "interactive"}}, 456} ->
          {:ok,
           %BinaryNode{
             tag: "iq",
             attrs: %{"type" => "result"},
             content: [
               %BinaryNode{
                 tag: "community",
                 attrs: %{
                   "id" => "120363001234567890@g.us",
                   "subject" => "Phase 12 Community",
                   "s_t" => "1710000000",
                   "size" => "1",
                   "creation" => "1710000000"
                 }
               }
             ]
           }}

        _ ->
          {:error, :unhandled}
      end
    end

    assert {:ok, connection} =
             BaileysEx.connect(%{creds: %{}},
               config: Config.new(fire_init_queries: false),
               socket_module: FakeSocket,
               test_pid: self(),
               query_handler: query_handler
             )

    assert_receive :fake_socket_connect

    assert {:ok, %{id: "120363001234567890@g.us"}} =
             BaileysEx.group_metadata(connection, "120363001234567890@g.us", query_timeout: 123)

    assert_receive {:fake_socket_query,
                    %BinaryNode{
                      tag: "iq",
                      attrs: %{
                        "to" => "120363001234567890@g.us",
                        "type" => "get",
                        "xmlns" => "w:g2"
                      }
                    }, 123}

    assert {:ok, %{id: "120363001234567890@g.us"}} =
             BaileysEx.community_metadata(connection, "120363001234567890@g.us",
               query_timeout: 456
             )

    assert_receive {:fake_socket_query,
                    %BinaryNode{
                      tag: "iq",
                      attrs: %{
                        "to" => "120363001234567890@g.us",
                        "type" => "get",
                        "xmlns" => "w:g2"
                      }
                    }, 456}

    assert :ok = BaileysEx.disconnect(connection)
  end

  test "public facade exports the remaining source-supported helper wrappers" do
    wrappers = [
      {:archive_chat, 5},
      {:mute_chat, 4},
      {:pin_chat, 4},
      {:star_messages, 5},
      {:mark_chat_read, 5},
      {:clear_chat, 4},
      {:delete_chat, 4},
      {:delete_message_for_me, 6},
      {:read_messages, 3},
      {:update_link_previews_privacy, 3},
      {:on_whatsapp, 3},
      {:fetch_status, 3},
      {:business_profile, 3},
      {:update_profile_name, 3},
      {:update_profile_picture, 5},
      {:remove_profile_picture, 3},
      {:reject_call, 4},
      {:create_call_link, 4},
      {:group_participants_update, 5},
      {:group_update_subject, 4},
      {:group_update_description, 4},
      {:group_setting_update, 4},
      {:group_invite_code, 3},
      {:group_revoke_invite, 3},
      {:group_accept_invite, 3},
      {:group_get_invite_info, 3},
      {:group_accept_invite_v4, 4},
      {:group_revoke_invite_v4, 4},
      {:group_request_participants_list, 3},
      {:group_request_participants_update, 5},
      {:group_fetch_all_participating, 2},
      {:group_toggle_ephemeral, 4},
      {:group_member_add_mode, 4},
      {:group_join_approval_mode, 4},
      {:fetch_blocklist, 2},
      {:update_block_status, 4},
      {:update_last_seen_privacy, 3},
      {:update_online_privacy, 3},
      {:update_profile_picture_privacy, 3},
      {:update_status_privacy, 3},
      {:update_read_receipts_privacy, 3},
      {:update_groups_add_privacy, 3},
      {:update_default_disappearing_mode, 3},
      {:update_call_privacy, 3},
      {:update_messages_privacy, 3},
      {:update_business_cover_photo, 3},
      {:remove_business_cover_photo, 3},
      {:business_collections, 4},
      {:business_product_create, 3},
      {:business_product_update, 4},
      {:business_product_delete, 3},
      {:business_order_details, 4},
      {:newsletter_create, 4},
      {:newsletter_delete, 3},
      {:newsletter_update, 4},
      {:newsletter_subscribers, 3},
      {:newsletter_admin_count, 3},
      {:newsletter_mute, 3},
      {:newsletter_unmute, 3},
      {:newsletter_subscribe_updates, 3},
      {:newsletter_fetch_messages, 4},
      {:newsletter_react_message, 5},
      {:newsletter_update_name, 4},
      {:newsletter_update_description, 4},
      {:newsletter_update_picture, 4},
      {:newsletter_remove_picture, 3},
      {:newsletter_change_owner, 4},
      {:newsletter_demote, 4},
      {:community_create_group, 5},
      {:community_leave, 3},
      {:community_update_subject, 4},
      {:community_update_description, 4},
      {:community_link_group, 4},
      {:community_unlink_group, 4},
      {:community_fetch_linked_groups, 3},
      {:community_participants_update, 5},
      {:community_request_participants_list, 3},
      {:community_request_participants_update, 5},
      {:community_invite_code, 3},
      {:community_revoke_invite, 3},
      {:community_accept_invite, 3},
      {:community_get_invite_info, 3},
      {:community_accept_invite_v4, 4},
      {:community_revoke_invite_v4, 4},
      {:community_toggle_ephemeral, 4},
      {:community_setting_update, 4},
      {:community_member_add_mode, 4},
      {:community_join_approval_mode, 4},
      {:community_fetch_all_participating, 2}
    ]

    Enum.each(wrappers, fn {name, arity} ->
      assert function_exported?(BaileysEx, name, arity),
             "expected BaileysEx.#{name}/#{arity} to be exported"
    end)
  end

  test "new query-backed facade wrappers delegate through the runtime socket" do
    query_handler = fn
      %BinaryNode{
        tag: "call",
        attrs: %{"from" => "15550001111:1@s.whatsapp.net", "to" => "15551234567@s.whatsapp.net"}
      },
      321 ->
        {:ok, %BinaryNode{tag: "call", attrs: %{"type" => "result"}, content: nil}}

      %BinaryNode{
        tag: "iq",
        attrs: %{"to" => "120363001234567890@g.us", "type" => "get", "xmlns" => "w:g2"},
        content: [%BinaryNode{tag: "invite"}]
      },
      _timeout ->
        {:ok,
         %BinaryNode{
           tag: "iq",
           attrs: %{"type" => "result"},
           content: [%BinaryNode{tag: "invite", attrs: %{"code" => "INVITE-123"}}]
         }}

      %BinaryNode{
        tag: "iq",
        attrs: %{"to" => "s.whatsapp.net", "type" => "get", "xmlns" => "blocklist"}
      },
      _timeout ->
        {:ok,
         %BinaryNode{
           tag: "iq",
           attrs: %{"type" => "result"},
           content: [
             %BinaryNode{
               tag: "list",
               attrs: %{},
               content: [
                 %BinaryNode{tag: "item", attrs: %{"jid" => "11111@s.whatsapp.net"}},
                 %BinaryNode{tag: "item", attrs: %{"jid" => "22222@s.whatsapp.net"}}
               ]
             }
           ]
         }}

      %BinaryNode{
        tag: "iq",
        attrs: %{"to" => "s.whatsapp.net", "type" => "get", "xmlns" => "w:biz"}
      },
      987 ->
        {:ok,
         %BinaryNode{
           tag: "iq",
           attrs: %{"type" => "result"},
           content: [
             %BinaryNode{
               tag: "business_profile",
               attrs: %{},
               content: [
                 %BinaryNode{
                   tag: "profile",
                   attrs: %{"jid" => "15551234567@s.whatsapp.net"},
                   content: [
                     %BinaryNode{tag: "description", attrs: %{}, content: "Store profile"}
                   ]
                 }
               ]
             }
           ]
         }}

      _node, _timeout ->
        {:error, :unhandled}
    end

    assert {:ok, connection} =
             BaileysEx.connect(%{creds: %{me: %{id: "15550001111:1@s.whatsapp.net"}}},
               config: Config.new(fire_init_queries: false),
               socket_module: FakeSocket,
               test_pid: self(),
               query_handler: query_handler
             )

    assert_receive :fake_socket_connect

    assert {:ok, %BinaryNode{tag: "call"}} =
             BaileysEx.reject_call(
               connection,
               "call-1",
               "15551234567@s.whatsapp.net",
               query_timeout: 321
             )

    assert_receive {:fake_socket_query, %BinaryNode{tag: "call"}, 321}

    assert {:ok, "INVITE-123"} =
             BaileysEx.group_invite_code(connection, "120363001234567890@g.us")

    assert_receive {:fake_socket_query,
                    %BinaryNode{
                      tag: "iq",
                      attrs: %{
                        "to" => "120363001234567890@g.us",
                        "type" => "get",
                        "xmlns" => "w:g2"
                      }
                    }, _timeout}

    assert {:ok, ["11111@s.whatsapp.net", "22222@s.whatsapp.net"]} =
             BaileysEx.fetch_blocklist(connection)

    assert_receive {:fake_socket_query,
                    %BinaryNode{
                      tag: "iq",
                      attrs: %{
                        "to" => "s.whatsapp.net",
                        "type" => "get",
                        "xmlns" => "blocklist"
                      }
                    }, _timeout}

    assert {:ok, %{wid: "15551234567@s.whatsapp.net", description: "Store profile"}} =
             BaileysEx.business_profile(connection, "15551234567@s.whatsapp.net",
               query_timeout: 987
             )

    assert_receive {:fake_socket_query,
                    %BinaryNode{
                      tag: "iq",
                      attrs: %{
                        "to" => "s.whatsapp.net",
                        "type" => "get",
                        "xmlns" => "w:biz"
                      }
                    }, 987}

    assert :ok = BaileysEx.disconnect(connection)
  end

  test "send_wam_buffer/2 encodes BinaryInfo inputs before handing them to the socket" do
    assert {:ok, connection} =
             BaileysEx.connect(%{creds: %{}},
               config: Config.new(fire_init_queries: false),
               socket_module: FakeSocket,
               test_pid: self()
             )

    assert_receive :fake_socket_connect

    wam_buffer =
      WAM.new(sequence: 7)
      |> WAM.put_event(
        "WamDroppedEvent",
        [droppedEventCode: 5, droppedEventCount: 300, isFromWamsys: true],
        appIsBetaRelease: true,
        appVersion: "2.24.7"
      )

    assert {:ok, %BinaryNode{attrs: %{"xmlns" => "w:stats"}}} =
             BaileysEx.send_wam_buffer(connection, wam_buffer)

    assert_receive {:fake_socket_send_wam_buffer, encoded}

    assert encoded ==
             Base.decode16!(
               "57414D05010007002015801106322E32342E37390611FF31010541022C012603",
               case: :mixed
             )

    assert :ok = BaileysEx.disconnect(connection)
  end

  test "send_message/4 ignores unknown account identity keys and still relays device identity" do
    auth_state = %{
      creds: %{
        me: %{id: "15550001111:1@s.whatsapp.net", name: "Bailey"},
        account: %{
          "details" => <<1, 2>>,
          "account_signature_key" => <<9, 9>>,
          "account_signature" => <<3, 4>>,
          "device_signature" => <<5, 6>>,
          "extra" => "ignored"
        }
      }
    }

    assert {:ok, connection} = connect_runtime_with_fake_signal(auth_state)
    assert_receive :fake_socket_connect
    assert :ok = seed_runtime_device_list(connection)

    assert {:ok, %{id: "3EB0STRINGKEYS"}} =
             BaileysEx.send_message(connection, "15551234567@s.whatsapp.net", %{text: "hello"},
               message_id_fun: fn _me_id -> "3EB0STRINGKEYS" end
             )

    assert_receive {:fake_socket_send_node, %BinaryNode{content: content}}

    assert %BinaryNode{tag: "device-identity", content: {:binary, encoded_device_identity}} =
             Enum.find(content, &match?(%BinaryNode{tag: "device-identity"}, &1))

    assert {:ok,
            %ADVSignedDeviceIdentity{
              details: <<1, 2>>,
              account_signature_key: <<9, 9>>,
              account_signature: <<3, 4>>,
              device_signature: <<5, 6>>
            }} = ADVSignedDeviceIdentity.decode(encoded_device_identity)

    assert :ok = BaileysEx.disconnect(connection)
  end

  test "send_message/4 omits empty account signature keys from device identity" do
    auth_state = %{
      creds: %{
        me: %{id: "15550001111:1@s.whatsapp.net", name: "Bailey"},
        account: %{
          "details" => <<1, 2>>,
          "account_signature_key" => <<>>,
          "account_signature" => <<3, 4>>,
          "device_signature" => <<5, 6>>
        }
      }
    }

    assert {:ok, connection} = connect_runtime_with_fake_signal(auth_state)
    assert_receive :fake_socket_connect
    assert :ok = seed_runtime_device_list(connection)

    assert {:ok, %{id: "3EB0EMPTYSIGKEY"}} =
             BaileysEx.send_message(connection, "15551234567@s.whatsapp.net", %{text: "hello"},
               message_id_fun: fn _me_id -> "3EB0EMPTYSIGKEY" end
             )

    assert_receive {:fake_socket_send_node, %BinaryNode{content: content}}

    assert %BinaryNode{tag: "device-identity", content: {:binary, encoded_device_identity}} =
             Enum.find(content, &match?(%BinaryNode{tag: "device-identity"}, &1))

    assert {:ok,
            %ADVSignedDeviceIdentity{
              details: <<1, 2>>,
              account_signature_key: nil,
              account_signature: <<3, 4>>,
              device_signature: <<5, 6>>
            }} = ADVSignedDeviceIdentity.decode(encoded_device_identity)

    assert :ok = BaileysEx.disconnect(connection)
  end

  test "send_message/4 logs and drops malformed account identity data" do
    auth_state = %{
      creds: %{
        me: %{id: "15550001111:1@s.whatsapp.net", name: "Bailey"},
        account: %{
          "details" => 123,
          "account_signature" => <<3, 4>>,
          "device_signature" => <<5, 6>>
        }
      }
    }

    assert {:ok, connection} = connect_runtime_with_fake_signal(auth_state)
    assert_receive :fake_socket_connect
    assert :ok = seed_runtime_device_list(connection)

    log =
      capture_log(fn ->
        assert {:ok, %{id: "3EB0BADIDENTITY"}} =
                 BaileysEx.send_message(
                   connection,
                   "15551234567@s.whatsapp.net",
                   %{text: "hello"},
                   message_id_fun: fn _me_id -> "3EB0BADIDENTITY" end
                 )

        assert_receive {:fake_socket_send_node, %BinaryNode{content: content}}

        refute Enum.any?(content, &match?(%BinaryNode{tag: "device-identity"}, &1))
      end)

    assert log =~ "dropping invalid device identity account"
    assert log =~ "details"

    assert :ok = BaileysEx.disconnect(connection)
  end

  defp connect_runtime_with_fake_signal(auth_state) do
    {repo, _store} = MessageSignalHelpers.new_repo()
    session = MessageSignalHelpers.session_fixture()

    {:ok, repo} =
      Repository.inject_e2e_session(repo, %{
        jid: "15551234567:0@s.whatsapp.net",
        session: session
      })

    {:ok, repo} =
      Repository.inject_e2e_session(repo, %{
        jid: "15550001111:2@s.whatsapp.net",
        session: session
      })

    BaileysEx.connect(auth_state,
      config: Config.new(fire_init_queries: false),
      socket_module: FakeSocket,
      test_pid: self(),
      signal_repository_adapter: MessageSignalHelpers.FakeAdapter,
      signal_repository_adapter_state: repo.adapter_state
    )
  end

  defp seed_runtime_device_list(connection) do
    assert %Store{} = signal_store = Supervisor.signal_store(connection)

    Store.set(signal_store, %{
      :"device-list" => %{"15551234567" => ["0"], "15550001111" => ["1", "2"]}
    })
  end

  defp signal_key_pair(seed), do: Crypto.generate_key_pair(:x25519, private_key: <<seed::256>>)

  defp signal_auth_state(me_id) do
    identity_key = signal_key_pair(100)
    signed_pre_key_pair = signal_key_pair(101)
    {:ok, signed_pre_key} = Curve.signed_key_pair(identity_key, 1, key_pair: signed_pre_key_pair)

    AuthState.new(
      signed_identity_key: identity_key,
      signed_pre_key: signed_pre_key,
      registration_id: 1_234
    )
    |> AuthState.merge_updates(%{me: %{id: me_id, name: "Bailey"}})
  end

  defp signal_bundle(
         identity_seed,
         signed_pre_key_seed,
         pre_key_seed,
         registration_id,
         signed_pre_key_id,
         pre_key_id
       ) do
    identity_key = signal_key_pair(identity_seed)
    signed_pre_key_pair = signal_key_pair(signed_pre_key_seed)
    pre_key_pair = signal_key_pair(pre_key_seed)

    {:ok, signed_pre_key_public} = Curve.generate_signal_pub_key(signed_pre_key_pair.public)
    {:ok, signature} = Curve.sign(identity_key.private, signed_pre_key_public)

    %{
      registration_id: registration_id,
      identity_key: identity_key.public,
      signed_pre_key: %{
        key_id: signed_pre_key_id,
        public_key: signed_pre_key_pair.public,
        signature: signature
      },
      pre_key: %{key_id: pre_key_id, public_key: pre_key_pair.public}
    }
  end

  defp session_bundle_user_node(jid, bundle) do
    %BinaryNode{
      tag: "user",
      attrs: %{"jid" => jid},
      content: [
        %BinaryNode{
          tag: "registration",
          attrs: %{},
          content: {:binary, <<bundle.registration_id::unsigned-big-32>>}
        },
        %BinaryNode{
          tag: "identity",
          attrs: %{},
          content: {:binary, bundle.identity_key}
        },
        %BinaryNode{
          tag: "skey",
          attrs: %{},
          content: [
            %BinaryNode{
              tag: "id",
              attrs: %{},
              content: {:binary, <<bundle.signed_pre_key.key_id::unsigned-big-32>>}
            },
            %BinaryNode{
              tag: "value",
              attrs: %{},
              content: {:binary, bundle.signed_pre_key.public_key}
            },
            %BinaryNode{
              tag: "signature",
              attrs: %{},
              content: {:binary, bundle.signed_pre_key.signature}
            }
          ]
        },
        %BinaryNode{
          tag: "key",
          attrs: %{},
          content: [
            %BinaryNode{
              tag: "id",
              attrs: %{},
              content: {:binary, <<bundle.pre_key.key_id::unsigned-big-32>>}
            },
            %BinaryNode{
              tag: "value",
              attrs: %{},
              content: {:binary, bundle.pre_key.public_key}
            }
          ]
        }
      ]
    }
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition was not met in time")

  defp assert_runtime_persistence_contract(
         persistence_module,
         helper_fun,
         path,
         expected_name
       ) do
    assert {:ok, persisted_auth} = apply(persistence_module, helper_fun, [path])

    assert {:ok, connection} =
             BaileysEx.connect(
               persisted_auth.state,
               Keyword.merge(persisted_auth.connect_opts,
                 config: Config.new(fire_init_queries: false),
                 socket_module: FakeSocket,
                 test_pid: self()
               )
             )

    assert_receive :fake_socket_connect

    assert {:ok, %Store{module: KeyStore} = signal_store} = BaileysEx.signal_store(connection)
    assert :ok = Store.set(signal_store, %{:"device-list" => %{"15551234567" => ["0"]}})

    assert {:ok, ["0"]} =
             persistence_module.load_keys(path, :"device-list", "15551234567")

    assert {:ok, emitter} = BaileysEx.event_emitter(connection)
    assert :ok = EventEmitter.emit(emitter, :creds_update, %{me: %{name: expected_name}})

    assert_eventually(fn ->
      match?({:ok, %{me: %{name: ^expected_name}}}, BaileysEx.auth_state(connection))
    end)

    assert {:ok, latest_auth_state} = BaileysEx.auth_state(connection)
    assert :ok = persisted_auth.save_creds.(latest_auth_state)

    assert {:ok, %AuthState{me: %{name: ^expected_name}}} =
             persistence_module.load_credentials(path)

    assert :ok = BaileysEx.disconnect(connection)
  end
end
