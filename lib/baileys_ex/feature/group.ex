defmodule BaileysEx.Feature.Group do
  @moduledoc """
  Group-management helpers mapped from Baileys' `groups.ts`.
  """

  alias BaileysEx.BinaryNode
  alias BaileysEx.Connection.EventEmitter
  alias BaileysEx.Connection.Socket
  alias BaileysEx.Protocol.Proto.Message
  alias BaileysEx.Message.Sender
  alias BaileysEx.Message.Wire
  alias BaileysEx.Protocol.BinaryNode, as: BinaryNodeUtil
  alias BaileysEx.Protocol.JID

  @s_whatsapp_net "s.whatsapp.net"
  @timeout 60_000

  @type participant_result :: %{
          required(:jid) => String.t(),
          required(:status) => String.t(),
          optional(:content) => BinaryNode.t()
        }

  @doc "Create a new group and return the parsed group metadata."
  @spec create(term(), String.t(), [String.t()]) :: {:ok, map()} | {:error, term()}
  @spec create(term(), String.t(), [String.t()], keyword()) :: {:ok, map()} | {:error, term()}
  def create(conn, subject, participants, opts \\ [])
      when is_binary(subject) and is_list(participants) and is_list(opts) do
    with {:ok, result} <-
           group_query(conn, "@g.us", "set", [
             %BinaryNode{
               tag: "create",
               attrs: %{"subject" => subject, "key" => message_id(opts)},
               content: Enum.map(participants, &participant_node/1)
             }
           ]) do
      {:ok, extract_group_metadata(result)}
    end
  end

  @doc "Update the subject for an existing group."
  @spec update_subject(term(), String.t(), String.t()) :: :ok | {:error, term()}
  def update_subject(conn, group_jid, subject) when is_binary(group_jid) and is_binary(subject) do
    case group_query(conn, group_jid, "set", [
           %BinaryNode{tag: "subject", attrs: %{}, content: subject}
         ]) do
      {:ok, _} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc "Update or clear the group description."
  @spec update_description(term(), String.t(), String.t() | nil) :: :ok | {:error, term()}
  @spec update_description(term(), String.t(), String.t() | nil, keyword()) ::
          :ok | {:error, term()}
  def update_description(conn, group_jid, description, opts \\ [])
      when is_binary(group_jid) and is_list(opts) do
    description = empty_string_to_nil(description)

    with {:ok, metadata} <- get_metadata(conn, group_jid) do
      prev =
        case metadata do
          %{desc_id: desc_id} when is_binary(desc_id) -> desc_id
          _ -> nil
        end

      attrs =
        %{}
        |> maybe_put("id", if(is_binary(description), do: message_id(opts), else: nil))
        |> maybe_put("delete", if(is_nil(description), do: "true", else: nil))
        |> maybe_put("prev", prev)

      content =
        if is_binary(description) do
          [%BinaryNode{tag: "body", attrs: %{}, content: description}]
        end

      case group_query(conn, group_jid, "set", [
             %BinaryNode{tag: "description", attrs: attrs, content: content}
           ]) do
        {:ok, _} -> :ok
        {:error, _reason} = error -> error
      end
    end
  end

  @doc "Leave a group."
  @spec leave(term(), String.t()) :: :ok | {:error, term()}
  def leave(conn, group_jid) when is_binary(group_jid) do
    case group_query(conn, "@g.us", "set", [
           %BinaryNode{
             tag: "leave",
             attrs: %{},
             content: [%BinaryNode{tag: "group", attrs: %{"id" => group_jid}}]
           }
         ]) do
      {:ok, _} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc "Add participants to a group."
  @spec add_participants(term(), String.t(), [String.t()]) ::
          {:ok, [participant_result()]} | {:error, term()}
  def add_participants(conn, group_jid, jids),
    do: participant_update(conn, group_jid, jids, "add")

  @doc "Remove participants from a group."
  @spec remove_participants(term(), String.t(), [String.t()]) ::
          {:ok, [participant_result()]} | {:error, term()}
  def remove_participants(conn, group_jid, jids),
    do: participant_update(conn, group_jid, jids, "remove")

  @doc "Promote participants to admins."
  @spec promote_participants(term(), String.t(), [String.t()]) ::
          {:ok, [participant_result()]} | {:error, term()}
  def promote_participants(conn, group_jid, jids),
    do: participant_update(conn, group_jid, jids, "promote")

  @doc "Demote participants from admins."
  @spec demote_participants(term(), String.t(), [String.t()]) ::
          {:ok, [participant_result()]} | {:error, term()}
  def demote_participants(conn, group_jid, jids),
    do: participant_update(conn, group_jid, jids, "demote")

  @doc "Fetch the current invite code for a group."
  @spec invite_code(term(), String.t()) :: {:ok, String.t() | nil} | {:error, term()}
  def invite_code(conn, group_jid) when is_binary(group_jid) do
    with {:ok, result} <-
           group_query(conn, group_jid, "get", [%BinaryNode{tag: "invite", attrs: %{}}]) do
      {:ok, invite_code_from_result(result)}
    end
  end

  @doc "Revoke the current invite code and return the new one."
  @spec revoke_invite(term(), String.t()) :: {:ok, String.t() | nil} | {:error, term()}
  def revoke_invite(conn, group_jid) when is_binary(group_jid) do
    with {:ok, result} <-
           group_query(conn, group_jid, "set", [%BinaryNode{tag: "invite", attrs: %{}}]) do
      {:ok, invite_code_from_result(result)}
    end
  end

  @doc "Accept a legacy invite code and return the joined group JID."
  @spec accept_invite(term(), String.t()) :: {:ok, String.t() | nil} | {:error, term()}
  def accept_invite(conn, code) when is_binary(code) do
    with {:ok, result} <-
           group_query(conn, "@g.us", "set", [
             %BinaryNode{tag: "invite", attrs: %{"code" => code}}
           ]) do
      {:ok,
       BinaryNodeUtil.child(result, "group") && BinaryNodeUtil.child(result, "group").attrs["jid"]}
    end
  end

  @doc "Fetch interactive metadata for a group."
  @spec get_metadata(term(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_metadata(conn, group_jid) when is_binary(group_jid) do
    with {:ok, result} <-
           group_query(conn, group_jid, "get", [
             %BinaryNode{tag: "query", attrs: %{"request" => "interactive"}}
           ]) do
      {:ok, extract_group_metadata(result)}
    end
  end

  @doc "Fetch all participating groups and optionally emit `groups_update`."
  @spec fetch_all_participating(term(), keyword()) ::
          {:ok, %{String.t() => map()}} | {:error, term()}
  def fetch_all_participating(conn, opts \\ []) do
    root_tag = Keyword.get(opts, :root_tag, "groups")
    item_tag = Keyword.get(opts, :item_tag, "group")

    with {:ok, result} <-
           group_query(conn, "@g.us", "get", [
             %BinaryNode{
               tag: "participating",
               attrs: %{},
               content: [
                 %BinaryNode{tag: "participants", attrs: %{}},
                 %BinaryNode{tag: "description", attrs: %{}}
               ]
             }
           ]) do
      groups =
        result
        |> BinaryNodeUtil.child(root_tag)
        |> BinaryNodeUtil.children(item_tag)
        |> Enum.reduce(%{}, fn group_node, acc ->
          metadata =
            extract_group_metadata(%BinaryNode{
              tag: "result",
              attrs: %{},
              content: [group_node]
            })

          Map.put(acc, metadata.id, metadata)
        end)

      emit_groups_update(opts, Map.values(groups))
      {:ok, groups}
    end
  end

  @doc "Enable or disable disappearing messages for a group."
  @spec toggle_ephemeral(term(), String.t(), non_neg_integer()) :: :ok | {:error, term()}
  def toggle_ephemeral(conn, group_jid, expiration)
      when is_binary(group_jid) and is_integer(expiration) and expiration >= 0 do
    content =
      if expiration > 0 do
        %BinaryNode{tag: "ephemeral", attrs: %{"expiration" => Integer.to_string(expiration)}}
      else
        %BinaryNode{tag: "not_ephemeral", attrs: %{}}
      end

    case group_query(conn, group_jid, "set", [content]) do
      {:ok, _} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc "Resolve invite metadata for a code without joining."
  @spec get_invite_info(term(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_invite_info(conn, code) when is_binary(code) do
    with {:ok, result} <-
           group_query(conn, "@g.us", "get", [
             %BinaryNode{tag: "invite", attrs: %{"code" => code}}
           ]) do
      {:ok, extract_group_metadata(result)}
    end
  end

  @doc "Update announcement or locked settings for a group."
  @spec setting_update(
          term(),
          String.t(),
          :announcement | :not_announcement | :locked | :unlocked
        ) ::
          :ok | {:error, term()}
  def setting_update(conn, group_jid, setting)
      when setting in [:announcement, :not_announcement, :locked, :unlocked] do
    case group_query(conn, group_jid, "set", [
           %BinaryNode{tag: Atom.to_string(setting), attrs: %{}}
         ]) do
      {:ok, _} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc "Switch whether only admins or all members can add participants."
  @spec member_add_mode(term(), String.t(), :admin_add | :all_member_add) ::
          :ok | {:error, term()}
  def member_add_mode(conn, group_jid, mode) when mode in [:admin_add, :all_member_add] do
    case group_query(conn, group_jid, "set", [
           %BinaryNode{tag: "member_add_mode", attrs: %{}, content: Atom.to_string(mode)}
         ]) do
      {:ok, _} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc "Toggle join-approval mode for a group."
  @spec join_approval_mode(term(), String.t(), :on | :off) :: :ok | {:error, term()}
  def join_approval_mode(conn, group_jid, mode) when mode in [:on, :off] do
    case group_query(conn, group_jid, "set", [
           %BinaryNode{
             tag: "membership_approval_mode",
             attrs: %{},
             content: [
               %BinaryNode{
                 tag: "group_join",
                 attrs: %{"state" => Atom.to_string(mode)}
               }
             ]
           }
         ]) do
      {:ok, _} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc "Fetch the pending join-request list for a group."
  @spec request_participants_list(term(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def request_participants_list(conn, group_jid) when is_binary(group_jid) do
    with {:ok, result} <-
           group_query(conn, group_jid, "get", [
             %BinaryNode{tag: "membership_approval_requests", attrs: %{}}
           ]) do
      list =
        result
        |> BinaryNodeUtil.child("membership_approval_requests")
        |> BinaryNodeUtil.children("membership_approval_request")
        |> Enum.map(& &1.attrs)

      {:ok, list}
    end
  end

  @doc "Approve or reject pending join requests."
  @spec request_participants_update(term(), String.t(), [String.t()], :approve | :reject) ::
          {:ok, [participant_result()]} | {:error, term()}
  def request_participants_update(conn, group_jid, jids, action)
      when is_binary(group_jid) and is_list(jids) and action in [:approve, :reject] do
    action_tag = Atom.to_string(action)

    with {:ok, result} <-
           group_query(conn, group_jid, "set", [
             %BinaryNode{
               tag: "membership_requests_action",
               attrs: %{},
               content: [
                 %BinaryNode{
                   tag: action_tag,
                   attrs: %{},
                   content: Enum.map(jids, &participant_node/1)
                 }
               ]
             }
           ]) do
      action_node =
        result
        |> BinaryNodeUtil.child("membership_requests_action")
        |> BinaryNodeUtil.child(action_tag)

      {:ok,
       Enum.map(BinaryNodeUtil.children(action_node, "participant"), fn participant ->
         %{jid: participant.attrs["jid"], status: participant.attrs["error"] || "200"}
       end)}
    end
  end

  @doc """
  Accept a v4 invite and emit the same post-join side effects Baileys performs
  when callback options are provided.
  """
  @spec accept_invite_v4(term(), String.t() | map(), map(), keyword()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def accept_invite_v4(conn, key, invite_message, opts \\ [])

  def accept_invite_v4(
        conn,
        key,
        %{
          group_jid: group_jid,
          invite_code: code,
          invite_expiration: expiration
        } = invite_message,
        opts
      )
      when is_binary(group_jid) and is_binary(code) and is_integer(expiration) do
    admin =
      case key do
        %{remote_jid: remote_jid} -> remote_jid
        remote_jid when is_binary(remote_jid) -> remote_jid
      end

    case group_query(conn, group_jid, "set", [
           %BinaryNode{
             tag: "accept",
             attrs: %{
               "code" => code,
               "expiration" => Integer.to_string(expiration),
               "admin" => admin
             }
           }
         ]) do
      {:ok, %BinaryNode{} = result} ->
        maybe_emit_invite_v4_side_effects(key, invite_message, admin, opts)
        {:ok, result.attrs["from"] || group_jid}

      {:error, _reason} = error ->
        error
    end
  end

  @doc "Revoke a v4 invite for a specific invited user."
  @spec revoke_invite_v4(term(), String.t(), String.t()) :: :ok | {:error, term()}
  def revoke_invite_v4(conn, group_jid, invited_jid)
      when is_binary(group_jid) and is_binary(invited_jid) do
    case group_query(conn, group_jid, "set", [
           %BinaryNode{
             tag: "revoke",
             attrs: %{},
             content: [%BinaryNode{tag: "participant", attrs: %{"jid" => invited_jid}}]
           }
         ]) do
      {:ok, _} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc "Handle a dirty group/community update by refetching groups and cleaning the bucket."
  @spec handle_dirty_update(term(), %{type: String.t()}, keyword()) ::
          {:ok, %{String.t() => map()}} | :ignore | {:error, term()}
  def handle_dirty_update(conn, dirty_update, opts \\ [])

  def handle_dirty_update(conn, %{type: type} = dirty_update, opts)
      when type in ["groups", "communities"] do
    timestamp = Map.get(dirty_update, :timestamp) || Map.get(dirty_update, "timestamp")
    root_tag = Keyword.get(opts, :root_tag, if(type == "communities", do: "communities", else: "groups"))
    item_tag = Keyword.get(opts, :item_tag, if(type == "communities", do: "community", else: "group"))

    with {:ok, groups} <-
           fetch_all_participating(conn, Keyword.merge(opts, root_tag: root_tag, item_tag: item_tag)) do
      _ =
        send_node(
          Keyword.get(opts, :sendable, conn),
          clean_dirty_bits_node("groups", timestamp, opts)
        )

      {:ok, groups}
    end
  end

  def handle_dirty_update(_conn, _dirty_update, _opts), do: :ignore

  @doc "Set a custom label on a group member via the GROUP_MEMBER_LABEL_CHANGE protocol message."
  @spec update_member_label(map(), String.t(), String.t(), keyword()) ::
          {:ok, Sender.send_result(), Sender.context()} | {:error, term()}
  def update_member_label(context, group_jid, member_label, opts \\ [])

  def update_member_label(%{} = context, group_jid, member_label, opts)
      when is_binary(group_jid) and is_binary(member_label) do
    case JID.parse(group_jid) do
      %BaileysEx.JID{} = jid ->
        protocol_message = %Message{
          protocol_message: %Message.ProtocolMessage{
            type: :GROUP_MEMBER_LABEL_CHANGE,
            member_label: %Message.MemberLabel{
              label: String.slice(member_label, 0, 30),
              label_timestamp: label_timestamp(opts)
            }
          }
        }

        Sender.send_proto(
          context,
          jid,
          protocol_message,
          Keyword.merge(opts, additional_nodes: [member_label_meta_node()])
        )

      _ ->
        {:error, :invalid_group_jid}
    end
  end

  @doc """
  Extract Baileys-aligned group metadata from a group IQ result node.
  """
  @spec extract_group_metadata(BinaryNode.t()) :: map()
  def extract_group_metadata(%BinaryNode{} = result) do
    group = BinaryNodeUtil.child(result, "group") || BinaryNodeUtil.child(result, "community")
    desc_child = BinaryNodeUtil.child(group, "description")

    group
    |> base_group_metadata()
    |> Map.merge(description_metadata(desc_child))
    |> Map.merge(group_flag_metadata(group))
  end

  defp parse_participants(group) do
    Enum.map(BinaryNodeUtil.children(group, "participant"), &participant_metadata/1)
  end

  defp participant_metadata(%BinaryNode{attrs: attrs}) do
    jid = attrs["jid"]

    %{
      id: jid,
      phone_number: participant_phone_number(jid, attrs["phone_number"]),
      lid: participant_lid(jid, attrs["lid"]),
      admin: attrs["type"]
    }
  end

  defp base_group_metadata(group) do
    %{
      id: group_id(group.attrs["id"]),
      subject: group.attrs["subject"],
      notify: group.attrs["notify"],
      addressing_mode: addressing_mode(group.attrs["addressing_mode"]),
      subject_owner: group.attrs["s_o"],
      subject_owner_pn: group.attrs["s_o_pn"],
      subject_time: parse_int(group.attrs["s_t"]),
      size: group_size(group),
      creation: parse_int(group.attrs["creation"]),
      owner: normalize_optional_user(group.attrs["creator"]),
      owner_pn: normalize_optional_user(group.attrs["creator_pn"]),
      owner_country_code: group.attrs["creator_country_code"],
      participants: parse_participants(group)
    }
  end

  defp description_metadata(nil) do
    %{
      desc: nil,
      desc_id: nil,
      desc_owner: nil,
      desc_owner_pn: nil,
      desc_time: nil
    }
  end

  defp description_metadata(desc_child) do
    %{
      desc: BinaryNodeUtil.child_string(desc_child, "body"),
      desc_id: desc_child.attrs["id"],
      desc_owner: normalize_optional_user(desc_child.attrs["participant"]),
      desc_owner_pn: normalize_optional_user(desc_child.attrs["participant_pn"]),
      desc_time: parse_int(desc_child.attrs["t"])
    }
  end

  defp group_flag_metadata(group) do
    %{
      linked_parent: child_jid(group, "linked_parent"),
      restrict: has_child?(group, "locked"),
      announce: has_child?(group, "announcement"),
      is_community: has_child?(group, "parent"),
      is_community_announce: has_child?(group, "default_sub_group"),
      join_approval_mode: has_child?(group, "membership_approval_mode"),
      member_add_mode: BinaryNodeUtil.child_string(group, "member_add_mode") == "all_member_add",
      ephemeral_duration: ephemeral_duration(group)
    }
  end

  defp group_id(nil), do: nil

  defp group_id(id) do
    if String.contains?(id, "@"), do: id, else: JID.jid_encode(id, JID.g_us())
  end

  defp addressing_mode("lid"), do: :lid
  defp addressing_mode(_mode), do: :pn

  defp normalize_optional_user(value) when is_binary(value) do
    case JID.normalized_user(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_optional_user(_value), do: nil

  defp participant_phone_number(jid, phone_number) do
    if JID.lid?(jid) and JID.user?(phone_number), do: phone_number
  end

  defp participant_lid(jid, lid) do
    if JID.user?(jid) and JID.lid?(lid), do: lid
  end

  defp group_size(group) do
    case parse_int(group.attrs["size"]) do
      nil -> length(BinaryNodeUtil.children(group, "participant"))
      size -> size
    end
  end

  defp child_jid(group, tag) do
    case BinaryNodeUtil.child(group, tag) do
      nil -> nil
      child -> child.attrs["jid"]
    end
  end

  defp has_child?(group, tag), do: not is_nil(BinaryNodeUtil.child(group, tag))

  defp ephemeral_duration(group) do
    group
    |> BinaryNodeUtil.child("ephemeral")
    |> then(fn
      nil -> nil
      node -> parse_int(node.attrs["expiration"])
    end)
  end

  defp maybe_emit_invite_v4_side_effects(key, invite_message, admin, opts) do
    maybe_emit_message_update(key, invite_message, opts)
    maybe_emit_group_participant_add(admin, invite_message.group_jid, opts)
  end

  defp member_label_meta_node do
    %BinaryNode{
      tag: "meta",
      attrs: %{
        "tag_reason" => "user_update",
        "appdata" => "member_tag"
      },
      content: nil
    }
  end

  defp label_timestamp(opts) do
    case opts[:label_timestamp_fun] do
      fun when is_function(fun, 0) -> fun.()
      _ -> System.os_time(:second)
    end
  end

  defp maybe_emit_message_update(%{id: id} = key, invite_message, opts) when is_binary(id) do
    updated_invite =
      %Message.GroupInviteMessage{}
      |> Map.merge(invite_message)
      |> Map.put(:invite_expiration, 0)
      |> Map.put(:invite_code, "")

    updated_message = %Message{group_invite_message: updated_invite}
    payload = [%{key: key, update: %{message: updated_message}}]

    case opts[:message_update_fun] do
      fun when is_function(fun, 1) -> fun.(payload)
      _ -> :ok
    end
  end

  defp maybe_emit_message_update(_key, _invite_message, _opts), do: :ok

  defp maybe_emit_group_participant_add(admin, group_jid, opts) do
    me = opts[:me]

    if is_map(me) and is_binary(group_jid) do
      message =
        %{
          key: %{
            remote_jid: group_jid,
            id: message_id(opts, me_id(me)),
            from_me: false,
            participant: admin
          },
          message_stub_type: :GROUP_PARTICIPANT_ADD,
          message_stub_parameters: [JSON.encode!(me)],
          participant: admin,
          message_timestamp: message_timestamp(opts)
        }

      case opts[:upsert_message_fun] do
        fun when is_function(fun, 1) -> fun.(message)
        _ -> :ok
      end
    else
      :ok
    end
  end

  defp message_id(opts, seed_id \\ nil) do
    case opts[:message_id_fun] do
      fun when is_function(fun, 0) -> fun.()
      fun when is_function(fun, 1) -> fun.(seed_id)
      _ -> Wire.generate_message_id(seed_id)
    end
  end

  defp me_id(%{id: id}) when is_binary(id), do: id
  defp me_id(%{"id" => id}) when is_binary(id), do: id
  defp me_id(_me), do: nil

  defp empty_string_to_nil(""), do: nil
  defp empty_string_to_nil(description), do: description

  defp message_timestamp(opts) do
    case opts[:timestamp_fun] do
      fun when is_function(fun, 0) -> fun.()
      value when is_integer(value) -> value
      _ -> System.os_time(:second)
    end
  end

  defp participant_update(conn, group_jid, jids, action)
       when is_binary(group_jid) and is_list(jids) do
    with {:ok, result} <-
           group_query(conn, group_jid, "set", [
             %BinaryNode{
               tag: action,
               attrs: %{},
               content: Enum.map(jids, &participant_node/1)
             }
           ]) do
      {:ok,
       Enum.map(
         BinaryNodeUtil.children(BinaryNodeUtil.child(result, action), "participant"),
         fn participant ->
           %{
             jid: participant.attrs["jid"],
             status: participant.attrs["error"] || "200",
             content: participant
           }
         end
       )}
    end
  end

  defp group_query(conn, jid, type, content) do
    query(
      conn,
      %BinaryNode{
        tag: "iq",
        attrs: %{"type" => type, "xmlns" => "w:g2", "to" => jid},
        content: content
      },
      @timeout
    )
  end

  defp participant_node(jid), do: %BinaryNode{tag: "participant", attrs: %{"jid" => jid}}

  defp invite_code_from_result(result) do
    with %BinaryNode{attrs: attrs} <- BinaryNodeUtil.child(result, "invite") do
      attrs["code"]
    end
  end

  defp clean_dirty_bits_node(type, from_timestamp, opts) do
    attrs =
      %{"type" => type}
      |> maybe_put_timestamp(from_timestamp)

    %BinaryNode{
      tag: "iq",
      attrs: %{
        "to" => @s_whatsapp_net,
        "type" => "set",
        "xmlns" => "urn:xmpp:whatsapp:dirty",
        "id" => message_tag(opts)
      },
      content: [%BinaryNode{tag: "clean", attrs: attrs}]
    }
  end

  defp emit_groups_update(opts, groups) do
    case Keyword.get(opts, :emit_fun) do
      fun when is_function(fun, 1) ->
        fun.(groups)

      _ ->
        case Keyword.get(opts, :event_emitter) do
          nil -> :ok
          event_emitter -> EventEmitter.emit(event_emitter, :groups_update, groups)
        end
    end
  end

  defp query(queryable, %BinaryNode{} = node, timeout) when is_function(queryable, 2),
    do: queryable.(node, timeout)

  defp query(queryable, %BinaryNode{} = node, _timeout) when is_function(queryable, 1),
    do: queryable.(node)

  defp query({module, server}, %BinaryNode{} = node, timeout) when is_atom(module),
    do: module.query(server, node, timeout)

  defp query(queryable, %BinaryNode{} = node, timeout),
    do: Socket.query(queryable, node, timeout)

  defp send_node(sendable, %BinaryNode{} = node) when is_function(sendable, 1),
    do: sendable.(node)

  defp send_node({module, server}, %BinaryNode{} = node) when is_atom(module),
    do: module.send_node(server, node)

  defp send_node(sendable, %BinaryNode{} = node), do: Socket.send_node(sendable, node)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_timestamp(attrs, timestamp) when is_integer(timestamp) and timestamp > 0,
    do: Map.put(attrs, "timestamp", Integer.to_string(timestamp))

  defp maybe_put_timestamp(attrs, timestamp) when is_binary(timestamp) and timestamp != "",
    do: Map.put(attrs, "timestamp", timestamp)

  defp maybe_put_timestamp(attrs, _timestamp), do: attrs

  defp parse_int(nil), do: nil
  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp message_tag(opts) do
    case opts[:message_tag_fun] do
      fun when is_function(fun, 0) -> fun.()
      _ -> Integer.to_string(System.unique_integer([:positive, :monotonic]))
    end
  end
end
