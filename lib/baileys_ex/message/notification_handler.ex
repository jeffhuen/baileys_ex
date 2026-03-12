defmodule BaileysEx.Message.NotificationHandler do
  @moduledoc """
  Message-layer notification handling aligned with Baileys rc.9.

  This module owns the non-auth notification cases that produce messaging,
  group, newsletter, and account-side effects above the raw socket layer.
  """

  alias BaileysEx.BinaryNode
  alias BaileysEx.Connection.EventEmitter
  alias BaileysEx.Protocol.BinaryNode, as: BinaryNodeUtil
  alias BaileysEx.Protocol.JID, as: JIDUtil
  alias BaileysEx.Protocol.MessageStubType
  alias BaileysEx.Protocol.Proto.Message

  @type context :: %{
          optional(:event_emitter) => GenServer.server(),
          optional(:store_privacy_token_fun) => (String.t(), binary(), String.t() | nil ->
                                                   :ok | {:error, term()}),
          optional(:handle_encrypt_notification_fun) => (BinaryNode.t() -> term()),
          optional(:device_notification_fun) => (BinaryNode.t() -> term()),
          optional(:resync_app_state_fun) => (String.t() -> term())
        }

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
    do: handle_privacy_token_notification(node, context)

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
        author: author
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
    message =
      %{}
      |> Map.put(:message_stub_type, group_stub_type(tag))
      |> maybe_put(:message_stub_parameters, group_stub_parameters(tag, child, attrs))
      |> maybe_put(:participant, attrs["participant"])

    emit_group_message(context, attrs, message)
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
    case context[:device_notification_fun] do
      fun when is_function(fun, 1) ->
        _ = fun.(node)
        :ok

      _ ->
        :ok
    end
  end

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
          %BinaryNode{attrs: %{"name" => name}} -> _ = fun.(name)
          _ -> :ok
        end

      _ ->
        :ok
    end
  end

  defp handle_media_retry_notification(%BinaryNode{attrs: attrs} = node, context) do
    case BinaryNodeUtil.child(node, "mediaretry") do
      %BinaryNode{attrs: retry_attrs} ->
        emit(context, :messages_media_update, [
          %{
            id: retry_attrs["key"],
            result: retry_attrs["result"],
            remote_jid: attrs["from"],
            participant: attrs["participant"]
          }
        ])

      _ ->
        :ok
    end
  end

  defp handle_newsletter_notification(%BinaryNode{attrs: attrs} = node, context) do
    case BinaryNodeUtil.children(node) do
      [%BinaryNode{tag: "reaction", attrs: reaction_attrs} = child | _rest] ->
        emit(context, :newsletter_reaction, %{
          id: attrs["from"],
          server_id: reaction_attrs["message_id"],
          reaction: %{code: newsletter_reaction_code(child), count: 1}
        })

      [%BinaryNode{tag: "view", attrs: view_attrs, content: content} | _rest] ->
        emit(context, :newsletter_view, %{
          id: attrs["from"],
          server_id: view_attrs["message_id"],
          count: parse_integer(content) || 0
        })

      [%BinaryNode{tag: "participant", attrs: participant_attrs} | _rest] ->
        emit(context, :newsletter_participants_update, %{
          id: attrs["from"],
          author: attrs["participant"],
          user: participant_attrs["jid"],
          action: participant_attrs["action"],
          new_role: participant_attrs["role"]
        })

      [%BinaryNode{tag: "update"} = child | _rest] ->
        emit(context, :newsletter_settings_update, %{
          id: attrs["from"],
          update: newsletter_settings(child)
        })

      [%BinaryNode{tag: "message", attrs: message_attrs} = child | _rest] ->
        emit_newsletter_message(context, attrs["from"], child, message_attrs)

      _ ->
        :ok
    end
  end

  defp handle_mex_notification(%BinaryNode{} = node, context) do
    case BinaryNodeUtil.child(node, "mex") do
      %BinaryNode{content: content} when is_binary(content) ->
        case JSON.decode(content) do
          {:ok, %{"operation" => operation, "updates" => updates}} when is_list(updates) ->
            emit_mex_updates(context, operation, updates, node.attrs["from"])

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end

  defp handle_privacy_token_notification(%BinaryNode{attrs: attrs} = node, context) do
    with fun when is_function(fun, 3) <- context[:store_privacy_token_fun],
         %BinaryNode{content: token_nodes} <- BinaryNodeUtil.child(node, "tokens"),
         true <- is_list(token_nodes) do
      Enum.each(token_nodes, fn
        %BinaryNode{
          tag: "token",
          attrs: %{"type" => "trusted_contact", "t" => timestamp},
          content: {:binary, token}
        } ->
          _ = fun.(attrs["from"], token, timestamp)

        %BinaryNode{
          tag: "token",
          attrs: %{"type" => "trusted_contact", "t" => timestamp},
          content: token
        }
        when is_binary(token) ->
          _ = fun.(attrs["from"], token, timestamp)

        _other ->
          :ok
      end)
    else
      _ -> :ok
    end
  end

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

  defp emit_mex_updates(_context, _operation, _updates, _author), do: :ok

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
