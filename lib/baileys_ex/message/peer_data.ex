defmodule BaileysEx.Message.PeerData do
  @moduledoc """
  Peer data operation transport for phone-only protocol messages.
  """

  alias BaileysEx.Message.Sender
  alias BaileysEx.Protocol.JID, as: JIDUtil
  alias BaileysEx.Protocol.Proto.Message
  alias BaileysEx.Protocol.Proto.MessageKey

  @peer_attrs %{"category" => "peer", "push_priority" => "high_force"}
  @peer_meta [%BaileysEx.BinaryNode{tag: "meta", attrs: %{"appdata" => "default"}, content: nil}]

  @type context :: Sender.context()
  @type peer_request :: struct()
  @type message_key_like :: map()

  @doc """
  Transmits a constructed peer data operation request node.
  """
  @spec send_request(context(), peer_request(), keyword()) ::
          {:ok, String.t(), context()} | {:error, term()}
  def send_request(
        %{} = context,
        %Message.PeerDataOperationRequestMessage{} = request,
        opts \\ []
      ) do
    message = %Message{
      protocol_message: %Message.ProtocolMessage{
        type: :PEER_DATA_OPERATION_REQUEST_MESSAGE,
        peer_data_operation_request_message: request
      }
    }

    with {:ok, me_jid} <- normalized_self_jid(context),
         {:ok, %{id: request_id}, updated_context} <-
           Sender.send_proto(
             context,
             me_jid,
             message,
             Keyword.merge(opts,
               additional_attributes: @peer_attrs,
               additional_nodes: @peer_meta
             )
           ) do
      {:ok, request_id, updated_context}
    end
  end

  @doc """
  Requests an on-demand history sync payload from an existing session.
  """
  @spec fetch_message_history(context(), pos_integer(), message_key_like(), integer(), keyword()) ::
          {:ok, String.t(), context()} | {:error, term()}
  def fetch_message_history(
        %{} = context,
        count,
        oldest_msg_key,
        oldest_msg_timestamp,
        opts \\ []
      )
      when is_integer(count) and count > 0 and is_integer(oldest_msg_timestamp) do
    request = %Message.PeerDataOperationRequestMessage{
      peer_data_operation_request_type: :HISTORY_SYNC_ON_DEMAND,
      history_sync_on_demand_request:
        %Message.PeerDataOperationRequestMessage.HistorySyncOnDemandRequest{
          chat_jid: message_key_value(oldest_msg_key, :remote_jid),
          oldest_msg_id: message_key_value(oldest_msg_key, :id),
          oldest_msg_from_me: message_key_value(oldest_msg_key, :from_me),
          on_demand_msg_count: count,
          oldest_msg_timestamp_ms: oldest_msg_timestamp,
          account_lid: context[:me_lid]
        }
    }

    send_request(context, request, opts)
  end

  @doc """
  Constructs a peer request to resolve missing e2e placeholders.
  """
  @spec placeholder_resend_request(message_key_like()) :: peer_request()
  def placeholder_resend_request(message_key) do
    %Message.PeerDataOperationRequestMessage{
      peer_data_operation_request_type: :PLACEHOLDER_MESSAGE_RESEND,
      placeholder_message_resend_request: [
        %Message.PeerDataOperationRequestMessage.PlaceholderMessageResendRequest{
          message_key: normalize_message_key(message_key)
        }
      ]
    }
  end

  defp normalized_self_jid(%{me_id: me_id}) when is_binary(me_id) do
    case JIDUtil.parse(JIDUtil.normalized_user(me_id)) do
      %BaileysEx.JID{} = jid -> {:ok, jid}
      _ -> {:error, :invalid_me_id}
    end
  end

  defp normalized_self_jid(_context), do: {:error, :invalid_me_id}

  defp normalize_message_key(%MessageKey{} = key), do: key

  defp normalize_message_key(%{} = key) do
    %MessageKey{
      remote_jid: message_key_value(key, :remote_jid),
      from_me: message_key_value(key, :from_me),
      id: message_key_value(key, :id),
      participant: message_key_value(key, :participant)
    }
  end

  defp message_key_value(%MessageKey{} = key, field), do: Map.get(key, field)
  defp message_key_value(%{} = key, field), do: Map.get(key, field)
end
