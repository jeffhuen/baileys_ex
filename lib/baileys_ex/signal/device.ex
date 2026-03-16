defmodule BaileysEx.Signal.Device do
  @moduledoc """
  Device discovery and caching for message fanout.
  """

  alias BaileysEx.BinaryNode
  alias BaileysEx.JID
  alias BaileysEx.Protocol.JID, as: JIDUtil
  alias BaileysEx.Protocol.USync
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
            {Map.put(acc, jid, Enum.map(ids, &device_jid(parsed, &1))), misses}

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
    query = USync.with_protocol(query, :devices)

    with {:ok, node} <- USync.to_node(query, "message-device-query"),
         {:ok, response} <- query_node(context, node),
         {:ok, %{list: results}} <- USync.parse_result(query, response) do
      fetched =
        Enum.reduce(results, %{}, fn %{id: jid, devices: %{device_list: device_list}}, acc ->
          parsed = JIDUtil.parse(jid)
          ids = Enum.map(device_list, &Integer.to_string(&1.id))
          Map.put(acc, normalize_user_jid(jid), Enum.map(ids, &device_jid(parsed, &1)))
        end)

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
  defp query_node(%{socket: socket}, node), do: BaileysEx.Connection.Socket.query(socket, node)

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
    "#{user}:#{parse_device_id(device_id)}@#{server}"
  end

  defp parse_device_id(device_id) when is_integer(device_id), do: device_id
  defp parse_device_id(device_id) when is_binary(device_id), do: String.to_integer(device_id)

  defp explicit_device_jid?(jid) when is_binary(jid) do
    match?(%JID{device: device} when is_integer(device), JIDUtil.parse(jid))
  end
end
