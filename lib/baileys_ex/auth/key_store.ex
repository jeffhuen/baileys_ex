defmodule BaileysEx.Auth.KeyStore do
  @moduledoc """
  Persistence-backed transactional Signal key store.

  The runtime owns a key-store server and a task supervisor. Persistence work
  runs serially under the task supervisor so slow storage never blocks lock
  ownership and queue management in the server.
  """

  use Supervisor

  @behaviour BaileysEx.Signal.Store

  alias BaileysEx.Auth.KeyStore.Server

  defmodule OperationError do
    @moduledoc false

    defexception [:action, :reason]

    @impl true
    def message(%__MODULE__{action: action, reason: reason}) do
      "auth key store #{action} failed: #{inspect(reason)}"
    end
  end

  defmodule Ref do
    @moduledoc """
    Store reference returned by `wrap/1` and passed into KeyStore operations.
    """

    @enforce_keys [:pid, :server, :table]
    defstruct [:pid, :server, :table]

    @typedoc "Opaque auth key store reference."
    @type t :: %__MODULE__{pid: pid(), server: pid(), table: :ets.tid()}
  end

  defmodule TxRef do
    @moduledoc """
    Internal transaction-scoped KeyStore handle.

    Callers receive this only inside `transaction/3` callbacks. It carries the
    explicit transaction-local cache and mutation buffer used by the built-in
    persistence-backed Signal store implementation.

    This module exists to make the transaction contract and generated
    documentation accurate for advanced custom store implementers. Application
    code should not construct or persist these structs directly.
    """

    @enforce_keys [:pid, :table, :tx_table]
    defstruct [:pid, :table, :tx_table]

    @typedoc "Internal transaction-scoped auth key store reference."
    @type t :: %__MODULE__{pid: pid(), table: :ets.tid(), tx_table: :ets.tid()}
  end

  @doc "Starts the transactional key-store supervision subtree."
  @impl true
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    {start_opts, init_opts} = Keyword.split(opts, [:name])
    Supervisor.start_link(__MODULE__, init_opts, start_opts)
  end

  @doc "Creates a read-only query reference for a running key store."
  @impl true
  @spec wrap(GenServer.server()) :: Ref.t()
  def wrap(runtime) do
    server = server!(runtime)
    %Ref{pid: resolve_pid!(runtime), server: server, table: GenServer.call(server, :table)}
  end

  @doc "Fetches identifiers for a Signal data type."
  @impl true
  defdelegate get(ref, type, ids), to: Server

  @doc "Persists a typed Signal data set."
  @impl true
  defdelegate set(ref, data), to: Server

  @doc "Clears all persisted Signal keys."
  @impl true
  defdelegate clear(ref), to: Server

  @doc "Runs work under an exclusive transaction key."
  @impl true
  defdelegate transaction(ref, key, fun), to: Server

  @doc "Returns whether the supplied reference is transaction-scoped."
  @impl true
  defdelegate in_transaction?(ref), to: Server

  @impl true
  def init(opts) do
    runtime = self()

    server_opts =
      Keyword.put(opts, :task_supervisor, fn -> child_pid(runtime, Task.Supervisor) end)

    children = [
      Supervisor.child_spec(Task.Supervisor, id: Task.Supervisor),
      {Server, server_opts}
      |> Supervisor.child_spec([])
      |> Map.merge(%{id: Server, restart: :temporary, significant: true})
    ]

    Supervisor.init(children,
      strategy: :one_for_one,
      auto_shutdown: :any_significant
    )
  end

  defp server!(runtime) do
    runtime
    |> resolve_pid!()
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {Server, pid, :worker, _modules} when is_pid(pid) -> pid
      _other -> nil
    end)
    |> case do
      pid when is_pid(pid) -> pid
      nil -> exit({:noproc, {__MODULE__, :server, [runtime]}})
    end
  end

  defp child_pid(supervisor, child_id) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {^child_id, pid, _type, _modules} when is_pid(pid) -> pid
      _other -> nil
    end)
  catch
    :exit, _reason -> nil
  end

  defp resolve_pid!(pid) when is_pid(pid), do: pid

  defp resolve_pid!(server) do
    case GenServer.whereis(server) do
      pid when is_pid(pid) -> pid
      nil -> exit({:noproc, {__MODULE__, :whereis, [server]}})
    end
  end
end

defmodule BaileysEx.Auth.KeyStore.Server do
  @moduledoc """
  Internal persistence-backed transactional Signal key-store server.

  This module wraps an auth persistence backend with the same `get/3`, `set/2`,
  and `transaction/3` shape used by the runtime `Signal.Store` contract. Reads
  go through ETS, transaction work is cached on an explicit transaction handle, and commit
  failures roll back to the previous persisted snapshot before surfacing an
  error to the caller. When a persistence backend exports context-aware
  callbacks such as `load_keys/3` or `save_keys/4`, the store passes the
  configured `:persistence_context` as the first argument; otherwise it falls
  back to the behaviour's context-free callbacks.
  """

  use GenServer

  alias BaileysEx.Auth.KeyStore.{OperationError, Ref, TxRef}
  alias BaileysEx.Auth.NativeFilePersistence
  alias BaileysEx.Signal.Store.LockManager
  alias BaileysEx.Signal.Store.TransactionBuffer

  @missing :"$missing"

  @type state :: %{
          table: :ets.tid(),
          persistence_module: module(),
          persistence_context: term(),
          task_supervisor: Supervisor.supervisor() | (-> Supervisor.supervisor()),
          locks: map(),
          monitor_keys: map(),
          known_ids: map(),
          max_commit_retries: pos_integer(),
          max_operation_queue: pos_integer(),
          delay_between_tries_ms: non_neg_integer(),
          retry_timer_fun: (pid(), term(), non_neg_integer() -> term()),
          active_operation: map() | nil,
          operation_queue: :queue.queue()
        }

  @doc """
  Starts the transactional key store linked to the current process.

  Options:

  - `:persistence_module` - module implementing `BaileysEx.Auth.Persistence`
    (defaults to `BaileysEx.Auth.NativeFilePersistence`)
  - `:persistence_context` - backend-specific context passed to the built-in
    context-aware persistence callbacks when exported
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Creates a read-only query ref struct to pass directly into reads.
  """
  @spec wrap(pid()) :: Ref.t()
  def wrap(pid) when is_pid(pid) do
    %Ref{pid: pid, server: pid, table: GenServer.call(pid, :table)}
  end

  @doc """
  Fetches an array of identifiers for a given data type.
  """
  @spec get(Ref.t() | TxRef.t(), BaileysEx.Signal.Store.data_type(), [String.t()]) ::
          BaileysEx.Signal.Store.data_entries()
  def get(%Ref{} = ref, type, ids) when is_list(ids) do
    {entries, missing_ids} = read_cached_entries(ref.table, type, ids)
    merge_fetched_missing(entries, ref, type, missing_ids)
  end

  def get(%TxRef{} = ref, type, ids) when is_list(ids) do
    read_entries_in_transaction(ref, type, ids)
  end

  @doc """
  Sets arbitrary mutations into the persistence backend.
  """
  @spec set(Ref.t() | TxRef.t(), BaileysEx.Signal.Store.data_set()) :: :ok
  def set(%Ref{} = ref, data) when is_map(data) do
    case GenServer.call(ref.server, {:set, data}, :infinity) do
      :ok -> :ok
      {:error, reason} -> raise OperationError, action: :set, reason: reason
    end
  end

  def set(%TxRef{} = ref, data) when is_map(data) do
    :ok = merge_transaction_data(ref, data)
    :ok
  end

  @doc """
  Clears all keys from persistence.
  """
  @spec clear(Ref.t() | TxRef.t()) :: :ok
  def clear(%Ref{} = ref) do
    case GenServer.call(ref.server, :clear, :infinity) do
      :ok -> :ok
      {:error, reason} -> raise OperationError, action: :clear, reason: reason
    end
  end

  def clear(%TxRef{} = ref) do
    :ok = TransactionBuffer.clear(ref.tx_table)
    :ok
  end

  @doc """
  Acquires an exclusive lock tied to `key` before running the `fun`.
  Errors safely roll back changes if commit fails.
  """
  @spec transaction(Ref.t() | TxRef.t(), String.t(), (TxRef.t() -> result)) :: result
        when result: var
  def transaction(%Ref{} = ref, key, fun) when is_binary(key) and is_function(fun, 1) do
    :ok = GenServer.call(ref.server, {:lock, key, self()}, :infinity)
    tx_table = TransactionBuffer.new()
    tx_ref = %TxRef{pid: ref.server, table: ref.table, tx_table: tx_table}

    try do
      result = fun.(tx_ref)

      case GenServer.call(
             ref.server,
             {:commit_tx, TransactionBuffer.cleared?(tx_table),
              TransactionBuffer.mutation_data(tx_table)},
             :infinity
           ) do
        :ok -> result
        {:error, reason} -> raise OperationError, action: :transaction, reason: reason
      end
    after
      TransactionBuffer.delete(tx_table)
      :ok = GenServer.call(ref.server, {:unlock, key, self()}, :infinity)
    end
  end

  def transaction(%TxRef{} = ref, _key, fun) when is_function(fun, 1), do: fun.(ref)

  @doc """
  Returns true if the current process is in an active transaction context.
  """
  @spec in_transaction?(Ref.t() | TxRef.t()) :: boolean()
  def in_transaction?(%Ref{}), do: false
  def in_transaction?(%TxRef{}), do: true

  @impl true
  def init(opts) do
    table = :ets.new(__MODULE__, [:set, :protected, read_concurrency: true])

    {:ok,
     %{
       table: table,
       persistence_module: Keyword.get(opts, :persistence_module, NativeFilePersistence),
       persistence_context: Keyword.get(opts, :persistence_context),
       task_supervisor: Keyword.fetch!(opts, :task_supervisor),
       locks: %{},
       monitor_keys: %{},
       known_ids: %{},
       max_commit_retries: Keyword.get(opts, :max_commit_retries, 10),
       max_operation_queue: Keyword.get(opts, :max_commit_queue, 1_024),
       delay_between_tries_ms: Keyword.get(opts, :delay_between_tries_ms, 3_000),
       retry_timer_fun: Keyword.get(opts, :retry_timer_fun, &Process.send_after/3),
       active_operation: nil,
       operation_queue: :queue.new()
     }}
  end

  @impl true
  def handle_call(:table, _from, state), do: {:reply, state.table, state}

  def handle_call({:fetch_missing, type, ids}, from, state) do
    enqueue_operation_reply(state, new_fetch(from, type, ids))
  end

  def handle_call({:set, data}, from, state) do
    enqueue_commit_reply(state, from, data, false, nil)
  end

  def handle_call({:commit_tx, clear?, data}, from, state) do
    enqueue_commit_reply(state, from, data, clear?, elem(from, 0))
  end

  def handle_call(:clear, from, state) do
    enqueue_commit_reply(state, from, %{}, true, nil)
  end

  def handle_call({:lock, key, owner}, from, state) do
    case LockManager.acquire(state, key, from, owner) do
      {:acquired, updated_state} ->
        {:reply, :ok, updated_state}

      {:queued, updated_state} ->
        {:noreply, updated_state}
    end
  end

  def handle_call({:unlock, key, owner}, _from, state) do
    {:reply, :ok, LockManager.release(state, key, owner)}
  end

  @impl true
  def handle_info(
        {:retry_operation, operation_ref},
        %{active_operation: %{ref: operation_ref, task: nil}} = state
      ) do
    {:noreply, start_active_operation(state)}
  end

  def handle_info(
        {task_ref, result},
        %{active_operation: %{task: %Task{ref: task_ref}}} = state
      ) do
    Process.demonitor(task_ref, [:flush])
    {:noreply, complete_operation(state, result)}
  end

  def handle_info(
        {:DOWN, task_ref, :process, _pid, reason},
        %{active_operation: %{task: %Task{ref: task_ref}}} = state
      ) do
    {:noreply, complete_operation(state, {:task_exit, reason})}
  end

  def handle_info({:DOWN, monitor_ref, :process, owner, _reason}, state) do
    {:noreply, handle_transaction_owner_down(state, monitor_ref, owner)}
  end

  def handle_info({:retry_operation, _stale_ref}, state), do: {:noreply, state}

  defp read_entries_in_transaction(%TxRef{} = ref, type, ids) do
    {_entries, missing_ids} = TransactionBuffer.cached_entries(ref.tx_table, type, ids)

    if missing_ids != [] do
      fetched = fetch_transaction_missing(ref, type, missing_ids)
      :ok = TransactionBuffer.cache_fetched(ref.tx_table, type, missing_ids, fetched)
    end

    ref.tx_table
    |> TransactionBuffer.cached_entries(type, ids)
    |> elem(0)
  end

  defp fetch_transaction_missing(%TxRef{} = ref, type, missing_ids) do
    if TransactionBuffer.cleared?(ref.tx_table) do
      %{}
    else
      case GenServer.call(ref.pid, {:fetch_missing, type, missing_ids}, :infinity) do
        {:ok, result} -> result
        {:error, reason} -> raise OperationError, action: :get, reason: reason
      end
    end
  end

  defp merge_transaction_data(ref, data) do
    Enum.reduce(data, :ok, fn {type, entries}, :ok ->
      if type == :"pre-key" do
        merge_transaction_prekeys(ref, entries)
      else
        merge_transaction_entries(ref, type, entries)
      end
    end)
  end

  defp merge_transaction_entries(%TxRef{} = ref, type, entries) do
    TransactionBuffer.put_entries(ref.tx_table, %{type => entries})
  end

  defp merge_transaction_prekeys(%TxRef{} = ref, entries) do
    Enum.reduce(entries, :ok, fn
      {id, nil}, :ok ->
        case get(ref, :"pre-key", [id]) do
          %{^id => _existing} -> TransactionBuffer.put_entry(ref.tx_table, :"pre-key", id, nil)
          %{} -> :ok
        end

      {id, value}, :ok ->
        TransactionBuffer.put_entry(ref.tx_table, :"pre-key", id, value)
    end)
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

  defp enqueue_commit_reply(state, from, data, clear?, owner) do
    operation = new_commit(from, data, clear?, owner, state.max_commit_retries)

    case enqueue_operation(state, operation) do
      {:ok, state} -> {:noreply, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp enqueue_operation_reply(state, operation) do
    case enqueue_operation(state, operation) do
      {:ok, state} -> {:noreply, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp enqueue_operation(state, operation) do
    if operation_queue_size(state) >= state.max_operation_queue do
      {:error, queue_full_reason(operation)}
    else
      state =
        state
        |> Map.update!(:operation_queue, &:queue.in(operation, &1))
        |> maybe_start_next_operation()

      {:ok, state}
    end
  end

  defp operation_queue_size(state) do
    :queue.len(state.operation_queue) + if(state.active_operation, do: 1, else: 0)
  end

  defp queue_full_reason(%{kind: :commit}), do: :commit_queue_full
  defp queue_full_reason(%{kind: :fetch}), do: :operation_queue_full

  defp new_fetch(from, type, ids) do
    %{
      kind: :fetch,
      ref: make_ref(),
      from: from,
      type: type,
      ids: ids,
      task: nil
    }
  end

  defp new_commit(from, data, clear?, owner, attempts_left) do
    %{
      kind: :commit,
      ref: make_ref(),
      from: from,
      data: normalize_data(data),
      clear?: clear?,
      attempts_left: attempts_left,
      owner: owner,
      owner_down: nil,
      task: nil
    }
  end

  defp maybe_start_next_operation(%{active_operation: active} = state)
       when not is_nil(active),
       do: state

  defp maybe_start_next_operation(state) do
    case :queue.out(state.operation_queue) do
      {{:value, operation}, remaining} ->
        state
        |> Map.put(:operation_queue, remaining)
        |> Map.put(:active_operation, operation)
        |> start_active_operation()

      {:empty, _queue} ->
        state
    end
  end

  defp start_active_operation(
         %{
           active_operation: %{kind: :commit, clear?: false, data: data}
         } = state
       )
       when map_size(data) == 0 do
    finish_active_operation(state, :ok)
  end

  defp start_active_operation(%{active_operation: operation} = state) do
    worker_state =
      Map.take(state, [:table, :persistence_module, :persistence_context, :known_ids])

    task_supervisor = resolve_runtime_ref!(state.task_supervisor)

    task =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        execute_operation(worker_state, operation)
      end)

    put_in(state.active_operation.task, task)
  catch
    :exit, reason -> complete_operation(state, {:task_exit, reason})
  end

  defp execute_operation(state, %{kind: :fetch, type: type, ids: ids}) do
    fetch_missing(state, type, ids)
  end

  defp execute_operation(state, %{kind: :commit, data: data, clear?: clear?}) do
    commit_once(state, data, clear?)
  end

  defp complete_operation(%{active_operation: %{kind: :fetch}} = state, result) do
    case result do
      {:ok, fetched, cache_updates} ->
        state = apply_cache_updates(state, cache_updates)
        finish_active_operation(state, {:ok, fetched})

      {:error, reason} ->
        finish_active_operation(state, {:error, reason})

      {:task_exit, reason} ->
        finish_active_operation(state, {:error, {:persistence_task_exit, reason}})

      other ->
        finish_active_operation(state, {:error, {:invalid_fetch_result, other}})
    end
  end

  defp complete_operation(
         %{active_operation: %{kind: :commit, attempts_left: attempts_left} = operation} = state,
         result
       ) do
    case result do
      {:ok, cache_plan} ->
        state
        |> apply_cache_plan(cache_plan)
        |> finish_active_operation(:ok)

      {:error, {:rollback_failed, _reason, _rollback_reason} = rollback_failed} ->
        finish_active_operation(state, {:error, rollback_failed})

      {:error, _reason} when attempts_left > 1 ->
        retry_operation(state, operation)

      {:error, reason} ->
        finish_active_operation(state, {:error, reason})

      {:task_exit, reason} ->
        finish_active_operation(state, {:error, {:persistence_task_exit, reason}})

      other ->
        finish_active_operation(state, {:error, {:invalid_commit_result, other}})
    end
  end

  defp retry_operation(state, operation) do
    operation = %{operation | attempts_left: operation.attempts_left - 1, task: nil}

    _ =
      state.retry_timer_fun.(
        self(),
        {:retry_operation, operation.ref},
        state.delay_between_tries_ms
      )

    %{state | active_operation: operation}
  end

  defp finish_active_operation(%{active_operation: operation} = state, reply) do
    GenServer.reply(operation.from, reply)

    state
    |> Map.put(:active_operation, nil)
    |> maybe_release_dead_owner(operation)
    |> maybe_start_next_operation()
  end

  defp maybe_release_dead_owner(state, %{owner_down: {monitor_ref, owner}})
       when is_reference(monitor_ref) and is_pid(owner) do
    LockManager.handle_owner_down(state, monitor_ref, owner)
  end

  defp maybe_release_dead_owner(state, _operation), do: state

  defp handle_transaction_owner_down(state, monitor_ref, owner) do
    case mark_owner_down(state, monitor_ref, owner) do
      {:marked, state} -> state
      :not_found -> LockManager.handle_owner_down(state, monitor_ref, owner)
    end
  end

  defp mark_owner_down(
         %{active_operation: %{kind: :commit, owner: owner} = operation} = state,
         monitor_ref,
         owner
       ) do
    {:marked, %{state | active_operation: %{operation | owner_down: {monitor_ref, owner}}}}
  end

  defp mark_owner_down(state, monitor_ref, owner) do
    {operations, marked?} =
      state.operation_queue
      |> :queue.to_list()
      |> Enum.map_reduce(false, fn
        %{kind: :commit, owner: ^owner} = operation, false ->
          {%{operation | owner_down: {monitor_ref, owner}}, true}

        operation, marked? ->
          {operation, marked?}
      end)

    if marked? do
      {:marked, %{state | operation_queue: :queue.from_list(operations)}}
    else
      :not_found
    end
  end

  defp commit_once(state, data, clear?) do
    data = normalize_data(data)

    with {:ok, snapshot} <- snapshot_for_commit(state, data, clear?),
         prepared_data <- prepare_commit_data(data, snapshot) do
      case persist_commit(state, prepared_data, clear?) do
        :ok ->
          {:ok, {if(clear?, do: :replace, else: :merge), prepared_data}}

        {:error, reason} ->
          restore_failed_commit(state, snapshot, reason)
      end
    end
  end

  defp restore_failed_commit(state, snapshot, reason) do
    case restore_snapshot(state, snapshot) do
      :ok -> {:error, reason}
      {:error, rollback_reason} -> {:error, {:rollback_failed, reason, rollback_reason}}
    end
  end

  defp fetch_missing(_state, _type, []), do: {:ok, %{}, []}

  defp fetch_missing(state, type, ids) do
    Enum.reduce_while(ids, {:ok, %{}, []}, fn id, {:ok, fetched, cache_updates} ->
      case lookup_cache(state.table, type, id) do
        {:ok, value} ->
          {:cont, {:ok, Map.put(fetched, id, value), cache_updates}}

        :cached_missing ->
          {:cont, {:ok, fetched, cache_updates}}

        :miss ->
          fetch_missing_from_persistence(state, type, id, fetched, cache_updates)
      end
    end)
    |> case do
      {:ok, fetched, cache_updates} -> {:ok, fetched, Enum.reverse(cache_updates)}
      {:error, _reason} = error -> error
    end
  end

  defp fetch_missing_from_persistence(state, type, id, fetched, cache_updates) do
    case persistence_load(state, type, id) do
      {:ok, value} ->
        update = {type, id, value}
        {:cont, {:ok, Map.put(fetched, id, value), [update | cache_updates]}}

      {:error, :not_found} ->
        {:cont, {:ok, fetched, [{type, id, @missing} | cache_updates]}}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  defp apply_cache_updates(state, cache_updates) do
    Enum.reduce(cache_updates, state, fn
      {type, id, @missing}, acc_state ->
        cache_entry(acc_state.table, type, id, @missing)
        drop_known_id(acc_state, type, id)

      {type, id, value}, acc_state ->
        cache_entry(acc_state.table, type, id, value)
        put_known_id(acc_state, type, id)
    end)
  end

  defp apply_cache_plan(state, {:replace, data}) do
    true = :ets.delete_all_objects(state.table)
    apply_cache_data(%{state | known_ids: %{}}, data)
  end

  defp apply_cache_plan(state, {:merge, data}), do: apply_cache_data(state, data)

  defp apply_cache_data(state, data) do
    Enum.reduce(data, state, fn {type, entries}, acc_state ->
      Enum.reduce(entries, acc_state, fn
        {id, nil}, next_state ->
          cache_entry(next_state.table, type, id, @missing)
          drop_known_id(next_state, type, id)

        {id, value}, next_state ->
          cache_entry(next_state.table, type, id, value)
          put_known_id(next_state, type, id)
      end)
    end)
  end

  defp snapshot_for_commit(state, data, false), do: snapshot_for(state, data)

  defp snapshot_for_commit(state, data, true) do
    known_data =
      Enum.reduce(state.known_ids, %{}, fn {type, ids}, acc ->
        Map.put(acc, type, Map.new(ids, &{&1, nil}))
      end)

    snapshot_for(
      state,
      Map.merge(known_data, data, fn _type, left, right -> Map.merge(left, right) end)
    )
  end

  defp snapshot_for(state, data) do
    Enum.reduce_while(data, {:ok, %{}}, fn {type, entries}, {:ok, snapshot} ->
      case snapshot_values_for_type(state, type, Map.keys(entries)) do
        {:ok, values} -> {:cont, {:ok, Map.put(snapshot, type, values)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp snapshot_values_for_type(state, type, ids) do
    Enum.reduce_while(ids, {:ok, %{}}, fn id, {:ok, values} ->
      case snapshot_value(state, type, id) do
        {:ok, value} -> {:cont, {:ok, Map.put(values, id, value)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp snapshot_value(state, type, id) do
    case lookup_cache(state.table, type, id) do
      {:ok, value} -> {:ok, value}
      :cached_missing -> {:ok, @missing}
      :miss -> normalize_snapshot_load(persistence_load(state, type, id))
    end
  end

  defp normalize_snapshot_load({:ok, value}), do: {:ok, value}
  defp normalize_snapshot_load({:error, :not_found}), do: {:ok, @missing}
  defp normalize_snapshot_load({:error, reason}), do: {:error, reason}

  defp prepare_commit_data(data, snapshot) do
    case Map.fetch(data, :"pre-key") do
      {:ok, entries} ->
        existing = Map.get(snapshot, :"pre-key", %{})

        prepared =
          Enum.reduce(entries, %{}, fn
            {id, nil}, acc ->
              maybe_put_prekey_deletion(acc, existing, id)

            {id, value}, acc ->
              Map.put(acc, id, value)
          end)

        if map_size(prepared) == 0,
          do: Map.delete(data, :"pre-key"),
          else: Map.put(data, :"pre-key", prepared)

      :error ->
        data
    end
  end

  defp maybe_put_prekey_deletion(acc, existing, id) do
    if Map.get(existing, id, @missing) == @missing,
      do: acc,
      else: Map.put(acc, id, nil)
  end

  defp persist_commit(state, data, clear?) do
    case maybe_clear_persisted_entries(state, clear?) do
      :ok -> persist_mutations(state, data)
      {:error, _reason} = error -> error
    end
  end

  defp maybe_clear_persisted_entries(_state, false), do: :ok

  defp maybe_clear_persisted_entries(state, true) do
    Enum.reduce_while(state.known_ids, :ok, fn {type, ids}, :ok ->
      case persist_deletions(state, type, ids) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp persist_mutations(state, data) do
    Enum.reduce_while(data, :ok, fn {type, entries}, :ok ->
      case persist_entries(state, type, entries) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp persist_entries(state, type, entries) do
    Enum.reduce_while(entries, :ok, fn
      {id, nil}, :ok ->
        case persistence_delete(state, type, id) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      {id, value}, :ok ->
        case persistence_save(state, type, id, value) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
    end)
  end

  defp persist_deletions(state, type, ids) do
    Enum.reduce_while(ids, :ok, fn id, :ok ->
      case persistence_delete(state, type, id) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp restore_snapshot(state, snapshot) do
    Enum.reduce_while(snapshot, :ok, fn {type, entries}, :ok ->
      case restore_type_entries(state, type, entries) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp restore_type_entries(state, type, entries) do
    Enum.reduce_while(entries, :ok, fn
      {id, @missing}, :ok ->
        case persistence_delete(state, type, id) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      {id, value}, :ok ->
        case persistence_save(state, type, id, value) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
    end)
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
        invoke_persistence(module, fun, ctx_args)

      function_exported?(module, fun, length(args)) ->
        invoke_persistence(module, fun, args)

      true ->
        {:error, {:unsupported_persistence_operation, module, fun}}
    end
  end

  defp invoke_persistence(module, fun, args) do
    apply(module, fun, args)
  rescue
    error -> {:error, {:persistence_exception, error, __STACKTRACE__}}
  catch
    kind, reason -> {:error, {:persistence_throw, kind, reason}}
  end

  defp merge_fetched_missing(entries, _ref, _type, []), do: entries

  defp merge_fetched_missing(entries, ref, type, missing_ids) do
    case GenServer.call(ref.server, {:fetch_missing, type, missing_ids}, :infinity) do
      {:ok, fetched} -> Map.merge(entries, fetched)
      {:error, reason} -> raise OperationError, action: :get, reason: reason
    end
  end

  defp resolve_runtime_ref!(resolver) when is_function(resolver, 0) do
    case resolver.() do
      pid when is_pid(pid) -> pid
      nil -> raise "key-store task supervisor is not available"
    end
  end

  defp resolve_runtime_ref!(pid) when is_pid(pid), do: pid
end
