defmodule BaileysEx.Signal.LIDMappingStore do
  @moduledoc """
  Store-backed PN<->LID mapping helpers aligned with Baileys' lookup rules.

  User-level mappings are persisted in the `:"lid-mapping"` family using the
  same forward/reverse keys Baileys writes (`pn_user` and `lid_user_reverse`).
  Device-specific JIDs are derived at read time so Signal addressing preserves
  per-device separation without duplicating stored rows.

  Reverse PN lookup is intentionally limited to base `@lid` users, matching the
  Baileys reference. Derived `@hosted.lid` device addresses are produced during
  forward PN lookup, but are not treated as stored reverse-lookup identities.
  """

  alias BaileysEx.Protocol.JID
  alias BaileysEx.Signal.Store

  @type mapping :: %{pn: String.t(), lid: String.t()}
  @type lookup_fun :: ([String.t()] -> [mapping()] | nil)
  @type error :: :invalid_mapping

  @doc "Records active mapping correlations between Phone Numbers and Local Identifiers to the store engine."
  @spec store_lid_pn_mappings(Store.t(), [mapping()]) :: :ok | {:error, error()}
  def store_lid_pn_mappings(%Store{} = store, mappings) when is_list(mappings) do
    entries =
      Enum.reduce(mappings, %{}, fn mapping, acc ->
        case normalize_mapping(mapping) do
          {:ok, {pn_user, lid_user}} ->
            acc
            |> Map.put(forward_key(pn_user), lid_user)
            |> Map.put(reverse_key(lid_user), pn_user)

          :skip ->
            acc
        end
      end)

    case map_size(entries) do
      0 ->
        :ok

      _count ->
        Store.transaction(store, "lid-mapping", fn tx_store ->
          Store.set(tx_store, %{:"lid-mapping" => entries})
        end)
    end
  end

  def store_lid_pn_mappings(%Store{}, _mappings), do: {:error, :invalid_mapping}

  @doc "Retrieves the single valid LID value mapped to a distinct phone number identifier."
  @spec get_lid_for_pn(Store.t(), String.t(), keyword()) :: {:ok, String.t() | nil}
  def get_lid_for_pn(store, pn, opts \\ [])

  def get_lid_for_pn(%Store{} = store, pn, opts) when is_binary(pn) do
    with {:ok, mappings} <- get_lids_for_pns(store, [pn], opts) do
      {:ok, first_mapping_value(mappings, :lid)}
    end
  end

  def get_lid_for_pn(%Store{}, _pn, _opts), do: {:ok, nil}

  @doc "Bulk-requests numerous LID identities tied to multiple phone numbers."
  @spec get_lids_for_pns(Store.t(), [String.t()], keyword()) :: {:ok, [mapping()] | nil}
  def get_lids_for_pns(store, pns, opts \\ [])

  def get_lids_for_pns(%Store{} = store, pns, opts) when is_list(pns) do
    lookup = Keyword.get(opts, :lookup)

    mappings =
      Store.transaction(store, "lid-mapping", fn tx_store ->
        {resolved, pending} = resolve_pn_reads(tx_store, pns)
        resolve_pending_pns(tx_store, resolved, pending, lookup)
      end)

    {:ok, mappings}
  end

  def get_lids_for_pns(%Store{}, _pns, _opts), do: {:ok, nil}

  @doc "Obtains a Phone Number from an alias LID mapped node structure."
  @spec get_pn_for_lid(Store.t(), String.t()) :: {:ok, String.t() | nil}
  def get_pn_for_lid(%Store{} = store, lid) when is_binary(lid) do
    with {:ok, mappings} <- get_pns_for_lids(store, [lid]) do
      {:ok, first_mapping_value(mappings, :pn)}
    end
  end

  def get_pn_for_lid(%Store{}, _lid), do: {:ok, nil}

  @doc "Loads multiple source Phone Numbers from Local Identifiers collectively."
  @spec get_pns_for_lids(Store.t(), [String.t()]) :: {:ok, [mapping()] | nil}
  def get_pns_for_lids(%Store{} = store, lids) when is_list(lids) do
    resolved =
      Enum.reduce(lids, %{}, fn lid, acc ->
        case parse_lid(lid) do
          {:ok, parsed} -> merge_reverse_mapping(store, acc, lid, parsed)
          :error -> acc
        end
      end)

    {:ok, values_or_nil(resolved)}
  end

  def get_pns_for_lids(%Store{}, _lids), do: {:ok, nil}

  defp resolve_pn_reads(store, pns) do
    parsed =
      Enum.reduce(pns, [], fn pn, acc ->
        case parse_pn(pn) do
          {:ok, parsed_pn} -> [parsed_pn | acc]
          :error -> acc
        end
      end)
      |> Enum.reverse()

    forward_keys =
      parsed
      |> Enum.map(&forward_key(&1.user))
      |> Enum.uniq()

    entries = Store.get(store, :"lid-mapping", forward_keys)

    Enum.reduce(parsed, {%{}, []}, fn parsed_pn, {resolved, pending} ->
      case Map.get(entries, forward_key(parsed_pn.user)) do
        nil ->
          {resolved, [parsed_pn | pending]}

        lid_user ->
          mapping = %{pn: parsed_pn.original, lid: build_lid(parsed_pn, lid_user)}
          {Map.put(resolved, parsed_pn.original, mapping), pending}
      end
    end)
  end

  defp resolve_pending_pns(_store, resolved, [], _lookup), do: values_or_nil(resolved)

  defp resolve_pending_pns(%Store{}, resolved, _pending, nil) do
    values_or_nil(resolved)
  end

  defp resolve_pending_pns(%Store{} = store, resolved, pending, lookup) do
    lookup_input =
      pending
      |> Enum.map(&normalize_lookup_pn/1)
      |> Enum.uniq()

    fetched = lookup.(lookup_input) || []
    :ok = store_lid_pn_mappings(store, fetched)

    forward_entries =
      pending
      |> Enum.map(&forward_key(&1.user))
      |> Enum.uniq()
      |> then(&Store.get(store, :"lid-mapping", &1))

    pending
    |> Enum.reduce(resolved, fn parsed_pn, acc ->
      case Map.get(forward_entries, forward_key(parsed_pn.user)) do
        nil ->
          acc

        lid_user ->
          Map.put(acc, parsed_pn.original, %{
            pn: parsed_pn.original,
            lid: build_lid(parsed_pn, lid_user)
          })
      end
    end)
    |> values_or_nil()
  end

  defp normalize_lookup_pn(%{user: user, server: "hosted"}), do: "#{user}@s.whatsapp.net"
  defp normalize_lookup_pn(%{user: user}), do: "#{user}@s.whatsapp.net"

  defp merge_reverse_mapping(store, resolved, lid, parsed) do
    reverse_entries = Store.get(store, :"lid-mapping", [reverse_key(parsed.user)])

    case Map.get(reverse_entries, reverse_key(parsed.user)) do
      nil -> resolved
      pn_user -> Map.put(resolved, lid, %{lid: lid, pn: build_pn(parsed, pn_user)})
    end
  end

  defp normalize_mapping(%{lid: lid, pn: pn}) do
    normalize_mapping_pair(lid, pn)
  end

  defp normalize_mapping(_mapping), do: :skip

  defp normalize_mapping_pair(lid, pn) do
    cond do
      lid_entry?(lid) and pn_entry?(pn) -> mapping_tuple(lid, pn)
      lid_entry?(pn) and pn_entry?(lid) -> mapping_tuple(pn, lid)
      true -> :skip
    end
  end

  defp mapping_tuple(lid, pn) do
    with {:ok, lid_parsed} <- parse_lid(lid),
         {:ok, pn_parsed} <- parse_pn(pn) do
      {:ok, {pn_parsed.user, lid_parsed.user}}
    else
      :error -> :skip
    end
  end

  defp forward_key(pn_user), do: pn_user
  defp reverse_key(lid_user), do: "#{lid_user}_reverse"

  defp parse_pn(jid) do
    case JID.parse(jid) do
      %BaileysEx.JID{user: user, server: server, device: device}
      when is_binary(user) and server in ["s.whatsapp.net", "c.us", "hosted"] ->
        {:ok, %{original: jid, user: user, server: server, device: device || 0}}

      _other ->
        :error
    end
  end

  defp parse_lid(jid) do
    case JID.parse(jid) do
      %BaileysEx.JID{user: user, server: server, device: device}
      when is_binary(user) and server == "lid" ->
        {:ok, %{original: jid, user: user, server: server, device: device || 0}}

      _other ->
        :error
    end
  end

  defp pn_entry?(jid), do: match?({:ok, _parsed}, parse_pn(jid))
  defp lid_entry?(jid), do: match?({:ok, _parsed}, parse_lid(jid))

  defp build_lid(%{device: device, server: server}, lid_user) do
    lid_server = if server == "hosted", do: "hosted.lid", else: "lid"
    JID.jid_encode(lid_user, lid_server, device)
  end

  defp build_pn(%{device: device, server: server}, pn_user) do
    pn_server = if server == "hosted.lid", do: "hosted", else: "s.whatsapp.net"
    "#{pn_user}:#{device}@#{pn_server}"
  end

  defp values_or_nil(values) when map_size(values) == 0, do: nil
  defp values_or_nil(values), do: Map.values(values)

  defp first_mapping_value(nil, _key), do: nil
  defp first_mapping_value([mapping | _], key), do: Map.fetch!(mapping, key)
end
