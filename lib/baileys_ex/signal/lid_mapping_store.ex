defmodule BaileysEx.Signal.LIDMappingStore do
  @moduledoc """
  In-memory PN<->LID mapping store aligned with Baileys' LID lookup rules.

  The store keeps user-level mappings using the same forward/reverse key shape
  Baileys persists (`pn_user` and `lid_user_reverse`) and derives device-specific
  JIDs during lookup so the repository can preserve per-device Signal addressing.
  """

  alias BaileysEx.Protocol.JID

  @type mapping :: %{pn: String.t(), lid: String.t()}
  @type lookup_fun :: ([String.t()] -> [mapping()] | nil)

  @type t :: %__MODULE__{
          entries: %{optional(String.t()) => String.t()},
          pn_to_lid_lookup: lookup_fun() | nil
        }

  @type error :: :invalid_mapping

  defstruct entries: %{}, pn_to_lid_lookup: nil

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{pn_to_lid_lookup: Keyword.get(opts, :pn_to_lid_lookup)}
  end

  @spec store_lid_pn_mappings(t(), [mapping()]) :: {:ok, t()} | {:error, error()}
  def store_lid_pn_mappings(%__MODULE__{} = store, mappings) when is_list(mappings) do
    updated_store =
      Enum.reduce(mappings, store, fn mapping, acc ->
        case normalize_mapping(mapping) do
          {:ok, {pn_user, lid_user}} -> put_mapping(acc, pn_user, lid_user)
          :skip -> acc
        end
      end)

    {:ok, updated_store}
  end

  def store_lid_pn_mappings(%__MODULE__{}, _mappings), do: {:error, :invalid_mapping}

  @spec get_lid_for_pn(t(), String.t()) :: {:ok, t(), String.t() | nil}
  def get_lid_for_pn(%__MODULE__{} = store, pn) when is_binary(pn) do
    with {:ok, store, mappings} <- get_lids_for_pns(store, [pn]) do
      {:ok, store, first_mapping_value(mappings, :lid)}
    end
  end

  def get_lid_for_pn(%__MODULE__{} = store, _pn), do: {:ok, store, nil}

  @spec get_lids_for_pns(t(), [String.t()]) :: {:ok, t(), [mapping()] | nil}
  def get_lids_for_pns(%__MODULE__{} = store, pns) when is_list(pns) do
    {store, resolved, pending} =
      Enum.reduce(pns, {store, %{}, []}, fn pn, {acc, resolved, pending} ->
        resolve_pn_lookup(acc, resolved, pending, pn)
      end)

    resolve_pending_pns(store, resolved, pending)
  end

  def get_lids_for_pns(%__MODULE__{} = store, _pns), do: {:ok, store, nil}

  @spec get_pn_for_lid(t(), String.t()) :: {:ok, t(), String.t() | nil}
  def get_pn_for_lid(%__MODULE__{} = store, lid) when is_binary(lid) do
    with {:ok, store, mappings} <- get_pns_for_lids(store, [lid]) do
      {:ok, store, first_mapping_value(mappings, :pn)}
    end
  end

  def get_pn_for_lid(%__MODULE__{} = store, _lid), do: {:ok, store, nil}

  @spec get_pns_for_lids(t(), [String.t()]) :: {:ok, t(), [mapping()] | nil}
  def get_pns_for_lids(%__MODULE__{} = store, lids) when is_list(lids) do
    resolved =
      Enum.reduce(lids, %{}, fn lid, acc ->
        resolve_lid_lookup(store, acc, lid)
      end)

    {:ok, store, values_or_nil(resolved)}
  end

  def get_pns_for_lids(%__MODULE__{} = store, _lids), do: {:ok, store, nil}

  defp resolve_pending_pns(store, resolved, []), do: {:ok, store, values_or_nil(resolved)}

  defp resolve_pending_pns(store, resolved, pending) do
    case fetch_pending_pairs(store, pending) do
      {:ok, updated_store} ->
        fetched =
          Enum.reduce(pending, resolved, fn parsed, acc ->
            merge_fetched_mapping(updated_store, acc, parsed)
          end)

        {:ok, updated_store, values_or_nil(fetched)}
    end
  end

  defp fetch_pending_pairs(%__MODULE__{pn_to_lid_lookup: nil} = store, _pending), do: {:ok, store}

  defp fetch_pending_pairs(%__MODULE__{} = store, pending) do
    lookup_input =
      pending
      |> Enum.map(&normalize_lookup_pn/1)
      |> Enum.uniq()

    fetched = store.pn_to_lid_lookup.(lookup_input) || []
    store_lid_pn_mappings(store, fetched)
  end

  defp normalize_lookup_pn(%{user: user, server: "hosted"}), do: "#{user}@s.whatsapp.net"
  defp normalize_lookup_pn(%{user: user}), do: "#{user}@s.whatsapp.net"

  defp resolve_pn_lookup(store, resolved, pending, pn) do
    case parse_pn(pn) do
      {:ok, parsed} -> resolve_cached_pn(store, resolved, pending, pn, parsed)
      :error -> {store, resolved, pending}
    end
  end

  defp resolve_cached_pn(store, resolved, pending, pn, parsed) do
    case fetch_lid_user(store, parsed.user) do
      {:ok, lid_user} ->
        mapping = %{pn: pn, lid: build_lid(parsed, lid_user)}
        {store, Map.put(resolved, pn, mapping), pending}

      :error ->
        {store, resolved, [parsed | pending]}
    end
  end

  defp resolve_lid_lookup(store, resolved, lid) do
    case parse_lid(lid) do
      {:ok, parsed} -> merge_reverse_mapping(store, resolved, lid, parsed)
      :error -> resolved
    end
  end

  defp merge_reverse_mapping(store, resolved, lid, parsed) do
    case fetch_pn_user(store, parsed.user) do
      {:ok, pn_user} -> Map.put(resolved, lid, %{lid: lid, pn: build_pn(parsed, pn_user)})
      :error -> resolved
    end
  end

  defp merge_fetched_mapping(store, resolved, parsed) do
    case fetch_lid_user(store, parsed.user) do
      {:ok, lid_user} ->
        Map.put(resolved, parsed.original, %{
          pn: parsed.original,
          lid: build_lid(parsed, lid_user)
        })

      :error ->
        resolved
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

  defp put_mapping(%__MODULE__{} = store, pn_user, lid_user) do
    %__MODULE__{
      store
      | entries:
          store.entries
          |> Map.put(forward_key(pn_user), lid_user)
          |> Map.put(reverse_key(lid_user), pn_user)
    }
  end

  defp fetch_lid_user(store, pn_user), do: Map.fetch(store.entries, forward_key(pn_user))
  defp fetch_pn_user(store, lid_user), do: Map.fetch(store.entries, reverse_key(lid_user))
  defp forward_key(pn_user), do: pn_user
  defp reverse_key(lid_user), do: "#{lid_user}_reverse"

  defp parse_pn(jid) do
    case JID.parse(jid) do
      %BaileysEx.JID{user: user, server: server, device: device}
      when is_binary(user) and server in ["s.whatsapp.net", "c.us", "hosted"] ->
        {:ok, %{original: jid, user: user, server: server, device: device || 0}}

      _ ->
        :error
    end
  end

  defp parse_lid(jid) do
    case JID.parse(jid) do
      %BaileysEx.JID{user: user, server: server, device: device}
      when is_binary(user) and server in ["lid", "hosted.lid"] ->
        {:ok, %{original: jid, user: user, server: server, device: device || 0}}

      _ ->
        :error
    end
  end

  defp pn_entry?(jid) do
    match?({:ok, _parsed}, parse_pn(jid))
  end

  defp lid_entry?(jid) do
    match?({:ok, _parsed}, parse_lid(jid))
  end

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
