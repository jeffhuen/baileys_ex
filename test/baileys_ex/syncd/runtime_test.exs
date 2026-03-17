defmodule BaileysEx.Syncd.RuntimeTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Connection.EventEmitter
  alias BaileysEx.Connection.Store
  alias BaileysEx.Feature.AppState
  alias BaileysEx.Protocol.Proto.Syncd
  alias BaileysEx.Signal.Store, as: SignalStore
  alias BaileysEx.Syncd.Codec
  alias BaileysEx.Syncd.Keys

  @key_data :binary.copy(<<0xAB>>, 32)
  @key_id_bin <<1, 2, 3, 4>>
  @key_id_b64 Base.encode64(@key_id_bin)

  defp start_store(extra_entries \\ %{}) do
    {:ok, store} = Store.start_link(auth_state: %{})

    # Store the app state sync key
    Store.put_app_state_sync_key(store, @key_id_b64, %{key_data: @key_data})

    # Store the my_app_state_key_id in creds
    Store.put(store, :creds, %{my_app_state_key_id: @key_id_b64})

    for {k, v} <- extra_entries do
      Store.put(store, k, v)
    end

    store
  end

  defp start_signal_store(extra_families \\ %{}) do
    {:ok, store} = SignalStore.start_link()
    :ok = SignalStore.set(store, %{:"app-state-sync-key" => %{@key_id_b64 => @key_data}})

    Enum.each(extra_families, fn {family, values} ->
      :ok = SignalStore.set(store, %{family => values})
    end)

    store
  end

  defp empty_sync_response do
    %{
      tag: "iq",
      attrs: %{},
      content: [
        %{
          tag: "sync",
          attrs: %{},
          content: []
        }
      ]
    }
  end

  defp patch_query_version(%{
         content: [%{tag: "sync", content: [%{tag: "collection"} = collection]}]
       }) do
    if Enum.any?(List.wrap(collection.content), &match?(%{tag: "patch"}, &1)) do
      collection.attrs["version"]
    else
      nil
    end
  end

  describe "Store app state sync key helpers" do
    test "get/put app state sync key roundtrip" do
      store = start_store()
      ref = Store.wrap(store)

      assert {:ok, %{key_data: @key_data}} =
               Store.get_app_state_sync_key(ref, @key_id_b64)
    end

    test "missing key returns error" do
      store = start_store()
      ref = Store.wrap(store)

      assert {:error, {:key_not_found, "nonexistent"}} =
               Store.get_app_state_sync_key(ref, "nonexistent")
    end

    test "get/put app state sync version roundtrip" do
      store = start_store()
      ref = Store.wrap(store)

      state = %{version: 5, hash: Codec.new_lt_hash_state().hash, index_value_map: %{}}
      Store.put_app_state_sync_version(store, :regular_high, state)

      assert Store.get_app_state_sync_version(ref, :regular_high) == state
    end

    test "missing version returns nil" do
      store = start_store()
      ref = Store.wrap(store)

      assert Store.get_app_state_sync_version(ref, :regular_high) == nil
    end
  end

  describe "app_patch/4" do
    test "encodes patch and sends IQ to queryable" do
      store = start_store()
      me = self()

      # Mock queryable that captures the sent node
      queryable = fn node ->
        send(me, {:query_sent, node})
        {:ok, %{tag: "iq", attrs: %{}, content: []}}
      end

      patch_create = %{
        type: :regular_high,
        index: ["mute", "user@s.whatsapp.net"],
        sync_action: %Syncd.SyncActionValue{
          timestamp: 1_710_000_000,
          mute_action: %Syncd.MuteAction{muted: true, mute_end_timestamp: 1_710_086_400}
        },
        api_version: 2,
        operation: :set
      }

      assert :ok = AppState.app_patch(queryable, store, patch_create, emit_own_events: false)

      # Verify the IQ was sent (the resync query + the patch query)
      # First query is the resync (which returns empty), second is the actual patch
      assert_received {:query_sent, %{tag: "iq", attrs: %{"xmlns" => "w:sync:app:state"}}}
      assert_received {:query_sent, %{tag: "iq", attrs: %{"xmlns" => "w:sync:app:state"}}}
    end

    test "persists updated sync version to store" do
      store = start_store()

      queryable = fn _node ->
        {:ok, %{tag: "iq", attrs: %{}, content: []}}
      end

      patch_create = %{
        type: :regular_high,
        index: ["pin_v1", "user@s.whatsapp.net"],
        sync_action: %Syncd.SyncActionValue{
          timestamp: 1_710_000_000,
          pin_action: %Syncd.PinAction{pinned: true}
        },
        api_version: 5,
        operation: :set
      }

      assert :ok = AppState.app_patch(queryable, store, patch_create, emit_own_events: false)

      # Verify state was persisted
      ref = Store.wrap(store)
      state = Store.get_app_state_sync_version(ref, :regular_high)
      assert state != nil
      assert state.version == 1
      assert byte_size(state.hash) == 128
      assert state.hash != <<0::1024>>
    end

    test "uses signal store for app state keys and versions when provided" do
      {:ok, creds_store} = Store.start_link(auth_state: %{})
      Store.put(creds_store, :creds, %{my_app_state_key_id: @key_id_b64})
      signal_store = start_signal_store()

      queryable = fn _node -> {:ok, empty_sync_response()} end

      patch_create = %{
        type: :regular_high,
        index: ["pin_v1", "user@s.whatsapp.net"],
        sync_action: %Syncd.SyncActionValue{
          timestamp: 1_710_000_000,
          pin_action: %Syncd.PinAction{pinned: true}
        },
        api_version: 5,
        operation: :set
      }

      assert :ok =
               AppState.app_patch(queryable, creds_store, patch_create,
                 emit_own_events: false,
                 signal_store: signal_store
               )

      assert Store.get_app_state_sync_version(Store.wrap(creds_store), :regular_high) == nil

      assert %{"regular_high" => %{version: 1, hash: hash}} =
               SignalStore.get(signal_store, :"app-state-sync-version", ["regular_high"])

      assert byte_size(hash) == 128
    end

    test "returns error when app state key not present" do
      {:ok, store} = Store.start_link(auth_state: %{})
      Store.put(store, :creds, %{})

      queryable = fn _node -> {:ok, %{tag: "iq"}} end

      patch = %{
        type: :regular_high,
        index: ["mute", "jid"],
        sync_action: %Syncd.SyncActionValue{},
        api_version: 2,
        operation: :set
      }

      assert {:error, :app_state_key_not_present} =
               AppState.app_patch(queryable, store, patch)
    end

    test "emits own events when enabled" do
      store = start_store()
      {:ok, emitter} = EventEmitter.start_link()
      parent = self()
      _unsubscribe = EventEmitter.process(emitter, &send(parent, {:events, &1}))

      queryable = fn _node ->
        {:ok, %{tag: "iq", attrs: %{}, content: []}}
      end

      patch_create = %{
        type: :regular_high,
        index: ["mute", "user@s.whatsapp.net"],
        sync_action: %Syncd.SyncActionValue{
          timestamp: 1_710_000_000,
          mute_action: %Syncd.MuteAction{muted: true, mute_end_timestamp: 1_710_086_400}
        },
        api_version: 2,
        operation: :set
      }

      assert :ok =
               AppState.app_patch(queryable, store, patch_create,
                 emit_own_events: true,
                 event_emitter: emitter,
                 me: %{name: "Test", id: "me@s.whatsapp.net"}
               )

      assert_receive {:events, %{chats_update: [%{mute_end_time: 1_710_086_400}]}}, 300
    end

    test "returns the resync error and skips the patch send when resync fails" do
      store = start_store()
      parent = self()

      queryable = fn node ->
        send(parent, {:query_sent, node})
        {:error, :timeout}
      end

      patch_create = %{
        type: :regular_high,
        index: ["mute", "user@s.whatsapp.net"],
        sync_action: %Syncd.SyncActionValue{
          timestamp: 1_710_000_000,
          mute_action: %Syncd.MuteAction{muted: true, mute_end_timestamp: 1_710_086_400}
        },
        api_version: 2,
        operation: :set
      }

      assert {:error, :timeout} =
               AppState.app_patch(queryable, store, patch_create, emit_own_events: false)

      assert_received {:query_sent, _node}
      refute_received {:query_sent, _second_node}
    end

    test "serializes concurrent patch sends through the signal store transaction" do
      {:ok, creds_store} = Store.start_link(auth_state: %{})
      Store.put(creds_store, :creds, %{my_app_state_key_id: @key_id_b64})
      signal_store = start_signal_store()
      parent = self()
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      queryable = fn node ->
        case patch_query_version(node) do
          nil ->
            {:ok, empty_sync_response()}

          version ->
            order = Agent.get_and_update(counter, fn current -> {current + 1, current + 1} end)
            send(parent, {:patch_query, order, version, self()})

            if order == 1 do
              receive do
                :release_first_patch -> :ok
              end
            end

            {:ok, %{tag: "iq", attrs: %{}, content: []}}
        end
      end

      patch = fn muted ->
        %{
          type: :regular_high,
          index: ["mute", "user@s.whatsapp.net"],
          sync_action: %Syncd.SyncActionValue{
            timestamp: 1_710_000_000,
            mute_action: %Syncd.MuteAction{muted: muted, mute_end_timestamp: 1_710_086_400}
          },
          api_version: 2,
          operation: :set
        }
      end

      task_1 =
        Task.async(fn ->
          AppState.app_patch(queryable, creds_store, patch.(true),
            emit_own_events: false,
            signal_store: signal_store
          )
        end)

      assert_receive {:patch_query, 1, "0", first_caller}

      task_2 =
        Task.async(fn ->
          AppState.app_patch(queryable, creds_store, patch.(false),
            emit_own_events: false,
            signal_store: signal_store
          )
        end)

      refute_receive {:patch_query, 2, _version, _caller}, 50

      send(first_caller, :release_first_patch)

      assert :ok = Task.await(task_1)
      assert_receive {:patch_query, 2, "1", second_caller}
      send(second_caller, :release_first_patch)
      assert :ok = Task.await(task_2)
    end
  end

  describe "chat_modify/6" do
    test "builds patch and sends it via app_patch" do
      store = start_store()
      me = self()

      queryable = fn node ->
        send(me, {:query_sent, node})
        {:ok, %{tag: "iq", attrs: %{}, content: []}}
      end

      # Use app_patch directly with proto structs (the correct path)
      patch_create = %{
        type: :regular_high,
        index: ["mute", "user@s.whatsapp.net"],
        sync_action: %Syncd.SyncActionValue{
          timestamp: 1_710_000_000,
          mute_action: %Syncd.MuteAction{muted: true, mute_end_timestamp: 1_710_086_400}
        },
        api_version: 2,
        operation: :set
      }

      assert :ok = AppState.app_patch(queryable, store, patch_create, emit_own_events: false)

      # Should have sent resync + patch queries
      assert_received {:query_sent, _}
      assert_received {:query_sent, _}
    end
  end

  describe "resync_app_state/4" do
    test "processes server response with patches" do
      store = start_store()
      keys = Keys.expand_app_state_keys(@key_data)
      {:ok, emitter} = EventEmitter.start_link()
      parent = self()
      _unsubscribe = EventEmitter.process(emitter, &send(parent, {:events, &1}))
      iv = :binary.copy(<<0x42>>, 16)

      # Build a valid encoded patch that the server would return
      state = Codec.new_lt_hash_state()

      patch_create = %{
        type: :regular_high,
        index: ["mute", "user@s.whatsapp.net"],
        sync_action: %Syncd.SyncActionValue{
          timestamp: 1_710_000_000,
          mute_action: %Syncd.MuteAction{muted: true, mute_end_timestamp: 1_710_086_400}
        },
        api_version: 2,
        operation: :set
      }

      get_key = fn _kid -> {:ok, %{key_data: @key_data}} end

      {:ok, %{patch: patch, state: enc_state}} =
        Codec.encode_syncd_patch(patch_create, @key_id_b64, state, get_key, iv: iv)

      patch = %{patch | version: %Syncd.SyncdVersion{version: enc_state.version}}
      patch_binary = Syncd.SyncdPatch.encode(patch)

      # Mock queryable that returns a valid response
      queryable = fn _node ->
        {:ok,
         %{
           tag: "iq",
           attrs: %{},
           content: [
             %{
               tag: "sync",
               attrs: %{},
               content: [
                 %{
                   tag: "collection",
                   attrs: %{
                     "name" => "regular_high",
                     "version" => "1",
                     "has_more_patches" => "false"
                   },
                   content: [
                     %{tag: "patch", attrs: %{}, content: patch_binary}
                   ]
                 }
               ]
             }
           ]
         }}
      end

      assert :ok =
               AppState.resync_app_state(queryable, store, [:regular_high],
                 event_emitter: emitter,
                 me: %{name: "Test", id: "me@s.whatsapp.net"}
               )

      # Should receive a mute event
      assert_receive {:events, %{chats_update: [%{mute_end_time: 1_710_086_400}]}}, 300

      # State should be persisted
      ref = Store.wrap(store)
      state = Store.get_app_state_sync_version(ref, :regular_high)
      assert state != nil
      assert state.version == 1

      _ = keys
    end

    test "handles empty server response gracefully" do
      store = start_store()

      queryable = fn _node ->
        {:ok,
         %{
           tag: "iq",
           attrs: %{},
           content: [
             %{
               tag: "sync",
               attrs: %{},
               content: []
             }
           ]
         }}
      end

      assert :ok = AppState.resync_app_state(queryable, store, [:regular_high])
    end

    test "uses JS-parity MAC defaults for version 0 patches during a fresh sync" do
      store = start_store()
      {:ok, emitter} = EventEmitter.start_link()
      parent = self()
      _unsubscribe = EventEmitter.process(emitter, &send(parent, {:events, &1}))
      iv = :binary.copy(<<0x24>>, 16)

      patch_create = %{
        type: :regular_high,
        index: ["mute", "user@s.whatsapp.net"],
        sync_action: %Syncd.SyncActionValue{
          timestamp: 1_710_000_000,
          mute_action: %Syncd.MuteAction{muted: true, mute_end_timestamp: 1_710_086_400}
        },
        api_version: 2,
        operation: :set
      }

      get_key = fn _kid -> {:ok, %{key_data: @key_data}} end

      {:ok, %{patch: patch}} =
        Codec.encode_syncd_patch(
          patch_create,
          @key_id_b64,
          Codec.new_lt_hash_state(),
          get_key,
          iv: iv
        )

      version_zero_patch = %{
        patch
        | version: %Syncd.SyncdVersion{version: 0},
          snapshot_mac: <<0::256>>,
          patch_mac: <<0::256>>
      }

      patch_binary = Syncd.SyncdPatch.encode(version_zero_patch)

      queryable = fn _node ->
        {:ok,
         %{
           tag: "iq",
           attrs: %{},
           content: [
             %{
               tag: "sync",
               attrs: %{},
               content: [
                 %{
                   tag: "collection",
                   attrs: %{
                     "name" => "regular_high",
                     "version" => "0",
                     "has_more_patches" => "false"
                   },
                   content: [
                     %{tag: "patch", attrs: %{}, content: patch_binary}
                   ]
                 }
               ]
             }
           ]
         }}
      end

      assert :ok =
               AppState.resync_app_state(queryable, store, [:regular_high],
                 event_emitter: emitter
               )

      assert_receive {:events,
                      %{
                        chats_update: [%{id: "user@s.whatsapp.net", mute_end_time: 1_710_086_400}]
                      }},
                     300
    end

    test "initial sync threads unarchive_chats settings into later archive mutations" do
      store =
        start_store(%{
          creds: %{
            my_app_state_key_id: @key_id_b64,
            account_settings: %{unarchive_chats: true}
          }
        })

      {:ok, emitter} = EventEmitter.start_link()
      parent = self()
      _unsubscribe = EventEmitter.process(emitter, &send(parent, {:events, &1}))

      :ok =
        EventEmitter.seed(emitter, %{
          historySets: %{chats: %{"chat-1@s.whatsapp.net" => %{last_message_recv_timestamp: 150}}},
          chatUpserts: %{}
        })

      get_key = fn _kid -> {:ok, %{key_data: @key_data}} end

      {:ok, %{patch: setting_patch}} =
        Codec.encode_syncd_patch(
          %{
            type: :regular,
            index: ["setting_unarchiveChats"],
            sync_action: %Syncd.SyncActionValue{
              timestamp: 1_710_000_000,
              unarchive_chats_setting: %Syncd.UnarchiveChatsSetting{unarchive_chats: false}
            },
            api_version: 5,
            operation: :set
          },
          @key_id_b64,
          Codec.new_lt_hash_state(),
          get_key,
          iv: :binary.copy(<<0x11>>, 16)
        )

      {:ok, %{patch: archive_patch}} =
        Codec.encode_syncd_patch(
          %{
            type: :regular_high,
            index: ["archive", "chat-1@s.whatsapp.net"],
            sync_action: %Syncd.SyncActionValue{
              timestamp: 1_710_000_001,
              archive_chat_action: %Syncd.ArchiveChatAction{
                archived: true,
                message_range: %Syncd.SyncActionMessageRange{last_message_timestamp: 100}
              }
            },
            api_version: 3,
            operation: :set
          },
          @key_id_b64,
          Codec.new_lt_hash_state(),
          get_key,
          iv: :binary.copy(<<0x22>>, 16)
        )

      queryable = fn _node ->
        {:ok,
         %{
           tag: "iq",
           attrs: %{},
           content: [
             %{
               tag: "sync",
               attrs: %{},
               content: [
                 %{
                   tag: "collection",
                   attrs: %{
                     "name" => "regular",
                     "version" => "1",
                     "has_more_patches" => "false"
                   },
                   content: [
                     %{
                       tag: "patch",
                       attrs: %{},
                       content:
                         Syncd.SyncdPatch.encode(%{
                           setting_patch
                           | version: %Syncd.SyncdVersion{version: 0},
                             snapshot_mac: <<0::256>>,
                             patch_mac: <<0::256>>
                         })
                     },
                     %{
                       tag: "patch",
                       attrs: %{},
                       content:
                         Syncd.SyncdPatch.encode(%{
                           archive_patch
                           | version: %Syncd.SyncdVersion{version: 1},
                             snapshot_mac: <<0::256>>,
                             patch_mac: <<0::256>>
                         })
                     }
                   ]
                 }
               ]
             }
           ]
         }}
      end

      assert :ok =
               AppState.resync_app_state(queryable, store, [:regular],
                 event_emitter: emitter,
                 is_initial_sync: true,
                 validate_snapshot_macs: false,
                 validate_patch_macs: false
               )

      assert_receive {:events, %{creds_update: %{account_settings: %{unarchive_chats: false}}}},
                     300

      assert_receive {:events,
                      %{
                        chats_update: [
                          %{id: "chat-1@s.whatsapp.net", archived: true}
                        ]
                      }},
                     300
    end
  end

  describe "build_patch/4 (existing patch builder)" do
    test "mute patch structure unchanged" do
      patch =
        AppState.build_patch(:mute, "user@s.whatsapp.net", 1_710_086_400,
          timestamp: 1_710_000_000
        )

      assert patch.type == :regular_high
      assert patch.index == ["mute", "user@s.whatsapp.net"]
      assert patch.operation == :set
      assert patch.api_version == 2
    end
  end
end
