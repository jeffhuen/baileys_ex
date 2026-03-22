defmodule BaileysEx.Feature.Privacy do
  @moduledoc """
  Privacy-setting queries aligned with Baileys `chats.ts`.
  """

  alias BaileysEx.BinaryNode
  alias BaileysEx.Connection.Store
  import BaileysEx.Connection.TransportAdapter, only: [query: 3]
  alias BaileysEx.Feature.Chat
  alias BaileysEx.Protocol.BinaryNode, as: BinaryNodeUtil
  alias BaileysEx.Protocol.USync

  @s_whatsapp_net "s.whatsapp.net"
  @timeout 60_000

  @doc """
  Fetch privacy settings from the server, or return cached settings when a store
  is supplied and `force` is false.
  """
  @spec fetch_settings(term()) :: {:ok, map()} | {:error, term()}
  def fetch_settings(queryable), do: fetch_settings(queryable, false, [])

  @doc false
  @spec fetch_settings(term(), boolean() | keyword()) :: {:ok, map()} | {:error, term()}
  def fetch_settings(queryable, force) when is_boolean(force),
    do: fetch_settings(queryable, force, [])

  def fetch_settings(queryable, opts) when is_list(opts),
    do: fetch_settings(queryable, false, opts)

  @doc false
  @spec fetch_settings(term(), boolean(), keyword()) :: {:ok, map()} | {:error, term()}
  def fetch_settings(queryable, force, opts)
      when is_boolean(force) and is_list(opts) do
    case {force, get_store_value(opts[:store], :privacy_settings)} do
      {false, settings} when is_map(settings) ->
        {:ok, settings}

      _ ->
        node = %BinaryNode{
          tag: "iq",
          attrs: %{"xmlns" => "privacy", "to" => @s_whatsapp_net, "type" => "get"},
          content: [%BinaryNode{tag: "privacy", attrs: %{}, content: nil}]
        }

        with {:ok, %BinaryNode{} = response} <- query(queryable, node, timeout(opts)) do
          settings =
            response
            |> BinaryNodeUtil.child("privacy")
            |> reduce_children_to_dictionary("category")

          :ok = maybe_put_store(opts[:store], :privacy_settings, settings)
          {:ok, settings}
        end
    end
  end

  @doc "Who can see your last seen."
  @spec update_last_seen(term(), atom() | String.t(), keyword()) ::
          {:ok, BinaryNode.t()} | {:error, term()}
  def update_last_seen(queryable, value, opts \\ []),
    do: privacy_query(queryable, "last", value, opts)

  @doc "Online status visibility."
  @spec update_online(term(), atom() | String.t(), keyword()) ::
          {:ok, BinaryNode.t()} | {:error, term()}
  def update_online(queryable, value, opts \\ []),
    do: privacy_query(queryable, "online", value, opts)

  @doc "Profile-picture visibility."
  @spec update_profile_picture(term(), atom() | String.t(), keyword()) ::
          {:ok, BinaryNode.t()} | {:error, term()}
  def update_profile_picture(queryable, value, opts \\ []),
    do: privacy_query(queryable, "profile", value, opts)

  @doc "Status/story visibility."
  @spec update_status(term(), atom() | String.t(), keyword()) ::
          {:ok, BinaryNode.t()} | {:error, term()}
  def update_status(queryable, value, opts \\ []),
    do: privacy_query(queryable, "status", value, opts)

  @doc "Read-receipt visibility."
  @spec update_read_receipts(term(), atom() | String.t(), keyword()) ::
          {:ok, BinaryNode.t()} | {:error, term()}
  def update_read_receipts(queryable, value, opts \\ []),
    do: privacy_query(queryable, "readreceipts", value, opts)

  @doc "Who can add you to calls."
  @spec update_call_add(term(), atom() | String.t(), keyword()) ::
          {:ok, BinaryNode.t()} | {:error, term()}
  def update_call_add(queryable, value, opts \\ []),
    do: privacy_query(queryable, "calladd", value, opts)

  @doc "Who can message you."
  @spec update_messages(term(), atom() | String.t(), keyword()) ::
          {:ok, BinaryNode.t()} | {:error, term()}
  def update_messages(queryable, value, opts \\ []),
    do: privacy_query(queryable, "messages", value, opts)

  @doc "Who can add you to groups."
  @spec update_group_add(term(), atom() | String.t(), keyword()) ::
          {:ok, BinaryNode.t()} | {:error, term()}
  def update_group_add(queryable, value, opts \\ []),
    do: privacy_query(queryable, "groupadd", value, opts)

  @doc """
  Disable or enable server-side link-preview generation via the Baileys
  app-state patch path.
  """
  @spec update_disable_link_previews_privacy(term(), boolean()) ::
          {:ok, map()} | {:error, term()}
  def update_disable_link_previews_privacy(conn, disabled?),
    do: Chat.update_disable_link_previews_privacy(conn, disabled?)

  @doc "Elixir-friendly alias for `update_disable_link_previews_privacy/2`."
  @spec update_link_previews(term(), boolean()) :: {:ok, map()} | {:error, term()}
  def update_link_previews(conn, disabled?),
    do: update_disable_link_previews_privacy(conn, disabled?)

  @doc "Set the account default disappearing-message duration in seconds."
  @spec update_default_disappearing_mode(term(), non_neg_integer(), keyword()) ::
          {:ok, BinaryNode.t()} | {:error, term()}
  def update_default_disappearing_mode(queryable, duration, opts \\ [])
      when is_integer(duration) and duration >= 0 and is_list(opts) do
    node = %BinaryNode{
      tag: "iq",
      attrs: %{"xmlns" => "disappearing_mode", "to" => @s_whatsapp_net, "type" => "set"},
      content: [
        %BinaryNode{
          tag: "disappearing_mode",
          attrs: %{"duration" => Integer.to_string(duration)},
          content: nil
        }
      ]
    }

    query(queryable, node, timeout(opts))
  end

  @doc "Fetch disappearing durations for one or more JIDs via USync."
  @spec fetch_disappearing_duration(term(), [String.t()], keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_disappearing_duration(queryable, jids, opts \\ [])
      when is_list(jids) and is_list(opts) do
    query =
      Enum.reduce(
        jids,
        USync.new(context: :interactive) |> USync.with_protocol(:disappearing_mode),
        fn jid, acc ->
          USync.with_user(acc, %{id: jid})
        end
      )

    if query.users == [] do
      {:ok, []}
    else
      sid =
        Keyword.get_lazy(opts, :sid, fn ->
          Integer.to_string(System.unique_integer([:positive]))
        end)

      with {:ok, node} <- USync.to_node(query, sid),
           {:ok, %BinaryNode{} = response} <- query(queryable, node, timeout(opts)),
           {:ok, %{list: list}} <- USync.parse_result(query, response) do
        {:ok, list}
      end
    end
  end

  @doc "Fetch the full account blocklist."
  @spec fetch_blocklist(term(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def fetch_blocklist(queryable, opts \\ []) when is_list(opts) do
    node = %BinaryNode{
      tag: "iq",
      attrs: %{"xmlns" => "blocklist", "to" => @s_whatsapp_net, "type" => "get"},
      content: nil
    }

    with {:ok, %BinaryNode{} = response} <- query(queryable, node, timeout(opts)) do
      blocklist =
        response
        |> BinaryNodeUtil.child("list")
        |> BinaryNodeUtil.children("item")
        |> Enum.map(& &1.attrs["jid"])
        |> Enum.reject(&is_nil/1)

      :ok = maybe_put_store(opts[:store], :blocklist, blocklist)
      {:ok, blocklist}
    end
  end

  @doc "Block or unblock a user."
  @spec update_block_status(term(), String.t(), :block | :unblock, keyword()) ::
          {:ok, BinaryNode.t()} | {:error, term()}
  def update_block_status(queryable, jid, action, opts \\ [])
      when is_binary(jid) and action in [:block, :unblock] and is_list(opts) do
    node = %BinaryNode{
      tag: "iq",
      attrs: %{"xmlns" => "blocklist", "to" => @s_whatsapp_net, "type" => "set"},
      content: [
        %BinaryNode{
          tag: "item",
          attrs: %{"action" => Atom.to_string(action), "jid" => jid},
          content: nil
        }
      ]
    }

    query(queryable, node, timeout(opts))
  end

  defp privacy_query(queryable, name, value, opts) when is_binary(name) and is_list(opts) do
    node = %BinaryNode{
      tag: "iq",
      attrs: %{"xmlns" => "privacy", "to" => @s_whatsapp_net, "type" => "set"},
      content: [
        %BinaryNode{
          tag: "privacy",
          attrs: %{},
          content: [
            %BinaryNode{
              tag: "category",
              attrs: %{"name" => name, "value" => value_to_string(value)},
              content: nil
            }
          ]
        }
      ]
    }

    query(queryable, node, timeout(opts))
  end

  defp reduce_children_to_dictionary(nil, _child_tag), do: %{}

  defp reduce_children_to_dictionary(node, child_tag) do
    node
    |> BinaryNodeUtil.children(child_tag)
    |> Enum.reduce(%{}, fn child, acc ->
      name = child.attrs["name"] || child.attrs["config_code"]
      value = child.attrs["value"] || child.attrs["config_value"]

      case {name, value} do
        {name, value} when is_binary(name) and is_binary(value) -> Map.put(acc, name, value)
        _ -> acc
      end
    end)
  end

  defp timeout(opts), do: Keyword.get(opts, :query_timeout, @timeout)

  defp value_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp value_to_string(value) when is_binary(value), do: value
  defp value_to_string(value), do: to_string(value)

  defp get_store_value(nil, _key), do: nil
  defp get_store_value(%Store.Ref{} = store, key), do: Store.get(store, key)
  defp get_store_value(store, key), do: store |> Store.wrap() |> Store.get(key)

  defp maybe_put_store(nil, _key, _value), do: :ok
  defp maybe_put_store(store, key, value), do: Store.put(store, key, value)

end
