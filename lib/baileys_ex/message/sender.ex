defmodule BaileysEx.Message.Sender do
  @moduledoc """
  Message send pipeline.
  """

  alias BaileysEx.BinaryNode
  alias BaileysEx.JID
  alias BaileysEx.Media.MessageBuilder, as: MediaMessageBuilder
  alias BaileysEx.Message.Builder
  alias BaileysEx.Message.Reporting
  alias BaileysEx.Message.Wire
  alias BaileysEx.Protocol.JID, as: JIDUtil
  alias BaileysEx.Protocol.Proto.Message
  alias BaileysEx.Signal.Repository
  alias BaileysEx.Signal.Device
  alias BaileysEx.Signal.Store

  @status_broadcast %JID{user: "status", server: "broadcast"}

  @type context :: %{
          required(:signal_repository) => Repository.t(),
          required(:signal_store) => Store.t(),
          required(:me_id) => String.t(),
          optional(:device_identity) => binary(),
          optional(:me_lid) => String.t(),
          optional(:query_fun) => (BinaryNode.t() -> {:ok, BinaryNode.t()} | {:error, term()}),
          optional(:send_node_fun) => (BinaryNode.t() -> :ok | {:error, term()}),
          optional(:socket) => GenServer.server()
        }

  @type proto_message :: struct()

  @type send_result :: %{
          id: String.t(),
          jid: JID.t(),
          message: proto_message(),
          timestamp: integer()
        }

  @spec send(context(), JID.t(), map(), keyword()) ::
          {:ok, send_result(), context()}
          | {:error, term()}
  def send(context, jid, content, opts \\ [])

  def send(%{} = context, %JID{} = jid, %Message{} = proto_message, opts) do
    send_proto(context, jid, proto_message, opts)
  end

  def send(%{} = context, %JID{} = jid, content, opts) when is_map(content) do
    media_opts =
      opts
      |> Keyword.put_new_lazy(:media_queryable, fn -> context[:query_fun] || context[:socket] end)
      |> Keyword.put_new(:store_ref, context[:store_ref])

    with {:ok, prepared_content} <- MediaMessageBuilder.prepare(content, media_opts),
         %Message{} = proto_message <- Builder.build(prepared_content, opts) do
      send_proto(context, jid, proto_message, opts)
    end
  end

  @spec send_proto(context(), JID.t(), proto_message(), keyword()) ::
          {:ok, send_result(), context()}
          | {:error, term()}
  def send_proto(%{} = context, %JID{} = jid, %Message{} = proto_message, opts \\ []) do
    with {:ok, message_id} <- generate_message_id(context, opts),
         {:ok, updated_context, stanza_children} <-
           relay_content(context, jid, proto_message, opts),
         :ok <-
           relay(
             updated_context,
             build_relay_node(jid, message_id, proto_message, stanza_children, opts)
           ) do
      {:ok,
       %{
         id: message_id,
         jid: jid,
         message: proto_message,
         timestamp: now(opts)
       }, updated_context}
    end
  end

  @spec send_status(context(), map(), keyword()) :: {:ok, map(), context()} | {:error, term()}
  def send_status(%{} = context, content, opts \\ []) when is_map(content) do
    send(context, @status_broadcast, content, opts)
  end

  defp relay_content(
         %{signal_store: %Store{}} = context,
         %JID{} = jid,
         %Message{} = message,
         opts
       ) do
    cond do
      JIDUtil.group?(jid) ->
        relay_group_message(context, jid, message, opts)

      JIDUtil.status_broadcast?(jid) ->
        relay_group_message(
          context,
          jid,
          message,
          Keyword.put_new(opts, :group_participants, opts[:status_jid_list] || [])
        )

      true ->
        relay_direct_message(context, jid, message, opts)
    end
  end

  defp relay_direct_message(%{signal_store: store, me_id: me_id} = context, jid, message, opts) do
    recipient_jid = JIDUtil.to_string(jid)
    me_user_jid = base_user_jid(me_id)

    with {:ok, context, recipient_devices} <- discover_devices(context, [recipient_jid], opts),
         {:ok, context, own_devices} <- discover_devices(context, [me_user_jid], opts) do
      recipient_devices =
        recipient_devices
        |> Enum.reject(&(&1 == me_id))
        |> Enum.uniq()

      own_devices =
        Enum.reject(own_devices, &skip_own_device?(&1, me_id, recipient_jid, recipient_devices))
        |> Enum.uniq()

      phash = Wire.generate_participant_hash(recipient_devices ++ own_devices)
      dsm = wrap_device_sent_message(message, recipient_jid)

      with {:ok, repo, me_nodes, me_include_identity?} <-
             create_participant_nodes(context.signal_repository, own_devices, dsm, phash),
           {:ok, repo, other_nodes, other_include_identity?} <-
             create_participant_nodes(repo, recipient_devices, message, phash) do
        trusted_contact_token = trusted_contact_token(store, recipient_jid)

        children =
          []
          |> maybe_append_participants(me_nodes ++ other_nodes)
          |> maybe_append_device_identity(
            (me_include_identity? || other_include_identity?) &&
              Map.has_key?(context, :device_identity),
            context[:device_identity]
          )
          |> maybe_append_tctoken(trusted_contact_token)

        {:ok, %{context | signal_repository: repo}, children}
      end
    end
  end

  defp relay_group_message(
         %{signal_repository: repo, signal_store: store, me_id: me_id} = context,
         jid,
         message,
         opts
       ) do
    participants = opts[:group_participants] || []
    group_jid = JIDUtil.to_string(jid)

    with {:ok, context, participant_devices} <- discover_devices(context, participants, opts),
         {:ok, repo, %{ciphertext: ciphertext, sender_key_distribution_message: distribution}} <-
           Repository.encrypt_group_message(repo, %{
             group: group_jid,
             me_id: me_id,
             data: Wire.encode(message)
           }) do
      known_devices =
        case Store.get(store, :"sender-key-memory", [group_jid]) do
          %{^group_jid => devices} when is_map(devices) -> devices
          _ -> %{}
        end

      new_devices = Enum.reject(participant_devices, &Map.has_key?(known_devices, &1))

      sender_key_message = %Message{
        sender_key_distribution_message: %Message.SenderKeyDistributionMessage{
          group_id: group_jid,
          axolotl_sender_key_distribution_message: distribution
        }
      }

      phash = Wire.generate_participant_hash(participant_devices)

      with {:ok, repo, participant_nodes, include_device_identity?} <-
             create_participant_nodes(repo, new_devices, sender_key_message, phash) do
        :ok =
          Store.set(store, %{
            :"sender-key-memory" => %{
              group_jid =>
                Enum.reduce(participant_devices, known_devices, fn device_jid, acc ->
                  Map.put(acc, device_jid, true)
                end)
            }
          })

        children =
          [
            %BinaryNode{
              tag: "enc",
              attrs: %{"type" => "skmsg", "v" => "2"},
              content: {:binary, ciphertext}
            }
          ]
          |> maybe_append_participants(participant_nodes)
          |> maybe_append_device_identity(
            include_device_identity? && Map.has_key?(context, :device_identity),
            context[:device_identity]
          )

        {:ok, %{context | signal_repository: repo}, children}
      end
    end
  end

  defp create_participant_nodes(%Repository{} = repo, device_jids, %Message{} = message, phash) do
    bytes = Wire.encode(message)

    Enum.reduce_while(device_jids, {:ok, repo, [], false}, fn device_jid,
                                                              {:ok, acc_repo, nodes,
                                                               include_identity?} ->
      case Repository.encrypt_message(acc_repo, %{jid: device_jid, data: bytes}) do
        {:ok, next_repo, %{type: type, ciphertext: ciphertext}} ->
          node = %BinaryNode{
            tag: "to",
            attrs: %{"jid" => device_jid},
            content: [
              %BinaryNode{
                tag: "enc",
                attrs: %{"type" => Atom.to_string(type), "v" => "2", "phash" => phash},
                content: {:binary, ciphertext}
              }
            ]
          }

          {:cont, {:ok, next_repo, nodes ++ [node], include_identity? || type == :pkmsg}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp discover_devices(context, jids, opts) do
    case opts[:device_lookup_fun] || context[:device_lookup_fun] do
      fun when is_function(fun, 3) ->
        normalize_device_lookup_result(fun.(context, jids, opts), context)

      _ ->
        device_module = opts[:device_module] || context[:device_module] || Device
        normalize_device_lookup_result(device_module.get_devices(context, jids, opts), context)
    end
  end

  defp normalize_device_lookup_result({:ok, %{} = context_update, devices}, %{} = context)
       when is_list(devices) do
    {:ok, Map.merge(context, context_update), devices}
  end

  defp normalize_device_lookup_result({:error, _reason} = error, _context), do: error

  defp relay(%{send_node_fun: fun}, %BinaryNode{} = node) when is_function(fun, 1), do: fun.(node)

  defp relay(%{socket: socket}, %BinaryNode{} = node),
    do: BaileysEx.Connection.Socket.send_node(socket, node)

  defp relay(_context, %BinaryNode{} = _node), do: {:error, :send_node_not_configured}

  defp build_relay_node(jid, message_id, %Message{} = message, content, opts) do
    attrs =
      %{
        "id" => message_id,
        "to" => JIDUtil.to_string(jid),
        "type" => stanza_type(message)
      }
      |> Map.merge(stringify_attrs(opts[:additional_attributes] || %{}))

    reporting_node =
      Reporting.reporting_node(message, %{
        id: message_id,
        remote_jid: JIDUtil.to_string(jid),
        participant: opts[:participant],
        from_me: true
      })

    %BinaryNode{
      tag: "message",
      attrs: attrs,
      content: content ++ List.wrap(reporting_node) ++ List.wrap(opts[:additional_nodes])
    }
  end

  defp wrap_device_sent_message(%Message{} = message, destination_jid) do
    %Message{
      device_sent_message: %Message.DeviceSentMessage{
        destination_jid: destination_jid,
        message: message
      },
      message_context_info: message.message_context_info
    }
  end

  defp trusted_contact_token(%Store{} = store, destination_jid) do
    case Store.get(store, :tctoken, [destination_jid]) do
      %{^destination_jid => %{token: token}} -> token
      _ -> nil
    end
  end

  defp maybe_append_participants(children, []), do: children

  defp maybe_append_participants(children, participants) do
    children ++ [%BinaryNode{tag: "participants", attrs: %{}, content: participants}]
  end

  defp maybe_append_device_identity(children, false, _device_identity), do: children
  defp maybe_append_device_identity(children, true, nil), do: children

  defp maybe_append_device_identity(children, true, device_identity) do
    children ++
      [%BinaryNode{tag: "device-identity", attrs: %{}, content: {:binary, device_identity}}]
  end

  defp maybe_append_tctoken(children, nil), do: children

  defp maybe_append_tctoken(children, token),
    do: children ++ [%BinaryNode{tag: "tctoken", attrs: %{}, content: token}]

  defp generate_message_id(%{me_id: me_id}, opts) do
    case opts[:message_id_fun] do
      fun when is_function(fun, 1) -> {:ok, fun.(me_id)}
      fun when is_function(fun, 0) -> {:ok, fun.()}
      nil -> {:ok, Wire.generate_message_id(me_id)}
    end
  end

  defp now(opts) do
    case opts[:timestamp_fun] do
      fun when is_function(fun, 0) -> fun.()
      _ -> System.os_time(:millisecond)
    end
  end

  defp base_user_jid(jid) do
    case JIDUtil.parse(jid) do
      %JID{user: user, server: server} -> JIDUtil.jid_encode(user, server)
      _ -> jid
    end
  end

  defp skip_own_device?(device_jid, me_id, recipient_jid, recipient_devices) do
    device_jid == me_id ||
      (same_user?(device_jid, recipient_jid) && device_jid == recipient_jid) ||
      device_jid in recipient_devices
  end

  defp same_user?(jid1, jid2), do: JIDUtil.same_user?(jid1, jid2)

  defp stringify_attrs(attrs) do
    Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
  end

  defp stanza_type(%Message{reaction_message: %Message.ReactionMessage{}}), do: "reaction"
  defp stanza_type(%Message{protocol_message: %Message.ProtocolMessage{}}), do: "protocol"
  defp stanza_type(%Message{event_message: %Message.EventMessage{}}), do: "event"
  defp stanza_type(%Message{poll_creation_message: %Message.PollCreationMessage{}}), do: "poll"
  defp stanza_type(%Message{poll_creation_message_v2: %Message.PollCreationMessage{}}), do: "poll"
  defp stanza_type(%Message{poll_creation_message_v3: %Message.PollCreationMessage{}}), do: "poll"
  defp stanza_type(%Message{extended_text_message: %Message.ExtendedTextMessage{}}), do: "text"
  defp stanza_type(%Message{conversation: text}) when is_binary(text), do: "text"
  defp stanza_type(_message), do: "media"
end
