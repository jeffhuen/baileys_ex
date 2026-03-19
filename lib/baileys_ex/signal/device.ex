defmodule BaileysEx.Signal.Device do
  @moduledoc """
  Device discovery and caching for message fanout.
  """

  require Logger

  alias BaileysEx.BinaryNode
  alias BaileysEx.Connection.Socket
  alias BaileysEx.JID
  alias BaileysEx.Protocol.JID, as: JIDUtil
  alias BaileysEx.Protocol.USync
  alias BaileysEx.Signal.LIDMappingStore
  alias BaileysEx.Signal.Session
  alias BaileysEx.Signal.Store

  @type context :: %{
          required(:signal_store) => Store.t(),
          optional(:query_fun) => (BinaryNode.t() -> {:ok, BinaryNode.t()} | {:error, term()}),
          optional(:socket) => GenServer.server(),
          optional(atom()) => term()
        }

  @doc "Collects linked devices for recipient sets, loading them via the signal store or via USync device info packets."
  @spec get_devices(context(), [String.t()], keyword()) ::
          {:ok, context(), [String.t()]} | {:error, term()}
  def get_devices(context, jids, opts \\ [])

  def get_devices(%{signal_store: %Store{}} = context, jids, _opts) when is_list(jids) do
    explicit_devices =
      jids
      |> Enum.filter(&explicit_device_jid?/1)
      |> Enum.uniq()

    base_jids =
      jids
      |> Enum.reject(&explicit_device_jid?/1)
      |> Enum.map(&normalize_user_jid/1)
      |> Enum.uniq()

    {cached, missing} =
      Enum.reduce(base_jids, {%{}, []}, fn jid, {acc, misses} ->
        parsed = JIDUtil.parse(jid)
        devices = Store.get(context.signal_store, :"device-list", [parsed.user || ""])
        user = parsed.user

        case Map.get(devices, user) do
          ids when is_list(ids) ->
            device_jids = device_jids_for_lookup(jid, ids)
            {Map.put(acc, jid, device_jids), misses}

          _ ->
            {acc, [jid | misses]}
        end
      end)

    with {:ok, context, fetched} <- maybe_fetch_devices(context, Enum.reverse(missing)) do
      devices =
        explicit_devices ++
          List.flatten(Map.values(cached)) ++
          List.flatten(Map.values(fetched))

      {:ok, context, Enum.uniq(devices)}
    end
  end

  def get_devices(_context, _jids, _opts), do: {:error, :signal_store_not_configured}

  defp maybe_fetch_devices(context, []), do: {:ok, context, %{}}

  defp maybe_fetch_devices(%{} = context, jids) when is_list(jids) do
    if Map.has_key?(context, :query_fun) or Map.has_key?(context, :socket) do
      fetch_devices_via_query(context, jids)
    else
      {:ok, context, Map.new(jids, &{&1, []})}
    end
  end

  defp fetch_devices_via_query(%{signal_store: %Store{} = store} = context, jids) do
    query = Enum.reduce(jids, USync.new(context: :message), &USync.with_user(&2, %{id: &1}))

    query =
      query
      |> USync.with_protocol(:devices)
      |> USync.with_protocol(:lid)

    with {:ok, node} <- USync.to_node(query, "message-device-query"),
         {:ok, response} <- query_node(context, node),
         {:ok, %{list: results}} <- USync.parse_result(query, response) do
      Logger.warning(
        "[Device] usync devices query: requested=#{inspect(jids)} " <>
          "results=#{inspect(summarize_results(results))}"
      )

      fetched =
        Enum.reduce(results, %{}, fn %{id: jid, devices: %{device_list: device_list}} = result,
                                     acc ->
          ids = Enum.map(device_list, &Integer.to_string(&1.id))
          requested_jid = requested_jid_for_result(result, jids)

          Map.put(
            acc,
            normalize_user_jid(requested_jid || jid),
            device_jids_for_result(result, requested_jid, ids)
          )
        end)

      lid_mappings =
        Enum.flat_map(results, fn
          %{id: pn, lid: lid} when is_binary(pn) and is_binary(lid) -> [%{pn: pn, lid: lid}]
          _ -> []
        end)

      :ok = LIDMappingStore.store_lid_pn_mappings(store, lid_mappings)

      context = maybe_refresh_lid_sessions(context, lid_mappings)

      :ok =
        Store.set(store, %{
          :"device-list" =>
            Map.new(results, fn %{id: jid, devices: %{device_list: device_list}} ->
              parsed = JIDUtil.parse(jid)
              {parsed.user, Enum.map(device_list, &Integer.to_string(&1.id))}
            end)
        })

      {:ok, context, fetched}
    end
  end

  defp query_node(%{query_fun: fun}, node) when is_function(fun, 1), do: fun.(node)
  defp query_node(%{socket: socket}, node), do: Socket.query(socket, node)

  defp query_node(_context, _node),
    do: {:ok, %BinaryNode{tag: "iq", attrs: %{"type" => "result"}, content: []}}

  defp normalize_user_jid(jid) do
    jid
    |> JIDUtil.normalized_user()
    |> case do
      "" -> jid
      normalized -> normalized
    end
  end

  defp device_jid(%JID{user: user, server: server}, device_id) do
    device_id = parse_device_id(device_id)
    JIDUtil.jid_encode(user, device_server(server, device_id), device_id)
  end

  defp device_jids_for_lookup(jid, ids) when is_binary(jid) and is_list(ids) do
    parsed = JIDUtil.parse(jid)
    Enum.map(ids, &device_jid(parsed, &1))
  end

  defp device_jids_for_result(%{id: jid} = result, requested_jid, ids)
       when is_binary(jid) and is_list(ids) do
    parsed =
      result
      |> result_device_base_jid(requested_jid)
      |> JIDUtil.parse()

    Enum.map(ids, &device_jid(parsed, &1))
  end

  defp requested_jid_for_result(%{id: jid} = result, requested_jids)
       when is_list(requested_jids) do
    lid = Map.get(result, :lid)
    normalized_requested = MapSet.new(Enum.map(requested_jids, &normalize_user_jid/1))
    normalized_lid = normalize_user_jid(lid)
    normalized_id = normalize_user_jid(jid)

    cond do
      is_binary(lid) and MapSet.member?(normalized_requested, normalized_lid) ->
        normalized_lid

      MapSet.member?(normalized_requested, normalized_id) ->
        normalized_id

      true ->
        nil
    end
  end

  defp result_device_base_jid(%{lid: lid}, requested_jid)
       when is_binary(lid) and is_binary(requested_jid) do
    if JIDUtil.lid?(requested_jid) or JIDUtil.hosted_lid?(requested_jid) do
      lid
    else
      result_device_base_jid(%{id: requested_jid}, nil)
    end
  end

  defp result_device_base_jid(%{id: jid}, _requested_jid) when is_binary(jid), do: jid
  defp result_device_base_jid(%{lid: lid}, _requested_jid) when is_binary(lid), do: lid

  defp parse_device_id(device_id) when is_integer(device_id), do: device_id
  defp parse_device_id(device_id) when is_binary(device_id), do: String.to_integer(device_id)

  defp device_server("hosted", _device_id), do: "hosted"
  defp device_server("hosted.lid", _device_id), do: "hosted.lid"
  defp device_server("lid", 99), do: "hosted.lid"
  defp device_server(_server, 99), do: "hosted"
  defp device_server(server, _device_id), do: server

  defp explicit_device_jid?(jid) when is_binary(jid) do
    match?(%JID{device: device} when is_integer(device), JIDUtil.parse(jid))
  end

  defp summarize_results(results) when is_list(results) do
    Enum.map(results, fn result ->
      %{
        id: result[:id],
        lid: result[:lid],
        devices:
          Enum.map(get_in(result, [:devices, :device_list]) || [], fn device ->
            %{
              id: device[:id],
              key_index: device[:key_index],
              hosted?: device[:is_hosted]
            }
          end)
      }
    end)
  end

  defp maybe_refresh_lid_sessions(%{signal_repository: _repository} = context, lid_mappings) do
    lids = Enum.map(lid_mappings, & &1.lid)

    case lids do
      [] ->
        context

      _ ->
        case Session.assert_sessions(context, lids, force: true) do
          {:ok, updated_context, _fetched?} ->
            updated_context

          {:error, reason} ->
            Logger.warning(
              "[Device] failed to refresh sessions for LID mappings " <>
                "lids=#{inspect(lids)} reason=#{inspect(reason)}"
            )

            context
        end
    end
  end

  defp maybe_refresh_lid_sessions(context, _lid_mappings), do: context
end
