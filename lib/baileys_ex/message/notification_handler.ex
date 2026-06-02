defmodule BaileysEx.Message.NotificationHandler do
  @moduledoc """
  Message-layer notification handling aligned with Baileys rc.9.

  This module owns the non-auth notification cases that produce messaging,
  group, newsletter, and account-side effects above the raw socket layer.
  """

  require Logger

  alias BaileysEx.BinaryNode
  alias BaileysEx.Connection.EventEmitter
  alias BaileysEx.Feature.TcToken
  alias BaileysEx.Media.Retry, as: MediaRetry
  alias BaileysEx.Message.StubSideEffects
  alias BaileysEx.Protocol.BinaryNode, as: BinaryNodeUtil
  alias BaileysEx.Protocol.JID, as: JIDUtil
  alias BaileysEx.Protocol.MessageStubType
  alias BaileysEx.Protocol.Proto.Message
  alias BaileysEx.Signal.Repository
  alias BaileysEx.Signal.Store

  @reachout_enforcement_types MapSet.new([
                                "BIZ_COMMERCE_VIOLATION_ALCOHOL",
                                "BIZ_COMMERCE_VIOLATION_ADULT",
                                "BIZ_COMMERCE_VIOLATION_ANIMALS",
                                "BIZ_COMMERCE_VIOLATION_BODY_PARTS_FLUIDS",
                                "BIZ_COMMERCE_VIOLATION_DATING",
                                "BIZ_COMMERCE_VIOLATION_DIGITAL_SERVICES_PRODUCTS",
                                "BIZ_COMMERCE_VIOLATION_DRUGS",
                                "BIZ_COMMERCE_VIOLATION_DRUGS_ONLY_OTC",
                                "BIZ_COMMERCE_VIOLATION_GAMBLING",
                                "BIZ_COMMERCE_VIOLATION_HEALTHCARE",
                                "BIZ_COMMERCE_VIOLATION_REAL_FAKE_CURRENCY",
                                "BIZ_COMMERCE_VIOLATION_SUPPLEMENTS",
                                "BIZ_COMMERCE_VIOLATION_TOBACCO",
                                "BIZ_COMMERCE_VIOLATION_VIOLENT_CONTENT",
                                "BIZ_COMMERCE_VIOLATION_WEAPONS",
                                "BIZ_QUALITY",
                                "DEFAULT",
                                "WEB_COMPANION_ONLY"
                              ])

  @message_capping_fields [
    {"total_quota", :total_quota},
    {"used_quota", :used_quota},
    {"cycle_start_timestamp", :cycle_start_timestamp},
    {"cycle_end_timestamp", :cycle_end_timestamp},
    {"server_sent_timestamp", :server_sent_timestamp},
    {"ote_status", :ote_status},
    {"mv_status", :mv_status},
    {"capping_status", :capping_status}
  ]

  @type context :: %{
          optional(:event_emitter) => GenServer.server(),
          optional(:me_id) => String.t(),
          optional(:store_privacy_token_fun) => (String.t(), binary(), String.t() | nil ->
                                                   :ok | {:error, term()}),
          optional(:handle_encrypt_notification_fun) => (BinaryNode.t() -> term()),
          optional(:device_notification_fun) => (BinaryNode.t() -> term()),
          optional(:signal_store) => Store.t(),
          optional(:signal_repository) => Repository.t(),
          optional(:resync_app_state_fun) => (String.t() -> term()),
          optional(:now_seconds) => integer()
        }

  @doc """
  Processes a raw envelope notification node and maps it to runtime events.
  """
  @spec process_node(BinaryNode.t(), context()) :: :ok
  def process_node(%BinaryNode{tag: "notification", attrs: %{"type" => type}} = node, context) do
    dispatch_notification(type, node, context)
  end

  def process_node(%BinaryNode{}, _context), do: :ok

  defp dispatch_notification("w:gp2", node, context), do: handle_group_notification(node, context)

  defp dispatch_notification("encrypt", node, context),
    do: handle_encrypt_notification(node, context)

  defp dispatch_notification("devices", node, context),
    do: handle_devices_notification(node, context)

  defp dispatch_notification("picture", node, context),
    do: handle_picture_notification(node, context)

  defp dispatch_notification("account_sync", node, context),
    do: handle_account_sync_notification(node, context)

  defp dispatch_notification("server_sync", node, context),
    do: handle_server_sync_notification(node, context)

  defp dispatch_notification("mediaretry", node, context),
    do: handle_media_retry_notification(node, context)

  defp dispatch_notification("newsletter", node, context),
    do: handle_newsletter_notification(node, context)

  defp dispatch_notification("mex", node, context), do: handle_mex_notification(node, context)
  defp dispatch_notification("link_code_companion_reg", _node, _context), do: :ok

  defp dispatch_notification("privacy_token", node, context),
    do: TcToken.handle_notification(node, context)

  defp dispatch_notification(_type, _node, _context), do: :ok

  defp handle_group_notification(%BinaryNode{} = node, context) do
    case BinaryNodeUtil.children(node) do
      [child | _rest] ->
        emit_group_side_effects(node, child, context)

      [] ->
        :ok
    end
  end

  defp emit_group_side_effects(
         %BinaryNode{attrs: %{"from" => group_jid, "participant" => author} = attrs},
         %BinaryNode{tag: "create", attrs: create_attrs},
         context
       ) do
    emit(context, :chats_upsert, [
      %{
        id: create_attrs["id"] || group_jid,
        name: create_attrs["subject"],
        conversation_timestamp: parse_integer(create_attrs["creation"])
      }
    ])

    emit(context, :groups_upsert, [
      %{
        id: create_attrs["id"] || group_jid,
        subject: create_attrs["subject"],
        creation: parse_integer(create_attrs["creation"]),
        owner: create_attrs["creator"],
        author: author,
        author_username: attrs["participant_username"]
      }
    ])

    emit_group_message(context, attrs, %{
      message_stub_type: :GROUP_CREATE,
      message_stub_parameters: [create_attrs["subject"]]
    })
  end

  defp emit_group_side_effects(
         %BinaryNode{attrs: attrs},
         %BinaryNode{tag: "ephemeral", attrs: child_attrs},
         context
       ) do
    emit_group_message(context, attrs, %{
      message: %{
        protocol_message: %{
          type: :EPHEMERAL_SETTING,
          ephemeral_expiration: parse_integer(child_attrs["expiration"]) || 0
        }
      }
    })
  end

  defp emit_group_side_effects(
         %BinaryNode{attrs: attrs},
         %BinaryNode{tag: "not_ephemeral"},
         context
       ) do
    emit_group_message(context, attrs, %{
      message: %{protocol_message: %{type: :EPHEMERAL_SETTING, ephemeral_expiration: 0}}
    })
  end

  defp emit_group_side_effects(
         %BinaryNode{attrs: attrs},
         %BinaryNode{tag: tag} = child,
         context
       ) do
    stub_type = group_stub_type(tag)
    stub_parameters = group_stub_parameters(tag, child, attrs)

    message =
      %{}
      |> Map.put(:message_stub_type, stub_type)
      |> maybe_put(:message_stub_parameters, stub_parameters)
      |> maybe_put(:participant, attrs["participant"])

    emit_group_message(context, attrs, message)

    emit_stub_side_effects(context, %{
      stub_type: stub_type,
      stub_parameters: stub_parameters || [],
      group_jid: attrs["from"],
      author: attrs["participant"],
      author_pn: attrs["participant_pn"],
      me_id: context[:me_id] || ""
    })
  end

  @spec emit_stub_side_effects(context(), StubSideEffects.stub_input()) :: :ok
  defp emit_stub_side_effects(context, input) do
    input
    |> StubSideEffects.derive()
    |> Enum.each(fn {event, data} ->
      emit(context, event, data)
    end)
  end

  defp handle_encrypt_notification(%BinaryNode{} = node, context) do
    case context[:handle_encrypt_notification_fun] do
      fun when is_function(fun, 1) ->
        _ = fun.(node)
        :ok

      _ ->
        :ok
    end
  end

  defp handle_devices_notification(%BinaryNode{} = node, context) do
    :ok = apply_devices_notification(node, context)

    case context[:device_notification_fun] do
      fun when is_function(fun, 1) ->
        _ = fun.(node)
        :ok

      _ ->
        :ok
    end
  end

  defp apply_devices_notification(
         %BinaryNode{} = node,
         %{signal_store: %Store{} = store} = context
       ) do
    with [%BinaryNode{} = child | _rest] <- BinaryNodeUtil.children(node),
         tag when tag in ["add", "remove", "update"] <- child.tag,
         decoded when decoded != [] <- decode_device_entries(child) do
      decoded
      |> Enum.group_by(& &1.user)
      |> Enum.each(fn {user, entries} ->
        apply_device_entries(store, context, tag, user, entries)
      end)
    end

    :ok
  end

  defp apply_devices_notification(%BinaryNode{}, _context), do: :ok

  defp apply_device_entries(%Store{} = store, _context, "update", user, _entries) do
    Store.set(store, %{:"device-list" => %{user => nil}})
  end

  defp apply_device_entries(%Store{} = store, context, tag, user, entries) do
    if tag == "remove" do
      maybe_delete_device_sessions(context, entries)
    end

    case Store.get(store, :"device-list", [user]) do
      %{^user => existing_devices} when is_list(existing_devices) and existing_devices != [] ->
        affected = MapSet.new(Enum.map(entries, & &1.device_id))

        updated_devices =
          case tag do
            "add" ->
              existing_devices
              |> Enum.reject(&MapSet.member?(affected, &1))
              |> Kernel.++(Enum.map(entries, & &1.device_id))

            "remove" ->
              Enum.reject(existing_devices, &MapSet.member?(affected, &1))
          end

        if updated_devices == [] do
          Store.set(store, %{:"device-list" => %{user => nil}})
        else
          Store.set(store, %{:"device-list" => %{user => updated_devices}})
        end

      _ ->
        :ok
    end
  end

  defp decode_device_entries(%BinaryNode{} = child) do
    child
    |> BinaryNodeUtil.children("device")
    |> Enum.flat_map(fn
      %BinaryNode{attrs: %{"jid" => jid}} when is_binary(jid) ->
        case JIDUtil.parse(jid) do
          %{user: user, device: device} when is_binary(user) ->
            [%{jid: jid, user: user, device_id: Integer.to_string(device || 0)}]

          _ ->
            []
        end

      _ ->
        []
    end)
  end

  defp maybe_delete_device_sessions(%{signal_repository: %Repository{} = repository}, entries) do
    _ = Repository.delete_session(repository, Enum.map(entries, & &1.jid))
    :ok
  end

  defp maybe_delete_device_sessions(_context, _entries), do: :ok

  defp handle_picture_notification(%BinaryNode{attrs: attrs} = node, context) do
    set_picture = BinaryNodeUtil.child(node, "set")
    delete_picture = BinaryNodeUtil.child(node, "delete")

    emit(context, :contacts_update, [
      %{
        id: attrs["from"],
        img_url: if(set_picture, do: :changed, else: :removed)
      }
    ])

    if JIDUtil.group?(attrs["from"]) do
      picture_node = set_picture || delete_picture

      emit_group_message(context, attrs, %{
        message_stub_type: :GROUP_CHANGE_ICON,
        message_stub_parameters: if(set_picture, do: [set_picture.attrs["id"]], else: nil),
        participant: picture_node && picture_node.attrs["author"]
      })
    else
      :ok
    end
  end

  defp handle_account_sync_notification(%BinaryNode{} = node, context) do
    case BinaryNodeUtil.children(node) do
      [%BinaryNode{tag: "disappearing_mode", attrs: attrs}] ->
        emit(context, :creds_update, %{
          account_settings: %{
            default_disappearing_mode: %{
              ephemeral_expiration: parse_integer(attrs["duration"]) || 0,
              ephemeral_setting_timestamp: parse_integer(attrs["t"])
            }
          }
        })

      [%BinaryNode{tag: "blocklist", content: items}] when is_list(items) ->
        Enum.each(items, fn
          %BinaryNode{tag: "item", attrs: %{"jid" => jid, "action" => action}} ->
            emit(context, :blocklist_update, %{
              blocklist: [jid],
              type: if(action == "block", do: :add, else: :remove)
            })

          _other ->
            :ok
        end)

      _ ->
        :ok
    end
  end

  defp handle_server_sync_notification(%BinaryNode{} = node, context) do
    case context[:resync_app_state_fun] do
      fun when is_function(fun, 1) ->
        case BinaryNodeUtil.child(node, "collection") do
          %BinaryNode{attrs: %{"name" => name}} ->
            normalize_server_sync_result(name, fun.(name))

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end

  @spec normalize_server_sync_result(String.t(), term()) :: :ok
  defp normalize_server_sync_result(_name, :ok), do: :ok

  defp normalize_server_sync_result(name, {:error, reason}) do
    Logger.warning("server_sync resync failed for #{name}: #{inspect(reason)}")
    :ok
  end

  defp normalize_server_sync_result(_name, _result), do: :ok

  defp handle_media_retry_notification(%BinaryNode{attrs: attrs} = node, context) do
    _ = attrs
    emit(context, :messages_media_update, [MediaRetry.decode_notification_event(node)])
  end

  defp handle_newsletter_notification(%BinaryNode{attrs: attrs} = node, context) do
    node
    |> BinaryNodeUtil.children()
    |> Enum.each(&handle_newsletter_child(&1, attrs, context))

    :ok
  end

  defp handle_newsletter_child(
         %BinaryNode{tag: "reaction", attrs: reaction_attrs} = child,
         attrs,
         context
       ) do
    emit(context, :newsletter_reaction, %{
      id: attrs["from"],
      server_id: reaction_attrs["message_id"],
      reaction: %{code: newsletter_reaction_code(child), count: 1}
    })
  end

  defp handle_newsletter_child(
         %BinaryNode{tag: "view", attrs: view_attrs, content: content},
         attrs,
         context
       ) do
    emit(context, :newsletter_view, %{
      id: attrs["from"],
      server_id: view_attrs["message_id"],
      count: parse_integer(content) || 0
    })
  end

  defp handle_newsletter_child(
         %BinaryNode{tag: "participant", attrs: participant_attrs},
         attrs,
         context
       ) do
    emit(context, :newsletter_participants_update, %{
      id: attrs["from"],
      author: attrs["participant"],
      user: participant_attrs["jid"],
      action: participant_attrs["action"],
      new_role: participant_attrs["role"]
    })
  end

  defp handle_newsletter_child(%BinaryNode{tag: "update"} = child, attrs, context) do
    emit(context, :newsletter_settings_update, %{
      id: attrs["from"],
      update: newsletter_settings(child)
    })
  end

  defp handle_newsletter_child(
         %BinaryNode{tag: "message", attrs: message_attrs} = child,
         attrs,
         context
       ) do
    emit_newsletter_message(context, attrs["from"], child, message_attrs)
  end

  defp handle_newsletter_child(%BinaryNode{}, _attrs, _context), do: :ok

  defp handle_mex_notification(%BinaryNode{} = node, context) do
    case BinaryNodeUtil.child(node, "update") do
      %BinaryNode{} = update_node ->
        handle_mex_update_notification(update_node, context)

      _ ->
        handle_legacy_mex_notification(node, context)
    end
  end

  defp handle_mex_update_notification(%BinaryNode{attrs: attrs, content: content}, context) do
    with op_name when is_binary(op_name) <- attrs["op_name"],
         payload when is_binary(payload) <- binary_content(content),
         {:ok, %{"data" => data} = response} <- JSON.decode(payload),
         true <- mex_response_ok?(response) do
      dispatch_mex_update(op_name, data, context)
    else
      _ -> :ok
    end
  end

  defp handle_legacy_mex_notification(%BinaryNode{} = node, context) do
    case BinaryNodeUtil.child(node, "mex") || BinaryNodeUtil.child(node, "update") do
      %BinaryNode{content: content} when is_binary(content) ->
        dispatch_legacy_mex_payload(content, node.attrs["from"], context)

      %BinaryNode{content: {:binary, content}} when is_binary(content) ->
        dispatch_legacy_mex_payload(content, node.attrs["from"], context)

      _ ->
        :ok
    end
  end

  defp mex_response_ok?(%{"errors" => errors}) when is_list(errors) and errors != [], do: false
  defp mex_response_ok?(_response), do: true

  defp dispatch_legacy_mex_payload(content, author, context) do
    case JSON.decode(content) do
      {:ok, %{"operation" => operation, "updates" => updates}} when is_list(updates) ->
        emit_mex_updates(context, operation, updates, author)

      {:ok, %{"data" => %{"xwa2_notify_linked_profiles" => linked_profiles}}} ->
        emit_mex_updates(context, "NotificationLinkedProfilesUpdates", [linked_profiles], author)

      _ ->
        :ok
    end
  end

  defp dispatch_mex_update("NotificationUserReachoutTimelockUpdate", data, context) do
    case data["xwa2_notify_account_reachout_timelock"] do
      payload when is_map(payload) ->
        emit(context, :connection_update, %{
          reachout_time_lock: reachout_time_lock(payload, context)
        })

      _ ->
        :ok
    end
  end

  defp dispatch_mex_update("MessageCappingInfoNotification", data, context) do
    case data["xwa2_notify_new_chat_messages_capping_info_update"] do
      payload when is_map(payload) ->
        emit(context, :message_capping_update, normalize_message_capping(payload))

      _ ->
        :ok
    end
  end

  defp dispatch_mex_update("NotificationLinkedProfilesUpdates", data, context) do
    case data["xwa2_notify_linked_profiles"] do
      payload when is_map(payload) ->
        emit_mex_updates(context, "NotificationLinkedProfilesUpdates", [payload], nil)

      _ ->
        :ok
    end
  end

  defp dispatch_mex_update(_op_name, _data, _context), do: :ok

  defp emit_group_message(context, attrs, payload) do
    emit(context, :messages_upsert, %{
      type: :append,
      messages: [
        Map.merge(
          %{
            key: %{
              remote_jid: attrs["from"],
              from_me: false,
              participant: attrs["participant"],
              id: attrs["id"]
            },
            message_timestamp: parse_integer(attrs["t"]),
            participant: attrs["participant"]
          },
          payload
        )
      ]
    })
  end

  defp emit_newsletter_message(context, newsletter_jid, %BinaryNode{} = child, message_attrs) do
    case BinaryNodeUtil.child(child, "plaintext") do
      %BinaryNode{content: {:binary, payload}} ->
        emit_decoded_newsletter_message(context, newsletter_jid, payload, message_attrs)

      %BinaryNode{content: payload} when is_binary(payload) ->
        emit_decoded_newsletter_message(context, newsletter_jid, payload, message_attrs)

      _ ->
        :ok
    end
  end

  defp emit_decoded_newsletter_message(context, newsletter_jid, payload, message_attrs) do
    case Message.decode(payload) do
      {:ok, %Message{} = message} ->
        emit(context, :messages_upsert, %{
          type: :append,
          messages: [
            %{
              key: %{
                remote_jid: newsletter_jid,
                from_me: false,
                id: message_attrs["message_id"] || message_attrs["server_id"]
              },
              message: message,
              message_timestamp: parse_integer(message_attrs["t"])
            }
          ]
        })

      _ ->
        :ok
    end
  end

  defp emit_mex_updates(context, "NotificationNewsletterUpdate", updates, _author) do
    Enum.each(updates, fn
      %{"jid" => jid, "settings" => settings} when is_map(settings) ->
        emit(context, :newsletter_settings_update, %{id: jid, update: settings})

      _other ->
        :ok
    end)
  end

  defp emit_mex_updates(context, "NotificationNewsletterAdminPromote", updates, author) do
    Enum.each(updates, fn
      %{"jid" => jid, "user" => user} ->
        emit(context, :newsletter_participants_update, %{
          id: jid,
          author: author,
          user: user,
          new_role: "ADMIN",
          action: "promote"
        })

      _other ->
        :ok
    end)
  end

  defp emit_mex_updates(context, "NotificationLinkedProfilesUpdates", updates, _author) do
    Enum.each(updates, fn
      %{"jid" => lid, "added_profiles" => profiles} when is_list(profiles) ->
        Enum.each(profiles, fn
          pn when is_binary(pn) ->
            emit(context, :lid_mapping_update, %{lid: lid, pn: pn})

          %{"pn" => pn} when is_binary(pn) ->
            emit(context, :lid_mapping_update, %{lid: lid, pn: pn})

          %{"jid" => pn} when is_binary(pn) ->
            emit(context, :lid_mapping_update, %{lid: lid, pn: pn})

          _other ->
            :ok
        end)

      _other ->
        :ok
    end)
  end

  defp emit_mex_updates(_context, _operation, _updates, _author), do: :ok

  defp reachout_time_lock(%{"is_active" => false}, _context) do
    %{is_active: false, enforcement_type: "DEFAULT"}
  end

  defp reachout_time_lock(payload, context) do
    enforcement_type =
      case payload["enforcement_type"] do
        value when is_binary(value) ->
          if MapSet.member?(@reachout_enforcement_types, value), do: value, else: "DEFAULT"

        _ ->
          "DEFAULT"
      end

    %{
      is_active: payload["is_active"] == true,
      enforcement_type: enforcement_type
    }
    |> maybe_put(
      :time_enforcement_ends,
      reachout_end_time(payload["time_enforcement_ends"], payload["is_active"] == true, context)
    )
  end

  defp reachout_end_time(value, active?, context)

  defp reachout_end_time(nil, true, context), do: unix_to_datetime(now_seconds(context) + 60)
  defp reachout_end_time("", true, context), do: unix_to_datetime(now_seconds(context) + 60)

  defp reachout_end_time(value, _active?, _context) do
    with seconds when is_integer(seconds) <- parse_integer(value),
         {:ok, datetime} <- DateTime.from_unix(seconds) do
      datetime
    else
      _ -> nil
    end
  end

  defp now_seconds(%{now_seconds: seconds}) when is_integer(seconds), do: seconds
  defp now_seconds(_context), do: System.system_time(:second)

  defp unix_to_datetime(seconds) do
    case DateTime.from_unix(seconds) do
      {:ok, datetime} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp normalize_message_capping(payload) when is_map(payload) do
    Enum.reduce(@message_capping_fields, %{}, fn {source_key, target_key}, acc ->
      maybe_put(acc, target_key, payload[source_key])
    end)
  end

  defp newsletter_reaction_code(%BinaryNode{} = child) do
    case BinaryNodeUtil.child(child, "reaction") do
      %BinaryNode{content: content} when is_binary(content) -> content
      %BinaryNode{content: {:binary, content}} -> content
      _ -> nil
    end
  end

  defp newsletter_settings(%BinaryNode{} = child) do
    case BinaryNodeUtil.child(child, "settings") do
      %BinaryNode{} = settings ->
        %{}
        |> maybe_put(:name, node_string(BinaryNodeUtil.child(settings, "name")))
        |> maybe_put(:description, node_string(BinaryNodeUtil.child(settings, "description")))

      _ ->
        %{}
    end
  end

  defp group_stub_type(tag), do: MessageStubType.from_string(tag)

  defp group_stub_parameters("promote", child, _attrs), do: participant_parameters(child)
  defp group_stub_parameters("demote", child, _attrs), do: participant_parameters(child)
  defp group_stub_parameters("remove", child, _attrs), do: participant_parameters(child)
  defp group_stub_parameters("add", child, _attrs), do: participant_parameters(child)
  defp group_stub_parameters("leave", child, _attrs), do: participant_parameters(child)
  defp group_stub_parameters("subject", %BinaryNode{attrs: attrs}, _attrs), do: [attrs["subject"]]

  defp group_stub_parameters("description", %BinaryNode{} = child, _attrs),
    do: [node_string(BinaryNodeUtil.child(child, "body"))]

  defp group_stub_parameters("announcement", _child, _attrs), do: ["on"]
  defp group_stub_parameters("not_announcement", _child, _attrs), do: ["off"]
  defp group_stub_parameters("locked", _child, _attrs), do: ["on"]
  defp group_stub_parameters("unlocked", _child, _attrs), do: ["off"]

  defp group_stub_parameters("invite", %BinaryNode{attrs: attrs}, _node_attrs),
    do: [attrs["code"]]

  defp group_stub_parameters("member_add_mode", %BinaryNode{content: content}, _attrs),
    do: [binary_content(content)]

  defp group_stub_parameters("membership_approval_mode", %BinaryNode{} = child, _attrs) do
    case BinaryNodeUtil.child(child, "group_join") do
      %BinaryNode{attrs: join_attrs} -> [join_attrs["state"]]
      _ -> nil
    end
  end

  defp group_stub_parameters("created_membership_requests", _child, attrs) do
    [JSON.encode!(%{lid: attrs["participant"], pn: attrs["participant_pn"]}), "created"]
  end

  defp group_stub_parameters("revoked_membership_requests", _child, attrs) do
    [JSON.encode!(%{lid: attrs["participant"], pn: attrs["participant_pn"]}), "revoked"]
  end

  defp group_stub_parameters(_tag, _child, _attrs), do: nil

  defp participant_parameters(%BinaryNode{} = child) do
    child
    |> BinaryNodeUtil.children("participant")
    |> Enum.map(fn participant ->
      JSON.encode!(%{
        id: participant.attrs["jid"],
        phone_number: participant.attrs["phone_number"],
        lid: participant.attrs["lid"],
        username: participant.attrs["participant_username"] || participant.attrs["username"],
        admin: participant.attrs["type"]
      })
    end)
  end

  defp parse_integer(nil), do: nil

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp parse_integer(value) when is_integer(value), do: value
  defp parse_integer(_value), do: nil

  defp node_string(%BinaryNode{content: content}), do: binary_content(content)
  defp node_string(_node), do: nil

  defp binary_content({:binary, content}) when is_binary(content), do: content
  defp binary_content(content) when is_binary(content), do: content
  defp binary_content(_content), do: nil

  defp emit(%{event_emitter: event_emitter}, event, data) when not is_nil(event_emitter) do
    EventEmitter.emit(event_emitter, event, data)
  end

  defp emit(_context, _event, _data), do: :ok

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
