defmodule BaileysEx.Message.Normalizer do
  @moduledoc """
  Received-message normalization and content side effects aligned with Baileys rc.9.
  """

  alias BaileysEx.Crypto
  alias BaileysEx.Message.Parser
  alias BaileysEx.Protocol.JID, as: JIDUtil
  alias BaileysEx.Protocol.Proto.Message
  alias BaileysEx.Protocol.Proto.MessageContextInfo
  alias BaileysEx.Protocol.Proto.MessageKey
  alias BaileysEx.Signal.Repository

  @type side_effect ::
          {:messages_reaction, list()}
          | {:messages_update, list()}

  @spec normalize(map(), keyword()) :: {:ok, map(), [side_effect()]}
  def normalize(%{message: %Message{} = message} = received_message, opts) do
    normalized_key = normalize_outer_key(Map.get(received_message, :key, %{}))
    normalized_message = Parser.normalize_content(message)

    base_message =
      received_message
      |> Map.put(:key, normalized_key)
      |> maybe_put(:participant, normalized_key[:participant])
      |> maybe_put(:sender_jid, normalize_jid(received_message[:sender_jid]))
      |> Map.put(:message, normalize_embedded_content(normalized_message, normalized_key, opts))

    side_effects = content_side_effects(base_message, opts)
    {:ok, base_message, Enum.reject(side_effects, &is_nil/1)}
  end

  def normalize(received_message, _opts), do: {:ok, received_message, []}

  defp normalize_embedded_content(%Message{} = message, outer_key, opts) do
    cond do
      match?(%Message.ReactionMessage{}, message.reaction_message) ->
        %Message.ReactionMessage{} = reaction_message = message.reaction_message

        %Message{
          message
          | reaction_message: %Message.ReactionMessage{
              reaction_message
              | key: normalize_target_key(reaction_message.key, outer_key, opts)
            }
        }

      match?(%Message.PollUpdateMessage{}, message.poll_update_message) ->
        %Message.PollUpdateMessage{} = poll_update_message = message.poll_update_message

        normalized_key =
          normalize_target_key(poll_update_message.poll_creation_message_key, outer_key, opts)

        %Message{
          message
          | poll_update_message: %Message.PollUpdateMessage{
              poll_update_message
              | poll_creation_message_key: normalized_key
            }
        }

      true ->
        message
    end
  end

  defp content_side_effects(%{message: %Message{} = message} = received_message, opts) do
    [
      reaction_side_effect(received_message, message),
      poll_update_side_effect(received_message, message, opts),
      event_response_side_effect(received_message, message, opts)
    ]
  end

  defp reaction_side_effect(received_message, %Message{
         reaction_message: %Message.ReactionMessage{} = reaction_message
       }) do
    {:messages_reaction,
     [
       %{
         reaction: %{
           key: received_message.key,
           text: reaction_message.text,
           sender_timestamp_ms: reaction_message.sender_timestamp_ms
         },
         key: message_key_to_map(reaction_message.key)
       }
     ]}
  end

  defp reaction_side_effect(_received_message, _message), do: nil

  defp poll_update_side_effect(
         received_message,
         %Message{
           poll_update_message: %Message.PollUpdateMessage{} = poll_update_message
         },
         opts
       ) do
    with %MessageKey{} = source_key <- poll_update_message.poll_creation_message_key,
         %{message: %Message{} = source_message} <- fetch_message(source_key, opts),
         %MessageContextInfo{message_secret: secret} when is_binary(secret) <-
           source_message.message_context_info,
         {:ok, vote} <-
           decrypt_poll_vote(
             poll_update_message.vote,
             source_key,
             received_message.key,
             secret,
             opts
           ) do
      {:messages_update,
       [
         %{
           key: message_key_to_map(source_key),
           update: %{
             poll_updates: [
               %{
                 poll_update_message_key: message_key_to_map(source_key),
                 vote: vote,
                 sender_timestamp_ms: poll_update_message.sender_timestamp_ms
               }
             ]
           }
         }
       ]}
    else
      _ -> nil
    end
  end

  defp poll_update_side_effect(_received_message, _message, _opts), do: nil

  defp event_response_side_effect(
         received_message,
         %Message{
           enc_event_response_message:
             %Message.EncEventResponseMessage{} = enc_event_response_message
         },
         opts
       ) do
    with %MessageKey{} = source_key <- enc_event_response_message.event_creation_message_key,
         %{message: %Message{} = source_message} <- fetch_message(source_key, opts),
         %MessageContextInfo{message_secret: secret} when is_binary(secret) <-
           source_message.message_context_info,
         {:ok, response} <-
           decrypt_event_response(
             enc_event_response_message,
             source_key,
             received_message.key,
             secret,
             opts
           ) do
      {:messages_update,
       [
         %{
           key: message_key_to_map(source_key),
           update: %{
             event_responses: [
               %{
                 event_response_message_key: received_message.key,
                 sender_timestamp_ms: response.timestamp_ms,
                 response: response
               }
             ]
           }
         }
       ]}
    else
      _ -> nil
    end
  end

  defp event_response_side_effect(_received_message, _message, _opts), do: nil

  defp fetch_message(%MessageKey{} = key, opts) do
    case opts[:get_message_fun] do
      fun when is_function(fun, 1) -> fun.(message_key_to_map(key))
      _ -> nil
    end
  end

  defp decrypt_poll_vote(
         %Message.PollEncValue{enc_payload: payload, enc_iv: iv},
         source_key,
         message_key,
         secret,
         opts
       )
       when is_binary(payload) and is_binary(iv) do
    poll_creator_jid = key_author(source_key, opts)
    voter_jid = key_author(message_key, opts)
    sign = IO.iodata_to_binary([source_key.id, poll_creator_jid, voter_jid, "Poll Vote", <<1>>])
    key0 = Crypto.hmac_sha256(<<0::256>>, secret)
    dec_key = Crypto.hmac_sha256(key0, sign)
    aad = "#{source_key.id}\0#{voter_jid}"

    with {:ok, plaintext} <- Crypto.aes_gcm_decrypt(dec_key, iv, payload, aad),
         {:ok, %Message.PollVoteMessage{} = vote} <- Message.PollVoteMessage.decode(plaintext) do
      {:ok, vote}
    end
  end

  defp decrypt_poll_vote(_vote, _source_key, _message_key, _secret, _opts),
    do: {:error, :missing_poll_vote}

  defp decrypt_event_response(
         %Message.EncEventResponseMessage{enc_payload: payload, enc_iv: iv},
         source_key,
         message_key,
         secret,
         opts
       )
       when is_binary(payload) and is_binary(iv) do
    event_creator_jid = event_creator_jid(source_key, opts)
    responder_jid = key_author(message_key, opts)

    sign =
      IO.iodata_to_binary([
        source_key.id,
        event_creator_jid,
        responder_jid,
        "Event Response",
        <<1>>
      ])

    key0 = Crypto.hmac_sha256(<<0::256>>, secret)
    dec_key = Crypto.hmac_sha256(key0, sign)
    aad = "#{source_key.id}\0#{responder_jid}"

    with {:ok, plaintext} <- Crypto.aes_gcm_decrypt(dec_key, iv, payload, aad),
         {:ok, %Message.EventResponseMessage{} = response} <-
           Message.EventResponseMessage.decode(plaintext) do
      {:ok, response}
    end
  end

  defp decrypt_event_response(_message, _source_key, _message_key, _secret, _opts),
    do: {:error, :missing_event_response}

  defp event_creator_jid(%MessageKey{} = key, opts) do
    jid = key_author(key, opts)

    if is_binary(jid) and is_struct(opts[:signal_repository], Repository) and
         (JIDUtil.lid?(jid) or JIDUtil.hosted_lid?(jid)) do
      case Repository.get_pn_for_lid(opts[:signal_repository], jid) do
        {:ok, _repo, pn} when is_binary(pn) -> normalize_jid(pn)
        _ -> jid
      end
    else
      jid
    end
  end

  defp key_author(%MessageKey{} = key, opts) do
    if key.from_me do
      normalize_jid(opts[:me_id])
    else
      key.participant || key.remote_jid || ""
    end
  end

  defp key_author(key, opts) when is_map(key) do
    if key[:from_me] do
      normalize_jid(opts[:me_id])
    else
      key[:participant_alt] || key[:remote_jid_alt] || key[:participant] || key[:remote_jid] || ""
    end
  end

  defp normalize_target_key(%MessageKey{} = key, outer_key, opts) do
    target =
      %MessageKey{
        key
        | remote_jid: normalize_jid(key.remote_jid),
          participant: normalize_jid(key.participant)
      }

    if outer_key[:from_me] do
      target
    else
      author = target.participant || target.remote_jid

      %MessageKey{
        target
        | from_me: key_from_me?(target, author, opts),
          remote_jid: outer_key[:remote_jid],
          participant: target.participant || outer_key[:participant]
      }
    end
  end

  defp key_from_me?(%MessageKey{from_me: true}, _author, _opts), do: false

  defp key_from_me?(%MessageKey{}, author, opts) do
    JIDUtil.same_user?(author, opts[:me_id]) or
      (is_binary(opts[:me_lid]) and JIDUtil.same_user?(author, opts[:me_lid]))
  end

  defp normalize_outer_key(key) when is_map(key) do
    key
    |> Map.update(:remote_jid, nil, &normalize_jid/1)
    |> Map.update(:participant, nil, &normalize_jid/1)
    |> Map.update(:remote_jid_alt, nil, &normalize_jid/1)
    |> Map.update(:participant_alt, nil, &normalize_jid/1)
  end

  defp normalize_outer_key(key), do: key

  defp normalize_jid(nil), do: nil

  defp normalize_jid(jid) when is_binary(jid) do
    cond do
      JIDUtil.hosted_pn?(jid) ->
        jid |> JIDUtil.parse() |> then(&JIDUtil.jid_encode(&1.user, JIDUtil.s_whatsapp_net()))

      JIDUtil.hosted_lid?(jid) ->
        jid |> JIDUtil.parse() |> then(&JIDUtil.jid_encode(&1.user, JIDUtil.lid()))

      true ->
        case JIDUtil.normalized_user(jid) do
          "" -> jid
          normalized -> normalized
        end
    end
  end

  defp message_key_to_map(%MessageKey{} = key) do
    %{
      remote_jid: key.remote_jid,
      from_me: key.from_me,
      id: key.id,
      participant: key.participant
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
