defmodule BaileysEx.Signal.Store do
  @moduledoc """
  Runtime-backed Signal key store boundary aligned with Baileys' `keys` contract.

  The store exposes three core operations:

  - `get/3` for keyed reads by logical family
  - `set/2` for batched updates and deletions (`nil` removes an entry)
  - `transaction/3` for per-key serialized work with caller-local read/write caching

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
  @callback transaction(term(), String.t(), (-> result)) :: result when result: var
  @callback in_transaction?(term()) :: boolean()

  defstruct [:module, :ref]

  @spec start_link(keyword()) :: {:ok, t()} | :ignore | {:error, term()}
  def start_link(opts \\ []) do
    module = Keyword.get(opts, :module, Memory)
    module_opts = Keyword.delete(opts, :module)

    case module.start_link(module_opts) do
      {:ok, ref} -> {:ok, %__MODULE__{module: module, ref: module.wrap(ref)}}
      other -> other
    end
  end

  @spec get(t(), data_type(), [String.t()]) :: data_entries()
  def get(%__MODULE__{} = store, type, ids), do: store.module.get(store.ref, type, ids)

  @spec set(t(), data_set()) :: :ok
  def set(%__MODULE__{} = store, data), do: store.module.set(store.ref, data)

  @spec clear(t()) :: :ok
  def clear(%__MODULE__{} = store), do: store.module.clear(store.ref)

  @spec transaction(t(), String.t(), (-> result)) :: result when result: var
  def transaction(%__MODULE__{} = store, key, fun),
    do: store.module.transaction(store.ref, key, fun)

  @spec in_transaction?(t()) :: boolean()
  def in_transaction?(%__MODULE__{} = store), do: store.module.in_transaction?(store.ref)
end
