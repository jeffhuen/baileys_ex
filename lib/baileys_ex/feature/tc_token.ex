defmodule BaileysEx.Feature.TcToken do
  @moduledoc """
  Trusted-contact token helpers aligned with Baileys' privacy-token flow.
  """

  alias BaileysEx.BinaryNode
  alias BaileysEx.Connection.Socket
  alias BaileysEx.Protocol.BinaryNode, as: BinaryNodeUtil
  alias BaileysEx.Protocol.JID
  alias BaileysEx.Signal.Store

  @s_whatsapp_net "s.whatsapp.net"
  @timeout 60_000

  @doc """
  Append a stored TC token node to the provided content list.

  Mirrors Baileys `buildTcTokenFromJid`: if no token exists, returns the
  existing content when present or `nil` when it is empty.
  """
  @spec build_content(Store.t() | nil, String.t(), [BinaryNode.t()]) :: [BinaryNode.t()] | nil
  def build_content(store, jid, base_content \\ [])

  def build_content(%Store{} = store, jid, base_content)
      when is_binary(jid) and is_list(base_content) do
    case build_node(store, jid) do
      %BinaryNode{} = node -> base_content ++ [node]
      nil when base_content == [] -> nil
      nil -> base_content
    end
  end

  def build_content(_store, _jid, []), do: nil
  def build_content(_store, _jid, base_content) when is_list(base_content), do: base_content

  @doc "Build a `tctoken` child node for a JID when a stored token exists."
  @spec build_node(Store.t() | nil, String.t()) :: BinaryNode.t() | nil
  def build_node(%Store{} = store, jid) when is_binary(jid) do
    case safe_get_token(store, jid) do
      {:ok, token} -> %BinaryNode{tag: "tctoken", attrs: %{}, content: {:binary, token}}
      :error -> nil
    end
  end

  def build_node(_store, _jid), do: nil

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
        maybe_store_with_callback(jid, token, timestamp, opts)
        maybe_store_in_signal_store(jid, token, timestamp, opts)
    end
  end

  defp store_token(_token_node, _jid, _opts), do: :ok

  defp maybe_store_with_callback(jid, token, timestamp, opts) do
    case opts[:store_privacy_token_fun] do
      fun when is_function(fun, 3) ->
        _ = fun.(jid, token, timestamp)
        :ok

      _ ->
        :ok
    end
  end

  defp maybe_store_in_signal_store(jid, token, timestamp, opts) do
    case opts[:signal_store] do
      %Store{} = signal_store ->
        Store.set(signal_store, %{tctoken: %{jid => %{token: token, timestamp: timestamp}}})

      _ ->
        :ok
    end
  end

  defp binary_content({:binary, token}) when is_binary(token), do: token
  defp binary_content(token) when is_binary(token), do: token
  defp binary_content(_content), do: nil

  defp safe_get_token(%Store{} = store, jid) do
    jid = normalized_jid(jid)
    direct_get_token(store, jid)
  end

  defp direct_get_token(%Store{} = store, jid) do
    try do
      case Store.get(store, :tctoken, [jid]) do
        %{^jid => %{token: token}} when is_binary(token) -> {:ok, token}
        _ -> :error
      end
    rescue
      ArgumentError -> :error
    catch
      :exit, _reason -> :error
    end
  end

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

  defp query(queryable, %BinaryNode{} = node, timeout) when is_function(queryable, 2),
    do: queryable.(node, timeout)

  defp query(queryable, %BinaryNode{} = node, _timeout) when is_function(queryable, 1),
    do: queryable.(node)

  defp query({module, server}, %BinaryNode{} = node, timeout) when is_atom(module),
    do: module.query(server, node, timeout)

  defp query(queryable, %BinaryNode{} = node, timeout),
    do: Socket.query(queryable, node, timeout)
end
