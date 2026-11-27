defmodule BaileysEx.Connection.EventBuffer do
  @moduledoc false

  alias __MODULE__

  @type keyed :: {[term()], %{optional(term()) => term()}}

  @type t :: %__MODULE__{
          history_sets: map() | nil,
          chat_upserts: keyed(),
          chat_updates: keyed(),
          chat_deletes: keyed(),
          contact_upserts: keyed(),
          contact_updates: keyed(),
          message_upserts: %{type: term(), meta: map(), items: keyed()} | nil,
          message_updates: keyed(),
          message_deletes: keyed(),
          message_reactions: keyed(),
          message_receipts: keyed(),
          group_updates: keyed()
        }

  defstruct history_sets: nil,
            chat_upserts: {[], %{}},
            chat_updates: {[], %{}},
            chat_deletes: {[], %{}},
            contact_upserts: {[], %{}},
            contact_updates: {[], %{}},
            message_upserts: nil,
            message_updates: {[], %{}},
            message_deletes: {[], %{}},
            message_reactions: {[], %{}},
            message_receipts: {[], %{}},
            group_updates: {[], %{}}

  @list_events [
    :chats_upsert,
    :chats_update,
    :chats_delete,
    :contacts_upsert,
    :contacts_update,
    :messages_update,
    :messages_reaction,
    :message_receipt_update,
    :groups_update
  ]

  @spec new() :: t()
  def new, do: %EventBuffer{}

  @spec mergeable?(atom(), term()) :: boolean()
  def mergeable?(:messaging_history_set, data), do: is_map(data)
  def mergeable?(:messages_upsert, %{type: _type, messages: msgs}) when is_list(msgs), do: true
  def mergeable?(:messages_delete, %{keys: keys}) when is_list(keys), do: true
  def mergeable?(event, data) when event in @list_events, do: is_list(data)
  def mergeable?(_event, _data), do: false

  @spec messages_upsert_flush_needed?(t(), map()) :: boolean()
  def messages_upsert_flush_needed?(
        %EventBuffer{message_upserts: %{type: buffered_type, meta: buffered_meta, items: items}},
        %{type: type} = data
      ) do
    incoming_request_id = Map.get(data, :request_id)
    buffered_request_id = Map.get(buffered_meta, :request_id)

    (buffered_type != type or buffered_request_id != incoming_request_id) and
      keyed_non_empty?(items)
  end

  def messages_upsert_flush_needed?(%EventBuffer{}, _data), do: false

  @spec pop_message_upserts(t()) :: {map() | nil, t()}
  def pop_message_upserts(%EventBuffer{message_upserts: nil} = buffer), do: {nil, buffer}

  def pop_message_upserts(%EventBuffer{message_upserts: upserts} = buffer) do
    {build_message_upserts_payload(upserts), %{buffer | message_upserts: nil}}
  end

  @spec append(t(), MapSet.t(), map(), atom(), term()) :: {t(), MapSet.t()}
  def append(%EventBuffer{} = buffer, history_cache, seed, :messaging_history_set, data)
      when is_map(data) do
    buffer = ensure_history_sets(buffer)

    {buffer, history_cache} =
      merge_history_chats(buffer, history_cache, List.wrap(data[:chats]), seed)

    {buffer, history_cache} =
      merge_history_contacts(buffer, history_cache, List.wrap(data[:contacts]))

    {buffer, history_cache} =
      merge_history_messages(buffer, history_cache, List.wrap(data[:messages]))

    buffer =
      buffer
      |> merge_history_past_participants(List.wrap(data[:past_participants]))
      |> merge_history_lid_pn_mappings(List.wrap(data[:lid_pn_mappings]))
      |> merge_history_fields(data)

    {buffer, history_cache}
  end

  def append(%EventBuffer{} = buffer, history_cache, seed, :chats_upsert, chats)
      when is_list(chats) do
    {Enum.reduce(chats, buffer, &append_chat_upsert(&2, seed, &1)), history_cache}
  end

  def append(%EventBuffer{} = buffer, history_cache, seed, :chats_update, updates)
      when is_list(updates) do
    {Enum.reduce(updates, buffer, &append_chat_update(&2, seed, &1)), history_cache}
  end

  def append(%EventBuffer{} = buffer, history_cache, _seed, :chats_delete, ids)
      when is_list(ids) do
    {Enum.reduce(ids, buffer, &append_chat_delete(&2, &1)), history_cache}
  end

  def append(%EventBuffer{} = buffer, history_cache, _seed, :contacts_upsert, contacts)
      when is_list(contacts) do
    {Enum.reduce(contacts, buffer, &append_contact_upsert(&2, &1)), history_cache}
  end

  def append(%EventBuffer{} = buffer, history_cache, _seed, :contacts_update, updates)
      when is_list(updates) do
    {Enum.reduce(updates, buffer, &append_contact_update(&2, &1)), history_cache}
  end

  def append(
        %EventBuffer{} = buffer,
        history_cache,
        _seed,
        :messages_upsert,
        %{type: type, messages: messages} = data
      )
      when is_list(messages) do
    meta = Map.drop(data, [:type, :messages])
    {Enum.reduce(messages, buffer, &append_message_upsert(&2, type, meta, &1)), history_cache}
  end

  def append(%EventBuffer{} = buffer, history_cache, _seed, :messages_update, updates)
      when is_list(updates) do
    {Enum.reduce(updates, buffer, &append_message_update(&2, &1)), history_cache}
  end

  def append(%EventBuffer{} = buffer, history_cache, _seed, :messages_delete, %{keys: keys})
      when is_list(keys) do
    {Enum.reduce(keys, buffer, &append_message_delete(&2, &1)), history_cache}
  end

  def append(%EventBuffer{} = buffer, history_cache, _seed, :messages_reaction, reactions)
      when is_list(reactions) do
    {Enum.reduce(reactions, buffer, &append_message_reaction(&2, &1)), history_cache}
  end

  def append(%EventBuffer{} = buffer, history_cache, _seed, :message_receipt_update, receipts)
      when is_list(receipts) do
    {Enum.reduce(receipts, buffer, &append_message_receipt(&2, &1)), history_cache}
  end

  def append(%EventBuffer{} = buffer, history_cache, _seed, :groups_update, updates)
      when is_list(updates) do
    group_updates =
      Enum.reduce(updates, buffer.group_updates, fn update, acc ->
        keyed_put(acc, item_id(update), update, &merge_fields/2)
      end)

    {%{buffer | group_updates: group_updates}, history_cache}
  end

  @spec flush(t(), map()) :: {map(), t()}
  def flush(%EventBuffer{} = buffer, seed) do
    eval_seed = effective_seed(seed, buffer)

    {buffer, ready_chat_updates, pending_chat_updates} =
      resolve_chat_updates_for_flush(buffer, eval_seed)

    events =
      %{}
      |> maybe_put_history_set(buffer.history_sets)
      |> maybe_put_keyed(:chats_upsert, buffer.chat_upserts)
      |> maybe_put_non_empty(:chats_update, ready_chat_updates)
      |> maybe_put_keyed(:chats_delete, buffer.chat_deletes)
      |> maybe_put_keyed(:contacts_upsert, buffer.contact_upserts)
      |> maybe_put_keyed(:contacts_update, buffer.contact_updates)
      |> maybe_put_message_upserts(buffer.message_upserts)
      |> maybe_put_keyed(:messages_update, buffer.message_updates)
      |> maybe_put_message_deletes(buffer.message_deletes)
      |> maybe_put_non_empty(:messages_reaction, flatten_reactions(buffer.message_reactions))
      |> maybe_put_non_empty(:message_receipt_update, flatten_receipts(buffer.message_receipts))
      |> maybe_put_keyed(:groups_update, buffer.group_updates)

    remaining_buffer = %EventBuffer{chat_updates: pending_chat_updates}
    {events, remaining_buffer}
  end

  # -- History set consolidation --

  defp ensure_history_sets(%EventBuffer{history_sets: nil} = buffer) do
    %{
      buffer
      | history_sets: %{
          chats: keyed_new(),
          contacts: keyed_new(),
          messages: keyed_new(),
          past_participants: keyed_new(),
          lid_pn_mappings: keyed_new(),
          fields: %{}
        }
    }
  end

  defp ensure_history_sets(%EventBuffer{} = buffer), do: buffer

  defp merge_history_chats(buffer, history_cache, chats, seed) do
    Enum.reduce(chats, {buffer, history_cache}, &merge_history_chat(&2, &1, seed))
  end

  defp merge_history_chat({acc, cache}, chat, seed) do
    id = item_id(chat)

    case keyed_get(acc.history_sets.chats, id) do
      nil ->
        insert_uncached_history_chat(acc, cache, id, chat, seed)

      existing ->
        updated =
          Map.put(
            existing,
            :end_of_history_transfer_type,
            Map.get(chat, :end_of_history_transfer_type)
          )

        {put_history_chat(acc, id, updated), cache}
    end
  end

  defp insert_uncached_history_chat(acc, cache, id, chat, seed) do
    cache_key = if is_nil(id), do: nil, else: {:chat, id}

    if is_nil(cache_key) or not MapSet.member?(cache, cache_key) do
      next_acc =
        acc
        |> put_history_chat(id, chat)
        |> absorb_pending_chat_update(seed, :history, id)

      {next_acc, maybe_put_cache(cache, cache_key)}
    else
      {acc, cache}
    end
  end

  defp put_history_chat(buffer, id, chat) do
    put_in(
      buffer.history_sets.chats,
      keyed_put(buffer.history_sets.chats, id, chat, fn _o, n -> n end)
    )
  end

  defp merge_history_contacts(buffer, history_cache, contacts) do
    {merged, next_cache} =
      Enum.reduce(contacts, {buffer.history_sets.contacts, history_cache}, fn contact,
                                                                              {acc, cache} ->
        id = item_id(contact)

        if keyed_has_key?(acc, id) do
          {keyed_put(acc, id, contact, &merge_fields/2), cache}
        else
          merge_uncached_history_contact(acc, cache, id, contact)
        end
      end)

    {put_in(buffer.history_sets.contacts, merged), next_cache}
  end

  defp merge_uncached_history_contact(acc, cache, id, contact) do
    cache_key = if is_nil(id), do: nil, else: {:contact, id}

    if is_nil(cache_key) or not MapSet.member?(cache, cache_key) or contact_has_name?(contact) do
      next_acc = keyed_put(acc, id, contact, &merge_fields/2)
      next_cache = if cache_key, do: MapSet.put(cache, cache_key), else: cache
      {next_acc, next_cache}
    else
      {acc, cache}
    end
  end

  defp contact_has_name?(contact) when is_map(contact) do
    truthy_string?(Map.get(contact, :notify)) or
      truthy_string?(Map.get(contact, :name)) or
      truthy_string?(Map.get(contact, :verified_name))
  end

  defp contact_has_name?(_contact), do: false

  defp truthy_string?(value) when is_binary(value) and value != "", do: true
  defp truthy_string?(_value), do: false

  defp merge_history_messages(buffer, history_cache, messages) do
    {merged, next_cache} =
      Enum.reduce(
        messages,
        {buffer.history_sets.messages, history_cache},
        &merge_history_message(&2, &1)
      )

    {put_in(buffer.history_sets.messages, merged), next_cache}
  end

  defp merge_history_message({acc, cache}, message) do
    key = message_key_id(message)
    cache_key = if is_nil(key), do: nil, else: {:msg, key}

    if not keyed_has_key?(acc, key) and
         (is_nil(cache_key) or not MapSet.member?(cache, cache_key)) do
      {keyed_put(acc, key, message, fn old, _new -> old end), maybe_put_cache(cache, cache_key)}
    else
      {acc, cache}
    end
  end

  defp maybe_put_cache(cache, nil), do: cache
  defp maybe_put_cache(cache, key), do: MapSet.put(cache, key)

  defp merge_history_past_participants(buffer, entries) do
    merged =
      Enum.reduce(entries, buffer.history_sets.past_participants, fn entry, acc ->
        key = past_participants_group_key(entry)
        keyed_put(acc, key, entry, &merge_past_participants_entry/2)
      end)

    put_in(buffer.history_sets.past_participants, merged)
  end

  defp past_participants_group_key(%{group_jid: group_jid}) when is_binary(group_jid),
    do: group_jid

  defp past_participants_group_key(%{"group_jid" => group_jid}) when is_binary(group_jid),
    do: group_jid

  defp past_participants_group_key(entry), do: entry

  defp merge_past_participants_entry(existing, incoming)
       when is_map(existing) and is_map(incoming) do
    existing_list = List.wrap(Map.get(existing, :past_participants))
    incoming_list = List.wrap(Map.get(incoming, :past_participants))

    seen = MapSet.new(existing_list, &past_participant_sig/1)

    {deduped_rev, _seen} =
      Enum.reduce(incoming_list, {Enum.reverse(existing_list), seen}, fn participant,
                                                                         {acc, set} ->
        sig = past_participant_sig(participant)

        if MapSet.member?(set, sig) do
          {acc, set}
        else
          {[participant | acc], MapSet.put(set, sig)}
        end
      end)

    Map.put(existing, :past_participants, Enum.reverse(deduped_rev))
  end

  defp merge_past_participants_entry(existing, _incoming), do: existing

  defp past_participant_sig(participant) when is_map(participant) do
    {
      Map.get(participant, :user_jid),
      Map.get(participant, :leave_ts),
      Map.get(participant, :leave_reason)
    }
  end

  defp past_participant_sig(participant), do: participant

  defp merge_history_lid_pn_mappings(buffer, mappings) do
    merged =
      Enum.reduce(mappings, buffer.history_sets.lid_pn_mappings, fn mapping, acc ->
        keyed_put(acc, mapping, mapping, fn old, _new -> old end)
      end)

    put_in(buffer.history_sets.lid_pn_mappings, merged)
  end

  defp merge_history_fields(buffer, data) do
    fields =
      Map.drop(data, [:chats, :contacts, :messages, :past_participants, :lid_pn_mappings])

    merged_fields =
      buffer.history_sets.fields
      |> Map.merge(fields)
      |> Map.put(
        :is_latest,
        fields[:is_latest] == true or buffer.history_sets.fields[:is_latest] == true
      )

    put_in(buffer.history_sets.fields, merged_fields)
  end

  # -- Chat consolidation --

  defp append_chat_upsert(buffer, seed, chat) do
    id = item_id(chat)
    buffer = %{buffer | chat_deletes: keyed_delete(buffer.chat_deletes, id)}

    if history_has_chat?(buffer, id) do
      updated_history_chats =
        keyed_put(buffer.history_sets.chats, id, chat, &concat_chats/2)

      buffer
      |> put_in([Access.key(:history_sets), :chats], updated_history_chats)
      |> absorb_pending_chat_update(seed, :history, id)
    else
      updated_upserts = keyed_put(buffer.chat_upserts, id, chat, &concat_chats/2)

      %{buffer | chat_upserts: updated_upserts}
      |> absorb_pending_chat_update(seed, :upsert, id)
    end
  end

  defp append_chat_update(buffer, seed, update) do
    id = item_id(update)
    buffer = %{buffer | chat_deletes: keyed_delete(buffer.chat_deletes, id)}
    eval_seed = effective_seed(seed, buffer)

    case evaluate_chat_update(update, eval_seed) do
      {:emit, resolved_update} ->
        apply_resolved_chat_update(buffer, id, resolved_update)

      {:pending, pending_update} ->
        %{
          buffer
          | chat_updates:
              keyed_put(buffer.chat_updates, id, pending_update, fn _old, new -> new end)
        }

      :drop ->
        buffer
    end
  end

  defp apply_resolved_chat_update(buffer, id, update) do
    cond do
      history_has_chat?(buffer, id) ->
        put_in(
          buffer.history_sets.chats,
          keyed_put(buffer.history_sets.chats, id, update, &concat_chats/2)
        )

      keyed_has_key?(buffer.chat_upserts, id) ->
        %{buffer | chat_upserts: keyed_put(buffer.chat_upserts, id, update, &concat_chats/2)}

      true ->
        %{buffer | chat_updates: keyed_put(buffer.chat_updates, id, update, &concat_chats/2)}
    end
  end

  defp absorb_pending_chat_update(buffer, seed, target, id) when not is_nil(id) do
    case keyed_get(buffer.chat_updates, id) do
      nil ->
        buffer

      update ->
        eval_seed = effective_seed(seed, buffer)
        apply_absorbed_chat_update(buffer, target, id, evaluate_chat_update(update, eval_seed))
    end
  end

  defp absorb_pending_chat_update(buffer, _seed, _target, _id), do: buffer

  defp apply_absorbed_chat_update(buffer, :history, id, {:emit, resolved}) do
    existing = keyed_get(buffer.history_sets.chats, id)
    merged = concat_chats(resolved, existing)

    buffer
    |> put_in(
      [Access.key(:history_sets), :chats],
      keyed_put(buffer.history_sets.chats, id, merged, fn _o, n -> n end)
    )
    |> Map.put(:chat_updates, keyed_delete(buffer.chat_updates, id))
  end

  defp apply_absorbed_chat_update(buffer, :upsert, id, {:emit, resolved}) do
    existing = keyed_get(buffer.chat_upserts, id)
    merged = concat_chats(resolved, existing)

    %{
      buffer
      | chat_upserts: keyed_put(buffer.chat_upserts, id, merged, fn _o, n -> n end),
        chat_updates: keyed_delete(buffer.chat_updates, id)
    }
  end

  defp apply_absorbed_chat_update(buffer, _target, id, :drop) do
    %{buffer | chat_updates: keyed_delete(buffer.chat_updates, id)}
  end

  defp apply_absorbed_chat_update(buffer, _target, _id, {:pending, _update}), do: buffer

  defp append_chat_delete(buffer, id) do
    buffer = %{
      buffer
      | chat_deletes: keyed_put(buffer.chat_deletes, id, id, fn old, _new -> old end),
        chat_updates: keyed_delete(buffer.chat_updates, id),
        chat_upserts: keyed_delete(buffer.chat_upserts, id)
    }

    if buffer.history_sets do
      put_in(buffer.history_sets.chats, keyed_delete(buffer.history_sets.chats, id))
    else
      buffer
    end
  end

  defp resolve_chat_updates_for_flush(buffer, eval_seed) do
    {buffer, ready_rev, pending} =
      buffer.chat_updates
      |> keyed_values()
      |> Enum.reduce(
        {buffer, [], keyed_new()},
        &resolve_chat_update_for_flush(&1, &2, eval_seed)
      )

    {buffer, Enum.reverse(ready_rev), pending}
  end

  defp resolve_chat_update_for_flush(update, {buf, ready, pend}, eval_seed) do
    id = item_id(update)

    case evaluate_chat_update(update, eval_seed) do
      {:emit, resolved} ->
        fold_flushed_chat_update(buf, ready, pend, id, resolved)

      {:pending, pending_update} ->
        {buf, ready, keyed_put(pend, id, pending_update, fn _old, new -> new end)}

      :drop ->
        {buf, ready, pend}
    end
  end

  defp fold_flushed_chat_update(buf, ready, pend, id, resolved) do
    cond do
      history_has_chat?(buf, id) ->
        updated =
          put_in(
            buf.history_sets.chats,
            keyed_put(buf.history_sets.chats, id, resolved, &concat_chats/2)
          )

        {updated, ready, pend}

      keyed_has_key?(buf.chat_upserts, id) ->
        updated = %{
          buf
          | chat_upserts: keyed_put(buf.chat_upserts, id, resolved, &concat_chats/2)
        }

        {updated, ready, pend}

      true ->
        {buf, [resolved | ready], pend}
    end
  end

  # -- Contact consolidation --

  defp append_contact_upsert(buffer, contact) do
    id = item_id(contact)

    {contact, contact_updates} =
      case keyed_get(buffer.contact_updates, id) do
        nil -> {contact, buffer.contact_updates}
        pending -> {merge_fields(pending, contact), keyed_delete(buffer.contact_updates, id)}
      end

    buffer = %{buffer | contact_updates: contact_updates}

    if history_has_contact?(buffer, id) do
      put_in(
        buffer.history_sets.contacts,
        keyed_put(buffer.history_sets.contacts, id, contact, &merge_fields/2)
      )
    else
      %{buffer | contact_upserts: keyed_put(buffer.contact_upserts, id, contact, &merge_fields/2)}
    end
  end

  defp append_contact_update(buffer, update) do
    id = item_id(update)

    cond do
      history_has_contact?(buffer, id) ->
        put_in(
          buffer.history_sets.contacts,
          keyed_put(buffer.history_sets.contacts, id, update, &merge_fields/2)
        )

      keyed_has_key?(buffer.contact_upserts, id) ->
        %{
          buffer
          | contact_upserts: keyed_put(buffer.contact_upserts, id, update, &merge_fields/2)
        }

      true ->
        %{
          buffer
          | contact_updates: keyed_put(buffer.contact_updates, id, update, &merge_fields/2)
        }
    end
  end

  # -- Message consolidation --

  defp append_message_upsert(buffer, type, meta, message) do
    key = message_key_id(message)
    existing = find_existing_message(buffer, key)
    message = maybe_preserve_timestamp(message, existing)

    {message, message_updates} =
      case keyed_get(buffer.message_updates, key) do
        %{update: pending_patch} when is_map(pending_patch) ->
          {Map.merge(message, pending_patch), keyed_delete(buffer.message_updates, key)}

        _ ->
          {message, buffer.message_updates}
      end

    buffer = %{buffer | message_updates: message_updates}

    if history_has_message?(buffer, key) do
      put_in(
        buffer.history_sets.messages,
        keyed_put(buffer.history_sets.messages, key, message, fn _old, new -> new end)
      )
    else
      put_message_upsert(buffer, type, meta, key, message)
    end
  end

  defp put_message_upsert(%EventBuffer{message_upserts: nil} = buffer, type, meta, key, message) do
    %{
      buffer
      | message_upserts: %{
          type: type,
          meta: meta,
          items: keyed_put(keyed_new(), key, message, fn _old, new -> new end)
        }
    }
  end

  defp put_message_upsert(
         %EventBuffer{
           message_upserts: %{type: existing_type, meta: existing_meta, items: items}
         } = buffer,
         type,
         meta,
         key,
         message
       ) do
    merged_type = if type == :notify or existing_type == :notify, do: :notify, else: type

    %{
      buffer
      | message_upserts: %{
          type: merged_type,
          meta: Map.merge(existing_meta, meta),
          items: keyed_put(items, key, message, fn _old, new -> new end)
        }
    }
  end

  defp append_message_update(buffer, item) do
    key = message_key_id(item)
    patch = Map.get(item, :update) || %{}

    cond do
      history_has_message?(buffer, key) ->
        put_in(
          buffer.history_sets.messages,
          keyed_put(buffer.history_sets.messages, key, patch, fn old, p -> Map.merge(old, p) end)
        )

      message_upserts_has_key?(buffer, key) ->
        put_in(
          buffer.message_upserts.items,
          keyed_put(buffer.message_upserts.items, key, patch, fn old, p -> Map.merge(old, p) end)
        )

      true ->
        updated =
          keyed_put(buffer.message_updates, key, item, fn old, new ->
            Map.put(
              old,
              :update,
              Map.merge(Map.get(old, :update) || %{}, Map.get(new, :update) || %{})
            )
          end)

        %{buffer | message_updates: updated}
    end
  end

  defp append_message_delete(buffer, key) do
    k = key_id(key)

    message_upserts =
      case buffer.message_upserts do
        %{items: items} = upserts -> %{upserts | items: keyed_delete(items, k)}
        nil -> nil
      end

    %{
      buffer
      | message_deletes: keyed_put(buffer.message_deletes, k, key, fn old, _new -> old end),
        message_upserts: message_upserts,
        message_updates: keyed_delete(buffer.message_updates, k)
    }
  end

  defp append_message_reaction(buffer, %{key: key, reaction: reaction}) when is_map(reaction) do
    k = key_id(key)

    if message_upserts_has_key?(buffer, k) do
      put_in(
        buffer.message_upserts.items,
        keyed_put(buffer.message_upserts.items, k, reaction, &update_message_with_reaction/2)
      )
    else
      updated =
        keyed_put(
          buffer.message_reactions,
          k,
          update_message_with_reaction(%{key: key, reactions: []}, reaction),
          fn existing, _incoming -> update_message_with_reaction(existing, reaction) end
        )

      %{buffer | message_reactions: updated}
    end
  end

  defp append_message_reaction(buffer, _other), do: buffer

  defp append_message_receipt(buffer, %{key: key, receipt: receipt}) when is_map(receipt) do
    k = key_id(key)

    if message_upserts_has_key?(buffer, k) do
      put_in(
        buffer.message_upserts.items,
        keyed_put(buffer.message_upserts.items, k, receipt, &update_message_with_receipt/2)
      )
    else
      updated =
        keyed_put(
          buffer.message_receipts,
          k,
          update_message_with_receipt(%{key: key, user_receipt: []}, receipt),
          fn existing, _incoming -> update_message_with_receipt(existing, receipt) end
        )

      %{buffer | message_receipts: updated}
    end
  end

  defp append_message_receipt(buffer, _other), do: buffer

  defp update_message_with_reaction(target, reaction) when is_map(target) and is_map(reaction) do
    author = reaction_author(Map.get(reaction, :key))
    normalized = Map.update(reaction, :text, "", &(&1 || ""))

    existing =
      target
      |> Map.get(:reactions, [])
      |> List.wrap()
      |> Enum.reject(&(reaction_author(Map.get(&1, :key)) == author))

    Map.put(target, :reactions, existing ++ [normalized])
  end

  defp reaction_author(%{} = key) do
    if Map.get(key, :from_me) == true do
      "me"
    else
      Map.get(key, :participant_alt) ||
        Map.get(key, :remote_jid_alt) ||
        Map.get(key, :participant) ||
        Map.get(key, :remote_jid) || ""
    end
  end

  defp reaction_author(_key), do: ""

  defp update_message_with_receipt(target, receipt) when is_map(target) and is_map(receipt) do
    user_jid = Map.get(receipt, :user_jid)
    existing = target |> Map.get(:user_receipt, []) |> List.wrap()

    updated =
      case Enum.find_index(existing, &(Map.get(&1, :user_jid) == user_jid)) do
        nil -> existing ++ [receipt]
        idx -> List.update_at(existing, idx, &Map.merge(&1, receipt))
      end

    Map.put(target, :user_receipt, updated)
  end

  defp flatten_reactions(keyed) do
    Enum.flat_map(keyed_values(keyed), fn %{key: key, reactions: reactions} ->
      Enum.map(reactions, &%{key: key, reaction: &1})
    end)
  end

  defp flatten_receipts(keyed) do
    Enum.flat_map(keyed_values(keyed), fn %{key: key, user_receipt: receipts} ->
      Enum.map(receipts, &%{key: key, receipt: &1})
    end)
  end

  # -- Helpers --

  defp effective_seed(seed, %EventBuffer{} = buffer) do
    history_chats =
      case buffer.history_sets do
        %{chats: {_order, items}} -> items
        nil -> %{}
      end

    {_order, upsert_chats} = buffer.chat_upserts

    seed
    |> merge_seed_chats(:historySets, :history_sets, history_chats)
    |> merge_seed_flat(:chatUpserts, :chat_upserts, upsert_chats)
  end

  defp merge_seed_chats(seed, _camel, _snake, chats) when map_size(chats) == 0, do: seed

  defp merge_seed_chats(seed, camel, snake, chats) do
    merged =
      seed
      |> get_in([camel, :chats])
      |> Kernel.||(%{})
      |> Map.merge(chats)

    seed
    |> Map.put(camel, %{chats: merged})
    |> Map.put(snake, %{chats: merged})
  end

  defp merge_seed_flat(seed, _camel, _snake, chats) when map_size(chats) == 0, do: seed

  defp merge_seed_flat(seed, camel, snake, chats) do
    merged =
      seed
      |> Map.get(camel, %{})
      |> Map.merge(chats)

    seed
    |> Map.put(camel, merged)
    |> Map.put(snake, merged)
  end

  defp evaluate_chat_update(%{conditional: condition} = update, seed)
       when is_function(condition, 1) do
    case condition.(seed) do
      true -> {:emit, Map.delete(update, :conditional)}
      nil -> {:pending, update}
      _ -> :drop
    end
  end

  defp evaluate_chat_update(update, _seed), do: {:emit, update}

  defp concat_chats(a, b) when is_map(a) and is_map(b) do
    {a, b} = normalize_cleared_unread_count(a, b)
    b = merge_unread_count(a, b)
    Map.merge(a, b)
  end

  defp concat_chats(_a, b), do: b

  defp normalize_cleared_unread_count(%{unread_count: a_count} = a, %{unread_count: nil} = b)
       when is_integer(a_count) and a_count < 0 do
    {Map.delete(a, :unread_count), Map.delete(b, :unread_count)}
  end

  defp normalize_cleared_unread_count(a, b), do: {a, b}

  defp merge_unread_count(%{unread_count: a_count}, %{unread_count: b_count} = b)
       when is_integer(a_count) and is_integer(b_count) and b_count >= 0 do
    Map.put(b, :unread_count, max(b_count, 0) + max(a_count, 0))
  end

  defp merge_unread_count(_a, b), do: b

  defp find_existing_message(_buffer, nil), do: nil

  defp find_existing_message(buffer, key) do
    from_upserts =
      case buffer.message_upserts do
        %{items: items} -> keyed_get(items, key)
        nil -> nil
      end

    from_upserts ||
      case buffer.history_sets do
        %{messages: messages} -> keyed_get(messages, key)
        nil -> nil
      end
  end

  defp maybe_preserve_timestamp(message, %{message_timestamp: ts})
       when is_map(message) and not is_nil(ts) do
    Map.put(message, :message_timestamp, ts)
  end

  defp maybe_preserve_timestamp(message, _existing), do: message

  defp history_has_chat?(%EventBuffer{history_sets: %{chats: chats}}, id),
    do: keyed_has_key?(chats, id)

  defp history_has_chat?(_buffer, _id), do: false

  defp history_has_contact?(%EventBuffer{history_sets: %{contacts: contacts}}, id),
    do: keyed_has_key?(contacts, id)

  defp history_has_contact?(_buffer, _id), do: false

  defp history_has_message?(%EventBuffer{history_sets: %{messages: messages}}, key),
    do: keyed_has_key?(messages, key)

  defp history_has_message?(_buffer, _key), do: false

  defp message_upserts_has_key?(%EventBuffer{message_upserts: %{items: items}}, key),
    do: keyed_has_key?(items, key)

  defp message_upserts_has_key?(_buffer, _key), do: false

  # -- Flush output builders --

  defp maybe_put_history_set(events, nil), do: events

  defp maybe_put_history_set(events, acc) do
    past_participants = keyed_values(acc.past_participants)

    payload =
      acc.fields
      |> Map.put(:chats, keyed_values(acc.chats))
      |> Map.put(:contacts, keyed_values(acc.contacts))
      |> Map.put(:messages, keyed_values(acc.messages))
      |> Map.put(:lid_pn_mappings, keyed_values(acc.lid_pn_mappings))
      |> maybe_put_non_empty(:past_participants, past_participants)

    Map.put(events, :messaging_history_set, payload)
  end

  defp maybe_put_keyed(events, key, keyed) do
    maybe_put_non_empty(events, key, keyed_values(keyed))
  end

  defp maybe_put_message_upserts(events, nil), do: events

  defp maybe_put_message_upserts(events, upserts) do
    case build_message_upserts_payload(upserts) do
      nil -> events
      payload -> Map.put(events, :messages_upsert, payload)
    end
  end

  defp build_message_upserts_payload(%{type: type, meta: meta, items: items}) do
    case keyed_values(items) do
      [] ->
        nil

      messages ->
        meta
        |> Map.put(:messages, messages)
        |> Map.put(:type, type)
    end
  end

  defp maybe_put_message_deletes(events, keyed) do
    case keyed_values(keyed) do
      [] -> events
      keys -> Map.put(events, :messages_delete, %{keys: keys})
    end
  end

  defp maybe_put_non_empty(map, _key, []), do: map
  defp maybe_put_non_empty(map, key, list), do: Map.put(map, key, list)

  # -- Keyed ordered-map helpers --

  defp keyed_new, do: {[], %{}}

  defp keyed_non_empty?({_order, items}), do: map_size(items) > 0

  defp keyed_has_key?(_keyed, nil), do: false
  defp keyed_has_key?({_order, items}, key), do: Map.has_key?(items, key)

  defp keyed_get(_keyed, nil), do: nil
  defp keyed_get({_order, items}, key), do: Map.get(items, key)

  defp keyed_put({order, items}, nil, item, _merge) do
    ref = make_ref()
    {[ref | order], Map.put(items, ref, item)}
  end

  defp keyed_put({order, items}, key, item, merge) do
    case items do
      %{^key => old} -> {order, Map.put(items, key, merge.(old, item))}
      _ -> {[key | order], Map.put(items, key, item)}
    end
  end

  defp keyed_delete(keyed, nil), do: keyed

  defp keyed_delete({order, items}, key) do
    if Map.has_key?(items, key) do
      {List.delete(order, key), Map.delete(items, key)}
    else
      {order, items}
    end
  end

  defp keyed_values({order, items}) do
    order
    |> Enum.reverse()
    |> Enum.map(&Map.fetch!(items, &1))
  end

  defp item_id(%{id: id}) when not is_nil(id), do: id
  defp item_id(_item), do: nil

  defp message_key_id(%{key: key}) when is_map(key), do: key_id(key)
  defp message_key_id(_item), do: nil

  defp key_id(%{} = key),
    do: {Map.get(key, :remote_jid), Map.get(key, :id), Map.get(key, :from_me) == true}

  defp key_id(_key), do: nil

  defp merge_fields(old, new) when is_map(old) and is_map(new) do
    non_nil =
      new
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    Map.merge(old, non_nil)
  end

  defp merge_fields(_old, new), do: new
end
