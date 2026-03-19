defmodule BaileysEx.Feature.AppState do
  @moduledoc """
  App state sync (Syncd) — runtime orchestration for cross-device state
  synchronization.

  Provides patch construction, outbound push (`app_patch/3`), full resync
  (`resync_app_state/4`), and the high-level `chat_modify/4` entry point.
  Delegates encoding/decoding to `Syncd.Codec` and action mapping to
  `Syncd.ActionMapper`.

  Ports `appPatch`, `resyncAppState`, `chatModify` from Baileys `chats.ts:465-902`.
  """

  require Logger

  @type operation :: :set | :remove
  @type patch_type ::
          :critical_block | :critical_unblock_low | :regular_high | :regular_low | :regular

  @type patch :: %{
          required(:sync_action) => map(),
          required(:index) => [String.t()],
          required(:type) => patch_type(),
          required(:api_version) => pos_integer(),
          required(:operation) => operation()
        }

  alias BaileysEx.BinaryNode
  alias BaileysEx.Connection.EventEmitter
  alias BaileysEx.Connection.Store
  alias BaileysEx.Protocol.JID
  alias BaileysEx.Protocol.Proto.Syncd
  alias BaileysEx.Signal.Store, as: SignalStore
  alias BaileysEx.Syncd.ActionMapper
  alias BaileysEx.Syncd.Codec

  @max_sync_attempts 2

  # ============================================================================
  # Runtime orchestration — chats.ts:465-902
  # ============================================================================

  @doc """
  Full resync of app state collections from the server.

  Fetches snapshots and patches for each collection, decodes them, persists
  the updated LTHash state, and emits sync action events.

  Ports `resyncAppState` from `chats.ts:479-632`.

  ## Parameters

    * `queryable` — function or `{module, pid}` for sending IQ queries
    * `store` — Store server or Ref for key/version persistence
    * `collections` — list of collection names to sync
    * `opts` — options:
      - `:is_initial_sync` — boolean (default `false`)
      - `:event_emitter` — pid to receive events
      - `:me` — current user contact info
      - `:validate_snapshot_macs` — boolean (default `false`)
      - `:validate_patch_macs` — boolean (default `false`)
  """
  @spec resync_app_state(term(), GenServer.server(), [patch_type()], keyword()) ::
          :ok | {:error, term()}
  def resync_app_state(queryable, store, collections, opts \\ []) do
    is_initial_sync = Keyword.get(opts, :is_initial_sync, false)
    me = Keyword.get(opts, :me, %{})
    event_emitter = Keyword.get(opts, :event_emitter)
    validate_snapshot = Keyword.get(opts, :validate_snapshot_macs, false)
    validate_patch = Keyword.get(opts, :validate_patch_macs, false)
    state_store = app_state_store(store, opts)
    transaction_key = app_state_transaction_key(store, opts)
    codec_opts = Keyword.take(opts, [:external_blob_fetcher])

    Logger.warning(
      "[AppStateDiag] resync_app_state entering transaction key=#{inspect(transaction_key)}"
    )

    with_app_state_transaction(state_store, transaction_key, fn ->
      Logger.warning(
        "[AppStateDiag] transaction acquired, starting resync loop collections=#{inspect(collections)}"
      )

      context = %{
        queryable: queryable,
        state_store: state_store,
        get_key: fn key_id -> get_app_state_sync_key(state_store, key_id) end,
        validate_snapshot: validate_snapshot,
        validate_patch: validate_patch,
        codec_opts: codec_opts
      }

      case do_resync_loop(context, collections, %{
             attempts_map: %{},
             initial_version_map: %{},
             global_mutation_map: %{},
             global_mutation_order: []
           }) do
        {:ok,
         %{global_mutation_map: final_mutations, global_mutation_order: final_mutation_order}} ->
          Logger.warning(
            "[AppStateDiag] resync complete " <>
              "initial_sync=#{is_initial_sync} " <>
              "mutation_count=#{length(final_mutation_order)} " <>
              "push_name_mutation=#{push_name_mutation?(final_mutation_order)} " <>
              "mutation_heads=#{inspect(diagnostic_mutation_heads(final_mutation_order))}"
          )

          emit_mutation_map(
            event_emitter,
            final_mutations,
            final_mutation_order,
            me,
            initial_sync: is_initial_sync,
            account_settings: get_in(fetch_creds(store, opts), [:account_settings])
          )

        {:error, _} = err ->
          Logger.warning("[AppStateDiag] resync loop returned error: #{inspect(err)}")
          err

        other ->
          Logger.warning("[AppStateDiag] resync loop unexpected return: #{inspect(other)}")
          {:error, {:unexpected_return, other}}
      end
    end)
  end

  @doc """
  Send an outbound app state patch to the server.

  Acquires the current sync version, encodes the patch, sends it via IQ,
  and persists the updated state.

  Ports `appPatch` from `chats.ts:779-853`.

  ## Parameters

    * `queryable` — function or `{module, pid}` for sending IQ queries
    * `store` — Store server or Ref
    * `patch_create` — `%{type:, index:, sync_action:, api_version:, operation:}`
    * `opts` — options:
      - `:emit_own_events` — boolean (default `true`)
      - `:event_emitter` — pid
      - `:me` — current user contact info
  """
  @spec app_patch(
          term(),
          GenServer.server() | BaileysEx.Connection.Store.Ref.t(),
          patch(),
          keyword()
        ) :: :ok | {:error, term()}
  def app_patch(queryable, store, patch_create, opts \\ []) do
    emit_own = Keyword.get(opts, :emit_own_events, true)
    me = Keyword.get(opts, :me, %{})
    event_emitter = Keyword.get(opts, :event_emitter)
    state_store = app_state_store(store, opts)
    transaction_key = app_state_transaction_key(store, opts)
    name = patch_create.type

    with_app_state_transaction(state_store, transaction_key, fn ->
      creds = fetch_creds(store, opts)
      my_key_id = opts[:my_app_state_key_id] || creds[:my_app_state_key_id]

      case my_key_id do
        key_id when is_binary(key_id) and key_id != "" ->
          do_app_patch(%{
            queryable: queryable,
            store: store,
            state_store: state_store,
            patch_create: patch_create,
            my_key_id: key_id,
            name: name,
            emit_own: emit_own,
            event_emitter: event_emitter,
            me: me,
            opts: opts
          })

        _ ->
          {:error, :app_state_key_not_present}
      end
    end)
  end

  @doc """
  High-level chat modification — builds a patch and sends it.

  Ports `chatModify` from `chats.ts:899-902`.
  """
  @spec chat_modify(
          term(),
          GenServer.server() | BaileysEx.Connection.Store.Ref.t(),
          atom(),
          String.t(),
          term(),
          keyword()
        ) ::
          :ok | {:error, term()}
  def chat_modify(queryable, store, action, jid, value, opts \\ []) do
    patch = build_patch(action, jid, value, opts)
    app_patch(queryable, store, patch, opts)
  end

  @doc """
  Build a Baileys-style app-state patch for the given action and pass it to the
  provided transport callback when one is supplied.
  """
  @spec push_patch(term(), atom(), String.t(), term(), keyword()) ::
          {:ok, patch()} | {:error, term()}
  def push_patch(conn, action, jid, value, opts \\ []) when is_atom(action) and is_binary(jid) do
    patch = build_patch(action, jid, value, opts)

    case conn do
      fun when is_function(fun, 1) ->
        case fun.(patch) do
          {:ok, _result} -> {:ok, patch}
          :ok -> {:ok, patch}
          {:error, _reason} = error -> error
          _other -> {:ok, patch}
        end

      _ ->
        {:ok, patch}
    end
  end

  @doc """
  Construct the app-state patch structure without sending it.
  """
  @spec build_patch(atom(), String.t(), term(), keyword()) :: patch()
  def build_patch(action, jid, value, opts \\ []) when is_atom(action) and is_binary(jid) do
    timestamp = Keyword.get_lazy(opts, :timestamp, fn -> System.os_time(:millisecond) end)

    action
    |> patch_for(jid, value, timestamp)
    |> put_in([:sync_action, :timestamp], timestamp)
  end

  defp patch_for(:mute, jid, duration, _timestamp) do
    %{
      sync_action: %{
        mute_action: %{
          muted: is_integer(duration) and duration > 0,
          mute_end_timestamp: if(is_integer(duration) and duration > 0, do: duration)
        }
      },
      index: ["mute", jid],
      type: :regular_high,
      api_version: 2,
      operation: :set
    }
  end

  defp patch_for(:archive, jid, %{archive: archive?, last_messages: last_messages}, _timestamp) do
    %{
      sync_action: %{
        archive_chat_action: %{
          archived: !!archive?,
          message_range: message_range(last_messages)
        }
      },
      index: ["archive", jid],
      type: :regular_low,
      api_version: 3,
      operation: :set
    }
  end

  defp patch_for(:mark_read, jid, %{read: read?, last_messages: last_messages}, _timestamp) do
    %{
      sync_action: %{
        mark_chat_as_read_action: %{
          read: !!read?,
          message_range: message_range(last_messages)
        }
      },
      index: ["markChatAsRead", jid],
      type: :regular_low,
      api_version: 3,
      operation: :set
    }
  end

  defp patch_for(
         :delete_for_me,
         jid,
         %{
           key: key,
           timestamp: timestamp,
           delete_media: delete_media
         },
         _sync_timestamp
       ) do
    %{
      sync_action: %{
        delete_message_for_me_action: %{
          delete_media: !!delete_media,
          message_timestamp: timestamp
        }
      },
      index: ["deleteMessageForMe", jid, key[:id] || key["id"], from_me_index(key), "0"],
      type: :regular_high,
      api_version: 3,
      operation: :set
    }
  end

  defp patch_for(:clear, jid, %{last_messages: last_messages}, _timestamp) do
    %{
      sync_action: %{
        clear_chat_action: %{
          message_range: message_range(last_messages)
        }
      },
      index: ["clearChat", jid, "1", "0"],
      type: :regular_high,
      api_version: 6,
      operation: :set
    }
  end

  defp patch_for(:pin, jid, pin?, _timestamp) do
    %{
      sync_action: %{
        pin_action: %{
          pinned: !!pin?
        }
      },
      index: ["pin_v1", jid],
      type: :regular_low,
      api_version: 5,
      operation: :set
    }
  end

  defp patch_for(:contact, jid, nil, _timestamp) do
    %{
      sync_action: %{
        contact_action: %{}
      },
      index: ["contact", jid],
      type: :critical_unblock_low,
      api_version: 2,
      operation: :remove
    }
  end

  defp patch_for(:contact, jid, %{} = contact_action, _timestamp) do
    %{
      sync_action: %{
        contact_action: contact_action
      },
      index: ["contact", jid],
      type: :critical_unblock_low,
      api_version: 2,
      operation: :set
    }
  end

  defp patch_for(:disable_link_previews, _jid, disabled?, _timestamp) do
    action =
      if disabled? do
        %{is_previews_disabled: true}
      else
        %{}
      end

    %{
      sync_action: %{
        privacy_setting_disable_link_previews_action: action
      },
      index: ["setting_disableLinkPreviews"],
      type: :regular,
      api_version: 8,
      operation: :set
    }
  end

  defp patch_for(:star, jid, %{messages: [first | _rest], star: star?}, _timestamp) do
    %{
      sync_action: %{
        star_action: %{
          starred: !!star?
        }
      },
      index: ["star", jid, first[:id] || first["id"], from_me_index(first), "0"],
      type: :regular_low,
      api_version: 2,
      operation: :set
    }
  end

  defp patch_for(:delete, jid, %{last_messages: last_messages}, _timestamp) do
    %{
      sync_action: %{
        delete_chat_action: %{
          message_range: message_range(last_messages)
        }
      },
      index: ["deleteChat", jid, "1"],
      type: :regular_high,
      api_version: 6,
      operation: :set
    }
  end

  defp patch_for(:push_name_setting, _jid, name, _timestamp) when is_binary(name) do
    %{
      sync_action: %{
        push_name_setting: %{
          name: name
        }
      },
      index: ["setting_pushName"],
      type: :critical_block,
      api_version: 1,
      operation: :set
    }
  end

  defp patch_for(:quick_reply, _jid, %{} = quick_reply, timestamp) do
    quick_reply_timestamp =
      quick_reply
      |> value_get(:timestamp)
      |> case do
        nil -> Integer.to_string(div(timestamp, 1000))
        value -> to_string(value)
      end

    %{
      sync_action: %{
        quick_reply_action: %{
          count: 0,
          deleted: !!value_get(quick_reply, :deleted, false),
          keywords: [],
          message: value_get(quick_reply, :message, ""),
          shortcut: value_get(quick_reply, :shortcut, "")
        }
      },
      index: ["quick_reply", quick_reply_timestamp],
      type: :regular,
      api_version: 2,
      operation: :set
    }
  end

  defp patch_for(:add_label, _jid, %{} = label, _timestamp) do
    %{
      sync_action: %{
        label_edit_action: %{
          name: value_get(label, :name),
          color: value_get(label, :color),
          predefined_id: value_get(label, :predefined_id),
          deleted: value_get(label, :deleted)
        }
      },
      index: ["label_edit", value_get(label, :id)],
      type: :regular,
      api_version: 3,
      operation: :set
    }
  end

  defp patch_for(:add_chat_label, jid, %{} = value, _timestamp) do
    label_association_patch(jid, value, :chat, true)
  end

  defp patch_for(:remove_chat_label, jid, %{} = value, _timestamp) do
    label_association_patch(jid, value, :chat, false)
  end

  defp patch_for(:add_message_label, jid, %{} = value, _timestamp) do
    label_association_patch(jid, value, :message, true)
  end

  defp patch_for(:remove_message_label, jid, %{} = value, _timestamp) do
    label_association_patch(jid, value, :message, false)
  end

  defp patch_for(action, _jid, _value, _timestamp) do
    raise ArgumentError, "unsupported app-state patch action: #{inspect(action)}"
  end

  defp label_association_patch(jid, value, :chat, labeled?) do
    %{
      sync_action: %{
        label_association_action: %{
          labeled: labeled?
        }
      },
      index: ["label_jid", value_get(value, :label_id), jid],
      type: :regular,
      api_version: 3,
      operation: :set
    }
  end

  defp label_association_patch(jid, value, :message, labeled?) do
    %{
      sync_action: %{
        label_association_action: %{
          labeled: labeled?
        }
      },
      index: [
        "label_message",
        value_get(value, :label_id),
        jid,
        value_get(value, :message_id),
        "0",
        "0"
      ],
      type: :regular,
      api_version: 3,
      operation: :set
    }
  end

  defp message_range(last_messages) when is_list(last_messages) do
    last_message = List.last(last_messages)
    normalized_messages = Enum.map(last_messages, &normalize_last_message/1)

    %{
      last_message_timestamp: last_message && Map.get(last_message, :message_timestamp),
      messages: normalized_messages
    }
  end

  defp message_range(%{} = range), do: range

  defp normalize_last_message(%{} = message) do
    key = message_key!(message)
    id = required_key!(key, :id)
    remote_jid = required_key!(key, :remote_jid)
    from_me = Map.get(key, :from_me, Map.get(key, "from_me", false))
    participant = validate_participant(key, remote_jid, from_me)
    timestamp = message_timestamp!(message)

    normalized_key =
      normalized_key(key, id, remote_jid, from_me, participant)

    message
    |> put_message_key(normalized_key)
    |> put_message_timestamp(timestamp)
  end

  defp from_me_index(%{} = key) do
    if Map.get(key, :from_me, Map.get(key, "from_me", false)), do: "1", else: "0"
  end

  defp maybe_put_key(%{} = key, _field, nil), do: key

  defp maybe_put_key(%{} = key, field, value) do
    key
    |> Map.put(field, value)
    |> Map.put(Atom.to_string(field), value)
  end

  defp put_required_key(%{} = key, field, value) do
    key
    |> Map.put(field, value)
    |> Map.put(Atom.to_string(field), value)
  end

  defp message_key!(%{} = message) do
    Map.get(message, :key) || Map.get(message, "key") || raise ArgumentError, "missing key"
  end

  defp required_key!(%{} = key, field) do
    Map.get(key, field) || Map.get(key, Atom.to_string(field)) ||
      raise ArgumentError, "incomplete key: missing #{field}"
  end

  defp validate_participant(%{} = key, remote_jid, from_me) do
    participant = Map.get(key, :participant) || Map.get(key, "participant")

    if String.ends_with?(remote_jid, "@g.us") and not from_me and is_nil(participant) do
      raise ArgumentError, "expected participant on non-from-me group message"
    end

    case participant do
      value when is_binary(value) -> JID.normalized_user(value)
      _ -> nil
    end
  end

  defp message_timestamp!(%{} = message) do
    case Map.get(message, :message_timestamp) || Map.get(message, "message_timestamp") do
      timestamp when is_integer(timestamp) -> timestamp
      _ -> raise ArgumentError, "missing timestamp in last message list"
    end
  end

  defp normalized_key(key, id, remote_jid, from_me, participant) do
    key
    |> put_required_key(:id, id)
    |> put_required_key(:remote_jid, remote_jid)
    |> put_required_key(:from_me, from_me)
    |> maybe_put_key(:participant, participant)
  end

  defp put_message_key(%{} = message, normalized_key) do
    message
    |> Map.put(:key, normalized_key)
    |> Map.put("key", normalized_key)
  end

  defp put_message_timestamp(%{} = message, timestamp) do
    message
    |> Map.put(:message_timestamp, timestamp)
    |> Map.put("message_timestamp", timestamp)
  end

  defp value_get(%{} = value, key, default \\ nil) do
    Map.get(value, key, Map.get(value, Atom.to_string(key), default))
  end

  # ============================================================================
  # Resync loop — chats.ts:500-624
  # ============================================================================

  defp do_resync_loop(_context, [], loop_state), do: {:ok, loop_state}

  defp do_resync_loop(context, collections_to_handle, loop_state) do
    Logger.warning(
      "[AppStateDiag] resync_loop pass collections=#{inspect(collections_to_handle)}"
    )

    {iq_node, states, initial_version_map} =
      build_resync_request(
        context.state_store,
        collections_to_handle,
        loop_state.initial_version_map
      )

    loop_state = %{loop_state | initial_version_map: initial_version_map}

    Logger.warning("[AppStateDiag] sending sync query")

    with {:ok, response} <- query(context.queryable, iq_node),
         _ = Logger.warning("[AppStateDiag] sync query response received, extracting patches"),
         {:ok, decoded} <- Codec.extract_syncd_patches(response, context.codec_opts) do
      Logger.warning("[AppStateDiag] patches decoded, collections=#{inspect(Map.keys(decoded))}")

      loop_state =
        process_collections(
          decoded,
          Enum.filter(collections_to_handle, &(&1 in Map.keys(decoded))),
          states,
          loop_state,
          context
        )

      remaining = loop_state.remaining
      Logger.warning("[AppStateDiag] collections processed, remaining=#{inspect(remaining)}")

      do_resync_loop(context, remaining, Map.delete(loop_state, :remaining))
    else
      error ->
        Logger.warning("[AppStateDiag] resync_loop with failed: #{inspect(error)}")
        error
    end
  end

  defp build_resync_request(state_store, collections_to_handle, initial_version_map) do
    {nodes, states, initial_version_map} =
      Enum.reduce(collections_to_handle, {[], %{}, initial_version_map}, fn name,
                                                                            {nodes_acc,
                                                                             states_acc, ivm} ->
        {state, ivm} =
          case get_app_state_sync_version(state_store, name) do
            nil ->
              {Codec.new_lt_hash_state(), ivm}

            cached_state ->
              {cached_state, Map.put_new(ivm, name, cached_state.version)}
          end

        node = %BinaryNode{
          tag: "collection",
          attrs: %{
            "name" => Atom.to_string(name),
            "version" => to_string(state.version),
            "return_snapshot" => to_string(state.version == 0)
          }
        }

        {[node | nodes_acc], Map.put(states_acc, name, state), ivm}
      end)

    iq_node = %BinaryNode{
      tag: "iq",
      attrs: %{
        "to" => "s.whatsapp.net",
        "xmlns" => "w:sync:app:state",
        "type" => "set"
      },
      content: [%BinaryNode{tag: "sync", attrs: %{}, content: Enum.reverse(nodes)}]
    }

    {iq_node, states, initial_version_map}
  end

  defp process_collections(decoded, collections_to_handle, states, loop_state, context) do
    Enum.reduce(decoded, Map.put(loop_state, :remaining, collections_to_handle), fn
      {name, collection}, acc ->
        case process_single_collection(name, collection, Map.get(states, name), acc, context) do
          {:ok, updated_state} ->
            maybe_remove_collection(updated_state, name, collection.has_more_patches)

          {:error, reason} ->
            handle_collection_failure(acc, context.state_store, name, reason)
        end
    end)
  end

  defp process_single_collection(name, collection, state, loop_state, context) do
    state = state || Codec.new_lt_hash_state()

    with {:ok, state, mutation_map, mutation_order} <-
           maybe_decode_snapshot(name, collection.snapshot, state, loop_state, context),
         {:ok, _state, mutation_map, mutation_order, initial_version_map} <-
           maybe_decode_patches(
             name,
             collection.patches,
             state,
             mutation_map,
             mutation_order,
             loop_state,
             context
           ) do
      {:ok,
       %{
         loop_state
         | global_mutation_map: mutation_map,
           global_mutation_order: mutation_order,
           initial_version_map: initial_version_map
       }}
    end
  end

  defp maybe_decode_snapshot(_name, nil, state, loop_state, _context) do
    {:ok, state, loop_state.global_mutation_map, loop_state.global_mutation_order}
  end

  defp maybe_decode_snapshot(name, snapshot, _state, loop_state, context) do
    case Codec.decode_syncd_snapshot(
           name,
           snapshot,
           context.get_key,
           Map.get(loop_state.initial_version_map, name),
           context.validate_snapshot
         ) do
      {:ok, %{state: new_state, mutation_map: mutation_map, mutation_order: mutation_order}} ->
        put_app_state_sync_version(context.state_store, name, new_state)

        {:ok, new_state, Map.merge(loop_state.global_mutation_map, mutation_map),
         loop_state.global_mutation_order ++ mutation_order}

      {:error, _} = err ->
        err
    end
  end

  defp maybe_decode_patches(_name, [], state, mutation_map, mutation_order, loop_state, _context) do
    {:ok, state, mutation_map, mutation_order, loop_state.initial_version_map}
  end

  defp maybe_decode_patches(
         name,
         patches,
         state,
         mutation_map,
         mutation_order,
         loop_state,
         context
       ) do
    case Codec.decode_patches(
           name,
           patches,
           state,
           context.get_key,
           Map.get(loop_state.initial_version_map, name),
           context.validate_patch,
           context.codec_opts
         ) do
      {:ok,
       %{
         state: new_state,
         mutation_map: patch_mutation_map,
         mutation_order: patch_mutation_order
       }} ->
        put_app_state_sync_version(context.state_store, name, new_state)

        {:ok, new_state, Map.merge(mutation_map, patch_mutation_map),
         mutation_order ++ patch_mutation_order,
         Map.put(loop_state.initial_version_map, name, new_state.version)}

      {:error, _} = err ->
        err
    end
  end

  defp maybe_remove_collection(loop_state, _name, true), do: loop_state

  defp maybe_remove_collection(loop_state, name, false) do
    %{loop_state | remaining: List.delete(loop_state.remaining, name)}
  end

  defp handle_collection_failure(loop_state, state_store, name, reason) do
    attempts = Map.get(loop_state.attempts_map, name, 0) + 1
    irrecoverable? = attempts >= @max_sync_attempts or match?({:key_not_found, _}, reason)

    Logger.info(
      "failed to sync #{name}: #{inspect(reason)}" <>
        if(irrecoverable?, do: "", else: ", retrying from scratch")
    )

    put_app_state_sync_version(state_store, name, nil)

    %{
      loop_state
      | attempts_map: Map.put(loop_state.attempts_map, name, attempts),
        remaining:
          if(irrecoverable?,
            do: List.delete(loop_state.remaining, name),
            else: loop_state.remaining
          )
    }
  end

  # ============================================================================
  # Queryable dispatch
  # ============================================================================

  defp query(fun, node) when is_function(fun, 1), do: fun.(node)
  defp query({module, pid}, node), do: module.query(pid, node)
  defp query(pid, node) when is_pid(pid), do: GenServer.call(pid, {:query, node})

  defp do_app_patch(context) do
    get_key = fn key_id -> get_app_state_sync_key(context.state_store, key_id) end

    with :ok <- resync_app_state(context.queryable, context.store, [context.name], context.opts),
         initial <-
           get_app_state_sync_version(context.state_store, context.name) ||
             Codec.new_lt_hash_state(),
         {:ok, %{patch: patch, state: state}} <-
           Codec.encode_syncd_patch(context.patch_create, context.my_key_id, initial, get_key),
         {:ok, _response} <-
           query(context.queryable, build_patch_node(context.name, patch, state)) do
      put_app_state_sync_version(context.state_store, context.name, state)

      maybe_emit_own_patch_events(
        context.emit_own,
        context.event_emitter,
        context.name,
        patch,
        state,
        initial,
        get_key,
        context.me
      )
    end
  end

  defp maybe_emit_own_patch_events(
         false,
         _event_emitter,
         _name,
         _patch,
         _state,
         _initial,
         _get_key,
         _me
       ),
       do: :ok

  defp maybe_emit_own_patch_events(true, nil, _name, _patch, _state, _initial, _get_key, _me),
    do: :ok

  defp maybe_emit_own_patch_events(true, event_emitter, name, patch, state, initial, get_key, me) do
    versioned_patch = %{patch | version: %Syncd.SyncdVersion{version: state.version}}

    case Codec.decode_patches(name, [versioned_patch], initial, get_key) do
      {:ok, %{mutation_map: mutation_map, mutation_order: mutation_order}} ->
        emit_mutation_map(event_emitter, mutation_map, mutation_order, me, [])

      {:error, _} ->
        :ok
    end

    :ok
  end

  defp build_patch_node(name, patch, state) do
    patch_binary = Syncd.SyncdPatch.encode(patch)

    %BinaryNode{
      tag: "iq",
      attrs: %{
        "to" => "s.whatsapp.net",
        "type" => "set",
        "xmlns" => "w:sync:app:state"
      },
      content: [
        %BinaryNode{
          tag: "sync",
          attrs: %{},
          content: [
            %BinaryNode{
              tag: "collection",
              attrs: %{
                "name" => Atom.to_string(name),
                "version" => to_string(state.version - 1),
                "return_snapshot" => "false"
              },
              content: [
                %BinaryNode{tag: "patch", attrs: %{}, content: patch_binary}
              ]
            }
          ]
        }
      ]
    }
  end

  defp emit_mutation_map(nil, _mutation_map, _mutation_order, _me, _opts), do: :ok

  defp emit_mutation_map(event_emitter, mutation_map, mutation_order, me, opts) do
    ordered_mutations = mutation_order(mutation_map, mutation_order)

    emit_fun = fn ->
      _ =
        Enum.reduce(ordered_mutations, opts, fn mutation, emit_opts ->
          emit_one_mutation(event_emitter, mutation, me, emit_opts)
        end)

      :ok
    end

    if is_pid(event_emitter) or is_atom(event_emitter) do
      EventEmitter.create_buffered_function(event_emitter, emit_fun).()
    else
      emit_fun.()
    end
  end

  defp emit_one_mutation(event_emitter, mutation, me, opts) do
    events = ActionMapper.process_sync_action(mutation, me, opts)

    maybe_log_mutation_diagnostics(mutation, events)

    Enum.each(events, fn {event, data} -> :ok = EventEmitter.emit(event_emitter, event, data) end)

    update_mutation_opts(opts, events)
  end

  defp mutation_order(_mutation_map, [_ | _] = mutation_order), do: mutation_order

  defp mutation_order(mutation_map, _mutation_order),
    do: Enum.map(mutation_map, fn {_key, mutation} -> mutation end)

  defp maybe_log_mutation_diagnostics(mutation, events) do
    cond do
      push_name_mutation?(mutation) ->
        Logger.warning(
          "[AppStateDiag] push-name mutation " <>
            "index=#{inspect(mutation_index(mutation))} " <>
            "event_names=#{inspect(Enum.map(events, &elem(&1, 0)))} " <>
            "emitted_name=#{inspect(push_name_from_events(events))}"
        )

      is_binary(push_name_from_events(events)) ->
        Logger.warning(
          "[AppStateDiag] creds_update emitted push name " <>
            "from index=#{inspect(mutation_index(mutation))} " <>
            "name=#{inspect(push_name_from_events(events))}"
        )

      true ->
        :ok
    end
  end

  defp push_name_mutation?(mutations) when is_list(mutations),
    do: Enum.any?(mutations, &push_name_mutation?/1)

  defp push_name_mutation?(%{index: ["setting_pushName" | _rest]}), do: true
  defp push_name_mutation?(%{"index" => ["setting_pushName" | _rest]}), do: true
  defp push_name_mutation?(_mutation), do: false

  defp mutation_index(%{index: index}) when is_list(index), do: index
  defp mutation_index(%{"index" => index}) when is_list(index), do: index
  defp mutation_index(_mutation), do: []

  defp diagnostic_mutation_heads(mutations) when is_list(mutations) do
    mutations
    |> Enum.map(&mutation_index/1)
    |> Enum.map(fn
      [head | _rest] -> head
      [] -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp push_name_from_events(events) when is_list(events) do
    Enum.find_value(events, fn
      {:creds_update, %{me: %{name: name}}} when is_binary(name) and name != "" -> name
      {:creds_update, %{me: %{"name" => name}}} when is_binary(name) and name != "" -> name
      _other -> nil
    end)
  end

  defp update_mutation_opts(opts, events) do
    Enum.reduce(events, opts, fn
      {:creds_update, %{account_settings: account_settings}}, acc when is_map(account_settings) ->
        current = Keyword.get(acc, :account_settings, %{})
        Keyword.put(acc, :account_settings, Map.merge(current, account_settings))

      _event, acc ->
        acc
    end)
  end

  defp app_state_store(store, opts), do: Keyword.get(opts, :signal_store, store)

  defp app_state_transaction_key(store, opts) do
    Keyword.get(opts, :transaction_key) || get_in(fetch_creds(store, opts), [:me, :id]) ||
      "app-state"
  end

  defp with_app_state_transaction(%SignalStore{} = store, key, fun),
    do: SignalStore.transaction(store, key, fun)

  defp with_app_state_transaction(_store, _key, fun), do: fun.()

  defp fetch_creds(store, opts) do
    opts
    |> Keyword.get(:creds_store, store)
    |> do_fetch_creds()
  end

  defp do_fetch_creds(%Store.Ref{} = ref), do: Store.get(ref, :creds, %{})

  defp do_fetch_creds(server) when is_pid(server) or is_atom(server) do
    server
    |> Store.wrap()
    |> Store.get(:creds, %{})
  rescue
    ArgumentError -> %{}
  end

  defp do_fetch_creds(_store), do: %{}

  defp get_app_state_sync_key(%SignalStore{} = store, key_id) do
    case SignalStore.get(store, :"app-state-sync-key", [key_id]) do
      %{^key_id => %{key_data: _} = key_data} -> {:ok, key_data}
      %{^key_id => key_data} when is_binary(key_data) -> {:ok, %{key_data: key_data}}
      _ -> {:error, {:key_not_found, key_id}}
    end
  end

  defp get_app_state_sync_key(%Store.Ref{} = store, key_id),
    do: Store.get_app_state_sync_key(store, key_id)

  defp get_app_state_sync_key(store, key_id) when is_pid(store) or is_atom(store),
    do: Store.get_app_state_sync_key(store, key_id)

  defp get_app_state_sync_version(%SignalStore{} = store, collection_name) do
    key = Atom.to_string(collection_name)

    case SignalStore.get(store, :"app-state-sync-version", [key]) do
      %{^key => state} -> state
      _ -> nil
    end
  end

  defp get_app_state_sync_version(%Store.Ref{} = store, collection_name),
    do: Store.get_app_state_sync_version(store, collection_name)

  defp get_app_state_sync_version(store, collection_name) when is_pid(store) or is_atom(store),
    do: Store.get_app_state_sync_version(store, collection_name)

  defp put_app_state_sync_version(%SignalStore{} = store, collection_name, state) do
    key = Atom.to_string(collection_name)
    :ok = SignalStore.set(store, %{:"app-state-sync-version" => %{key => state}})
  end

  defp put_app_state_sync_version(%Store.Ref{} = store, collection_name, state),
    do: Store.put_app_state_sync_version(store, collection_name, state)

  defp put_app_state_sync_version(store, collection_name, state)
       when is_pid(store) or is_atom(store) do
    Store.put_app_state_sync_version(store, collection_name, state)
  end
end
