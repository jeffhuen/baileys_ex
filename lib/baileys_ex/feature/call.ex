defmodule BaileysEx.Feature.Call do
  @moduledoc """
  Call helpers aligned with Baileys call handling in `messages-recv.ts` and
  `chats.ts`.
  """

  alias BaileysEx.BinaryNode
  alias BaileysEx.Connection.EventEmitter
  alias BaileysEx.Connection.Store
  import BaileysEx.Connection.TransportAdapter, only: [query: 3]
  alias BaileysEx.Protocol.BinaryNode, as: BinaryNodeUtil
  @timeout 60_000
  @terminal_statuses [:reject, :accept, :timeout, :terminate]

  @type call_status :: :offer | :ringing | :timeout | :reject | :accept | :terminate

  @type call_event :: %{
          required(:chat_id) => String.t() | nil,
          required(:from) => String.t() | nil,
          optional(:caller_pn) => String.t() | nil,
          required(:id) => String.t(),
          required(:date) => DateTime.t(),
          required(:offline) => boolean(),
          required(:status) => call_status(),
          optional(:is_video) => boolean(),
          optional(:is_group) => boolean(),
          optional(:group_jid) => String.t() | nil,
          optional(:latency_ms) => integer()
        }

  @doc """
  Parse and emit an inbound call node, cache offer metadata, and send the call
  ack when `opts[:send_node_fun]` is available.
  """
  @spec handle_node(BinaryNode.t(), keyword()) :: {:ok, call_event()} | {:error, term()}
  def handle_node(%BinaryNode{tag: "call", attrs: attrs} = node, opts \\ []) when is_list(opts) do
    case BinaryNodeUtil.children(node) do
      [%BinaryNode{} = info_child | _rest] ->
        status = call_status(info_child)

        call =
          %{
            chat_id: attrs["from"],
            from: info_child.attrs["from"] || info_child.attrs["call-creator"],
            caller_pn: info_child.attrs["caller_pn"],
            id: info_child.attrs["call-id"],
            date: unix_datetime(attrs["t"]),
            offline: not is_nil(attrs["offline"]),
            status: status
          }
          |> maybe_enrich_offer(info_child, status)
          |> merge_cached_offer(opts[:store_ref])

        maybe_store_offer(opts[:store_ref], call, status)
        maybe_emit_call(opts[:event_emitter], call)
        :ok = maybe_send_ack(opts[:send_node_fun], build_ack(node))

        {:ok, call}

      [] ->
        {:error, :missing_call_info}
    end
  end

  @doc """
  Reject an inbound call.
  """
  @spec reject_call(term(), String.t(), String.t(), keyword()) ::
          {:ok, BinaryNode.t()} | {:error, term()}
  def reject_call(queryable, call_id, caller_jid, opts \\ [])
      when is_binary(call_id) and is_binary(caller_jid) and is_list(opts) do
    me_id = current_me_id(opts)

    node = %BinaryNode{
      tag: "call",
      attrs: %{"from" => me_id, "to" => caller_jid},
      content: [
        %BinaryNode{
          tag: "reject",
          attrs: %{
            "call-id" => call_id,
            "call-creator" => caller_jid,
            "count" => "0"
          },
          content: nil
        }
      ]
    }

    query(queryable, node, Keyword.get(opts, :query_timeout, @timeout))
  end

  @doc """
  Create a call link for audio or video.
  """
  @spec create_call_link(term(), :audio | :video, keyword()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def create_call_link(queryable, type, opts \\ [])
      when type in [:audio, :video] and is_list(opts) do
    event =
      case opts[:event] do
        %{start_time: start_time} -> %{"start_time" => to_string(start_time)}
        %{"start_time" => start_time} -> %{"start_time" => to_string(start_time)}
        %{startTime: start_time} -> %{"start_time" => to_string(start_time)}
        %{"startTime" => start_time} -> %{"start_time" => to_string(start_time)}
        _ -> nil
      end

    attrs =
      %{"to" => "@call"}
      |> maybe_put("id", query_id(opts))

    node = %BinaryNode{
      tag: "call",
      attrs: attrs,
      content: [
        %BinaryNode{
          tag: "link_create",
          attrs: %{"media" => Atom.to_string(type)},
          content:
            if event do
              [%BinaryNode{tag: "event", attrs: event, content: nil}]
            end
        }
      ]
    }

    with {:ok, %BinaryNode{} = response} <-
           query(queryable, node, Keyword.get(opts, :timeout_ms, @timeout)) do
      {:ok, response |> BinaryNodeUtil.child("link_create") |> token_attr()}
    end
  end

  defp maybe_enrich_offer(call, info_child, :offer) do
    Map.merge(call, %{
      is_video: not is_nil(BinaryNodeUtil.child(info_child, "video")),
      is_group: info_child.attrs["type"] == "group" or not is_nil(info_child.attrs["group-jid"]),
      group_jid: info_child.attrs["group-jid"]
    })
  end

  defp maybe_enrich_offer(call, _info_child, _status), do: call

  defp merge_cached_offer(call, nil), do: call

  defp merge_cached_offer(%{id: id, caller_pn: caller_pn} = call, store_ref) when is_binary(id) do
    case cached_offer(store_ref, id) do
      %{is_video: is_video, is_group: is_group} = cached ->
        call
        |> maybe_put(:is_video, Map.get(call, :is_video, is_video))
        |> maybe_put(:is_group, Map.get(call, :is_group, is_group))
        |> maybe_put(:group_jid, Map.get(call, :group_jid, cached[:group_jid]))
        |> maybe_put(:caller_pn, caller_pn || cached[:caller_pn])

      _ ->
        call
    end
  end

  defp merge_cached_offer(call, _store_ref), do: call

  defp maybe_store_offer(nil, _call, _status), do: :ok

  defp maybe_store_offer(%Store.Ref{} = store_ref, %{id: id} = call, :offer) when is_binary(id) do
    offers = Store.get(store_ref, :call_offers, %{})
    :ok = Store.put(store_ref, :call_offers, Map.put(offers, id, call))
  end

  defp maybe_store_offer(%Store.Ref{} = store_ref, %{id: id}, status)
       when status in @terminal_statuses and is_binary(id) do
    offers = Store.get(store_ref, :call_offers, %{})
    :ok = Store.put(store_ref, :call_offers, Map.delete(offers, id))
  end

  defp maybe_store_offer(_store_ref, _call, _status), do: :ok

  defp maybe_emit_call(nil, _call), do: :ok

  defp maybe_emit_call(event_emitter, call) do
    EventEmitter.emit(event_emitter, :call, [call])
  end

  defp maybe_send_ack(nil, _ack), do: :ok
  defp maybe_send_ack(fun, ack) when is_function(fun, 1), do: fun.(ack)

  defp build_ack(%BinaryNode{tag: tag, attrs: attrs}) do
    %BinaryNode{
      tag: "ack",
      attrs:
        %{"id" => attrs["id"], "to" => attrs["from"], "class" => tag}
        |> maybe_put("participant", attrs["participant"])
        |> maybe_put("recipient", attrs["recipient"])
        |> maybe_put("type", attrs["type"]),
      content: nil
    }
  end

  defp cached_offer(%Store.Ref{} = store_ref, id) do
    store_ref
    |> Store.get(:call_offers, %{})
    |> Map.get(id)
  end

  defp call_status(%BinaryNode{tag: tag, attrs: attrs}) do
    case tag do
      "offer" -> :offer
      "offer_notice" -> :offer
      "terminate" -> if(attrs["reason"] == "timeout", do: :timeout, else: :terminate)
      "reject" -> :reject
      "accept" -> :accept
      _ -> :ringing
    end
  end

  defp unix_datetime(nil), do: DateTime.from_unix!(0)

  defp unix_datetime(value) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, ""} -> DateTime.from_unix!(seconds)
      _ -> DateTime.from_unix!(0)
    end
  end

  defp token_attr(%BinaryNode{attrs: attrs}), do: attrs["token"]
  defp token_attr(nil), do: nil

  defp current_me_id(opts) do
    case opts[:me] || store_me(opts[:store]) do
      %{id: id} when is_binary(id) -> id
      %{"id" => id} when is_binary(id) -> id
      _ -> raise ArgumentError, "missing current user id for call rejection"
    end
  end

  defp store_me(nil), do: nil
  defp store_me(%Store.Ref{} = store), do: Store.get(store, :creds, %{})[:me]

  defp store_me(store) do
    store
    |> Store.wrap()
    |> Store.get(:creds, %{})
    |> Map.get(:me)
  rescue
    ArgumentError -> nil
  end

  defp query_id(opts) do
    case opts[:query_id] || opts[:id] do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
