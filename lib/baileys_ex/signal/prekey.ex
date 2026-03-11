defmodule BaileysEx.Signal.PreKey do
  @moduledoc false

  alias BaileysEx.Auth.State
  alias BaileysEx.BinaryNode
  alias BaileysEx.Signal.Curve
  alias BaileysEx.Signal.Store

  @s_whatsapp_net "s.whatsapp.net"
  @key_bundle_type <<5>>
  @max_upload_retries 3
  @default_min_prekey_count 5
  @default_initial_prekey_count 812
  @default_min_upload_interval_ms 5_000
  @default_upload_timeout_ms 30_000

  @spec next_pre_keys_node(Store.t(), map(), pos_integer()) ::
          {:ok, %{update: map(), node: BinaryNode.t()}} | {:error, term()}
  def next_pre_keys_node(%Store{} = store, auth_state, count)
      when is_map(auth_state) and is_integer(count) and count > 0 do
    with {:ok, registration_id} <- fetch_integer(auth_state, :registration_id),
         {:ok, signed_identity_key} <- fetch_key_pair(auth_state, :signed_identity_key),
         {:ok, signed_pre_key} <- fetch_signed_pre_key(auth_state) do
      {update, pre_keys} = generate_next_pre_keys(store, auth_state, count)

      {:ok,
       %{
         update: update,
         node:
           prekey_upload_node(
             registration_id,
             signed_identity_key.public,
             signed_pre_key,
             pre_keys
           )
       }}
    end
  end

  @spec upload_if_required(keyword()) :: :ok | {:error, term()}
  def upload_if_required(opts) when is_list(opts) do
    upload_key = Keyword.get(opts, :upload_key, self())
    timeout_ms = Keyword.get(opts, :upload_timeout_ms, @default_upload_timeout_ms)

    :global.trans({__MODULE__, upload_key}, fn ->
      with_upload_timeout(timeout_ms, fn -> do_upload_if_required_locked(opts) end)
    end)
  end

  @spec maybe_upload_for_server_count(keyword(), non_neg_integer()) :: :ok | {:error, term()}
  def maybe_upload_for_server_count(opts, pre_key_count)
      when is_list(opts) and is_integer(pre_key_count) and pre_key_count >= 0 do
    upload_key = Keyword.get(opts, :upload_key, self())
    timeout_ms = Keyword.get(opts, :upload_timeout_ms, @default_upload_timeout_ms)

    :global.trans({__MODULE__, upload_key}, fn ->
      with_upload_timeout(timeout_ms, fn ->
        do_maybe_upload_for_server_count_locked(opts, pre_key_count)
      end)
    end)
  end

  @spec digest_key_bundle(keyword()) :: :ok | {:error, term()}
  def digest_key_bundle(opts) when is_list(opts) do
    query_fun = Keyword.fetch!(opts, :query_fun)

    with {:ok, response} <- query_fun.(digest_key_bundle_node()),
         %BinaryNode{} <- child_by_tag(response, "digest") do
      :ok
    else
      nil ->
        with :ok <- upload_if_required(opts) do
          {:error, :missing_digest_node}
        end

      {:error, _reason} = error ->
        error

      _ ->
        {:error, :missing_digest_node}
    end
  end

  @spec rotate_signed_pre_key(keyword()) ::
          {:ok, %{signed_pre_key: map()}} | {:error, term()}
  def rotate_signed_pre_key(opts) when is_list(opts) do
    auth_state = Keyword.fetch!(opts, :auth_state)
    query_fun = Keyword.fetch!(opts, :query_fun)
    emit_creds_update = Keyword.get(opts, :emit_creds_update, fn _update -> :ok end)

    with {:ok, signed_identity_key} <- fetch_key_pair(auth_state, :signed_identity_key),
         current_key_id <- current_signed_pre_key_id(auth_state),
         {:ok, signed_pre_key} <- Curve.signed_key_pair(signed_identity_key, current_key_id + 1),
         {:ok, _response} <- query_fun.(rotate_signed_pre_key_node(signed_pre_key)),
         :ok <- emit_creds_update.(%{signed_pre_key: signed_pre_key}) do
      {:ok, %{signed_pre_key: signed_pre_key}}
    end
  end

  @spec available_prekeys_node() :: BinaryNode.t()
  def available_prekeys_node do
    %BinaryNode{
      tag: "iq",
      attrs: %{"to" => @s_whatsapp_net, "type" => "get", "xmlns" => "encrypt"},
      content: [%BinaryNode{tag: "count", attrs: %{}, content: nil}]
    }
  end

  @spec available_prekeys_count(BinaryNode.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def available_prekeys_count(%BinaryNode{} = response) do
    with %BinaryNode{attrs: %{"value" => value}} <- child_by_tag(response, "count"),
         {count, ""} <- Integer.parse(value) do
      {:ok, count}
    else
      _ -> {:error, :invalid_prekey_count_response}
    end
  end

  defp do_upload_if_required_locked(opts) do
    query_fun = Keyword.fetch!(opts, :query_fun)

    with {:ok, pre_key_count} <- get_available_prekeys_on_server(query_fun) do
      do_maybe_upload_for_server_count_locked(opts, pre_key_count)
    end
  end

  defp do_maybe_upload_for_server_count_locked(opts, pre_key_count) do
    store = Keyword.fetch!(opts, :store)
    auth_state = Keyword.fetch!(opts, :auth_state)
    context = build_upload_context(opts)
    min_prekey_count = Keyword.get(opts, :min_prekey_count, @default_min_prekey_count)
    initial_prekey_count = Keyword.get(opts, :initial_prekey_count, @default_initial_prekey_count)

    with {:ok, current_prekey_id, current_prekey_exists?} <-
           verify_current_prekey_exists(store, auth_state) do
      requested_count = if pre_key_count == 0, do: initial_prekey_count, else: min_prekey_count
      low_server_count? = pre_key_count <= requested_count
      missing_current_prekey? = current_prekey_id > 0 and not current_prekey_exists?

      if low_server_count? or missing_current_prekey? do
        upload_prekeys(context, auth_state, requested_count)
      else
        :ok
      end
    end
  end

  defp upload_prekeys(context, auth_state, count, retry_count \\ 0) do
    now = context.now_ms.()

    if skip_upload?(context, retry_count, now) do
      :ok
    else
      {next_auth_state, node} = generate_upload_node(context, auth_state, count)

      case context.query_fun.(node) do
        {:ok, _response} ->
          :ok = context.put_last_upload_at.(now)
          :ok

        {:error, _reason} = error when retry_count >= @max_upload_retries ->
          error

        {:error, _reason} ->
          backoff_delay_ms = min(1_000 * trunc(:math.pow(2, retry_count)), 10_000)
          context.sleep_fun.(backoff_delay_ms)
          upload_prekeys(context, next_auth_state, count, retry_count + 1)
      end
    end
  end

  defp build_upload_context(opts) do
    %{
      store: Keyword.fetch!(opts, :store),
      query_fun: Keyword.fetch!(opts, :query_fun),
      emit_creds_update: Keyword.get(opts, :emit_creds_update, fn _update -> :ok end),
      now_ms: Keyword.get(opts, :now_ms, fn -> System.os_time(:millisecond) end),
      get_last_upload_at: Keyword.get(opts, :get_last_upload_at, fn -> nil end),
      put_last_upload_at: Keyword.get(opts, :put_last_upload_at, fn _timestamp -> :ok end),
      min_upload_interval_ms:
        Keyword.get(opts, :min_upload_interval_ms, @default_min_upload_interval_ms),
      sleep_fun: Keyword.get(opts, :sleep_fun, &Process.sleep/1)
    }
  end

  defp skip_upload?(context, retry_count, now) do
    last_upload_at = context.get_last_upload_at.()

    retry_count == 0 and is_integer(last_upload_at) and
      now - last_upload_at < context.min_upload_interval_ms
  end

  defp generate_upload_node(context, auth_state, count) do
    Store.transaction(context.store, transaction_key(auth_state), fn ->
      {:ok, %{update: update, node: node}} = next_pre_keys_node(context.store, auth_state, count)
      :ok = context.emit_creds_update.(update)
      {State.merge_updates(auth_state, update), node}
    end)
  end

  defp transaction_key(auth_state) do
    case State.get(auth_state, :me, %{}) do
      %{id: id} when is_binary(id) -> id
      %{"id" => id} when is_binary(id) -> id
      _ -> "upload-pre-keys"
    end
  end

  defp get_available_prekeys_on_server(query_fun),
    do:
      query_fun.(available_prekeys_node())
      |> then(fn
        {:ok, response} -> available_prekeys_count(response)
        {:error, _reason} = error -> error
      end)

  defp verify_current_prekey_exists(store, auth_state) do
    next_pre_key_id = State.get(auth_state, :next_pre_key_id, 1)
    current_prekey_id = next_pre_key_id - 1

    if current_prekey_id <= 0 do
      {:ok, 0, false}
    else
      key_id = Integer.to_string(current_prekey_id)
      exists? = Store.get(store, :"pre-key", [key_id]) != %{}
      {:ok, current_prekey_id, exists?}
    end
  end

  defp generate_next_pre_keys(store, auth_state, count) do
    next_pre_key_id = State.get(auth_state, :next_pre_key_id, 1)
    first_unuploaded_pre_key_id = State.get(auth_state, :first_unuploaded_pre_key_id, 1)

    available = next_pre_key_id - first_unuploaded_pre_key_id
    remaining = max(count - available, 0)
    last_prekey_id = next_pre_key_id + remaining - 1

    new_prekeys =
      if remaining > 0 do
        Enum.reduce(next_pre_key_id..last_prekey_id, %{}, fn id, acc ->
          Map.put(acc, Integer.to_string(id), Curve.generate_key_pair())
        end)
      else
        %{}
      end

    :ok = Store.set(store, %{:"pre-key" => new_prekeys})

    prekey_ids =
      first_unuploaded_pre_key_id..(first_unuploaded_pre_key_id + count - 1)
      |> Enum.map(&Integer.to_string/1)

    prekeys = Store.get(store, :"pre-key", prekey_ids)

    update = %{
      next_pre_key_id: max(last_prekey_id + 1, next_pre_key_id),
      first_unuploaded_pre_key_id: max(first_unuploaded_pre_key_id, last_prekey_id + 1)
    }

    {update, prekeys}
  end

  defp digest_key_bundle_node do
    %BinaryNode{
      tag: "iq",
      attrs: %{"to" => @s_whatsapp_net, "type" => "get", "xmlns" => "encrypt"},
      content: [%BinaryNode{tag: "digest", attrs: %{}, content: nil}]
    }
  end

  defp prekey_upload_node(registration_id, signed_identity_public_key, signed_pre_key, prekeys) do
    %BinaryNode{
      tag: "iq",
      attrs: %{"xmlns" => "encrypt", "type" => "set", "to" => @s_whatsapp_net},
      content: [
        %BinaryNode{
          tag: "registration",
          attrs: %{},
          content: {:binary, encode_big_endian(registration_id, 4)}
        },
        %BinaryNode{tag: "type", attrs: %{}, content: {:binary, @key_bundle_type}},
        %BinaryNode{tag: "identity", attrs: %{}, content: {:binary, signed_identity_public_key}},
        %BinaryNode{
          tag: "list",
          attrs: %{},
          content:
            prekeys
            |> Enum.sort_by(fn {id, _key} -> String.to_integer(id) end)
            |> Enum.map(fn {id, key_pair} -> xmpp_prekey(key_pair, String.to_integer(id)) end)
        },
        xmpp_signed_prekey(signed_pre_key)
      ]
    }
  end

  defp xmpp_signed_prekey(%{key_pair: key_pair, key_id: key_id, signature: signature}) do
    %BinaryNode{
      tag: "skey",
      attrs: %{},
      content: [
        %BinaryNode{tag: "id", attrs: %{}, content: {:binary, encode_big_endian(key_id, 3)}},
        %BinaryNode{tag: "value", attrs: %{}, content: {:binary, key_pair.public}},
        %BinaryNode{tag: "signature", attrs: %{}, content: {:binary, signature}}
      ]
    }
  end

  defp xmpp_prekey(key_pair, id) do
    %BinaryNode{
      tag: "key",
      attrs: %{},
      content: [
        %BinaryNode{tag: "id", attrs: %{}, content: {:binary, encode_big_endian(id, 3)}},
        %BinaryNode{tag: "value", attrs: %{}, content: {:binary, key_pair.public}}
      ]
    }
  end

  defp rotate_signed_pre_key_node(signed_pre_key) do
    %BinaryNode{
      tag: "iq",
      attrs: %{"xmlns" => "encrypt", "type" => "set", "to" => @s_whatsapp_net},
      content: [
        %BinaryNode{
          tag: "rotate",
          attrs: %{},
          content: [xmpp_signed_prekey(signed_pre_key)]
        }
      ]
    }
  end

  defp encode_big_endian(integer, bytes) when is_integer(integer) and integer >= 0 do
    <<integer::unsigned-big-integer-size(bytes * 8)>>
  end

  defp fetch_integer(auth_state, key) do
    case State.get(auth_state, key) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _ -> {:error, {:missing_integer, key}}
    end
  end

  defp fetch_key_pair(auth_state, key) do
    case State.get(auth_state, key) do
      %{public: public_key, private: private_key} = key_pair
      when is_binary(public_key) and is_binary(private_key) ->
        {:ok, key_pair}

      _ ->
        {:error, {:missing_key_pair, key}}
    end
  end

  defp fetch_signed_pre_key(auth_state) do
    case State.get(auth_state, :signed_pre_key) do
      %{
        key_pair: %{public: public_key, private: private_key},
        key_id: key_id,
        signature: signature
      } =
          signed_pre_key
      when is_binary(public_key) and is_binary(private_key) and is_integer(key_id) and
             is_binary(signature) ->
        {:ok, signed_pre_key}

      _ ->
        {:error, :missing_signed_pre_key}
    end
  end

  defp current_signed_pre_key_id(auth_state) do
    case State.get(auth_state, :signed_pre_key) do
      %{key_id: key_id} when is_integer(key_id) and key_id >= 0 -> key_id
      _ -> 0
    end
  end

  defp child_by_tag(%BinaryNode{content: content}, tag) when is_list(content) do
    Enum.find(content, &match?(%BinaryNode{tag: ^tag}, &1))
  end

  defp child_by_tag(_node, _tag), do: nil

  defp with_upload_timeout(timeout_ms, fun)
       when is_integer(timeout_ms) and timeout_ms > 0 and is_function(fun, 0) do
    caller = self()
    ref = make_ref()

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        Kernel.send(caller, {ref, fun.()})
      end)

    receive do
      {^ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        result

      {:DOWN, ^monitor_ref, :process, _pid, reason} ->
        {:error, {:upload_crash, reason}}
    after
      timeout_ms ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^monitor_ref, :process, _pid, _reason} -> :ok
        after
          0 -> :ok
        end

        {:error, :upload_timeout}
    end
  end
end
