defmodule BaileysEx.Message.Sender do
  @moduledoc """
  Message send pipeline.
  """

  alias BaileysEx.BinaryNode
  alias BaileysEx.Connection.Store, as: RuntimeStore
  alias BaileysEx.Feature.TcToken
  alias BaileysEx.JID
  alias BaileysEx.Media.MessageBuilder, as: MediaMessageBuilder
  alias BaileysEx.Message.Retry
  alias BaileysEx.Message.Builder
  alias BaileysEx.Message.Reporting
  alias BaileysEx.Message.Wire
  alias BaileysEx.Protocol.JID, as: JIDUtil
  alias BaileysEx.Protocol.Proto.Message
  alias BaileysEx.Signal.Repository
  alias BaileysEx.Signal.Device
  alias BaileysEx.Signal.Session
  alias BaileysEx.Signal.Store
  alias BaileysEx.Telemetry

  @status_broadcast %JID{user: "status", server: "broadcast"}

  @type context :: %{
          required(:signal_repository) => Repository.t(),
          required(:signal_store) => Store.t(),
          required(:me_id) => String.t(),
          optional(:device_identity) => binary(),
          optional(:enable_recent_message_cache) => boolean(),
          optional(:me_lid) => String.t(),
          optional(:store_ref) => RuntimeStore.Ref.t(),
          optional(:query_fun) => (BinaryNode.t() -> {:ok, BinaryNode.t()} | {:error, term()}),
          optional(:send_node_fun) => (BinaryNode.t() -> :ok | {:error, term()}),
          optional(:socket) => GenServer.server(),
          optional(:cached_group_metadata) => (String.t() -> {:ok, map()} | nil),
          optional(:group_metadata_fun) => (String.t() -> {:ok, map()} | {:error, term()})
        }

  @type proto_message :: struct()

  @type send_result :: %{
          id: String.t(),
          jid: JID.t(),
          message: proto_message(),
          timestamp: integer()
        }

  @doc """
  Sends a generic content map to the specified JID, converting maps to WAProto messages.
  """
  @spec send(context(), JID.t(), map(), keyword()) ::
          {:ok, send_result(), context()}
          | {:error, term()}
  def send(context, jid, content, opts \\ [])

  def send(%{} = context, %JID{} = jid, %Message{} = proto_message, opts) do
    send_proto(context, jid, proto_message, opts)
  end

  def send(%{} = context, %JID{} = jid, content, opts) when is_map(content) do
    Telemetry.span_with_result(
      [:message, :send],
      send_telemetry_metadata(jid),
      &send_result_metadata/1,
      fn ->
        media_opts =
          opts
          |> Keyword.put_new_lazy(:media_queryable, fn ->
            context[:query_fun] || context[:socket]
          end)
          |> Keyword.put_new(:store_ref, context[:store_ref])

        with {:ok, prepared_content} <- MediaMessageBuilder.prepare(content, media_opts),
             %Message{} = proto_message <- Builder.build(prepared_content, opts) do
          do_send_proto(context, jid, proto_message, opts)
        end
      end
    )
  end

  @doc """
  Serializes, encrypts, and transmits a pre-constructed WAProto message to a specific JID.
  """
  @spec send_proto(context(), JID.t(), proto_message(), keyword()) ::
          {:ok, send_result(), context()}
          | {:error, term()}
  def send_proto(%{} = context, %JID{} = jid, %Message{} = proto_message, opts \\ []) do
    Telemetry.span_with_result(
      [:message, :send],
      send_telemetry_metadata(jid),
      &send_result_metadata/1,
      fn -> do_send_proto(context, jid, proto_message, opts) end
    )
  end

  defp do_send_proto(%{} = context, %JID{} = jid, %Message{} = proto_message, opts) do
    with {:ok, message_id} <- generate_message_id(context, opts) do
      if retry_participant?(opts[:participant]) do
        do_send_retry_resend(context, jid, proto_message, message_id, opts)
      else
        with {:ok, updated_context, stanza_children} <-
               relay_content(context, jid, proto_message, opts),
             :ok <-
               relay(
                 updated_context,
                 build_relay_node(
                   updated_context,
                   jid,
                   message_id,
                   proto_message,
                   stanza_children,
                   opts
                 )
               ),
             :ok <-
               maybe_cache_recent_message(updated_context, jid, message_id, proto_message, opts) do
          {:ok,
           %{
             id: message_id,
             jid: jid,
             message: proto_message,
             timestamp: now(opts)
           }, updated_context}
        end
      end
    end
  end

  @doc """
  Uploads a new status update to all valid contacts via status broadcast channel.
  """
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
        with {:ok, opts} <- resolve_group_participants(context, jid, opts) do
          relay_group_message(context, jid, message, opts)
        end

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

  # Resolution order matching Baileys relayMessage:
  # 1. explicit group_participants: opt (always wins)
  # 2. cached_group_metadata callback (if configured and returns metadata with participants)
  # 3. live group_metadata_fun fallback
  defp resolve_group_participants(context, jid, opts) do
    if Keyword.has_key?(opts, :group_participants) do
      {:ok, opts}
    else
      group_jid_str = JIDUtil.to_string(jid)
      use_cached = Keyword.get(opts, :use_cached_group_metadata, true)

      case resolve_metadata(context, group_jid_str, use_cached) do
        {:ok, metadata} ->
          participants = extract_participant_ids(metadata)
          opts = Keyword.put(opts, :group_participants, participants)
          {:ok, maybe_add_ephemeral_expiration(opts, metadata)}

        _ ->
          {:error, :group_participants_not_found}
      end
    end
  end

  defp resolve_metadata(context, group_jid, use_cached) do
    cached_result =
      if use_cached do
        try_cached_metadata(context[:cached_group_metadata], group_jid)
      else
        nil
      end

    case cached_result do
      {:ok, %{participants: participants}} = result when is_list(participants) ->
        result

      _ ->
        try_live_metadata(context[:group_metadata_fun], group_jid)
    end
  end

  defp try_cached_metadata(nil, _jid), do: nil
  defp try_cached_metadata(fun, jid) when is_function(fun, 1), do: fun.(jid)

  defp try_live_metadata(nil, _jid), do: nil
  defp try_live_metadata(fun, jid) when is_function(fun, 1), do: fun.(jid)

  defp extract_participant_ids(%{participants: participants}) when is_list(participants) do
    Enum.map(participants, fn
      %{id: id} when is_binary(id) -> id
      %{"id" => id} when is_binary(id) -> id
      id when is_binary(id) -> id
    end)
  end

  defp extract_participant_ids(_metadata), do: []

  defp maybe_add_ephemeral_expiration(opts, %{ephemeral_duration: duration})
       when is_integer(duration) and duration > 0 do
    additional = Keyword.get(opts, :additional_attributes, %{})
    additional = Map.put_new(additional, "expiration", Integer.to_string(duration))
    Keyword.put(opts, :additional_attributes, additional)
  end

  defp maybe_add_ephemeral_expiration(opts, _metadata), do: opts

  defp relay_direct_message(%{me_id: me_id} = context, jid, message, opts) do
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

      with {:ok, context} <- maybe_assert_sessions(context, recipient_devices ++ own_devices),
           phash = Wire.generate_participant_hash(recipient_devices ++ own_devices),
           dsm = wrap_device_sent_message(message, recipient_jid),
           {:ok, repo, me_nodes, me_include_identity?} <-
             create_participant_nodes(context.signal_repository, own_devices, dsm, phash),
           {:ok, repo, other_nodes, other_include_identity?} <-
             create_participant_nodes(repo, recipient_devices, message, phash) do
        children =
          []
          |> maybe_append_participants(me_nodes ++ other_nodes)
          |> maybe_append_device_identity(
            (me_include_identity? || other_include_identity?) &&
              Map.has_key?(context, :device_identity),
            context[:device_identity]
          )

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

      with {:ok, context} <-
             maybe_assert_sessions(%{context | signal_repository: repo}, new_devices),
           {:ok, repo, participant_nodes, include_device_identity?} <-
             create_participant_nodes(
               context.signal_repository,
               new_devices,
               sender_key_message,
               phash
             ) do
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

  defp maybe_assert_sessions(%{signal_repository: %Repository{}} = context, []),
    do: {:ok, context}

  defp maybe_assert_sessions(%{signal_repository: %Repository{}} = context, jids) do
    case Session.assert_sessions(context, jids, force: false) do
      {:ok, next_context, _fetched?} -> {:ok, next_context}
      {:error, _reason} = error -> error
    end
  end

  defp relay(%{send_node_fun: fun}, %BinaryNode{} = node) when is_function(fun, 1), do: fun.(node)

  defp relay(%{socket: socket}, %BinaryNode{} = node),
    do: BaileysEx.Connection.Socket.send_node(socket, node)

  defp relay(_context, %BinaryNode{} = _node), do: {:error, :send_node_not_configured}

  defp do_send_retry_resend(%{} = context, %JID{} = jid, %Message{} = message, message_id, opts) do
    participant = opts[:participant]
    participant_jid = participant[:jid]
    count = participant[:count] || 1
    destination_jid = JIDUtil.to_string(jid)
    participant_message = retry_resend_message(context, message, destination_jid, participant_jid)
    bytes = Wire.encode(participant_message)

    with {:ok, updated_context} <- maybe_assert_sessions(context, [participant_jid]),
         {:ok, repo, %{type: type, ciphertext: ciphertext}} <-
           Repository.encrypt_message(updated_context.signal_repository, %{
             jid: participant_jid,
             data: bytes
           }),
         :ok <-
           relay(
             %{updated_context | signal_repository: repo},
             retry_resend_node(
               context,
               jid,
               participant,
               message_id,
               message,
               type,
               ciphertext,
               count,
               opts
             )
           ),
         :ok <-
           maybe_cache_recent_message(
             %{updated_context | signal_repository: repo},
             jid,
             message_id,
             message,
             opts
           ) do
      {:ok,
       %{
         id: message_id,
         jid: jid,
         message: message,
         timestamp: now(opts)
       }, %{updated_context | signal_repository: repo}}
    end
  end

  defp build_relay_node(context, jid, message_id, %Message{} = message, content, opts) do
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

    tc_token_node = trusted_contact_token_node(context, jid, opts[:participant])

    %BinaryNode{
      tag: "message",
      attrs: attrs,
      content:
        content ++
          List.wrap(reporting_node) ++
          List.wrap(tc_token_node) ++
          List.wrap(opts[:additional_nodes])
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

  defp trusted_contact_token_node(%{signal_store: %Store{} = store}, %JID{} = jid, participant) do
    if JIDUtil.group?(jid) or JIDUtil.status_broadcast?(jid) or retry_resend?(participant) do
      nil
    else
      TcToken.build_node(store, JIDUtil.to_string(jid))
    end
  end

  defp trusted_contact_token_node(_context, _jid, _participant), do: nil

  defp retry_resend?(%{jid: jid}) when is_binary(jid), do: true
  defp retry_resend?(_participant), do: false

  defp retry_participant?(%{jid: jid, count: count}) when is_binary(jid) and is_integer(count),
    do: true

  defp retry_participant?(%{jid: jid}) when is_binary(jid), do: true
  defp retry_participant?(_participant), do: false

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

  defp retry_resend_message(%{} = context, %Message{} = message, destination_jid, participant_jid) do
    me_identity = context[:me_lid] || context[:me_id]

    if same_user?(participant_jid, me_identity) do
      wrap_device_sent_message(message, destination_jid)
    else
      message
    end
  end

  defp retry_resend_node(
         %{} = context,
         %JID{} = jid,
         participant,
         message_id,
         %Message{} = message,
         type,
         ciphertext,
         count,
         opts
       ) do
    participant_jid = participant[:jid]
    destination_jid = JIDUtil.to_string(jid)
    me_identity = context[:me_lid] || context[:me_id]

    attrs =
      %{
        "id" => message_id,
        "to" => destination_jid,
        "type" => stanza_type(message)
      }
      |> Map.merge(stringify_attrs(opts[:additional_attributes] || %{}))
      |> maybe_put_attr("device_fanout", if(retry_device_fanout?(jid), do: "false"))

    attrs =
      cond do
        JIDUtil.group?(jid) ->
          Map.put(attrs, "participant", participant_jid)

        same_user?(participant_jid, me_identity) ->
          attrs
          |> Map.put("to", participant_jid)
          |> Map.put("recipient", destination_jid)

        true ->
          Map.put(attrs, "to", participant_jid)
      end

    content =
      [
        %BinaryNode{
          tag: "enc",
          attrs: %{
            "v" => "2",
            "type" => Atom.to_string(type),
            "count" => Integer.to_string(count)
          },
          content: {:binary, ciphertext}
        }
      ]
      |> maybe_append_device_identity(
        Map.has_key?(context, :device_identity),
        context[:device_identity]
      )

    %BinaryNode{tag: "message", attrs: attrs, content: content}
  end

  defp retry_device_fanout?(%JID{} = jid),
    do: not JIDUtil.group?(jid) and not JIDUtil.status_broadcast?(jid)

  defp maybe_cache_recent_message(
         %{store_ref: %RuntimeStore.Ref{} = store_ref, enable_recent_message_cache: true},
         %JID{} = jid,
         message_id,
         %Message{} = proto_message,
         opts
       )
       when is_binary(message_id) do
    if retry_participant?(opts[:participant]) do
      :ok
    else
      Retry.add_recent_message(store_ref, JIDUtil.to_string(jid), message_id, proto_message)
    end
  end

  defp maybe_cache_recent_message(_context, _jid, _message_id, _proto_message, _opts), do: :ok

  defp maybe_put_attr(attrs, _key, nil), do: attrs
  defp maybe_put_attr(attrs, key, value), do: Map.put(attrs, key, value)

  defp stringify_attrs(attrs) do
    Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
  end

  defp send_telemetry_metadata(%JID{} = jid) do
    %{
      jid: JIDUtil.to_string(jid),
      mode: send_mode(jid)
    }
  end

  defp send_mode(%JID{} = jid) do
    cond do
      JIDUtil.group?(jid) -> :group
      JIDUtil.status_broadcast?(jid) -> :status
      true -> :direct
    end
  end

  defp send_result_metadata({:ok, %{id: message_id}, _updated_context})
       when is_binary(message_id),
       do: %{message_id: message_id}

  defp send_result_metadata(_result), do: %{}

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
