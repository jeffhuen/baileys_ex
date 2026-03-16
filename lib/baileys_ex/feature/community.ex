defmodule BaileysEx.Feature.Community do
  @moduledoc """
  Community-management helpers mapped from Baileys' `communities.ts`.
  """

  alias BaileysEx.BinaryNode
  alias BaileysEx.Connection.EventEmitter
  alias BaileysEx.Connection.Socket
  alias BaileysEx.Feature.Group
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

  @doc "Create a new community and return the created metadata when the follow-up metadata fetch succeeds."
  @spec create(term(), String.t(), String.t() | nil) :: {:ok, map() | nil} | {:error, term()}
  @spec create(term(), String.t(), String.t() | nil, keyword()) ::
          {:ok, map() | nil} | {:error, term()}
  def create(conn, subject, description, opts \\ [])
      when is_binary(subject) and is_list(opts) and
             (is_binary(description) or is_nil(description)) do
    description = description || ""

    with {:ok, result} <-
           community_query(conn, "@g.us", "set", [
             %BinaryNode{
               tag: "create",
               attrs: %{"subject" => subject},
               content: [
                 %BinaryNode{
                   tag: "description",
                   attrs: %{"id" => description_id(opts)},
                   content: [%BinaryNode{tag: "body", attrs: %{}, content: description}]
                 },
                 %BinaryNode{
                   tag: "parent",
                   attrs: %{"default_membership_approval_mode" => "request_required"}
                 },
                 %BinaryNode{tag: "allow_non_admin_sub_group_creation", attrs: %{}},
                 %BinaryNode{tag: "create_general_chat", attrs: %{}}
               ]
             }
           ]) do
      parse_create_result(conn, result)
    end
  end

  @doc "Create a linked subgroup inside a community."
  @spec create_group(term(), String.t(), [String.t()], String.t()) ::
          {:ok, map() | nil} | {:error, term()}
  @spec create_group(term(), String.t(), [String.t()], String.t(), keyword()) ::
          {:ok, map() | nil} | {:error, term()}
  def create_group(conn, subject, participants, parent_community_jid, opts \\ [])
      when is_binary(subject) and is_list(participants) and is_binary(parent_community_jid) and
             is_list(opts) do
    with {:ok, result} <-
           community_query(conn, "@g.us", "set", [
             %BinaryNode{
               tag: "create",
               attrs: %{"subject" => subject, "key" => message_id(opts)},
               content:
                 Enum.map(participants, &participant_node/1) ++
                   [%BinaryNode{tag: "linked_parent", attrs: %{"jid" => parent_community_jid}}]
             }
           ]) do
      parse_create_result(conn, result)
    end
  end

  @doc "Leave a community."
  @spec leave(term(), String.t()) :: :ok | {:error, term()}
  def leave(conn, community_jid) when is_binary(community_jid) do
    case community_query(conn, "@g.us", "set", [
           %BinaryNode{
             tag: "leave",
             attrs: %{},
             content: [%BinaryNode{tag: "community", attrs: %{"id" => community_jid}}]
           }
         ]) do
      {:ok, _} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc "Update the subject for an existing community."
  @spec update_subject(term(), String.t(), String.t()) :: :ok | {:error, term()}
  def update_subject(conn, community_jid, subject)
      when is_binary(community_jid) and is_binary(subject) do
    Group.update_subject(conn, community_jid, subject)
  end

  @doc "Update or clear the community description."
  @spec update_description(term(), String.t(), String.t() | nil) :: :ok | {:error, term()}
  @spec update_description(term(), String.t(), String.t() | nil, keyword()) ::
          :ok | {:error, term()}
  def update_description(conn, community_jid, description, opts \\ [])
      when is_binary(community_jid) and is_list(opts) do
    description = empty_string_to_nil(description)

    with {:ok, metadata} <- metadata(conn, community_jid) do
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

      case community_query(conn, community_jid, "set", [
             %BinaryNode{tag: "description", attrs: attrs, content: content}
           ]) do
        {:ok, _} -> :ok
        {:error, _reason} = error -> error
      end
    end
  end

  @doc "Link an existing subgroup into a community."
  @spec link_group(term(), String.t(), String.t()) :: :ok | {:error, term()}
  def link_group(conn, group_jid, parent_community_jid)
      when is_binary(group_jid) and is_binary(parent_community_jid) do
    case community_query(conn, parent_community_jid, "set", [
           %BinaryNode{
             tag: "links",
             attrs: %{},
             content: [
               %BinaryNode{
                 tag: "link",
                 attrs: %{"link_type" => "sub_group"},
                 content: [%BinaryNode{tag: "group", attrs: %{"jid" => group_jid}}]
               }
             ]
           }
         ]) do
      {:ok, _} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc "Unlink a subgroup from a community."
  @spec unlink_group(term(), String.t(), String.t()) :: :ok | {:error, term()}
  def unlink_group(conn, group_jid, parent_community_jid)
      when is_binary(group_jid) and is_binary(parent_community_jid) do
    case community_query(conn, parent_community_jid, "set", [
           %BinaryNode{
             tag: "unlink",
             attrs: %{"unlink_type" => "sub_group"},
             content: [%BinaryNode{tag: "group", attrs: %{"jid" => group_jid}}]
           }
         ]) do
      {:ok, _} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc "Fetch all linked groups for a community or subgroup JID."
  @spec fetch_linked_groups(term(), String.t()) ::
          {:ok, %{community_jid: String.t(), is_community: boolean(), linked_groups: [map()]}}
          | {:error, term()}
  def fetch_linked_groups(conn, jid) when is_binary(jid) do
    with {:ok, metadata} <- Group.get_metadata(conn, jid) do
      community_jid = metadata[:linked_parent] || jid
      is_community = is_nil(metadata[:linked_parent])

      with {:ok, result} <-
             community_query(conn, community_jid, "get", [
               %BinaryNode{tag: "sub_groups", attrs: %{}}
             ]) do
        linked_groups =
          result
          |> BinaryNodeUtil.child("sub_groups")
          |> BinaryNodeUtil.children("group")
          |> Enum.map(&linked_group_metadata/1)

        {:ok,
         %{
           community_jid: community_jid,
           is_community: is_community,
           linked_groups: linked_groups
         }}
      end
    end
  end

  @doc "Add, remove, promote, or demote participants in a community."
  @spec participants_update(term(), String.t(), [String.t()], :add | :remove | :promote | :demote) ::
          {:ok, [participant_result()]} | {:error, term()}
  def participants_update(conn, community_jid, jids, action)
      when is_binary(community_jid) and is_list(jids) and
             action in [:add, :remove, :promote, :demote] do
    action_tag = Atom.to_string(action)
    attrs = if action == :remove, do: %{"linked_groups" => "true"}, else: %{}

    with {:ok, result} <-
           community_query(conn, community_jid, "set", [
             %BinaryNode{
               tag: action_tag,
               attrs: attrs,
               content: Enum.map(jids, &participant_node/1)
             }
           ]) do
      {:ok,
       Enum.map(
         BinaryNodeUtil.children(BinaryNodeUtil.child(result, action_tag), "participant"),
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

  @doc "Fetch the pending membership-approval request list for a community."
  @spec request_participants_list(term(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def request_participants_list(conn, community_jid) when is_binary(community_jid) do
    Group.request_participants_list(conn, community_jid)
  end

  @doc "Approve or reject pending community membership requests."
  @spec request_participants_update(term(), String.t(), [String.t()], :approve | :reject) ::
          {:ok, [participant_result()]} | {:error, term()}
  def request_participants_update(conn, community_jid, jids, action)
      when is_binary(community_jid) and is_list(jids) and action in [:approve, :reject] do
    Group.request_participants_update(conn, community_jid, jids, action)
  end

  @doc "Fetch the current invite code for a community."
  @spec invite_code(term(), String.t()) :: {:ok, String.t() | nil} | {:error, term()}
  def invite_code(conn, community_jid) when is_binary(community_jid) do
    Group.invite_code(conn, community_jid)
  end

  @doc "Revoke the current invite code and return the new one."
  @spec revoke_invite(term(), String.t()) :: {:ok, String.t() | nil} | {:error, term()}
  def revoke_invite(conn, community_jid) when is_binary(community_jid) do
    Group.revoke_invite(conn, community_jid)
  end

  @doc "Accept a legacy invite code and return the joined community JID."
  @spec accept_invite(term(), String.t()) :: {:ok, String.t() | nil} | {:error, term()}
  def accept_invite(conn, code) when is_binary(code) do
    with {:ok, result} <-
           community_query(conn, "@g.us", "set", [
             %BinaryNode{tag: "invite", attrs: %{"code" => code}}
           ]) do
      {:ok,
       with %BinaryNode{} = community <- BinaryNodeUtil.child(result, "community"),
            jid when is_binary(jid) <- community.attrs["jid"] do
         jid
       end}
    end
  end

  @doc "Fetch interactive metadata for a community."
  @spec metadata(term(), String.t()) :: {:ok, map()} | {:error, term()}
  @spec metadata(term(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def metadata(conn, community_jid, opts \\ [])
      when is_binary(community_jid) and is_list(opts) do
    with {:ok, result} <-
           community_query(
             conn,
             community_jid,
             "get",
             [
               %BinaryNode{tag: "query", attrs: %{"request" => "interactive"}}
             ],
             opts
           ) do
      {:ok, extract_metadata(result)}
    end
  end

  @doc "Fetch the metadata associated with an invite code without joining."
  @spec get_invite_info(term(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_invite_info(conn, code) when is_binary(code) do
    with {:ok, result} <-
           community_query(conn, "@g.us", "get", [
             %BinaryNode{tag: "invite", attrs: %{"code" => code}}
           ]) do
      {:ok, extract_metadata(result)}
    end
  end

  @doc "Accept a v4 invite and emit the same post-join side effects Baileys performs."
  @spec accept_invite_v4(term(), String.t() | map(), map(), keyword()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def accept_invite_v4(conn, key, invite_message, opts \\ []) do
    Group.accept_invite_v4(conn, key, invite_message, opts)
  end

  @doc "Revoke a v4 invite for a specific invited user."
  @spec revoke_invite_v4(term(), String.t(), String.t()) :: :ok | {:error, term()}
  def revoke_invite_v4(conn, community_jid, invited_jid)
      when is_binary(community_jid) and is_binary(invited_jid) do
    Group.revoke_invite_v4(conn, community_jid, invited_jid)
  end

  @doc "Enable or disable disappearing messages for a community."
  @spec toggle_ephemeral(term(), String.t(), non_neg_integer()) :: :ok | {:error, term()}
  def toggle_ephemeral(conn, community_jid, expiration)
      when is_binary(community_jid) and is_integer(expiration) and expiration >= 0 do
    Group.toggle_ephemeral(conn, community_jid, expiration)
  end

  @doc "Update announcement or locked settings for a community."
  @spec setting_update(
          term(),
          String.t(),
          :announcement | :not_announcement | :locked | :unlocked
        ) :: :ok | {:error, term()}
  def setting_update(conn, community_jid, setting)
      when setting in [:announcement, :not_announcement, :locked, :unlocked] do
    Group.setting_update(conn, community_jid, setting)
  end

  @doc "Switch whether only admins or all members can add participants."
  @spec member_add_mode(term(), String.t(), :admin_add | :all_member_add) ::
          :ok | {:error, term()}
  def member_add_mode(conn, community_jid, mode) when mode in [:admin_add, :all_member_add] do
    Group.member_add_mode(conn, community_jid, mode)
  end

  @doc "Toggle join-approval mode for a community."
  @spec join_approval_mode(term(), String.t(), :on | :off) :: :ok | {:error, term()}
  def join_approval_mode(conn, community_jid, mode) when mode in [:on, :off] do
    case community_query(conn, community_jid, "set", [
           %BinaryNode{
             tag: "membership_approval_mode",
             attrs: %{},
             content: [
               %BinaryNode{
                 tag: "community_join",
                 attrs: %{"state" => Atom.to_string(mode)}
               }
             ]
           }
         ]) do
      {:ok, _} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc "Fetch all participating communities and optionally emit a `groups_update` event."
  @spec fetch_all_participating(term(), keyword()) ::
          {:ok, %{String.t() => map()}} | {:error, term()}
  def fetch_all_participating(conn, opts \\ []) do
    with {:ok, result} <-
           community_query(conn, "@g.us", "get", [
             %BinaryNode{
               tag: "participating",
               attrs: %{},
               content: [
                 %BinaryNode{tag: "participants", attrs: %{}},
                 %BinaryNode{tag: "description", attrs: %{}}
               ]
             }
           ]) do
      communities =
        result
        |> BinaryNodeUtil.child("communities")
        |> BinaryNodeUtil.children("community")
        |> Enum.reduce(%{}, fn community_node, acc ->
          metadata =
            extract_metadata(%BinaryNode{
              tag: "result",
              attrs: %{},
              content: [community_node]
            })

          Map.put(acc, metadata.id, metadata)
        end)

      emit_groups_update(opts, Map.values(communities))
      {:ok, communities}
    end
  end

  @doc "Handle a dirty community update by refetching communities and cleaning the groups dirty bucket."
  @spec handle_dirty_update(term(), %{type: String.t()}, keyword()) ::
          {:ok, %{String.t() => map()}} | :ignore | {:error, term()}
  def handle_dirty_update(conn, dirty_update, opts \\ [])

  def handle_dirty_update(conn, %{type: "communities"} = dirty_update, opts) do
    timestamp = Map.get(dirty_update, :timestamp) || Map.get(dirty_update, "timestamp")

    with {:ok, communities} <- fetch_all_participating(conn, opts) do
      _ =
        send_node(
          Keyword.get(opts, :sendable, conn),
          clean_dirty_bits_node("groups", timestamp, opts)
        )

      {:ok, communities}
    end
  end

  def handle_dirty_update(_conn, _dirty_update, _opts), do: :ignore

  @doc "Extract Baileys-aligned community metadata from a community IQ result node."
  @spec extract_metadata(BinaryNode.t()) :: map()
  def extract_metadata(%BinaryNode{} = result) do
    community = BinaryNodeUtil.child(result, "community")
    desc_child = BinaryNodeUtil.child(community, "description")

    %{
      id: community_id(community.attrs["id"]),
      subject: community.attrs["subject"] || "",
      subject_owner: community.attrs["s_o"],
      subject_time: parse_int(community.attrs["s_t"]) || 0,
      size: length(BinaryNodeUtil.children(community, "participant")),
      creation: parse_int(community.attrs["creation"]) || 0,
      owner: normalize_optional_user(community.attrs["creator"]),
      desc: BinaryNodeUtil.child_string(desc_child, "body"),
      desc_id: desc_child && desc_child.attrs["id"],
      linked_parent: child_jid(community, "linked_parent"),
      restrict: has_child?(community, "locked"),
      announce: has_child?(community, "announcement"),
      is_community: has_child?(community, "parent"),
      is_community_announce: has_child?(community, "default_sub_community"),
      join_approval_mode: has_child?(community, "membership_approval_mode"),
      member_add_mode:
        BinaryNodeUtil.child_string(community, "member_add_mode") == "all_member_add",
      participants: parse_participants(community),
      ephemeral_duration: ephemeral_duration(community),
      addressing_mode: addressing_mode(BinaryNodeUtil.child_string(community, "addressing_mode"))
    }
  end

  defp parse_create_result(conn, result) do
    with %BinaryNode{} = group_node <- BinaryNodeUtil.child(result, "group"),
         id when is_binary(id) <- community_id(group_node.attrs["id"]) do
      case Group.get_metadata(conn, id) do
        {:ok, metadata} -> {:ok, metadata}
        {:error, _reason} -> {:ok, nil}
      end
    else
      _ -> {:ok, nil}
    end
  end

  defp linked_group_metadata(%BinaryNode{attrs: attrs}) do
    %{
      id: community_id(attrs["id"]),
      subject: attrs["subject"] || "",
      creation: parse_int(attrs["creation"]),
      owner: normalize_optional_user(attrs["creator"]),
      size: parse_int(attrs["size"])
    }
  end

  defp parse_participants(community) do
    Enum.map(BinaryNodeUtil.children(community, "participant"), fn participant ->
      %{
        id: participant.attrs["jid"],
        admin: participant.attrs["type"]
      }
    end)
  end

  defp community_query(conn, jid, type, content, opts \\ []) do
    query(
      conn,
      %BinaryNode{
        tag: "iq",
        attrs: %{"type" => type, "xmlns" => "w:g2", "to" => jid},
        content: content
      },
      Keyword.get(opts, :query_timeout, @timeout)
    )
  end

  defp description_id(opts) do
    opts
    |> message_id()
    |> String.slice(0, 12)
  end

  defp participant_node(jid), do: %BinaryNode{tag: "participant", attrs: %{"jid" => jid}}

  defp community_id(nil), do: nil

  defp community_id(id) do
    if String.contains?(id, "@"), do: id, else: JID.jid_encode(id, JID.g_us())
  end

  defp normalize_optional_user(value) when is_binary(value) do
    case JID.normalized_user(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_optional_user(_value), do: nil

  defp child_jid(node, tag) do
    case BinaryNodeUtil.child(node, tag) do
      nil -> nil
      child -> child.attrs["jid"]
    end
  end

  defp has_child?(node, tag), do: not is_nil(BinaryNodeUtil.child(node, tag))

  defp ephemeral_duration(node) do
    node
    |> BinaryNodeUtil.child("ephemeral")
    |> then(fn
      nil -> nil
      child -> parse_int(child.attrs["expiration"])
    end)
  end

  defp addressing_mode(nil), do: nil
  defp addressing_mode("lid"), do: :lid
  defp addressing_mode(_mode), do: :pn

  defp empty_string_to_nil(""), do: nil
  defp empty_string_to_nil(description), do: description

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

  defp message_id(opts, seed_id \\ nil) do
    case opts[:message_id_fun] do
      fun when is_function(fun, 0) -> fun.()
      fun when is_function(fun, 1) -> fun.(seed_id)
      _ -> Wire.generate_message_id(seed_id)
    end
  end

  defp message_tag(opts) do
    case opts[:message_tag_fun] do
      fun when is_function(fun, 0) -> fun.()
      _ -> Integer.to_string(System.unique_integer([:positive, :monotonic]))
    end
  end
end
