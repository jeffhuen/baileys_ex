defmodule BaileysEx.Auth.KeyStore do
  @moduledoc """
  Persistence-backed transactional Signal key store.

  This module wraps an auth persistence backend with the same `get/3`, `set/2`,
  and `transaction/3` shape used by the runtime `Signal.Store` contract. Reads
  go through ETS, transaction work is cached in the caller process, and commit
  failures roll back to the previous persisted snapshot before surfacing an
  error to the caller.
  """

  use GenServer

  @behaviour BaileysEx.Signal.Store

  alias BaileysEx.Auth.FilePersistence

  @missing :"$missing"

  defmodule OperationError do
    @moduledoc false

    defexception [:action, :reason]

    @impl true
    def message(%__MODULE__{action: action, reason: reason}) do
      "auth key store #{action} failed: #{inspect(reason)}"
    end
  end

  defmodule Ref do
    @moduledoc false

    @enforce_keys [:pid, :table]
    defstruct [:pid, :table]

    @type t :: %__MODULE__{pid: pid(), table: :ets.tid()}
  end

  @type state :: %{
          table: :ets.tid(),
          persistence_module: module(),
          persistence_context: term(),
          locks: map(),
          monitor_keys: map(),
          known_ids: map(),
          max_commit_retries: pos_integer(),
          delay_between_tries_ms: non_neg_integer()
        }

  @doc """
  Starts the transactional key store linked to the current process.
  """
  @impl true
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  @doc """
  Creates a read-only query ref struct to pass directly into reads.
  """
  @impl true
  @spec wrap(pid()) :: Ref.t()
  def wrap(pid) when is_pid(pid) do
    %Ref{pid: pid, table: GenServer.call(pid, :table)}
  end

  @doc """
  Fetches an array of identifiers for a given data type.
  """
  @impl true
  @spec get(Ref.t(), BaileysEx.Signal.Store.data_type(), [String.t()]) ::
          BaileysEx.Signal.Store.data_entries()
  def get(%Ref{} = ref, type, ids) when is_list(ids) do
    case current_tx(ref) do
      nil ->
        {entries, missing_ids} = read_cached_entries(ref.table, type, ids)
        merge_fetched_missing(entries, ref, type, missing_ids)

      context ->
        read_entries_in_transaction(ref, context, type, ids)
    end
  end

  @doc """
  Sets arbitrary mutations into the persistence backend.
  """
  @impl true
  @spec set(Ref.t(), BaileysEx.Signal.Store.data_set()) :: :ok
  def set(%Ref{} = ref, data) when is_map(data) do
    case current_tx(ref) do
      nil ->
        case GenServer.call(ref.pid, {:set, data}, :infinity) do
          :ok -> :ok
          {:error, reason} -> raise OperationError, action: :set, reason: reason
        end

      context ->
        ref
        |> merge_transaction_data(context, data)
        |> then(&update_tx(ref, &1))

        :ok
    end
  end

  @doc """
  Clears all keys from persistence.
  """
  @impl true
  @spec clear(Ref.t()) :: :ok
  def clear(%Ref{} = ref) do
    case GenServer.call(ref.pid, :clear, :infinity) do
      :ok -> :ok
      {:error, reason} -> raise OperationError, action: :clear, reason: reason
    end
  end

  @doc """
  Acquires an exclusive lock tied to `key` before running the `fun`.
  Errors safely roll back changes if commit fails.
  """
  @impl true
  @spec transaction(Ref.t(), String.t(), (-> result)) :: result when result: var
  def transaction(%Ref{} = ref, key, fun) when is_binary(key) and is_function(fun, 0) do
    case current_tx(ref) do
      nil ->
        :ok = GenServer.call(ref.pid, {:lock, key, self()}, :infinity)
        update_tx(ref, %{cache: %{}, mutations: %{}})

        try do
          result = fun.()

          case GenServer.call(ref.pid, {:set, current_tx(ref).mutations}, :infinity) do
            :ok -> result
            {:error, reason} -> raise OperationError, action: :transaction, reason: reason
          end
        after
          clear_tx(ref)
          :ok = GenServer.call(ref.pid, {:unlock, key, self()}, :infinity)
        end

      _existing ->
        fun.()
    end
  end

  @doc """
  Returns true if the current process is in an active transaction context.
  """
  @impl true
  @spec in_transaction?(Ref.t()) :: boolean()
  def in_transaction?(%Ref{} = ref), do: not is_nil(current_tx(ref))

  @impl true
  def init(opts) do
    table = :ets.new(__MODULE__, [:set, :protected, read_concurrency: true])

    {:ok,
     %{
       table: table,
       persistence_module: Keyword.get(opts, :persistence_module, FilePersistence),
       persistence_context: Keyword.get(opts, :persistence_context),
       locks: %{},
       monitor_keys: %{},
       known_ids: %{},
       max_commit_retries: Keyword.get(opts, :max_commit_retries, 10),
       delay_between_tries_ms: Keyword.get(opts, :delay_between_tries_ms, 3_000)
     }}
  end

  @impl true
  def handle_call(:table, _from, state), do: {:reply, state.table, state}

  def handle_call({:fetch_missing, type, ids}, _from, state) do
    case fetch_missing(state, type, ids) do
      {:ok, fetched, state} -> {:reply, {:ok, fetched}, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:set, data}, _from, state) do
    case commit_with_retry(state, data) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:clear, _from, state) do
    case clear_persisted_entries(state) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:lock, key, owner}, from, state) do
    case Map.get(state.locks, key) do
      nil ->
        {updated_state, _lock} = put_lock(state, key, owner)
        {:reply, :ok, updated_state}

      _lock ->
        {:noreply, enqueue_waiter(state, key, from, owner)}
    end
  end

  def handle_call({:unlock, key, owner}, _from, state) do
    {:reply, :ok, release_lock(state, key, owner)}
  end

  @impl true
  def handle_info({:DOWN, monitor_ref, :process, owner, _reason}, state) do
    case Map.pop(state.monitor_keys, monitor_ref) do
      {nil, _monitor_keys} ->
        {:noreply, state}

      {key, monitor_keys} ->
        updated_state = %{state | monitor_keys: monitor_keys}
        {:noreply, release_lock(updated_state, key, owner, monitor_ref)}
    end
  end

  defp current_tx(%Ref{pid: pid}), do: Process.get({__MODULE__, pid})
  defp update_tx(%Ref{pid: pid}, context), do: Process.put({__MODULE__, pid}, context)
  defp clear_tx(%Ref{pid: pid}), do: Process.delete({__MODULE__, pid})

  defp read_entries_in_transaction(ref, context, type, ids) do
    type_cache = Map.get(context.cache, type, %{})
    missing_ids = Enum.reject(ids, &Map.has_key?(type_cache, &1))

    context =
      case missing_ids do
        [] ->
          context

        _ ->
          fetched =
            case GenServer.call(ref.pid, {:fetch_missing, type, missing_ids}, :infinity) do
              {:ok, result} -> result
              {:error, reason} -> raise OperationError, action: :get, reason: reason
            end

          cache_fetched(context, type, missing_ids, fetched)
      end

    update_tx(ref, context)

    Enum.reduce(ids, %{}, fn id, acc ->
      case Map.fetch(context.cache[type] || %{}, id) do
        {:ok, nil} -> acc
        {:ok, value} -> Map.put(acc, id, value)
        :error -> acc
      end
    end)
  end

  defp cache_fetched(context, type, ids, fetched) do
    type_cache =
      Enum.reduce(ids, Map.get(context.cache, type, %{}), fn id, acc ->
        Map.put(acc, id, Map.get(fetched, id))
      end)

    put_in(context, [:cache, type], type_cache)
  end

  defp merge_transaction_data(ref, context, data) do
    Enum.reduce(data, context, fn {type, entries}, acc ->
      if type == :"pre-key" do
        merge_transaction_prekeys(ref, acc, entries)
      else
        merge_transaction_entries(acc, type, entries)
      end
    end)
  end

  defp merge_transaction_entries(context, type, entries) do
    Enum.reduce(entries, context, fn {id, value}, acc ->
      acc
      |> put_tx_cache(type, id, value)
      |> put_tx_mutation(type, id, value)
    end)
  end

  defp merge_transaction_prekeys(_ref, context, entries) do
    Enum.reduce(entries, context, fn
      {id, nil}, acc ->
        case Map.get(acc.cache, :"pre-key", %{}) do
          %{^id => existing} when not is_nil(existing) ->
            acc
            |> put_tx_cache(:"pre-key", id, nil)
            |> put_tx_mutation(:"pre-key", id, nil)

          _ ->
            acc
        end

      {id, value}, acc ->
        acc
        |> put_tx_cache(:"pre-key", id, value)
        |> put_tx_mutation(:"pre-key", id, value)
    end)
  end

  defp put_tx_cache(context, type, id, value) do
    update_in(context, [:cache, type], fn entries -> Map.put(entries || %{}, id, value) end)
  end

  defp put_tx_mutation(context, type, id, value) do
    update_in(context, [:mutations, type], fn entries -> Map.put(entries || %{}, id, value) end)
  end

  defp read_cached_entries(table, type, ids) do
    Enum.reduce(ids, {%{}, []}, fn id, {entries, missing_ids} ->
      case lookup_cache(table, type, id) do
        {:ok, value} -> {Map.put(entries, id, value), missing_ids}
        :cached_missing -> {entries, missing_ids}
        :miss -> {entries, [id | missing_ids]}
      end
    end)
    |> then(fn {entries, missing_ids} -> {entries, Enum.reverse(missing_ids)} end)
  end

  defp lookup_cache(table, type, id) do
    case :ets.lookup(table, {type, id}) do
      [{{^type, ^id}, @missing}] -> :cached_missing
      [{{^type, ^id}, value}] -> {:ok, value}
      [] -> :miss
    end
  end

  defp fetch_missing(state, _type, []), do: {:ok, %{}, state}

  defp fetch_missing(state, type, ids) do
    Enum.reduce_while(ids, {:ok, %{}, state}, fn id, {:ok, fetched, acc_state} ->
      case fetch_missing_id(acc_state, type, id) do
        {:ok, nil, next_state} ->
          {:cont, {:ok, fetched, next_state}}

        {:ok, value, next_state} ->
          {:cont, {:ok, Map.put(fetched, id, value), next_state}}

        {:error, reason, next_state} ->
          {:halt, {:error, reason, next_state}}
      end
    end)
  end

  defp fetch_missing_id(state, type, id) do
    case lookup_cache(state.table, type, id) do
      {:ok, value} -> {:ok, value, state}
      :cached_missing -> {:ok, nil, state}
      :miss -> load_and_cache(state, type, id)
    end
  end

  defp load_and_cache(state, type, id) do
    case persistence_load(state, type, id) do
      {:ok, value} ->
        cache_entry(state.table, type, id, value)
        {:ok, value, put_known_id(state, type, id)}

      {:error, :not_found} ->
        cache_entry(state.table, type, id, @missing)
        {:ok, nil, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp cache_entry(table, type, id, value) do
    true = :ets.insert(table, {{type, id}, value})
    :ok
  end

  defp put_known_id(state, type, id) do
    update_in(state.known_ids[type], fn ids ->
      MapSet.put(ids || MapSet.new(), id)
    end)
  end

  defp drop_known_id(state, type, id) do
    update_in(state.known_ids[type], fn
      nil -> nil
      ids -> MapSet.delete(ids, id)
    end)
  end

  defp commit_with_retry(state, data) when map_size(data) == 0, do: {:ok, state}

  defp commit_with_retry(state, data) do
    commit_with_retry(state, data, state.max_commit_retries)
  end

  defp commit_with_retry(state, _data, attempts_left) when attempts_left <= 0,
    do: {:error, :commit_retry_exhausted, state}

  defp commit_with_retry(state, data, attempts_left) do
    data = normalize_data(data)
    snapshot = snapshot_for(state, data)

    case apply_mutations(state, data) do
      {:ok, state} ->
        {:ok, state}

      {:error, reason, state} ->
        case restore_snapshot(state, snapshot) do
          {:ok, restored_state} when attempts_left > 1 ->
            Process.sleep(restored_state.delay_between_tries_ms)
            commit_with_retry(restored_state, data, attempts_left - 1)

          {:ok, restored_state} ->
            {:error, reason, restored_state}

          {:error, rollback_reason, restored_state} ->
            {:error, {:rollback_failed, reason, rollback_reason}, restored_state}
        end
    end
  end

  defp normalize_data(data) do
    Enum.reduce(data, %{}, fn {type, entries}, acc ->
      case normalize_entries(type, entries) do
        %{} = normalized when map_size(normalized) > 0 -> Map.put(acc, type, normalized)
        _ -> acc
      end
    end)
  end

  defp normalize_entries(_type, entries) when not is_map(entries), do: %{}

  defp normalize_entries(_type, entries) do
    Enum.reduce(entries, %{}, fn {id, value}, acc ->
      Map.put(acc, id, value)
    end)
  end

  defp apply_mutations(state, data) do
    data
    |> Enum.reduce_while(state, fn {type, entries}, acc_state ->
      apply_mutation_batch(acc_state, type, entries)
    end)
    |> case do
      {:error, reason, next_state} -> {:error, reason, next_state}
      next_state -> {:ok, next_state}
    end
  end

  defp apply_mutation_batch(state, type, entries) do
    case prepare_entries(state, type, entries) do
      {:ok, prepared_entries, next_state} ->
        case apply_prepared_entries(next_state, type, prepared_entries) do
          {:ok, updated_state} -> {:cont, updated_state}
          {:error, reason, updated_state} -> {:halt, {:error, reason, updated_state}}
        end

      {:error, reason, next_state} ->
        {:halt, {:error, reason, next_state}}
    end
  end

  defp prepare_entries(state, :"pre-key", entries), do: validate_prekey_entries(state, entries)
  defp prepare_entries(state, _type, entries), do: {:ok, entries, state}

  defp validate_prekey_entries(state, entries) do
    {deletions, updates} = Enum.split_with(entries, fn {_id, value} -> is_nil(value) end)
    updates = Map.new(updates)

    case fetch_missing(state, :"pre-key", Enum.map(deletions, &elem(&1, 0))) do
      {:ok, existing, next_state} ->
        {:ok, merge_prekey_deletions(updates, deletions, existing), next_state}

      {:error, reason, next_state} ->
        {:error, reason, next_state}
    end
  end

  defp merge_prekey_deletions(updates, deletions, existing) do
    Enum.reduce(deletions, updates, fn {id, _value}, acc ->
      if Map.has_key?(existing, id), do: Map.put(acc, id, nil), else: acc
    end)
  end

  defp apply_prepared_entries(state, type, entries) do
    Enum.reduce_while(entries, {:ok, state}, fn
      {id, nil}, {:ok, acc_state} ->
        case persistence_delete(acc_state, type, id) do
          :ok ->
            cache_entry(acc_state.table, type, id, @missing)
            {:cont, {:ok, drop_known_id(acc_state, type, id)}}

          {:error, reason} ->
            {:halt, {:error, reason, acc_state}}
        end

      {id, value}, {:ok, acc_state} ->
        case persistence_save(acc_state, type, id, value) do
          :ok ->
            cache_entry(acc_state.table, type, id, value)
            {:cont, {:ok, put_known_id(acc_state, type, id)}}

          {:error, reason} ->
            {:halt, {:error, reason, acc_state}}
        end
    end)
  end

  defp snapshot_for(state, data) do
    Enum.reduce(data, %{}, fn {type, entries}, acc ->
      Map.put(acc, type, snapshot_values_for_type(state, type, Map.keys(entries)))
    end)
  end

  defp snapshot_values_for_type(state, type, ids) do
    {cached, missing_ids} = read_cached_entries(state.table, type, ids)
    fetched = fetch_snapshot_missing(state, type, missing_ids)

    Enum.reduce(ids, %{}, fn id, acc ->
      Map.put(acc, id, snapshot_value(cached, fetched, id))
    end)
  end

  defp fetch_snapshot_missing(state, type, ids) do
    case fetch_missing(state, type, ids) do
      {:ok, values, _state} -> values
      {:error, _reason, _state} -> %{}
    end
  end

  defp snapshot_value(cached, fetched, id) do
    case Map.fetch(cached, id) do
      {:ok, value} -> value
      :error -> Map.get(fetched, id, @missing)
    end
  end

  defp restore_snapshot(state, snapshot) do
    Enum.reduce_while(snapshot, {:ok, state}, fn {type, entries}, {:ok, acc_state} ->
      restore_type_entries(acc_state, type, entries)
      |> case do
        {:ok, next_state} -> {:cont, {:ok, next_state}}
        {:error, reason, next_state} -> {:halt, {:error, reason, next_state}}
      end
    end)
  end

  defp restore_type_entries(state, type, entries) do
    Enum.reduce_while(entries, {:ok, state}, fn
      {id, @missing}, {:ok, acc_state} ->
        restore_snapshot_entry(acc_state, type, id, @missing)

      {id, value}, {:ok, acc_state} ->
        restore_snapshot_entry(acc_state, type, id, value)
    end)
  end

  defp restore_snapshot_entry(state, type, id, @missing) do
    case persistence_delete(state, type, id) do
      :ok ->
        cache_entry(state.table, type, id, @missing)
        {:cont, {:ok, drop_known_id(state, type, id)}}

      {:error, reason} ->
        {:halt, {:error, reason, state}}
    end
  end

  defp restore_snapshot_entry(state, type, id, value) do
    case persistence_save(state, type, id, value) do
      :ok ->
        cache_entry(state.table, type, id, value)
        {:cont, {:ok, put_known_id(state, type, id)}}

      {:error, reason} ->
        {:halt, {:error, reason, state}}
    end
  end

  defp clear_persisted_entries(state) do
    state.known_ids
    |> Enum.reduce_while({:ok, state}, fn {type, ids}, {:ok, acc_state} ->
      clear_known_ids(acc_state, type, ids)
      |> case do
        {:ok, next_state} -> {:cont, {:ok, next_state}}
        {:error, reason, next_state} -> {:halt, {:error, reason, next_state}}
      end
    end)
    |> case do
      {:ok, next_state} ->
        true = :ets.delete_all_objects(next_state.table)
        {:ok, %{next_state | known_ids: %{}}}

      {:error, reason, next_state} ->
        {:error, reason, next_state}
    end
  end

  defp clear_known_ids(state, type, ids) do
    Enum.reduce_while(ids, {:ok, state}, fn id, {:ok, acc_state} ->
      case persistence_delete(acc_state, type, id) do
        :ok -> {:cont, {:ok, acc_state}}
        {:error, reason} -> {:halt, {:error, reason, acc_state}}
      end
    end)
  end

  defp persistence_load(state, type, id) do
    apply_persistence(state, :load_keys, [type, id], [state.persistence_context, type, id])
  end

  defp persistence_save(state, type, id, value) do
    apply_persistence(
      state,
      :save_keys,
      [type, id, value],
      [state.persistence_context, type, id, value]
    )
  end

  defp persistence_delete(state, type, id) do
    apply_persistence(state, :delete_keys, [type, id], [state.persistence_context, type, id])
  end

  defp apply_persistence(
         %{persistence_module: module, persistence_context: context},
         fun,
         args,
         ctx_args
       ) do
    _ = Code.ensure_loaded(module)

    cond do
      not is_nil(context) and function_exported?(module, fun, length(ctx_args)) ->
        apply(module, fun, ctx_args)

      function_exported?(module, fun, length(args)) ->
        apply(module, fun, args)

      true ->
        {:error, {:unsupported_persistence_operation, module, fun}}
    end
  end

  defp put_lock(state, key, owner) do
    monitor_ref = Process.monitor(owner)
    lock = %{owner: owner, monitor_ref: monitor_ref, queue: :queue.new()}

    updated_state = %{
      state
      | locks: Map.put(state.locks, key, lock),
        monitor_keys: Map.put(state.monitor_keys, monitor_ref, key)
    }

    {updated_state, lock}
  end

  defp merge_fetched_missing(entries, _ref, _type, []), do: entries

  defp merge_fetched_missing(entries, ref, type, missing_ids) do
    case GenServer.call(ref.pid, {:fetch_missing, type, missing_ids}, :infinity) do
      {:ok, fetched} -> Map.merge(entries, fetched)
      {:error, reason} -> raise OperationError, action: :get, reason: reason
    end
  end

  defp enqueue_waiter(state, key, from, owner) do
    update_in(state, [:locks, key, :queue], fn queue ->
      :queue.in({from, owner}, queue || :queue.new())
    end)
  end

  defp release_lock(state, key, owner, monitor_ref \\ nil) do
    case Map.get(state.locks, key) do
      %{owner: ^owner, monitor_ref: lock_monitor_ref, queue: queue} ->
        demonitor_ref = monitor_ref || lock_monitor_ref
        Process.demonitor(demonitor_ref, [:flush])

        state
        |> update_in([:monitor_keys], &Map.delete(&1, demonitor_ref))
        |> promote_next_waiter(key, queue)

      _other ->
        state
    end
  end

  defp promote_next_waiter(state, key, queue) do
    case :queue.out(queue) do
      {{:value, {from, owner}}, remaining} ->
        {updated_state, lock} = put_lock(state, key, owner)
        next_state = put_in(updated_state, [:locks, key, :queue], remaining)
        GenServer.reply(from, :ok)
        put_in(next_state, [:locks, key], %{lock | queue: remaining})

      {:empty, _queue} ->
        %{state | locks: Map.delete(state.locks, key)}
    end
  end
end
