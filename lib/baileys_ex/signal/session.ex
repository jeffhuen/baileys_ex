defmodule BaileysEx.Signal.Session do
  @moduledoc """
  Session assertion helpers aligned with Baileys rc.9 `assertSessions`.
  """

  alias BaileysEx.BinaryNode
  alias BaileysEx.Protocol.BinaryNode, as: BinaryNodeUtil
  alias BaileysEx.Protocol.JID, as: JIDUtil
  alias BaileysEx.Signal.Curve
  alias BaileysEx.Signal.Repository

  @s_whatsapp_net "s.whatsapp.net"

  @type context :: %{
          required(:signal_repository) => Repository.t(),
          optional(:query_fun) => (BinaryNode.t() -> {:ok, BinaryNode.t()} | {:error, term()}),
          optional(atom()) => term()
        }

  @doc "Validates that active E2E sessions exist for the specified JIDs, fetching any missing pre-keys."
  @spec assert_sessions(context(), [String.t()], keyword()) ::
          {:ok, context(), boolean()} | {:error, term()}
  def assert_sessions(
        %{signal_repository: %Repository{} = repo} = context,
        jids,
        opts
      )
      when is_list(jids) do
    force? = Keyword.get(opts, :force, false)

    with {:ok, repo, jids_requiring_fetch} <- jids_requiring_fetch(repo, jids, force?),
         {:ok, repo, wire_jids} <- resolve_wire_jids(repo, jids_requiring_fetch),
         {:ok, response} <- maybe_query_sessions(context[:query_fun], wire_jids, force?),
         {:ok, repo} <- parse_and_inject_e2e_sessions(response, repo) do
      {:ok, %{context | signal_repository: repo}, wire_jids != []}
    end
  end

  def assert_sessions(_context, _jids, _opts), do: {:error, :query_fun_not_configured}

  @doc "Decodes E2E session pre-keys from the server payload and injects them into the signal repository."
  @spec parse_and_inject_e2e_sessions(BinaryNode.t(), Repository.t()) ::
          {:ok, Repository.t()} | {:error, term()}
  def parse_and_inject_e2e_sessions(%BinaryNode{} = response, %Repository{} = repo) do
    users =
      response
      |> BinaryNodeUtil.child("list")
      |> BinaryNodeUtil.children("user")

    Enum.reduce_while(users, {:ok, repo}, fn user_node, {:ok, acc_repo} ->
      with :ok <- BinaryNodeUtil.assert_error_free(user_node),
           {:ok, jid} <- fetch_attr(user_node, "jid"),
           {:ok, registration_id} <- child_uint(user_node, "registration"),
           {:ok, identity_key} <- child_signal_public_key(user_node, "identity"),
           {:ok, signed_pre_key} <-
             decode_signed_pre_key(BinaryNodeUtil.child(user_node, "skey")),
           {:ok, pre_key} <- decode_pre_key(BinaryNodeUtil.child(user_node, "key")),
           {:ok, next_repo} <-
             Repository.inject_e2e_session(acc_repo, %{
               jid: jid,
               session: %{
                 registration_id: registration_id,
                 identity_key: identity_key,
                 signed_pre_key: signed_pre_key,
                 pre_key: pre_key
               }
             }) do
        {:cont, {:ok, next_repo}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp jids_requiring_fetch(repo, jids, force?) do
    unique_jids = Enum.uniq(jids)

    Enum.reduce_while(unique_jids, {:ok, repo, []}, fn jid, {:ok, acc_repo, acc} ->
      case Repository.validate_session(acc_repo, jid) do
        {:ok, %{exists: true}} when not force? ->
          {:cont, {:ok, acc_repo, acc}}

        {:ok, _status} ->
          {:cont, {:ok, acc_repo, [jid | acc]}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, next_repo, result} -> {:ok, next_repo, Enum.reverse(result)}
      {:error, _reason} = error -> error
    end
  end

  defp resolve_wire_jids(repo, []), do: {:ok, repo, []}

  defp resolve_wire_jids(repo, jids) do
    Enum.reduce_while(jids, {:ok, repo, []}, fn jid, {:ok, acc_repo, acc} ->
      if JIDUtil.lid?(jid) or JIDUtil.hosted_lid?(jid) do
        {:cont, {:ok, acc_repo, [jid | acc]}}
      else
        resolve_pn_wire_jid(acc_repo, jid, acc)
      end
    end)
    |> case do
      {:ok, next_repo, wire_jids} -> {:ok, next_repo, Enum.reverse(wire_jids)}
      {:error, _reason} = error -> error
    end
  end

  defp resolve_pn_wire_jid(repo, jid, acc) do
    {:ok, next_repo, mapped_lid} = Repository.get_lid_for_pn(repo, jid)
    {:cont, {:ok, next_repo, [mapped_lid || jid | acc]}}
  end

  defp maybe_query_sessions(_query_fun, [], _force?),
    do: {:ok, %BinaryNode{tag: "iq", attrs: %{}, content: []}}

  defp maybe_query_sessions(query_fun, wire_jids, force?) when is_function(query_fun, 1) do
    query_fun.(assert_sessions_node(wire_jids, force?))
  end

  defp maybe_query_sessions(_query_fun, _wire_jids, _force?),
    do: {:error, :query_fun_not_configured}

  defp assert_sessions_node(wire_jids, force?) do
    %BinaryNode{
      tag: "iq",
      attrs: %{"xmlns" => "encrypt", "type" => "get", "to" => @s_whatsapp_net},
      content: [
        %BinaryNode{
          tag: "key",
          attrs: %{},
          content:
            Enum.map(wire_jids, fn jid ->
              attrs =
                %{"jid" => jid}
                |> maybe_put("reason", if(force?, do: "identity", else: nil))

              %BinaryNode{tag: "user", attrs: attrs, content: nil}
            end)
        }
      ]
    }
  end

  defp decode_signed_pre_key(%BinaryNode{} = node) do
    with {:ok, key_id} <- child_uint(node, "id"),
         {:ok, public_key} <- child_signal_public_key(node, "value"),
         {:ok, signature} <- child_required_bytes(node, "signature") do
      {:ok, %{key_id: key_id, public_key: public_key, signature: signature}}
    end
  end

  defp decode_signed_pre_key(_node), do: {:error, :missing_signed_pre_key}

  defp decode_pre_key(%BinaryNode{} = node) do
    with {:ok, key_id} <- child_uint(node, "id"),
         {:ok, public_key} <- child_signal_public_key(node, "value") do
      {:ok, %{key_id: key_id, public_key: public_key}}
    end
  end

  defp decode_pre_key(_node), do: {:error, :missing_pre_key}

  defp child_signal_public_key(node, tag) do
    with {:ok, bytes} <- child_required_bytes(node, tag) do
      Curve.generate_signal_pub_key(bytes)
    end
  end

  defp child_uint(node, tag) do
    with {:ok, bytes} <- child_required_bytes(node, tag) do
      {:ok, :binary.decode_unsigned(bytes)}
    end
  end

  defp child_required_bytes(node, tag) do
    case BinaryNodeUtil.child(node, tag) do
      %BinaryNode{content: {:binary, bytes}} when is_binary(bytes) -> {:ok, bytes}
      %BinaryNode{content: bytes} when is_binary(bytes) -> {:ok, bytes}
      _ -> {:error, {:missing_child, tag}}
    end
  end

  defp fetch_attr(%BinaryNode{attrs: attrs}, key) do
    case attrs[key] do
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, {:missing_attr, key}}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
