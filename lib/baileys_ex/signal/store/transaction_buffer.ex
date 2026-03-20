defmodule BaileysEx.Signal.Store.TransactionBuffer do
  @moduledoc false

  @missing :"$signal_store_missing"
  @clear_key :"$signal_store_clear"

  @spec new() :: :ets.tid()
  def new do
    :ets.new(__MODULE__, [:set, :private])
  end

  @spec delete(:ets.tid()) :: true
  def delete(table), do: :ets.delete(table)

  @spec clear(:ets.tid()) :: :ok
  def clear(table) do
    true = :ets.delete_all_objects(table)
    true = :ets.insert(table, {@clear_key, true})
    :ok
  end

  @spec cleared?(:ets.tid()) :: boolean()
  def cleared?(table) do
    match?([{@clear_key, true}], :ets.lookup(table, @clear_key))
  end

  @spec cached_entries(:ets.tid(), term(), [String.t()]) :: {map(), [String.t()]}
  def cached_entries(table, type, ids) do
    Enum.reduce(ids, {%{}, []}, fn id, {entries, missing_ids} ->
      case :ets.lookup(table, {:cache, type, id}) do
        [{{:cache, ^type, ^id}, @missing}] ->
          {entries, missing_ids}

        [{{:cache, ^type, ^id}, value}] ->
          {Map.put(entries, id, value), missing_ids}

        [] ->
          {entries, [id | missing_ids]}
      end
    end)
    |> then(fn {entries, missing_ids} -> {entries, Enum.reverse(missing_ids)} end)
  end

  @spec cache_fetched(:ets.tid(), term(), [String.t()], map()) :: :ok
  def cache_fetched(table, type, ids, fetched) do
    Enum.each(ids, fn id ->
      put_cache(table, type, id, Map.get(fetched, id, @missing))
    end)

    :ok
  end

  @spec put_entries(:ets.tid(), map()) :: :ok
  def put_entries(table, data) do
    Enum.each(data, fn {type, entries} ->
      Enum.each(entries, fn {id, value} ->
        put_entry(table, type, id, value)
      end)
    end)

    :ok
  end

  @spec put_entry(:ets.tid(), term(), String.t(), term()) :: :ok
  def put_entry(table, type, id, value) do
    put_cache(table, type, id, normalize_cache_value(value))
    true = :ets.insert(table, {{:mutation, type, id}, value})
    :ok
  end

  @spec mutation_data(:ets.tid()) :: map()
  def mutation_data(table) do
    table
    |> :ets.tab2list()
    |> Enum.reduce(%{}, fn
      {{:mutation, type, id}, value}, acc ->
        update_in(acc, [type], fn entries -> Map.put(entries || %{}, id, value) end)

      _other, acc ->
        acc
    end)
  end

  defp put_cache(table, type, id, value) do
    true = :ets.insert(table, {{:cache, type, id}, value})
    :ok
  end

  defp normalize_cache_value(nil), do: @missing
  defp normalize_cache_value(value), do: value
end
