defmodule BaileysEx.Message.IdentityChangeHandler do
  @moduledoc """
  Handles identity-change notifications and triggers rc.9-style session refreshes.
  """

  alias BaileysEx.BinaryNode
  alias BaileysEx.Protocol.BinaryNode, as: BinaryNodeUtil
  alias BaileysEx.Protocol.JID, as: JIDUtil
  alias BaileysEx.Signal.Repository
  alias BaileysEx.Signal.Session

  @debounce_ms 5_000

  @type result ::
          %{action: :no_identity_node}
          | %{action: :invalid_notification}
          | %{action: :skipped_companion_device, device: non_neg_integer()}
          | %{action: :skipped_self_primary}
          | %{action: :debounced}
          | %{action: :skipped_offline}
          | %{action: :skipped_no_session}
          | %{action: :session_refreshed}
          | %{action: :session_refresh_failed, error: term()}

  @spec handle(BinaryNode.t(), map(), map(), keyword()) ::
          {:ok, result(), map(), map()} | {:error, term()}
  def handle(%BinaryNode{} = node, %{} = context, cache \\ %{}, opts \\ []) do
    now_ms = Keyword.get_lazy(opts, :now_ms, fn -> System.monotonic_time(:millisecond) end)
    debounce_ms = Keyword.get(opts, :debounce_ms, @debounce_ms)
    cache = prune_cache(cache, now_ms, debounce_ms)
    from = node.attrs["from"]

    cond do
      not is_binary(from) ->
        {:ok, %{action: :invalid_notification}, context, cache}

      not match?(%BinaryNode{}, BinaryNodeUtil.child(node, "identity")) ->
        {:ok, %{action: :no_identity_node}, context, cache}

      companion_device?(from) ->
        device = JIDUtil.parse(from).device
        {:ok, %{action: :skipped_companion_device, device: device}, context, cache}

      self_primary?(from, context[:me_id], context[:me_lid]) ->
        {:ok, %{action: :skipped_self_primary}, context, cache}

      debounced?(cache, from) ->
        {:ok, %{action: :debounced}, context, cache}

      true ->
        do_handle_refresh(node, context, Map.put(cache, from, now_ms), from)
    end
  end

  defp do_handle_refresh(
         %BinaryNode{} = node,
         %{signal_repository: %Repository{} = repo} = context,
         cache,
         from
       ) do
    case Repository.validate_session(repo, from) do
      {:ok, %{exists: false}} ->
        {:ok, %{action: :skipped_no_session}, context, cache}

      {:ok, %{exists: true}} ->
        maybe_refresh_existing_session(node, context, cache, from)

      {:error, reason} ->
        {:ok, %{action: :session_refresh_failed, error: reason}, context, cache}
    end
  end

  defp do_handle_refresh(_node, context, cache, _from),
    do:
      {:ok, %{action: :session_refresh_failed, error: :signal_repository_not_configured}, context,
       cache}

  defp default_assert_sessions(context, jids, force?) do
    Session.assert_sessions(context, jids, force: force?)
  end

  defp maybe_refresh_existing_session(%BinaryNode{} = node, context, cache, from) do
    if offline_notification?(node) do
      {:ok, %{action: :skipped_offline}, context, cache}
    else
      refresh_session(context, cache, from)
    end
  end

  defp refresh_session(context, cache, from) do
    assert_sessions_fun = context[:assert_sessions_fun] || (&default_assert_sessions/3)

    case assert_sessions_fun.(context, [from], true) do
      {:ok, updated_context, _did_fetch} ->
        {:ok, %{action: :session_refreshed}, updated_context, cache}

      {:error, reason} ->
        {:ok, %{action: :session_refresh_failed, error: reason}, context, cache}
    end
  end

  defp prune_cache(cache, now_ms, debounce_ms) do
    Enum.reduce(cache, %{}, fn {jid, previous_ms}, acc ->
      if now_ms - previous_ms < debounce_ms do
        Map.put(acc, jid, previous_ms)
      else
        acc
      end
    end)
  end

  defp debounced?(cache, jid), do: is_integer(cache[jid])

  defp companion_device?(jid) do
    match?(
      %BaileysEx.JID{device: device} when is_integer(device) and device != 0,
      JIDUtil.parse(jid)
    )
  end

  defp self_primary?(jid, me_id, me_lid) do
    JIDUtil.same_user?(jid, me_id) or (is_binary(me_lid) and JIDUtil.same_user?(jid, me_lid))
  end

  defp offline_notification?(%BinaryNode{attrs: attrs}) do
    case attrs["offline"] do
      value when is_binary(value) -> value != ""
      _ -> false
    end
  end
end
