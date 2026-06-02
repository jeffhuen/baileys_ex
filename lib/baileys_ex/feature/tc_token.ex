defmodule BaileysEx.Feature.TcToken do
  @moduledoc """
  Trusted-contact token helpers aligned with Baileys' privacy-token flow.
  """

  alias BaileysEx.BinaryNode
  import BaileysEx.Connection.TransportAdapter, only: [query: 3]
  alias BaileysEx.Protocol.BinaryNode, as: BinaryNodeUtil
  alias BaileysEx.Protocol.JID
  alias BaileysEx.Signal.LIDMappingStore
  alias BaileysEx.Signal.Store

  @s_whatsapp_net "s.whatsapp.net"
  @timeout 60_000
  @tc_token_bucket_duration 604_800
  @tc_token_num_buckets 4
  @bot_phone_regex ~r/^1313555\d{4}$|^131655500\d{2}$/

  @doc """
  Append a stored TC token node to the provided content list.

  Mirrors Baileys `buildTcTokenFromJid`: if no token exists, returns the
  existing content when present or `nil` when it is empty.
  """
  @spec build_content(Store.t() | nil, String.t(), [BinaryNode.t()], keyword()) ::
          [BinaryNode.t()] | nil
  def build_content(store, jid, base_content \\ [], opts \\ [])

  def build_content(%Store{} = store, jid, base_content, opts)
      when is_binary(jid) and is_list(base_content) do
    case build_node(store, jid, opts) do
      %BinaryNode{} = node -> base_content ++ [node]
      nil when base_content == [] -> nil
      nil -> base_content
    end
  end

  def build_content(_store, _jid, [], _opts), do: nil

  def build_content(_store, _jid, base_content, _opts) when is_list(base_content),
    do: base_content

  @doc "Build a `tctoken` child node for a JID when a stored token exists."
  @spec build_node(Store.t() | nil, String.t(), keyword()) :: BinaryNode.t() | nil
  def build_node(store, jid, opts \\ [])

  def build_node(%Store{} = store, jid, opts) when is_binary(jid) do
    case safe_get_token(store, jid, opts) do
      {:ok, token} -> %BinaryNode{tag: "tctoken", attrs: %{}, content: {:binary, token}}
      :error -> nil
    end
  end

  def build_node(_store, _jid, _opts), do: nil

  @doc """
  Fetch trusted-contact privacy tokens for the given JIDs.
  """
  @spec get_privacy_tokens(term(), [String.t()], keyword()) ::
          {:ok, BinaryNode.t()} | {:error, term()}
  def get_privacy_tokens(queryable, jids, opts \\ []) when is_list(jids) do
    timestamp = Integer.to_string(timestamp(opts))

    node = %BinaryNode{
      tag: "iq",
      attrs: %{"to" => @s_whatsapp_net, "type" => "set", "xmlns" => "privacy"},
      content: [
        %BinaryNode{
          tag: "tokens",
          attrs: %{},
          content: Enum.map(jids, &privacy_token_request_node(&1, timestamp))
        }
      ]
    }

    query(queryable, node, Keyword.get(opts, :query_timeout, @timeout))
  end

  @doc """
  Store trusted-contact tokens returned by a privacy-token IQ result.
  """
  @spec store_from_iq_result(BinaryNode.t(), String.t() | nil, keyword()) :: :ok
  def store_from_iq_result(%BinaryNode{} = result, fallback_jid, opts \\ []) do
    result
    |> BinaryNodeUtil.child("tokens")
    |> BinaryNodeUtil.children("token")
    |> Enum.each(fn token_node ->
      store_token(token_node, fallback_jid || token_node.attrs["jid"], opts)
    end)

    :ok
  end

  @doc """
  Re-issue trusted-contact tokens after a peer identity changes.
  """
  @spec reissue_after_identity_change(term(), Store.t() | nil, String.t(), keyword()) ::
          :ok | {:error, term()}
  def reissue_after_identity_change(queryable, store, jid, opts \\ [])

  def reissue_after_identity_change(queryable, %Store{} = store, jid, opts)
      when is_binary(jid) and is_list(opts) do
    storage_jid = storage_jid(store, jid)

    with entry when is_map(entry) <- existing_entry(store, storage_jid),
         {:ok, sender_timestamp} <- sender_timestamp(entry),
         false <- expired?(sender_timestamp, opts),
         issue_jid <- issuance_jid(store, jid, storage_jid, opts),
         {:ok, %BinaryNode{} = result} <-
           get_privacy_tokens(
             queryable,
             [issue_jid],
             Keyword.put(opts, :timestamp_fun, fn -> sender_timestamp end)
           ) do
      store_from_iq_result(result, storage_jid, Keyword.put(opts, :signal_store, store))
    else
      {:error, reason} -> {:error, reason}
      _skip -> :ok
    end
  end

  def reissue_after_identity_change(_queryable, _store, _jid, _opts), do: :ok

  @doc """
  Issue a fresh trusted-contact token after an eligible outgoing 1:1 message.
  """
  @spec issue_after_outgoing_message(term(), Store.t() | nil, String.t(), keyword()) ::
          :ok | {:error, term()}
  def issue_after_outgoing_message(queryable, store, jid, opts \\ [])

  def issue_after_outgoing_message(queryable, %Store{} = store, jid, opts)
      when is_binary(jid) and is_list(opts) do
    storage_jid = storage_jid(store, jid)
    entry = existing_entry(store, storage_jid) || %{}
    issue_timestamp = timestamp(opts)

    with true <- regular_user?(jid),
         true <- should_send_new_tc_token?(map_value(entry, :sender_timestamp), opts),
         issue_jid <- issuance_jid(store, jid, storage_jid, opts),
         {:ok, %BinaryNode{} = result} <-
           get_privacy_tokens(
             queryable,
             [issue_jid],
             Keyword.put(opts, :timestamp_fun, fn -> issue_timestamp end)
           ),
         :ok <- store_from_iq_result(result, storage_jid, Keyword.put(opts, :signal_store, store)) do
      store_sender_timestamp(store, storage_jid, issue_timestamp)
    else
      {:error, reason} -> {:error, reason}
      _skip -> :ok
    end
  end

  def issue_after_outgoing_message(_queryable, _store, _jid, _opts), do: :ok

  @doc """
  Returns true for user JIDs that can participate in trusted-contact token flows.
  """
  @spec regular_user?(String.t() | nil) :: boolean()
  def regular_user?(jid) when is_binary(jid) do
    case JID.parse(jid) do
      %BaileysEx.JID{user: user, server: server}
      when is_binary(user) and user != "0" and
             server in ["s.whatsapp.net", "c.us", "lid", "hosted", "hosted.lid"] ->
        not Regex.match?(@bot_phone_regex, user)

      _ ->
        false
    end
  end

  def regular_user?(_jid), do: false

  @doc """
  Handle a `privacy_token` notification by persisting trusted-contact tokens.
  """
  @spec handle_notification(BinaryNode.t(), keyword()) :: :ok
  def handle_notification(node, opts \\ [])

  def handle_notification(
        %BinaryNode{tag: "notification", attrs: %{"type" => "privacy_token", "from" => from}} =
          node,
        opts
      ) do
    jid = normalized_jid(from)

    node
    |> BinaryNodeUtil.child("tokens")
    |> BinaryNodeUtil.children("token")
    |> Enum.each(&store_token(&1, jid, opts))

    :ok
  end

  def handle_notification(%BinaryNode{}, _opts), do: :ok

  defp privacy_token_request_node(jid, timestamp) do
    %BinaryNode{
      tag: "token",
      attrs: %{
        "jid" => normalized_jid(jid),
        "t" => timestamp,
        "type" => "trusted_contact"
      },
      content: nil
    }
  end

  defp store_token(
         %BinaryNode{
           tag: "token",
           attrs: %{"type" => "trusted_contact", "t" => timestamp},
           content: content
         },
         jid,
         opts
       ) do
    case binary_content(content) do
      nil ->
        :ok

      token ->
        maybe_store_token(jid, token, timestamp, opts)
    end
  end

  defp store_token(_token_node, _jid, _opts), do: :ok

  defp maybe_store_token(jid, token, timestamp, opts) do
    with {:ok, incoming_timestamp} <- parse_positive_timestamp(timestamp),
         true <- regular_user?(jid) do
      signal_store = opts[:signal_store]
      storage_jid = storage_jid(signal_store, jid)

      if stale_incoming_token?(signal_store, storage_jid, incoming_timestamp) do
        :ok
      else
        maybe_store_in_signal_store(signal_store, storage_jid, token, timestamp)
        maybe_store_with_callback(storage_jid, token, timestamp, opts)
      end
    else
      _ -> :ok
    end
  end

  defp maybe_store_with_callback(jid, token, timestamp, opts) do
    case opts[:store_privacy_token_fun] do
      fun when is_function(fun, 3) ->
        _ = fun.(jid, token, timestamp)
        :ok

      _ ->
        :ok
    end
  end

  defp maybe_store_in_signal_store(%Store{} = signal_store, jid, token, timestamp) do
    existing = existing_entry(signal_store, jid) || %{}

    Store.set(signal_store, %{
      tctoken: %{jid => existing |> Map.merge(%{token: token, timestamp: timestamp})}
    })
  end

  defp maybe_store_in_signal_store(_signal_store, _jid, _token, _timestamp), do: :ok

  defp stale_incoming_token?(%Store{} = store, jid, incoming_timestamp) do
    case existing_entry(store, jid) do
      nil ->
        false

      entry ->
        case parse_timestamp(map_value(entry, :timestamp)) do
          {:ok, existing_timestamp} when existing_timestamp > incoming_timestamp -> true
          _ -> false
        end
    end
  end

  defp stale_incoming_token?(_store, _jid, _incoming_timestamp), do: false

  defp store_sender_timestamp(%Store{} = store, jid, sender_timestamp) do
    current_entry = existing_entry(store, jid) || %{}
    token = map_value(current_entry, :token) || ""

    updated =
      %{token: token, sender_timestamp: sender_timestamp}
      |> maybe_put_timestamp(map_value(current_entry, :timestamp))

    Store.set(store, %{tctoken: %{jid => updated}})
  end

  defp maybe_put_timestamp(entry, nil), do: entry
  defp maybe_put_timestamp(entry, timestamp), do: Map.put(entry, :timestamp, timestamp)

  defp existing_entry(%Store{} = store, jid) do
    case Store.get(store, :tctoken, [jid]) do
      %{^jid => entry} when is_map(entry) -> entry
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  catch
    :exit, _reason -> nil
  end

  defp binary_content({:binary, token}) when is_binary(token), do: token
  defp binary_content(token) when is_binary(token), do: token
  defp binary_content(_content), do: nil

  defp safe_get_token(%Store{} = store, jid, opts) do
    jid = storage_jid(store, jid)
    direct_get_token(store, jid, opts)
  end

  defp direct_get_token(%Store{} = store, jid, opts) do
    case Store.get(store, :tctoken, [jid]) do
      %{^jid => entry} when is_map(entry) ->
        usable_token_entry(store, jid, entry, opts)

      _ ->
        :error
    end
  rescue
    ArgumentError -> :error
  catch
    :exit, _reason -> :error
  end

  defp usable_token_entry(store, jid, entry, opts) do
    token = map_value(entry, :token)

    cond do
      not (is_binary(token) and byte_size(token) > 0) ->
        :error

      expired?(map_value(entry, :timestamp), opts) ->
        clear_expired_token(store, jid, entry)
        :error

      true ->
        {:ok, token}
    end
  end

  defp clear_expired_token(%Store{} = store, jid, entry) do
    sender_timestamp = map_value(entry, :sender_timestamp)

    replacement =
      if is_nil(sender_timestamp) do
        nil
      else
        %{token: "", sender_timestamp: sender_timestamp}
      end

    Store.set(store, %{tctoken: %{jid => replacement}})
  end

  defp storage_jid(%Store{} = store, jid) do
    normalized = normalized_jid(jid)

    cond do
      JID.lid?(normalized) or JID.hosted_lid?(normalized) ->
        normalized

      true ->
        case LIDMappingStore.get_lid_for_pn(store, normalized) do
          {:ok, lid} when is_binary(lid) -> lid
          _ -> normalized
        end
    end
  rescue
    ArgumentError -> normalized_jid(jid)
  catch
    :exit, _reason -> normalized_jid(jid)
  end

  defp storage_jid(_store, jid), do: normalized_jid(jid)

  defp issuance_jid(%Store{} = store, jid, storage_jid, opts) do
    normalized = normalized_jid(jid)

    cond do
      Keyword.get(opts, :issue_to_lid?, false) ->
        storage_jid

      JID.lid?(normalized) or JID.hosted_lid?(normalized) ->
        case LIDMappingStore.get_pn_for_lid(store, normalized) do
          {:ok, pn} when is_binary(pn) -> pn
          _ -> normalized
        end

      true ->
        normalized
    end
  end

  defp expired?(timestamp, opts) do
    case parse_timestamp(timestamp) do
      {:ok, timestamp} ->
        now = Keyword.get_lazy(opts, :now, fn -> System.os_time(:second) end)
        current_bucket = div(now, @tc_token_bucket_duration)
        cutoff_bucket = current_bucket - (@tc_token_num_buckets - 1)
        cutoff_timestamp = cutoff_bucket * @tc_token_bucket_duration
        timestamp < cutoff_timestamp

      :error ->
        true
    end
  end

  defp should_send_new_tc_token?(sender_timestamp, opts) do
    case parse_timestamp(sender_timestamp) do
      {:ok, sender_timestamp} ->
        now = Keyword.get_lazy(opts, :now, fn -> System.os_time(:second) end)
        div(now, @tc_token_bucket_duration) > div(sender_timestamp, @tc_token_bucket_duration)

      :error ->
        true
    end
  end

  defp parse_positive_timestamp(value) do
    case parse_timestamp(value) do
      {:ok, timestamp} when timestamp > 0 -> {:ok, timestamp}
      _ -> :error
    end
  end

  defp sender_timestamp(entry) when is_map(entry) do
    case parse_timestamp(map_value(entry, :sender_timestamp)) do
      {:ok, timestamp} when timestamp > 0 -> {:ok, timestamp}
      _ -> :error
    end
  end

  defp parse_timestamp(value) when is_integer(value), do: {:ok, value}

  defp parse_timestamp(value) when is_binary(value) do
    case Integer.parse(value) do
      {timestamp, ""} -> {:ok, timestamp}
      _ -> :error
    end
  end

  defp parse_timestamp(_value), do: :error

  defp map_value(map, key) when is_map(map) do
    Map.get(map, key) ||
      Map.get(map, Atom.to_string(key)) ||
      Map.get(map, camelize_key(key))
  end

  defp camelize_key(:sender_timestamp), do: "senderTimestamp"
  defp camelize_key(key), do: Atom.to_string(key)

  defp normalized_jid(jid) do
    case JID.normalized_user(jid) do
      "" -> jid
      normalized -> normalized
    end
  end

  defp timestamp(opts) do
    case opts[:timestamp_fun] do
      fun when is_function(fun, 0) -> fun.()
      value when is_integer(value) -> value
      _ -> System.os_time(:second)
    end
  end
end
