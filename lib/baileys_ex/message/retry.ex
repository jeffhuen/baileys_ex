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
  @base_keys_key :message_retry_base_keys

  @recent_message_cache_size 512
  @recent_message_cache_ttl_ms 300_000
  @base_key_cache_size 1024
  @base_key_cache_ttl_ms 900_000
  @retry_counter_ttl_ms 900_000
  @session_recreate_cooldown_ms 3_600_000
  @session_history_ttl_ms 7_200_000
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

  @mac_error_codes Map.new(
                     [
                       Map.fetch!(@retry_reason_values, :SIGNAL_ERROR_INVALID_MESSAGE),
                       Map.fetch!(@retry_reason_values, :SIGNAL_ERROR_BAD_MAC)
                     ],
                     &{&1, true}
                   )

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

    history =
      store_ref
      |> Store.get(@session_history_key, %{})
      |> prune_timestamp_cache(now_ms, @session_history_ttl_ms)

    :ok = Store.put(store_ref, @session_history_key, history)

    cond do
      not has_session ->
        put_session_recreate_time(store_ref, history, jid, now_ms)
        %{reason: "we don't have a Signal session with them", recreate: true}

      mac_error?(error_code) ->
        put_session_recreate_time(store_ref, history, jid, now_ms)

        %{
          reason:
            "MAC error (code #{error_code}: #{retry_reason_name(error_code)}), immediate session recreation",
          recreate: true
        }

      recreate_cooldown_elapsed?(history, jid, now_ms) ->
        put_session_recreate_time(store_ref, history, jid, now_ms)
        %{reason: "retry count > 1 and over an hour since last recreation", recreate: true}

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
  Saves the open Signal base key observed during the rc10 retry collision check.
  """
  @spec save_base_key(Store.Ref.t(), String.t(), String.t(), binary(), keyword()) :: :ok
  def save_base_key(%Store.Ref{} = store_ref, addr, msg_id, base_key, opts \\ [])
      when is_binary(addr) and is_binary(msg_id) and is_binary(base_key) do
    now_ms = now_ms(opts)
    ttl_ms = Keyword.get(opts, :ttl_ms, @base_key_cache_ttl_ms)
    max_size = Keyword.get(opts, :max_size, @base_key_cache_size)

    cache =
      Store.get(store_ref, @base_keys_key, %{})
      |> prune_base_key_cache(now_ms, ttl_ms)
      |> Map.put({addr, msg_id}, %{base_key: base_key, timestamp: now_ms})
      |> enforce_base_key_cache_limit(max_size)

    Store.put(store_ref, @base_keys_key, cache)
  end

  @doc """
  Returns true when the cached base key exactly matches the current base key.
  """
  @spec has_same_base_key?(Store.Ref.t(), String.t(), String.t(), binary(), keyword()) ::
          boolean()
  def has_same_base_key?(%Store.Ref{} = store_ref, addr, msg_id, base_key, opts \\ [])
      when is_binary(addr) and is_binary(msg_id) and is_binary(base_key) do
    now_ms = now_ms(opts)
    ttl_ms = Keyword.get(opts, :ttl_ms, @base_key_cache_ttl_ms)

    cache =
      Store.get(store_ref, @base_keys_key, %{})
      |> prune_base_key_cache(now_ms, ttl_ms)

    :ok = Store.put(store_ref, @base_keys_key, cache)

    case Map.get(cache, {addr, msg_id}) do
      %{base_key: ^base_key} -> true
      _ -> false
    end
  end

  @doc """
  Deletes a cached retry base key once the collision check has completed.
  """
  @spec delete_base_key(Store.Ref.t(), String.t(), String.t()) :: :ok
  def delete_base_key(%Store.Ref{} = store_ref, addr, msg_id)
      when is_binary(addr) and is_binary(msg_id) do
    cache = Store.get(store_ref, @base_keys_key, %{}) |> Map.delete({addr, msg_id})
    Store.put(store_ref, @base_keys_key, cache)
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
      schedule_after(
        delay_ms,
        __MODULE__,
        :run_phone_request,
        [store_ref, message_id, callback],
        opts
      )

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
  rescue
    ArgumentError -> :ok
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
        cancel_scheduled(timer_ref)
        Store.put(store_ref, @phone_requests_key, rest)
    end
  end

  @doc """
  Marks a retry as successful and releases all per-message retry state.
  """
  @spec mark_retry_success(Store.Ref.t(), String.t()) :: :ok
  def mark_retry_success(%Store.Ref{} = store_ref, message_id) when is_binary(message_id) do
    clear_message_retry(store_ref, message_id)
  end

  @doc """
  Marks a retry as failed and releases all per-message retry state.
  """
  @spec mark_retry_failed(Store.Ref.t(), String.t()) :: :ok
  def mark_retry_failed(%Store.Ref{} = store_ref, message_id) when is_binary(message_id) do
    clear_message_retry(store_ref, message_id)
  end

  @doc """
  Clears all retry-manager caches and cancels pending phone requests.
  """
  @spec clear(Store.Ref.t()) :: :ok
  def clear(%Store.Ref{} = store_ref) do
    store_ref
    |> Store.get(@phone_requests_key, %{})
    |> Map.values()
    |> Enum.each(&cancel_scheduled/1)

    Enum.each(
      [
        @recent_cache_key,
        @retry_counter_key,
        @session_history_key,
        @phone_requests_key,
        @base_keys_key
      ],
      &Store.put(store_ref, &1, %{})
    )

    Store.put(store_ref, @recent_order_key, [])
  end

  @doc """
  Idempotently queues a placeholder resend command, stalling slightly to await in-flight messages.
  """
  @spec request_placeholder_resend(Store.Ref.t(), map(), map() | nil, keyword()) ::
          {:ok, String.t() | nil, term()} | {:error, term()}
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
    context = Keyword.get(opts, :context)
    sleep_fun = Keyword.get(opts, :sleep_fun, &Process.sleep/1)

    if match?({:ok, _metadata}, fetch_placeholder_resend(store_ref, message_id)) do
      {:ok, nil, context}
    else
      :ok = put_placeholder_resend(store_ref, message_id, msg_data, opts)
      if delay_ms > 0, do: sleep_fun.(delay_ms)

      if match?({:ok, _metadata}, fetch_placeholder_resend(store_ref, message_id)) do
        issue_placeholder_resend_request(store_ref, message_key, message_id, timeout_ms, opts)
      else
        {:ok, "RESOLVED", context}
      end
    end
  end

  @doc """
  Records an active placeholder awaiting server response.
  """
  @spec put_placeholder_resend(Store.Ref.t(), String.t(), map() | nil, keyword()) :: :ok
  def put_placeholder_resend(%Store.Ref{} = store_ref, message_id, data, opts \\ [])
      when is_binary(message_id) and (is_map(data) or is_nil(data)) and is_list(opts) do
    cache =
      Store.get(store_ref, @placeholder_cache_key, %{})
      |> Map.put(message_id, %{
        metadata: data,
        timer_ref: nil,
        inserted_at: now_ms(opts)
      })

    Store.put(store_ref, @placeholder_cache_key, cache)
  end

  @doc """
  Fetches an active placeholder that blocks resolution of a message.
  """
  @spec fetch_placeholder_resend(Store.Ref.t(), String.t()) :: {:ok, map() | nil} | :error
  def fetch_placeholder_resend(%Store.Ref{} = store_ref, message_id) when is_binary(message_id) do
    store_ref
    |> Store.get(@placeholder_cache_key, %{})
    |> Map.fetch(message_id)
    |> case do
      {:ok, %{metadata: metadata}} -> {:ok, metadata}
      :error -> :error
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
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Parses an incoming retry receipt and retrieves cached messages for re-encryption.
  """
  @spec handle_retry_receipt(Store.Ref.t(), BinaryNode.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
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
      do_handle_retry_receipt(store_ref, attrs, node, opts)
    end
  end

  defp do_handle_retry_receipt(store_ref, attrs, node, opts) do
    ids = [attrs["id"] | parse_list_ids(node)]
    remote_jid = attrs["from"] || attrs["recipient"] || attrs["to"]
    resend_fun = opts[:resend_fun]

    entries =
      ids
      |> Enum.map(&lookup_recent_entry(store_ref, remote_jid, &1))
      |> Enum.reject(&is_nil/1)

    maybe_resend_messages(entries, resend_fun, remote_jid, ids)

    {:ok, entries}
  end

  defp lookup_recent_entry(store_ref, remote_jid, id) do
    case get_recent_message(store_ref, remote_jid, id) do
      %{message: message} = entry -> %{id: id, message: message, entry: entry}
      nil -> nil
    end
  end

  @doc """
  Constructs and formats a protocol retry receipt to request a sender re-encrypt a failed message.
  """
  @spec send_retry_request(Store.Ref.t(), BinaryNode.t(), keyword()) ::
          {:ok, BinaryNode.t() | nil} | {:error, term()}
  def send_retry_request(%Store.Ref{} = store_ref, %BinaryNode{attrs: attrs} = node, opts \\ []) do
    message_id = attrs["id"]
    max_retry_count = Keyword.get(opts, :max_retry_count, @max_retry_count)

    if has_exceeded_max_retries?(store_ref, message_id, max_retry_count, opts) do
      :ok = mark_retry_failed(store_ref, message_id)
      {:ok, nil}
    else
      retry_count = increment_retry_count(store_ref, message_id, opts)
      do_send_retry_request(store_ref, node, retry_count, opts)
    end
  end

  defp do_send_retry_request(store_ref, %BinaryNode{attrs: attrs} = node, retry_count, opts) do
    include_keys? = Keyword.get(opts, :force_include_keys, false) || retry_count > 1
    :ok = maybe_schedule_placeholder_resend(store_ref, attrs, node, retry_count, opts)

    with {:ok, keys_node} <- retry_keys_node(include_keys?, opts),
         receipt <- retry_receipt(node, retry_count, keys_node, opts),
         :ok <- emit_retry_receipt(receipt, opts) do
      {:ok, receipt}
    end
  end

  defp retry_receipt(%BinaryNode{attrs: attrs}, retry_count, keys_node, opts) do
    %BinaryNode{
      tag: "receipt",
      attrs:
        %{
          "id" => attrs["id"],
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
              "id" => attrs["id"],
              "t" => attrs["t"] || Integer.to_string(now_seconds(opts)),
              "v" => "1",
              "error" =>
                opts
                |> Keyword.get(:error_code, 0)
                |> normalize_retry_reason()
                |> Kernel.||(0)
                |> Integer.to_string()
            },
            content: nil
          }
        ]
        |> maybe_append_registration(opts[:registration_id])
        |> maybe_append_keys(keys_node)
    }
  end

  defp retry_keys_node(false, _opts), do: {:ok, nil}

  defp retry_keys_node(true, opts) do
    case {opts[:keys_node], opts[:keys_node_fun]} do
      {%BinaryNode{} = keys_node, _fun} -> {:ok, keys_node}
      {_keys_node, fun} when is_function(fun, 0) -> fun.()
      _other -> {:error, :retry_keys_not_configured}
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
      {code, _rest} -> retry_reason_for_code(code)
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
    |> then(&Map.has_key?(@mac_error_codes, &1))
  end

  @doc """
  Bumps the volatile retry tally for a specific message tracking iteration count.
  """
  @spec increment_retry_count(Store.Ref.t(), String.t(), keyword()) :: pos_integer()
  def increment_retry_count(%Store.Ref{} = store_ref, message_id, opts \\ [])
      when is_binary(message_id) do
    now_ms = now_ms(opts)
    ttl_ms = retry_counter_ttl_ms(opts)
    counters = Store.get(store_ref, @retry_counter_key, %{})
    counters = prune_retry_counters(counters, now_ms, ttl_ms)
    count = retry_counter_value(Map.get(counters, message_id)) + 1

    :ok =
      Store.put(
        store_ref,
        @retry_counter_key,
        Map.put(counters, message_id, %{count: count, timestamp: now_ms})
      )

    count
  end

  @doc """
  Yields the current retry iteration count.
  """
  @spec get_retry_count(Store.Ref.t(), String.t(), keyword()) :: non_neg_integer()
  def get_retry_count(%Store.Ref{} = store_ref, message_id, opts \\ [])
      when is_binary(message_id) do
    now_ms = now_ms(opts)
    ttl_ms = retry_counter_ttl_ms(opts)
    counters = Store.get(store_ref, @retry_counter_key, %{})
    counters = prune_retry_counters(counters, now_ms, ttl_ms)
    count = retry_counter_value(Map.get(counters, message_id))

    counters =
      if count > 0 do
        Map.put(counters, message_id, %{count: count, timestamp: now_ms})
      else
        counters
      end

    :ok = Store.put(store_ref, @retry_counter_key, counters)
    count
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

  @spec has_exceeded_max_retries?(Store.Ref.t(), String.t(), pos_integer(), keyword()) ::
          boolean()
  def has_exceeded_max_retries?(
        %Store.Ref{} = store_ref,
        message_id,
        max_retry_count,
        opts
      )
      when is_binary(message_id) and is_integer(max_retry_count) and max_retry_count > 0 and
             is_list(opts) do
    get_retry_count(store_ref, message_id, opts) >= max_retry_count
  end

  defp put_session_recreate_time(%Store.Ref{} = store_ref, history, jid, timestamp) do
    Store.put(store_ref, @session_history_key, Map.put(history, jid, timestamp))
  end

  defp clear_message_retry(%Store.Ref{} = store_ref, message_id) do
    :ok = cancel_phone_request(store_ref, message_id)

    counters = Store.get(store_ref, @retry_counter_key, %{}) |> Map.delete(message_id)
    recent = Store.get(store_ref, @recent_cache_key, %{})

    recent_keys =
      for {{_to, id} = key, _entry} <- recent, id == message_id, do: key

    recent = Map.drop(recent, recent_keys)
    order = Store.get(store_ref, @recent_order_key, []) |> Enum.reject(&(&1 in recent_keys))

    :ok = Store.put(store_ref, @retry_counter_key, counters)
    :ok = Store.put(store_ref, @recent_cache_key, recent)
    Store.put(store_ref, @recent_order_key, order)
  end

  defp issue_placeholder_resend_request(store_ref, message_key, message_id, timeout_ms, opts) do
    with {:ok, cleanup_ref} <-
           schedule_after(
             timeout_ms,
             __MODULE__,
             :expire_placeholder_resend,
             [store_ref, message_id],
             opts
           ),
         :ok <- update_placeholder_timer(store_ref, message_id, cleanup_ref) do
      case send_placeholder_resend_request(message_key, opts[:send_request_fun]) do
        {:ok, request_id, context} ->
          {:ok, request_id, context}

        {:error, _reason} = error ->
          error

        other ->
          {:error, {:invalid_send_request_result, other}}
      end
    else
      {:error, _reason} = error ->
        :ok = resolve_placeholder_resend(store_ref, message_id)
        error
    end
  end

  defp send_placeholder_resend_request(message_key, fun) when is_function(fun, 1) do
    fun.(PeerData.placeholder_resend_request(message_key))
  end

  defp send_placeholder_resend_request(_message_key, _fun),
    do: {:error, :send_request_fun_not_configured}

  defp maybe_resend_messages(entries, resend_fun, remote_jid, ids)
       when is_function(resend_fun, 2) do
    Enum.each(entries, fn %{id: id, message: message} ->
      resend_fun.(message, %{id: id, remote_jid: remote_jid, ids: ids})
    end)
  end

  defp maybe_resend_messages(_entries, _resend_fun, _remote_jid, _ids), do: :ok

  defp recreate_cooldown_elapsed?(history, jid, now_ms) do
    case Map.get(history, jid) do
      nil -> true
      previous -> now_ms - previous > @session_recreate_cooldown_ms
    end
  end

  defp update_placeholder_timer(%Store.Ref{} = store_ref, message_id, timer_ref) do
    cache = Store.get(store_ref, @placeholder_cache_key, %{})

    cache =
      case cache do
        %{^message_id => %{timer_ref: _timer_ref} = entry} ->
          Map.put(cache, message_id, %{entry | timer_ref: timer_ref})

        _other ->
          cache
      end

    Store.put(store_ref, @placeholder_cache_key, cache)
  end

  defp pop_placeholder(%Store.Ref{} = store_ref, message_id) do
    cache = Store.get(store_ref, @placeholder_cache_key, %{})

    case Map.pop(cache, message_id) do
      {nil, rest} ->
        Store.put(store_ref, @placeholder_cache_key, rest)

      {%{timer_ref: timer_ref}, rest} ->
        if timer_ref, do: cancel_scheduled(timer_ref)
        Store.put(store_ref, @placeholder_cache_key, rest)
    end
  end

  defp schedule_after(delay_ms, module, function, args, opts) do
    case opts[:task_supervisor] do
      nil ->
        :timer.apply_after(delay_ms, module, function, args)

      task_supervisor ->
        start_supervised_timer(
          task_supervisor,
          opts[:timer_owner],
          delay_ms,
          module,
          function,
          args
        )
    end
  end

  defp start_supervised_timer(task_supervisor, owner, delay_ms, module, function, args) do
    case Task.Supervisor.start_child(task_supervisor, fn ->
           run_scheduled(owner, delay_ms, module, function, args)
         end) do
      {:ok, pid} -> {:ok, {:task, pid}}
      {:error, _reason} = error -> error
    end
  end

  defp run_scheduled(owner, delay_ms, module, function, args) when is_pid(owner) do
    monitor_ref = Process.monitor(owner)

    receive do
      {:DOWN, ^monitor_ref, :process, ^owner, _reason} -> :ok
    after
      delay_ms ->
        Process.demonitor(monitor_ref, [:flush])
        apply(module, function, args)
    end
  end

  defp run_scheduled(_owner, delay_ms, module, function, args) do
    receive do
    after
      delay_ms -> apply(module, function, args)
    end
  end

  defp cancel_scheduled({:task, pid}) when is_pid(pid) do
    Process.exit(pid, :shutdown)
    :ok
  end

  defp cancel_scheduled(timer_ref), do: :timer.cancel(timer_ref)

  defp normalize_retry_reason(reason) when is_atom(reason),
    do: Map.get(@retry_reason_values, reason, nil)

  defp normalize_retry_reason(reason) when is_integer(reason), do: reason
  defp normalize_retry_reason(_reason), do: nil

  defp retry_reason_for_code(code) do
    Enum.find_value(@retry_reason_values, :UNKNOWN_ERROR, fn
      {reason, ^code} -> reason
      _other -> false
    end)
  end

  defp retry_reason_name(4), do: "SignalErrorInvalidMessage"
  defp retry_reason_name(7), do: "SignalErrorBadMac"

  defp retry_counter_ttl_ms(opts) do
    Keyword.get(opts, :retry_counter_ttl_ms, @retry_counter_ttl_ms)
  end

  defp retry_counter_value(%{count: count}) when is_integer(count), do: count
  defp retry_counter_value(count) when is_integer(count), do: count
  defp retry_counter_value(_entry), do: 0

  defp prune_retry_counters(counters, now_ms, ttl_ms) do
    Enum.reduce(counters, %{}, fn
      {message_id, %{count: count, timestamp: timestamp} = entry}, acc
      when is_integer(count) and is_integer(timestamp) ->
        if now_ms - timestamp <= ttl_ms, do: Map.put(acc, message_id, entry), else: acc

      {_message_id, count}, acc when is_integer(count) ->
        acc

      _entry, acc ->
        acc
    end)
  end

  defp prune_timestamp_cache(cache, now_ms, ttl_ms) do
    Enum.reduce(cache, %{}, fn
      {key, timestamp}, acc when is_integer(timestamp) ->
        if now_ms - timestamp <= ttl_ms, do: Map.put(acc, key, timestamp), else: acc

      _entry, acc ->
        acc
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

  defp prune_base_key_cache(cache, now_ms, ttl_ms) do
    Enum.reduce(cache, %{}, fn {key, %{timestamp: timestamp} = value}, acc ->
      if now_ms - timestamp <= ttl_ms do
        Map.put(acc, key, value)
      else
        acc
      end
    end)
  end

  defp enforce_base_key_cache_limit(cache, max_size)
       when is_integer(max_size) and max_size > 0 do
    if map_size(cache) > max_size do
      cache
      |> Enum.sort_by(fn {_key, %{timestamp: timestamp}} -> timestamp end)
      |> Enum.drop(map_size(cache) - max_size)
      |> Map.new()
    else
      cache
    end
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
          opts
          |> Keyword.take([:task_supervisor, :timer_owner])
          |> Keyword.put(
            :delay_ms,
            Keyword.get(opts, :phone_request_delay_ms, @phone_request_delay_ms)
          )
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

  defp maybe_append_keys(content, %BinaryNode{} = keys_node), do: content ++ [keys_node]
  defp maybe_append_keys(content, nil), do: content

  defp maybe_put_attr(attrs, _key, nil), do: attrs
  defp maybe_put_attr(attrs, key, value), do: Map.put(attrs, key, value)
end
