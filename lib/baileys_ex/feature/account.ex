defmodule BaileysEx.Feature.Account do
  @moduledoc """
  Account standing and quota helpers aligned with Baileys `socket.ts`.
  """

  alias BaileysEx.BinaryNode
  alias BaileysEx.Connection.EventEmitter
  import BaileysEx.Connection.TransportAdapter, only: [query: 3]
  alias BaileysEx.Protocol.WMex

  @reachout_timelock_query_id "23983697327930364"
  @message_capping_info_query_id "24503548349331633"
  @timeout 60_000

  @doc """
  Fetch account reachout timelock state via WMex.

  Mirrors Baileys `fetchAccountReachoutTimelock`. When `:event_emitter` is supplied,
  the normalized result is also emitted as a `connection_update`.
  """
  @spec fetch_account_reachout_timelock(term(), keyword()) :: {:ok, map()} | {:error, term()}
  def fetch_account_reachout_timelock(queryable, opts \\ []) when is_list(opts) do
    with {:ok, result} <-
           execute_wmex_query(
             queryable,
             %{},
             @reachout_timelock_query_id,
             "xwa2_fetch_account_reachout_timelock",
             opts
           ) do
      state = normalize_reachout_timelock(result)
      emit_connection_update(opts[:event_emitter], state)
      {:ok, state}
    end
  end

  @doc """
  Fetch new-chat message cap information via WMex.
  """
  @spec fetch_new_chat_message_cap(term(), keyword()) :: {:ok, map()} | {:error, term()}
  def fetch_new_chat_message_cap(queryable, opts \\ []) when is_list(opts) do
    execute_wmex_query(
      queryable,
      %{"input" => %{"type" => "INDIVIDUAL_NEW_CHAT_MSG"}},
      @message_capping_info_query_id,
      "xwa2_message_capping_info",
      opts
    )
  end

  defp execute_wmex_query(conn, variables, query_id, data_path, opts) do
    with {:ok, %BinaryNode{} = response} <-
           query(
             conn,
             WMex.build_query(query_id, variables, message_tag(opts)),
             Keyword.get(opts, :query_timeout, @timeout)
           ) do
      WMex.extract_result(response, data_path)
    end
  end

  defp normalize_reachout_timelock(result) when is_map(result) do
    %{
      is_active: !!result["is_active"],
      enforcement_type: result["enforcement_type"] || "DEFAULT"
    }
    |> maybe_put(:time_enforcement_ends, parse_enforcement_end(result["time_enforcement_ends"]))
  end

  defp normalize_reachout_timelock(_result), do: %{is_active: false, enforcement_type: "DEFAULT"}

  defp parse_enforcement_end(nil), do: nil
  defp parse_enforcement_end("0"), do: nil
  defp parse_enforcement_end(0), do: nil

  defp parse_enforcement_end(value) when is_integer(value) do
    case DateTime.from_unix(value) do
      {:ok, datetime} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp parse_enforcement_end(value) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, ""} -> parse_enforcement_end(seconds)
      _ -> nil
    end
  end

  defp parse_enforcement_end(_value), do: nil

  defp emit_connection_update(nil, _state), do: :ok

  defp emit_connection_update(emitter, state) do
    EventEmitter.emit(emitter, :connection_update, %{reachout_time_lock: state})
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp message_tag(opts) do
    case opts[:message_tag_fun] do
      fun when is_function(fun, 0) -> fun.()
      _ -> Integer.to_string(System.unique_integer([:positive, :monotonic]))
    end
  end
end
