defmodule BaileysEx.Message.Retry do
  @moduledoc """
  Retry-state helpers modeled after Baileys' message retry manager.
  """

  alias BaileysEx.BinaryNode
  alias BaileysEx.Connection.Store
  alias BaileysEx.Message.PeerData
  alias BaileysEx.Protocol.BinaryNode, as: BinaryNodeUtil
  alias BaileysEx.Protocol.Proto.Message

  @recent_cache_key :message_retry_recent_cache
  @recent_order_key :message_retry_recent_order
  @retry_counter_key :message_retry_counters
  @session_history_key :message_retry_session_recreate_history
  @phone_requests_key :message_retry_phone_requests
  @placeholder_cache_key :message_retry_placeholder_resends

  @recent_message_cache_size 512
  @recent_message_cache_ttl_ms 300_000
  @session_recreate_cooldown_ms 3_600_000
  @phone_request_delay_ms 3_000
  @placeholder_request_timeout_ms 8_000
  @max_retry_count 5

  @retry_reason_values %{
    UNKNOWN_ERROR: 0,
    SIGNAL_ERROR_NO_SESSION: 1,
    SIGNAL_ERROR_INVALID_KEY: 2,
    SIGNAL_ERROR_INVALID_KEY_ID: 3,
    SIGNAL_ERROR_INVALID_MESSAGE: 4,
    SIGNAL_ERROR_INVALID_SIGNATURE: 5,
    SIGNAL_ERROR_FUTURE_MESSAGE: 6,
    SIGNAL_ERROR_BAD_MAC: 7,
    SIGNAL_ERROR_INVALID_SESSION: 8,
    SIGNAL_ERROR_INVALID_MSG_KEY: 9,
    BAD_BROADCAST_EPHEMERAL_SETTING: 10,
    UNKNOWN_COMPANION_NO_PREKEY: 11,
    ADV_FAILURE: 12,
    STATUS_REVOKE_DELAY: 13
  }

  @mac_error_codes MapSet.new([
                     Map.fetch!(@retry_reason_values, :SIGNAL_ERROR_INVALID_MESSAGE),
                     Map.fetch!(@retry_reason_values, :SIGNAL_ERROR_BAD_MAC)
                   ])

  @type proto_message :: struct()
  @type recent_message_entry :: %{message: proto_message(), timestamp: integer()}

  @doc """
  Determines if a recipient's Signal session must be recreated based on an error code.
  """
  @spec should_recreate_session(
          Store.Ref.t(),
          String.t(),
          boolean(),
          atom() | integer() | nil,
          keyword()
        ) ::
          %{reason: String.t(), recreate: boolean()}
  def should_recreate_session(
        %Store.Ref{} = store_ref,
        jid,
        has_session,
        error_code \\ nil,
        opts \\ []
      )
      when is_binary(jid) and is_boolean(has_session) do
    now_ms = now_ms(opts)
    error_code = normalize_retry_reason(error_code)

    cond do
      not has_session ->
        put_session_recreate_time(store_ref, jid, now_ms)
        %{reason: "we don't have a Signal session with them", recreate: true}

      mac_error?(error_code) ->
        put_session_recreate_time(store_ref, jid, now_ms)
        %{reason: "MAC error detected, immediate session recreation", recreate: true}

      recreate_cooldown_elapsed?(store_ref, jid, now_ms) ->
        put_session_recreate_time(store_ref, jid, now_ms)
        %{reason: "retry count > 1 and cooldown elapsed", recreate: true}

      true ->
        %{reason: "", recreate: false}
    end
  end

  @doc """
  Caches recently sent plaintext messages allowing retry requests to resend them.
  """
  @spec add_recent_message(Store.Ref.t(), String.t(), String.t(), proto_message(), keyword()) ::
          :ok
  def add_recent_message(%Store.Ref{} = store_ref, to, id, %Message{} = message, opts \\ [])
      when is_binary(to) and is_binary(id) do
    ttl_ms = Keyword.get(opts, :ttl_ms, @recent_message_cache_ttl_ms)
    max_size = Keyword.get(opts, :max_size, @recent_message_cache_size)
    now_ms = now_ms(opts)
    key = {to, id}

    cache =
      Store.get(store_ref, @recent_cache_key, %{})
      |> prune_recent_cache(now_ms, ttl_ms)
      |> Map.put(key, %{message: message, timestamp: now_ms})

    order =
      Store.get(store_ref, @recent_order_key, [])
      |> Enum.reject(&(&1 == key))
      |> Kernel.++([key])
      |> prune_recent_order(cache)

    {cache, order} = enforce_recent_cache_limit(cache, order, max_size)

    :ok = Store.put(store_ref, @recent_cache_key, cache)
    :ok = Store.put(store_ref, @recent_order_key, order)
  end

  @doc """
  Retrieves a cached sent message for a remote peer and message ID.
  """
  @spec get_recent_message(Store.Ref.t(), String.t(), String.t(), keyword()) ::
          recent_message_entry() | nil
  def get_recent_message(%Store.Ref{} = store_ref, to, id, opts \\ [])
      when is_binary(to) and is_binary(id) do
    ttl_ms = Keyword.get(opts, :ttl_ms, @recent_message_cache_ttl_ms)
    now_ms = now_ms(opts)
    key = {to, id}
    cache = Store.get(store_ref, @recent_cache_key, %{}) |> prune_recent_cache(now_ms, ttl_ms)
    order = Store.get(store_ref, @recent_order_key, []) |> prune_recent_order(cache)
    :ok = Store.put(store_ref, @recent_cache_key, cache)
    :ok = Store.put(store_ref, @recent_order_key, order)
    Map.get(cache, key)
  end

  @doc """
  Schedules an asynchronous fallback request for a retry sequence.
  """
  @spec schedule_phone_request(Store.Ref.t(), String.t(), (-> term()), keyword()) :: :ok
  def schedule_phone_request(%Store.Ref{} = store_ref, message_id, callback, opts \\ [])
      when is_binary(message_id) and is_function(callback, 0) do
    delay_ms = Keyword.get(opts, :delay_ms, @phone_request_delay_ms)
    cancel_phone_request(store_ref, message_id)

    {:ok, timer_ref} =
      :timer.apply_after(delay_ms, __MODULE__, :run_phone_request, [
        store_ref,
        message_id,
        callback
      ])

    pending = Store.get(store_ref, @phone_requests_key, %{}) |> Map.put(message_id, timer_ref)
    Store.put(store_ref, @phone_requests_key, pending)
  end

  @doc """
  Executes a scheduled fallback phone request, immediately invoking the callback.
  """
  @spec run_phone_request(Store.Ref.t(), String.t(), (-> term())) :: :ok
  def run_phone_request(%Store.Ref{} = store_ref, message_id, callback)
      when is_binary(message_id) and is_function(callback, 0) do
    pending = Store.get(store_ref, @phone_requests_key, %{}) |> Map.delete(message_id)
    :ok = Store.put(store_ref, @phone_requests_key, pending)
    callback.()
    :ok
  end

  @doc """
  Cancels a previously scheduled fallback request.
  """
  @spec cancel_phone_request(Store.Ref.t(), String.t()) :: :ok
  def cancel_phone_request(%Store.Ref{} = store_ref, message_id) when is_binary(message_id) do
    pending = Store.get(store_ref, @phone_requests_key, %{})

    case Map.pop(pending, message_id) do
      {nil, rest} ->
        Store.put(store_ref, @phone_requests_key, rest)

      {timer_ref, rest} ->
        :timer.cancel(timer_ref)
        Store.put(store_ref, @phone_requests_key, rest)
    end
  end

  @doc """
  Idempotently queues a placeholder resend command, stalling slightly to await in-flight messages.
  """
  @spec request_placeholder_resend(Store.Ref.t(), map(), map() | boolean() | nil, keyword()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def request_placeholder_resend(
        %Store.Ref{} = store_ref,
        message_key,
        msg_data \\ nil,
        opts \\ []
      )
      when is_map(message_key) do
    message_id = Map.fetch!(message_key, :id)
    delay_ms = Keyword.get(opts, :delay_ms, 2_000)
    timeout_ms = Keyword.get(opts, :timeout_ms, @placeholder_request_timeout_ms)

    if get_placeholder_resend(store_ref, message_id) do
      {:ok, nil}
    else
      :ok = put_placeholder_resend(store_ref, message_id, msg_data || true, opts)
      Process.sleep(delay_ms)

      if get_placeholder_resend(store_ref, message_id) do
        issue_placeholder_resend_request(store_ref, message_key, message_id, timeout_ms, opts)
      else
        {:ok, "RESOLVED"}
      end
    end
  end

  @doc """
  Records an active placeholder awaiting server response.
  """
  @spec put_placeholder_resend(Store.Ref.t(), String.t(), map() | boolean(), keyword()) :: :ok
  def put_placeholder_resend(%Store.Ref{} = store_ref, message_id, data, opts \\ [])
      when is_binary(message_id) and is_list(opts) do
    cache =
      Store.get(store_ref, @placeholder_cache_key, %{})
      |> Map.put(message_id, %{
        data: data,
        timer_ref: nil,
        inserted_at: now_ms(opts)
      })

    Store.put(store_ref, @placeholder_cache_key, cache)
  end

  @doc """
  Looks up a placeholder that actively blocking resolution of a message.
  """
  @spec get_placeholder_resend(Store.Ref.t(), String.t()) :: map() | boolean() | nil
  def get_placeholder_resend(%Store.Ref{} = store_ref, message_id) when is_binary(message_id) do
    case Store.get(store_ref, @placeholder_cache_key, %{}) do
      %{^message_id => %{data: data}} -> data
      _ -> nil
    end
  end

  @doc """
  Clears a resolved placeholder from state.
  """
  @spec resolve_placeholder_resend(Store.Ref.t(), String.t()) :: :ok
  def resolve_placeholder_resend(%Store.Ref{} = store_ref, message_id)
      when is_binary(message_id) do
    pop_placeholder(store_ref, message_id)
    :ok
  end

  @doc """
  Clears an expired placeholder timeout.
  """
  @spec expire_placeholder_resend(Store.Ref.t(), String.t()) :: :ok
  def expire_placeholder_resend(%Store.Ref{} = store_ref, message_id)
      when is_binary(message_id) do
    pop_placeholder(store_ref, message_id)
    :ok
  end

  @doc """
  Parses an incoming retry receipt and retrieves cached messages for re-encryption.
  """
  @spec handle_retry_receipt(Store.Ref.t(), BinaryNode.t(), keyword()) ::
          {:ok, [proto_message()]} | {:error, term()}
  def handle_retry_receipt(
        %Store.Ref{} = store_ref,
        %BinaryNode{tag: "receipt", attrs: attrs} = node,
        opts \\ []
      ) do
    retry_count = parse_retry_count(node)
    max_retry_count = Keyword.get(opts, :max_retry_count, @max_retry_count)

    if retry_count >= max_retry_count do
      {:error, :max_retries_exceeded}
    else
      ids = [attrs["id"] | parse_list_ids(node)]
      remote_jid = attrs["from"] || attrs["recipient"] || attrs["to"]
      resend_fun = opts[:resend_fun]

      messages =
        ids
        |> Enum.map(&get_recent_message(store_ref, remote_jid, &1))
        |> Enum.reject(&is_nil/1)
        |> Enum.map(& &1.message)

      maybe_resend_messages(messages, resend_fun, remote_jid, ids)

      {:ok, messages}
    end
  end

  @doc """
  Constructs and formats a protocol retry receipt to request a sender re-encrypt a failed message.
  """
  @spec send_retry_request(Store.Ref.t(), BinaryNode.t(), keyword()) ::
          {:ok, BinaryNode.t()} | {:error, term()}
  def send_retry_request(%Store.Ref{} = store_ref, %BinaryNode{attrs: attrs} = node, opts \\ []) do
    message_id = attrs["id"]
    retry_count = increment_retry_count(store_ref, message_id)
    max_retry_count = Keyword.get(opts, :max_retry_count, @max_retry_count)

    if retry_count >= max_retry_count do
      {:error, :max_retries_exceeded}
    else
      force_include_keys = Keyword.get(opts, :force_include_keys, false) || retry_count > 1

      receipt =
        %BinaryNode{
          tag: "receipt",
          attrs:
            %{
              "id" => message_id,
              "type" => "retry",
              "to" => attrs["from"]
            }
            |> maybe_put_attr("recipient", attrs["recipient"])
            |> maybe_put_attr("participant", attrs["participant"]),
          content:
            [
              %BinaryNode{
                tag: "retry",
                attrs: %{
                  "count" => Integer.to_string(retry_count),
                  "id" => message_id,
                  "t" => attrs["t"] || Integer.to_string(now_seconds(opts)),
                  "v" => "1",
                  "error" => Integer.to_string(Keyword.get(opts, :error_code, 0))
                },
                content: nil
              }
            ]
            |> maybe_append_registration(opts[:registration_id])
            |> maybe_append_keys(force_include_keys, opts[:keys_node])
        }

      with :ok <- emit_retry_receipt(receipt, opts) do
        maybe_schedule_placeholder_resend(store_ref, attrs, node, retry_count, opts)
        {:ok, receipt}
      end
    end
  end

  @doc """
  Parses stringified error codes from WhatsApp XML nodes.
  """
  @spec parse_retry_error_code(String.t() | nil) :: atom() | nil
  def parse_retry_error_code(nil), do: nil
  def parse_retry_error_code(""), do: nil

  def parse_retry_error_code(value) when is_binary(value) do
    case Integer.parse(value) do
      {code, ""} -> retry_reason_for_code(code)
      _ -> nil
    end
  end

  @doc """
  Indicates whether the parsed retry code suggests a fatal MAC/Signature error.
  """
  @spec mac_error?(atom() | integer() | nil) :: boolean()
  def mac_error?(reason) do
    reason
    |> normalize_retry_reason()
    |> then(&MapSet.member?(@mac_error_codes, &1))
  end

  @doc """
  Bumps the volatile retry tally for a specific message tracking iteration count.
  """
  @spec increment_retry_count(Store.Ref.t(), String.t()) :: pos_integer()
  def increment_retry_count(%Store.Ref{} = store_ref, message_id) when is_binary(message_id) do
    counters = Store.get(store_ref, @retry_counter_key, %{})
    count = Map.get(counters, message_id, 0) + 1
    :ok = Store.put(store_ref, @retry_counter_key, Map.put(counters, message_id, count))
    count
  end

  @doc """
  Yields the current retry iteration count.
  """
  @spec get_retry_count(Store.Ref.t(), String.t()) :: non_neg_integer()
  def get_retry_count(%Store.Ref{} = store_ref, message_id) when is_binary(message_id) do
    Store.get(store_ref, @retry_counter_key, %{}) |> Map.get(message_id, 0)
  end

  @doc """
  Checks if a message retry sequence has violated the configured limit loop.
  """
  @spec has_exceeded_max_retries?(Store.Ref.t(), String.t(), pos_integer()) :: boolean()
  def has_exceeded_max_retries?(
        %Store.Ref{} = store_ref,
        message_id,
        max_retry_count \\ @max_retry_count
      )
      when is_binary(message_id) and is_integer(max_retry_count) and max_retry_count > 0 do
    get_retry_count(store_ref, message_id) >= max_retry_count
  end

  defp put_session_recreate_time(%Store.Ref{} = store_ref, jid, timestamp) do
    history = Store.get(store_ref, @session_history_key, %{}) |> Map.put(jid, timestamp)
    Store.put(store_ref, @session_history_key, history)
  end

  defp issue_placeholder_resend_request(store_ref, message_key, message_id, timeout_ms, opts) do
    case send_placeholder_resend_request(message_key, opts[:send_request_fun]) do
      {:ok, request_id} ->
        {:ok, cleanup_ref} =
          :timer.apply_after(timeout_ms, __MODULE__, :expire_placeholder_resend, [
            store_ref,
            message_id
          ])

        update_placeholder_timer(store_ref, message_id, cleanup_ref)
        {:ok, request_id}

      {:error, _reason} = error ->
        error
    end
  end

  defp send_placeholder_resend_request(message_key, fun) when is_function(fun, 1) do
    fun.(PeerData.placeholder_resend_request(message_key))
  end

  defp send_placeholder_resend_request(_message_key, _fun),
    do: {:error, :send_request_fun_not_configured}

  defp maybe_resend_messages(messages, resend_fun, remote_jid, ids)
       when is_function(resend_fun, 2) do
    Enum.each(messages, fn message ->
      resend_fun.(message, %{remote_jid: remote_jid, ids: ids})
    end)
  end

  defp maybe_resend_messages(_messages, _resend_fun, _remote_jid, _ids), do: :ok

  defp recreate_cooldown_elapsed?(%Store.Ref{} = store_ref, jid, now_ms) do
    history = Store.get(store_ref, @session_history_key, %{})

    case Map.get(history, jid) do
      nil -> true
      previous -> now_ms - previous > @session_recreate_cooldown_ms
    end
  end

  defp update_placeholder_timer(%Store.Ref{} = store_ref, message_id, timer_ref) do
    cache =
      update_in(Store.get(store_ref, @placeholder_cache_key, %{}), [message_id], fn
        nil -> nil
        entry -> %{entry | timer_ref: timer_ref}
      end)

    Store.put(store_ref, @placeholder_cache_key, cache)
  end

  defp pop_placeholder(%Store.Ref{} = store_ref, message_id) do
    cache = Store.get(store_ref, @placeholder_cache_key, %{})

    case Map.pop(cache, message_id) do
      {nil, rest} ->
        Store.put(store_ref, @placeholder_cache_key, rest)

      {%{timer_ref: timer_ref}, rest} ->
        if timer_ref, do: :timer.cancel(timer_ref)
        Store.put(store_ref, @placeholder_cache_key, rest)
    end
  end

  defp normalize_retry_reason(reason) when is_atom(reason),
    do: Map.get(@retry_reason_values, reason, nil)

  defp normalize_retry_reason(reason) when is_integer(reason), do: reason
  defp normalize_retry_reason(_reason), do: nil

  defp retry_reason_for_code(code) do
    Enum.find_value(@retry_reason_values, fn
      {reason, ^code} -> reason
      _other -> nil
    end)
  end

  defp parse_retry_count(%BinaryNode{} = node) do
    case BinaryNodeUtil.child(node, "retry") do
      %BinaryNode{attrs: %{"count" => count}} ->
        case Integer.parse(count) do
          {parsed, ""} -> parsed
          _ -> 1
        end

      _ ->
        1
    end
  end

  defp parse_list_ids(%BinaryNode{content: [%BinaryNode{tag: "list", content: items} | _rest]})
       when is_list(items) do
    Enum.flat_map(items, fn
      %BinaryNode{tag: "item", attrs: %{"id" => id}} when is_binary(id) -> [id]
      _ -> []
    end)
  end

  defp parse_list_ids(%BinaryNode{}), do: []

  defp enforce_recent_cache_limit(cache, order, max_size) do
    if map_size(cache) > max_size do
      {drop, keep} = Enum.split(order, map_size(cache) - max_size)
      {Map.drop(cache, drop), keep}
    else
      {cache, order}
    end
  end

  defp prune_recent_cache(cache, now_ms, ttl_ms) do
    Enum.reduce(cache, %{}, fn {key, %{timestamp: timestamp} = value}, acc ->
      if now_ms - timestamp <= ttl_ms do
        Map.put(acc, key, value)
      else
        acc
      end
    end)
  end

  defp prune_recent_order(order, cache) do
    Enum.filter(order, &Map.has_key?(cache, &1))
  end

  defp now_ms(opts) do
    case opts[:now_ms] do
      fun when is_function(fun, 0) -> fun.()
      nil -> System.monotonic_time(:millisecond)
    end
  end

  defp now_seconds(opts) do
    case opts[:now_ms] do
      fun when is_function(fun, 0) -> div(fun.(), 1_000)
      value when is_integer(value) -> div(value, 1_000)
      _ -> System.os_time(:second)
    end
  end

  defp emit_retry_receipt(receipt, opts) do
    case opts[:send_node_fun] do
      fun when is_function(fun, 1) -> fun.(receipt)
      _ -> :ok
    end
  end

  defp maybe_schedule_placeholder_resend(store_ref, attrs, node, retry_count, opts)
       when retry_count <= 2 do
    case opts[:request_placeholder_resend_fun] do
      fun when is_function(fun, 2) ->
        message_key = %{
          remote_jid: attrs["from"],
          from_me: false,
          id: attrs["id"],
          participant: attrs["participant"]
        }

        msg_data = Keyword.get(opts, :message_data, %{key: message_key, raw_node: node})

        schedule_phone_request(
          store_ref,
          attrs["id"],
          fn ->
            fun.(message_key, msg_data)
          end,
          delay_ms: Keyword.get(opts, :phone_request_delay_ms, @phone_request_delay_ms)
        )

      _ ->
        :ok
    end
  end

  defp maybe_schedule_placeholder_resend(_store_ref, _attrs, _node, _retry_count, _opts), do: :ok

  defp maybe_append_registration(content, registration_id)
       when is_integer(registration_id) and registration_id >= 0 do
    content ++
      [
        %BinaryNode{
          tag: "registration",
          attrs: %{},
          content: <<registration_id::unsigned-big-32>>
        }
      ]
  end

  defp maybe_append_registration(content, _registration_id), do: content

  defp maybe_append_keys(content, true, %BinaryNode{} = keys_node), do: content ++ [keys_node]
  defp maybe_append_keys(content, _force_include_keys, _keys_node), do: content

  defp maybe_put_attr(attrs, _key, nil), do: attrs
  defp maybe_put_attr(attrs, key, value), do: Map.put(attrs, key, value)
end
