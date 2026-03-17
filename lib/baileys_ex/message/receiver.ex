defmodule BaileysEx.Message.Receiver do
  @moduledoc """
  Message receive pipeline.
  """

  require Logger

  alias BaileysEx.BinaryNode
  alias BaileysEx.Connection.Store, as: ConnectionStore
  alias BaileysEx.Connection.EventEmitter
  alias BaileysEx.Message.Decode
  alias BaileysEx.Message.HistorySync
  alias BaileysEx.Message.Normalizer
  alias BaileysEx.Message.Receipt
  alias BaileysEx.Message.Retry
  alias BaileysEx.Message.Wire
  alias BaileysEx.Protocol.JID, as: JIDUtil
  alias BaileysEx.Protocol.Proto.Message
  alias BaileysEx.Protocol.Proto.VerifiedNameCertificate
  alias BaileysEx.Protocol.Proto.VerifiedNameCertificate.Details, as: VerifiedNameDetails
  alias BaileysEx.Protocol.Proto.WebMessageInfo
  alias BaileysEx.Signal.Store
  alias BaileysEx.Signal.Repository
  alias BaileysEx.Telemetry

  @type context :: %{
          required(:signal_repository) => Repository.t(),
          required(:event_emitter) => GenServer.server(),
          required(:me_id) => String.t(),
          optional(:me_lid) => String.t(),
          optional(:enable_recent_message_cache) => boolean(),
          optional(:store_ref) => ConnectionStore.Ref.t(),
          optional(:signal_store) => Store.t(),
          optional(:send_receipt_fun) => (BinaryNode.t() -> :ok | {:error, term()}),
          optional(:get_message_fun) => (map() -> map() | nil),
          optional(atom()) => term()
        }

  @doc """
  Decrypts, validates, normalizes, and emits incoming text/media messages.
  """
  @spec process_node(BinaryNode.t(), context(), keyword()) ::
          {:ok, map(), context()} | {:error, term()}
  def process_node(node, context, opts \\ [])

  def process_node(%BinaryNode{tag: "message"} = node, %{} = context, _opts) do
    with {:ok, envelope, context} <- Decode.decode_envelope(node, context),
         {:ok, encrypted_content} <- extract_encrypted_content(node),
         {:ok, decrypted_repo, plaintext} <-
           decrypt_content(context.signal_repository, envelope, encrypted_content),
         {:ok, context} <-
           maybe_persist_lid_mapping(envelope, %{context | signal_repository: decrypted_repo}),
         {:ok, proto_message} <- Wire.decode(plaintext),
         :ok <-
           maybe_cache_recent_message(
             context,
             envelope.remote_jid,
             node.attrs["id"],
             proto_message
           ),
         received_message <- build_received_message(node, envelope, proto_message),
         {:ok, received_message, message_side_effects} <-
           normalize_received_message(received_message, context),
         :ok <- emit_message_side_effects(message_side_effects, context.event_emitter),
         {:ok, context} <- emit_protocol_side_effects(received_message, context),
         :ok <-
           EventEmitter.emit(context.event_emitter, :messages_upsert, %{
             type: :notify,
             messages: [received_message]
           }),
         :ok <- emit_receive_telemetry(node, envelope),
         :ok <- send_receipt(node, envelope, context) do
      {:ok, received_message, context}
    end
  end

  def process_node(%BinaryNode{} = node, _context, _opts),
    do: {:error, {:unsupported_node, node.tag}}

  @doc """
  Converts remote error ACKs into message error events.
  """
  @spec handle_bad_ack(BinaryNode.t(), GenServer.server()) :: :ok
  def handle_bad_ack(
        %BinaryNode{tag: "ack", attrs: %{"class" => "message", "error" => error} = attrs},
        event_emitter
      )
      when is_binary(error) do
    EventEmitter.emit(event_emitter, :messages_update, [
      %{
        key: %{
          remote_jid: attrs["from"],
          from_me: true,
          id: attrs["id"],
          participant: attrs["participant"]
        },
        update: %{status: :ERROR, message_stub_parameters: [error]}
      }
    ])
  end

  def handle_bad_ack(%BinaryNode{}, _event_emitter), do: :ok

  defp extract_encrypted_content(%BinaryNode{content: content}) when is_list(content) do
    content
    |> Enum.find(fn
      %BinaryNode{tag: "enc", attrs: %{"type" => _type}, content: {:binary, _ciphertext}} ->
        true

      %BinaryNode{tag: "enc", attrs: %{"type" => _type}, content: ciphertext}
      when is_binary(ciphertext) ->
        true

      %BinaryNode{tag: "plaintext", content: {:binary, _payload}} ->
        true

      %BinaryNode{tag: "plaintext", content: payload} when is_binary(payload) ->
        true

      _ ->
        false
    end)
    |> case do
      %BinaryNode{tag: "enc", attrs: %{"type" => type}, content: {:binary, ciphertext}} ->
        {:ok, %{type: type, ciphertext: ciphertext}}

      %BinaryNode{tag: "enc", attrs: %{"type" => type}, content: ciphertext}
      when is_binary(ciphertext) ->
        {:ok, %{type: type, ciphertext: ciphertext}}

      %BinaryNode{tag: "plaintext", content: {:binary, payload}} ->
        {:ok, %{type: "plaintext", ciphertext: payload}}

      %BinaryNode{tag: "plaintext", content: payload} when is_binary(payload) ->
        {:ok, %{type: "plaintext", ciphertext: payload}}

      nil ->
        {:error, :missing_encrypted_content}
    end
  end

  defp extract_encrypted_content(%BinaryNode{}), do: {:error, :missing_encrypted_content}

  defp decrypt_content(%Repository{} = repo, _envelope, %{
         type: "plaintext",
         ciphertext: plaintext
       }) do
    {:ok, repo, plaintext}
  end

  defp decrypt_content(%Repository{} = repo, envelope, %{type: type, ciphertext: ciphertext})
       when type in ["pkmsg", "msg"] do
    Repository.decrypt_message(repo, %{
      jid: envelope.decryption_jid,
      type: direct_message_type(type),
      ciphertext: ciphertext
    })
  end

  defp decrypt_content(%Repository{} = repo, envelope, %{type: "skmsg", ciphertext: ciphertext}) do
    Repository.decrypt_group_message(repo, %{
      group: envelope.remote_jid,
      author_jid: envelope.author_jid,
      msg: ciphertext
    })
  end

  defp decrypt_content(%Repository{}, _envelope, %{type: type}),
    do: {:error, {:unsupported_message_type, type}}

  defp build_received_message(
         %BinaryNode{attrs: attrs} = node,
         envelope,
         %Message{} = proto_message
       ) do
    %{
      key:
        %{
          id: attrs["id"],
          remote_jid: envelope.remote_jid,
          remote_jid_alt: envelope[:remote_jid_alt],
          participant: envelope.participant,
          participant_alt: envelope[:participant_alt],
          from_me: envelope.from_me
        }
        |> maybe_put(:addressing_mode, envelope[:addressing_mode])
        |> maybe_put(:server_id, envelope[:server_id]),
      message: proto_message,
      message_timestamp: parse_timestamp(attrs["t"]),
      sender_jid: envelope.author_jid,
      participant: envelope.participant,
      verified_biz_name: verified_biz_name(node)
    }
  end

  defp send_receipt(%BinaryNode{attrs: attrs}, envelope, context) do
    case Map.get(context, :send_receipt_fun) do
      fun when is_function(fun, 1) ->
        Receipt.send_receipt(
          fun,
          envelope.remote_jid,
          envelope.participant,
          [attrs["id"]],
          :delivered
        )

      _other ->
        :ok
    end
  end

  defp maybe_persist_lid_mapping(
         %{author_jid: sender, decryption_jid: decryption_jid} = envelope,
         %{signal_repository: %Repository{} = repo} = context
       ) do
    sender_alt = envelope[:participant_alt] || envelope[:remote_jid_alt]

    if should_store_lid_mapping?(sender, sender_alt, decryption_jid) do
      with {:ok, repo} <- Repository.store_lid_pn_mappings(repo, [%{lid: sender_alt, pn: sender}]),
           {:ok, repo, _result} <- Repository.migrate_session(repo, sender, sender_alt) do
        {:ok, %{context | signal_repository: repo}}
      else
        error ->
          Logger.warning(
            "failed to persist LID mapping from message envelope " <>
              "sender=#{inspect(sender)} sender_alt=#{inspect(sender_alt)} " <>
              "decryption_jid=#{inspect(decryption_jid)} error=#{inspect(error)}"
          )

          {:ok, context}
      end
    else
      {:ok, context}
    end
  end

  defp emit_protocol_side_effects(
         %{key: key, message: %Message{} = message, message_timestamp: message_timestamp} =
           received_message,
         %{event_emitter: event_emitter} = context
       ) do
    case Map.get(message, :protocol_message) do
      %Message.ProtocolMessage{} = protocol_message ->
        emit_protocol_message_side_effect(
          protocol_message,
          key,
          received_message,
          message_timestamp,
          event_emitter,
          context
        )

      _other ->
        {:ok, context}
    end
  end

  defp emit_protocol_side_effects(_received_message, context), do: {:ok, context}

  defp normalize_received_message(received_message, context) do
    Normalizer.normalize(received_message,
      me_id: context.me_id,
      me_lid: context[:me_lid],
      signal_repository: context[:signal_repository],
      get_message_fun: context[:get_message_fun]
    )
  end

  defp emit_receive_telemetry(%BinaryNode{attrs: attrs}, envelope) do
    Telemetry.execute(
      [:message, :receive],
      %{count: 1},
      %{
        message_id: attrs["id"],
        remote_jid: envelope.remote_jid
      }
    )
  end

  defp emit_message_side_effects(side_effects, event_emitter) when is_list(side_effects) do
    Enum.reduce_while(side_effects, :ok, fn
      {:messages_reaction, data}, :ok ->
        :ok = EventEmitter.emit(event_emitter, :messages_reaction, data)
        {:cont, :ok}

      {:messages_update, data}, :ok ->
        :ok = EventEmitter.emit(event_emitter, :messages_update, data)
        {:cont, :ok}

      _other, :ok ->
        {:cont, :ok}
    end)
  end

  defp emit_protocol_message_side_effect(
         %Message.ProtocolMessage{type: :HISTORY_SYNC_NOTIFICATION} = protocol_message,
         key,
         received_message,
         message_timestamp,
         event_emitter,
         context
       ) do
    handle_history_sync_notification(
      protocol_message,
      key,
      received_message,
      message_timestamp,
      event_emitter,
      context
    )
  end

  defp emit_protocol_message_side_effect(
         %Message.ProtocolMessage{type: :APP_STATE_SYNC_KEY_SHARE} = protocol_message,
         _key,
         _received_message,
         _message_timestamp,
         _event_emitter,
         context
       ) do
    :ok = handle_app_state_sync_key_share(protocol_message, context)
    {:ok, context}
  end

  defp emit_protocol_message_side_effect(
         %Message.ProtocolMessage{type: :PEER_DATA_OPERATION_REQUEST_RESPONSE_MESSAGE} =
           protocol_message,
         _key,
         _received_message,
         _message_timestamp,
         event_emitter,
         context
       ) do
    handle_peer_data_operation_request_response(protocol_message, event_emitter, context)
  end

  defp emit_protocol_message_side_effect(
         %Message.ProtocolMessage{type: :REVOKE} = protocol_message,
         key,
         _received_message,
         _message_timestamp,
         event_emitter,
         context
       ) do
    :ok =
      EventEmitter.emit(event_emitter, :messages_update, [
        %{
          key: Map.put(key, :id, protocol_message.key && protocol_message.key.id),
          update: %{message: nil, message_stub_type: :REVOKE, key: key}
        }
      ])

    {:ok, context}
  end

  defp emit_protocol_message_side_effect(
         %Message.ProtocolMessage{type: :MESSAGE_EDIT} = protocol_message,
         key,
         _received_message,
         message_timestamp,
         event_emitter,
         context
       ) do
    :ok =
      EventEmitter.emit(event_emitter, :messages_update, [
        %{
          key: Map.put(key, :id, protocol_message.key && protocol_message.key.id),
          update: %{
            message: %{edited_message: %{message: protocol_message.edited_message}},
            message_timestamp:
              timestamp_ms_to_seconds(protocol_message.timestamp_ms) || message_timestamp
          }
        }
      ])

    {:ok, context}
  end

  defp emit_protocol_message_side_effect(
         %Message.ProtocolMessage{type: :EPHEMERAL_SETTING, ephemeral_expiration: expiration},
         _key,
         %{key: %{remote_jid: remote_jid}},
         message_timestamp,
         event_emitter,
         context
       ) do
    :ok =
      EventEmitter.emit(event_emitter, :chats_update, [
        %{
          id: remote_jid,
          ephemeral_setting_timestamp: message_timestamp,
          ephemeral_expiration: expiration
        }
      ])

    {:ok, context}
  end

  defp emit_protocol_message_side_effect(
         %Message.ProtocolMessage{type: :GROUP_MEMBER_LABEL_CHANGE} = protocol_message,
         _key,
         %{
           key: %{
             remote_jid: remote_jid,
             participant: participant,
             participant_alt: participant_alt
           }
         },
         message_timestamp,
         event_emitter,
         context
       ) do
    case protocol_message.member_label do
      %Message.MemberLabel{label: label} when is_binary(label) ->
        :ok =
          EventEmitter.emit(event_emitter, :group_member_tag_update, %{
            group_id: remote_jid,
            participant: participant,
            participant_alt: participant_alt,
            label: label,
            message_timestamp: message_timestamp
          })

        {:ok, context}

      _ ->
        {:ok, context}
    end
  end

  defp emit_protocol_message_side_effect(
         %Message.ProtocolMessage{type: :LID_MIGRATION_MAPPING_SYNC} = protocol_message,
         _key,
         _received_message,
         _message_timestamp,
         _event_emitter,
         context
       ) do
    handle_lid_migration_mapping_sync(protocol_message, context)
  end

  defp emit_protocol_message_side_effect(
         %Message.ProtocolMessage{},
         _key,
         _received_message,
         _message_timestamp,
         _event_emitter,
         context
       ),
       do: {:ok, context}

  defp handle_app_state_sync_key_share(
         %Message.ProtocolMessage{
           app_state_sync_key_share: %Message.AppStateSyncKeyShare{keys: keys}
         },
         %{event_emitter: event_emitter, signal_store: %Store{} = signal_store}
       ) do
    keys
    |> Enum.reduce(nil, fn key, latest_key_id ->
      case key do
        %Message.AppStateSyncKey{
          key_id: %Message.AppStateSyncKeyId{key_id: key_id},
          key_data: %Message.AppStateSyncKeyData{key_data: key_data}
        }
        when is_binary(key_id) and is_binary(key_data) ->
          encoded_key_id = Base.encode64(key_id)
          :ok = Store.set(signal_store, %{:"app-state-sync-key" => %{encoded_key_id => key_data}})
          encoded_key_id

        _other ->
          latest_key_id
      end
    end)
    |> case do
      nil ->
        :ok

      latest_key_id ->
        EventEmitter.emit(event_emitter, :creds_update, %{my_app_state_key_id: latest_key_id})
    end
  end

  defp handle_app_state_sync_key_share(_protocol_message, _context), do: :ok

  defp handle_history_sync_notification(
         %Message.ProtocolMessage{
           history_sync_notification: %Message.HistorySyncNotification{} = notification
         },
         key,
         received_message,
         message_timestamp,
         event_emitter,
         context
       ) do
    is_latest = history_sync_latest?(context)

    :ok =
      maybe_record_processed_history(event_emitter, context, notification, key, message_timestamp)

    payload =
      notification
      |> history_sync_payload(received_message, context)
      |> maybe_put(:is_latest, history_sync_latest_value(notification, is_latest))

    :ok = EventEmitter.emit(event_emitter, :messaging_history_set, payload)
    {:ok, context}
  end

  defp handle_history_sync_notification(
         _protocol_message,
         _key,
         _received_message,
         _message_timestamp,
         _event_emitter,
         context
       ),
       do: {:ok, context}

  defp handle_peer_data_operation_request_response(
         %Message.ProtocolMessage{
           peer_data_operation_request_response_message:
             %Message.PeerDataOperationRequestResponseMessage{
               stanza_id: stanza_id,
               peer_data_operation_result: results
             }
         },
         event_emitter,
         context
       ) do
    Enum.each(results, fn result ->
      case result do
        %Message.PeerDataOperationRequestResponseMessage.PeerDataOperationResult{
          placeholder_message_resend_response:
            %Message.PeerDataOperationRequestResponseMessage.PeerDataOperationResult.PlaceholderMessageResendResponse{
              web_message_info_bytes: bytes
            }
        }
        when is_binary(bytes) ->
          emit_placeholder_resend(bytes, stanza_id, event_emitter, context)

        _ ->
          :ok
      end
    end)

    {:ok, context}
  end

  defp handle_peer_data_operation_request_response(_protocol_message, _event_emitter, context),
    do: {:ok, context}

  defp emit_placeholder_resend(bytes, stanza_id, event_emitter, context) do
    case WebMessageInfo.decode(bytes) do
      {:ok, %WebMessageInfo{} = info} ->
        cached = placeholder_cached_message(context, info)
        maybe_resolve_placeholder_resend(context, info)

        cached
        |> build_placeholder_message(info)
        |> then(fn restored ->
          EventEmitter.emit(event_emitter, :messages_upsert, %{
            messages: [restored],
            type: :notify,
            request_id: stanza_id
          })
        end)

      _ ->
        :ok
    end
  end

  defp build_placeholder_message(cached, %WebMessageInfo{} = info) when is_map(cached) do
    cached
    |> Map.put(:message, info.message)
    |> maybe_put(:message_timestamp, info.message_timestamp)
    |> maybe_put(:participant, cached[:participant] || info.participant)
    |> maybe_put(:push_name, cached[:push_name] || info.push_name)
    |> maybe_put(:verified_biz_name, cached[:verified_biz_name] || info.verified_biz_name)
    |> Map.update(:key, web_message_key(info), &Map.merge(web_message_key(info), &1))
  end

  defp build_placeholder_message(_cached, %WebMessageInfo{} = info) do
    %{
      key: web_message_key(info),
      message: info.message,
      message_timestamp: info.message_timestamp,
      participant: info.participant,
      push_name: info.push_name,
      verified_biz_name: info.verified_biz_name
    }
  end

  defp web_message_key(%WebMessageInfo{key: %BaileysEx.Protocol.Proto.MessageKey{} = key}) do
    %{
      remote_jid: key.remote_jid,
      from_me: key.from_me,
      id: key.id,
      participant: key.participant
    }
  end

  defp web_message_key(%WebMessageInfo{}), do: %{}

  defp handle_lid_migration_mapping_sync(
         %Message.ProtocolMessage{
           lid_migration_mapping_sync_message: %Message.LIDMigrationMappingSyncMessage{
             encoded_mapping_payload: payload
           }
         },
         %{signal_repository: %Repository{} = repo} = context
       )
       when is_binary(payload) do
    case Message.LIDMigrationMappingSyncPayload.decode(payload) do
      {:ok, decoded_payload} ->
        pairs = decode_lid_mapping_pairs(decoded_payload)
        persist_lid_mapping_pairs(repo, pairs, context)

      _ ->
        {:ok, context}
    end
  end

  defp handle_lid_migration_mapping_sync(_protocol_message, context), do: {:ok, context}

  defp direct_message_type("pkmsg"), do: :pkmsg
  defp direct_message_type("msg"), do: :msg

  defp maybe_cache_recent_message(
         %{store_ref: %ConnectionStore.Ref{} = store_ref, enable_recent_message_cache: true},
         remote_jid,
         message_id,
         %Message{} = proto_message
       )
       when is_binary(remote_jid) and is_binary(message_id) do
    Retry.add_recent_message(store_ref, remote_jid, message_id, proto_message)
  end

  defp maybe_cache_recent_message(_context, _remote_jid, _message_id, _proto_message), do: :ok

  defp verified_biz_name(%BinaryNode{content: content}) when is_list(content) do
    case Enum.find(content, &match?(%BinaryNode{tag: "verified_name"}, &1)) do
      %BinaryNode{content: {:binary, certificate}} ->
        decode_verified_biz_name(certificate)

      %BinaryNode{content: certificate} when is_binary(certificate) ->
        decode_verified_biz_name(certificate)

      _ ->
        nil
    end
  end

  defp verified_biz_name(%BinaryNode{}), do: nil

  defp decode_verified_biz_name(certificate) when is_binary(certificate) do
    with {:ok, %VerifiedNameCertificate{details: details}} when is_binary(details) <-
           VerifiedNameCertificate.decode(certificate),
         {:ok, %VerifiedNameDetails{verified_name: verified_name}} <-
           VerifiedNameDetails.decode(details) do
      verified_name
    else
      _ -> nil
    end
  end

  defp history_sync_latest?(context) do
    case context[:store_ref] && ConnectionStore.get(context.store_ref, :creds, %{}) do
      %{processed_history_messages: []} -> true
      %{processed_history_messages: processed} when is_list(processed) -> processed == []
      _ -> true
    end
  end

  defp maybe_record_processed_history(
         _event_emitter,
         _context,
         %{sync_type: :ON_DEMAND},
         _key,
         _timestamp
       ),
       do: :ok

  defp maybe_record_processed_history(
         event_emitter,
         context,
         _notification,
         key,
         message_timestamp
       ) do
    processed_history_messages =
      case context[:store_ref] && ConnectionStore.get(context.store_ref, :creds, %{}) do
        %{processed_history_messages: processed} when is_list(processed) ->
          processed ++ [%{key: key, message_timestamp: message_timestamp}]

        _ ->
          [%{key: key, message_timestamp: message_timestamp}]
      end

    EventEmitter.emit(event_emitter, :creds_update, %{
      processed_history_messages: processed_history_messages
    })
  end

  defp history_sync_payload(notification, received_message, context) do
    history_sync_fun_payload(notification, received_message, context)
    |> Map.put_new(:chats, [])
    |> Map.put_new(:contacts, [])
    |> Map.put_new(:messages, [])
    |> Map.put_new(:progress, notification.progress)
    |> Map.put_new(:sync_type, notification.sync_type)
    |> Map.put_new(:peer_data_request_session_id, notification.peer_data_request_session_id)
  end

  defp history_sync_fun_payload(notification, received_message, context) do
    case context[:history_sync_fun] do
      fun when is_function(fun, 3) ->
        normalize_history_sync_payload(fun.(notification, received_message, context))

      _ ->
        case HistorySync.process_notification(notification, received_message, context) do
          {:ok, data} when is_map(data) -> data
          _ -> %{}
        end
    end
  end

  defp normalize_history_sync_payload({:ok, data}) when is_map(data), do: data
  defp normalize_history_sync_payload(data) when is_map(data), do: data
  defp normalize_history_sync_payload(_data), do: %{}

  defp history_sync_latest_value(%{sync_type: :ON_DEMAND}, _is_latest), do: nil
  defp history_sync_latest_value(_notification, is_latest), do: is_latest

  defp placeholder_cached_message(context, %WebMessageInfo{} = info) do
    case {context[:store_ref], info.key && info.key.id} do
      {%ConnectionStore.Ref{} = store_ref, message_id} when is_binary(message_id) ->
        Retry.get_placeholder_resend(store_ref, message_id)

      _ ->
        nil
    end
  end

  defp maybe_resolve_placeholder_resend(context, %WebMessageInfo{} = info) do
    if context[:store_ref] && info.key && is_binary(info.key.id) do
      Retry.resolve_placeholder_resend(context.store_ref, info.key.id)
    else
      :ok
    end
  end

  defp decode_lid_mapping_pairs(decoded_payload) do
    Enum.flat_map(decoded_payload.pn_to_lid_mappings, fn mapping ->
      lid = mapping.latest_lid || mapping.assigned_lid

      if is_integer(mapping.pn) and is_integer(lid) do
        [%{lid: "#{lid}@lid", pn: "#{mapping.pn}@s.whatsapp.net"}]
      else
        []
      end
    end)
  end

  defp persist_lid_mapping_pairs(repo, pairs, context) do
    case Repository.store_lid_pn_mappings(repo, pairs) do
      {:ok, repo} ->
        {:ok, %{context | signal_repository: migrate_lid_mapping_sessions(repo, pairs)}}

      _ ->
        {:ok, context}
    end
  end

  defp migrate_lid_mapping_sessions(repo, pairs) do
    Enum.reduce(pairs, repo, fn %{pn: pn, lid: lid}, acc ->
      case Repository.migrate_session(acc, pn, lid) do
        {:ok, migrated_repo, _result} -> migrated_repo
        _ -> acc
      end
    end)
  end

  defp should_store_lid_mapping?(sender, sender_alt, decryption_jid) do
    is_binary(sender_alt) and
      (JIDUtil.lid?(sender_alt) or JIDUtil.hosted_lid?(sender_alt)) and
      (JIDUtil.user?(sender) or JIDUtil.hosted_pn?(sender)) and
      JIDUtil.same_user?(decryption_jid, sender)
  end

  defp maybe_put(attrs, _key, nil), do: attrs
  defp maybe_put(attrs, key, value), do: Map.put(attrs, key, value)

  defp parse_timestamp(nil), do: nil

  defp parse_timestamp(value) do
    case Integer.parse(value) do
      {timestamp, ""} -> timestamp
      _ -> nil
    end
  end

  defp timestamp_ms_to_seconds(nil), do: nil
  defp timestamp_ms_to_seconds(value), do: div(value, 1_000)
end
