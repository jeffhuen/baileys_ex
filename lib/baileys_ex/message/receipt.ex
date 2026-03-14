defmodule BaileysEx.Message.Receipt do
  @moduledoc """
  Receipt node construction and receipt-event parsing.
  """

  alias BaileysEx.BinaryNode
  alias BaileysEx.Connection.EventEmitter
  alias BaileysEx.Protocol.JID, as: JIDUtil

  @type receipt_type :: :delivered | :read | :read_self | :played | :sender | :retry | :hist_sync

  @receipt_status %{
    nil => :delivery_ack,
    "played" => :played,
    "read" => :read,
    "read-self" => :read,
    "sender" => :server_ack
  }

  @spec build_receipt_node(String.t(), String.t() | nil, [String.t()], receipt_type(), keyword()) ::
          BinaryNode.t()
  def build_receipt_node(jid, participant, [first_id | rest], type, opts \\ [])
      when is_binary(jid) and is_binary(first_id) and is_list(opts) do
    type_string = receipt_type_to_string(type)
    attrs = %{"id" => first_id}
    attrs = maybe_put_receipt_timestamp(attrs, type_string, opts)

    attrs =
      if type_string == "sender" and direct_jid?(jid) do
        attrs
        |> Map.put("recipient", jid)
        |> Map.put("to", participant)
      else
        attrs
        |> Map.put("to", jid)
        |> maybe_put("participant", participant)
      end

    attrs =
      case type_string do
        nil -> attrs
        value -> Map.put(attrs, "type", value)
      end

    %BinaryNode{
      tag: "receipt",
      attrs: attrs,
      content: build_list_content(rest)
    }
  end

  @spec send_receipt(
          (BinaryNode.t() -> :ok | {:error, term()}),
          String.t(),
          String.t() | nil,
          [String.t()],
          receipt_type(),
          keyword()
        ) ::
          :ok | {:error, term()}
  def send_receipt(sender, jid, participant, ids, type, opts \\ [])
      when is_function(sender, 1) and is_list(opts) do
    sender.(build_receipt_node(jid, participant, ids, type, opts))
  end

  @spec read_messages((BinaryNode.t() -> :ok | {:error, term()}), [map()], map(), keyword()) ::
          :ok | {:error, term()}
  def read_messages(sender, keys, privacy_settings, opts \\ [])
      when is_function(sender, 1) and is_list(keys) and is_map(privacy_settings) and is_list(opts) do
    read_type = if Map.get(privacy_settings, :readreceipts) == "all", do: :read, else: :read_self

    keys
    |> Enum.reject(&Map.get(&1, :from_me, false))
    |> aggregate_keys()
    |> Enum.reduce_while(:ok, fn %{jid: jid, participant: participant, ids: ids}, _acc ->
      case send_receipt(sender, jid, participant, ids, read_type, opts) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec process_receipt(BinaryNode.t(), GenServer.server()) :: :ok
  def process_receipt(%BinaryNode{tag: "receipt", attrs: attrs} = node, event_emitter) do
    remote_jid = attrs["from"]
    participant = attrs["participant"]
    ids = [attrs["id"] | parse_list_ids(node)]
    timestamp = parse_timestamp(attrs["t"])

    if JIDUtil.group?(remote_jid) or JIDUtil.status_broadcast?(remote_jid) do
      receipt_key = receipt_update_key(attrs["type"])

      EventEmitter.emit(
        event_emitter,
        :message_receipt_update,
        Enum.map(ids, fn id ->
          %{
            key: %{remote_jid: remote_jid, id: id, from_me: true, participant: participant},
            receipt:
              %{user_jid: participant}
              |> maybe_put(receipt_key, timestamp)
          }
        end)
      )
    else
      EventEmitter.emit(
        event_emitter,
        :messages_update,
        Enum.map(ids, fn id ->
          %{
            key: %{remote_jid: remote_jid, id: id, from_me: true, participant: participant},
            update: %{
              status: Map.get(@receipt_status, attrs["type"], :delivery_ack),
              message_timestamp: timestamp
            }
          }
        end)
      )
    end
  end

  defp aggregate_keys(keys) do
    keys
    |> Enum.reduce(%{}, fn key, acc ->
      group_key = {key.remote_jid, Map.get(key, :participant)}

      Map.update(
        acc,
        group_key,
        %{jid: key.remote_jid, participant: Map.get(key, :participant), ids: [key.id]},
        fn existing -> %{existing | ids: existing.ids ++ [key.id]} end
      )
    end)
    |> Map.values()
  end

  defp build_list_content([]), do: nil

  defp build_list_content(ids) do
    [
      %BinaryNode{
        tag: "list",
        attrs: %{},
        content: Enum.map(ids, &%BinaryNode{tag: "item", attrs: %{"id" => &1}, content: nil})
      }
    ]
  end

  defp parse_list_ids(%BinaryNode{content: [%BinaryNode{tag: "list", content: items} | _rest]})
       when is_list(items) do
    Enum.flat_map(items, fn
      %BinaryNode{tag: "item", attrs: %{"id" => id}} when is_binary(id) -> [id]
      _other -> []
    end)
  end

  defp parse_list_ids(%BinaryNode{}), do: []

  defp receipt_type_to_string(:delivered), do: nil
  defp receipt_type_to_string(:read_self), do: "read-self"
  defp receipt_type_to_string(type), do: Atom.to_string(type)

  defp maybe_put_receipt_timestamp(attrs, type, opts)
       when type in ["read", "read-self", "played"] do
    timestamp =
      case opts[:timestamp] do
        fun when is_function(fun, 0) -> fun.()
        value when is_integer(value) -> value
        _ -> System.os_time(:second)
      end

    Map.put(attrs, "t", Integer.to_string(timestamp))
  end

  defp maybe_put_receipt_timestamp(attrs, _type, _opts), do: attrs

  defp receipt_update_key("read"), do: :read_timestamp
  defp receipt_update_key("played"), do: :played_timestamp
  defp receipt_update_key(_type), do: :receipt_timestamp

  defp parse_timestamp(nil), do: nil

  defp parse_timestamp(value) do
    case Integer.parse(value) do
      {timestamp, ""} -> timestamp
      _other -> nil
    end
  end

  defp direct_jid?(jid),
    do:
      JIDUtil.user?(jid) or JIDUtil.lid?(jid) or JIDUtil.hosted_pn?(jid) or
        JIDUtil.hosted_lid?(jid)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
