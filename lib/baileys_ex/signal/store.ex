defmodule BaileysEx.Signal.Store do
  @moduledoc """
  Runtime-backed Signal key store boundary aligned with Baileys' `keys` contract.

  The store exposes three core operations:

  - `get/3` for keyed reads by logical family
  - `set/2` for batched updates and deletions (`nil` removes an entry)
  - `transaction/3` for per-key serialized work through an explicit
    transaction-scoped store handle

  Custom store modules must pass that transaction-scoped handle into the
  closure:

      transaction(ref, "session:alice", fn tx_ref ->
        existing = get(tx_ref, :session, ["alice.0"])
        :ok = set(tx_ref, %{session: %{"alice.0" => updated}})
        existing
      end)

  Concrete persistence remains swappable. The default in-memory runtime
  implementation can be replaced with file/ETS/DB-backed variants without
  changing repository consumers.
  """

  alias BaileysEx.Signal.Store.Memory

  @typedoc "Store handle passed to repository and helper modules."
  @type t :: %__MODULE__{module: module(), ref: term()}

  @type start_result :: {:ok, pid()} | :ignore | {:error, term()}

  @typedoc "Logical key families matching Baileys' Signal store."
  @type data_type ::
          :session
          | :"pre-key"
          | :"sender-key"
          | :"sender-key-memory"
          | :"app-state-sync-key"
          | :"app-state-sync-version"
          | :"lid-mapping"
          | :"device-list"
          | :tctoken
          | :"identity-key"

  @typedoc "One value written under a logical key family."
  @type data_value ::
          binary()
          | [String.t()]
          | %{optional(String.t()) => boolean()}
          | %{required(:token) => binary(), optional(:timestamp) => String.t()}
          | %{required(:public) => binary(), required(:private) => binary()}
          | term()

  @type data_entries :: %{optional(String.t()) => data_value()}
  @type data_set :: %{optional(data_type()) => %{optional(String.t()) => data_value() | nil}}

  @callback start_link(keyword()) :: start_result()
  @callback wrap(term()) :: term()
  @callback get(term(), data_type(), [String.t()]) :: data_entries()
  @callback set(term(), data_set()) :: :ok
  @callback clear(term()) :: :ok
  @callback transaction(term(), String.t(), (term() -> result)) :: result when result: var
  @callback in_transaction?(term()) :: boolean()

  defstruct [:module, :ref]

  @doc "Initializes and starts the underlying data store process/pool."
  @spec start_link(keyword()) :: {:ok, t()} | :ignore | {:error, term()}
  def start_link(opts \\ []) do
    module = Keyword.get(opts, :module, Memory)
    module_opts = Keyword.delete(opts, :module)

    case module.start_link(module_opts) do
      {:ok, ref} -> {:ok, %__MODULE__{module: module, ref: module.wrap(ref)}}
      other -> other
    end
  end

  @doc "Extracts values from the store sequentially resolving cache items."
  @spec get(t(), data_type(), [String.t()]) :: data_entries()
  def get(%__MODULE__{} = store, type, ids), do: store.module.get(store.ref, type, ids)

  @doc "Persists an explicitly typed data set definition back to the store."
  @spec set(t(), data_set()) :: :ok
  def set(%__MODULE__{} = store, data), do: store.module.set(store.ref, data)

  @doc "Flushes the data store completely."
  @spec clear(t()) :: :ok
  def clear(%__MODULE__{} = store), do: store.module.clear(store.ref)

  @doc """
  Executes work inside of a logically consistent mutex-isolated transaction.

  The callback receives a transaction-scoped store handle. Reads and writes
  that should participate in the transaction must use that handle, not the
  outer non-transactional store handle.
  """
  @spec transaction(t(), String.t(), (t() -> result)) :: result when result: var
  def transaction(%__MODULE__{} = store, key, fun) when is_function(fun, 1) do
    store.module.transaction(store.ref, key, fn tx_ref ->
      fun.(%__MODULE__{module: store.module, ref: tx_ref})
    end)
  end

  @doc "Examines if identical transaction processes cover the ongoing context stack."
  @spec in_transaction?(t()) :: boolean()
  def in_transaction?(%__MODULE__{} = store), do: store.module.in_transaction?(store.ref)

  @doc """
  Resolve a running store process or `{module, server}` tuple into a wrapped
  `BaileysEx.Signal.Store` handle.
  """
  @spec wrap_running(t() | {module(), term()} | term() | nil) :: t() | nil
  def wrap_running(nil), do: nil
  def wrap_running(%__MODULE__{} = store), do: store

  def wrap_running({module, server}) when is_atom(module) do
    pid = GenServer.whereis(server)

    if is_pid(pid) and function_exported?(module, :wrap, 1) do
      %__MODULE__{module: module, ref: module.wrap(pid)}
    else
      nil
    end
  end

  def wrap_running(server), do: wrap_running({Memory, server})
end
