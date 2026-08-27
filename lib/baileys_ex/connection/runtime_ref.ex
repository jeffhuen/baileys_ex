defmodule BaileysEx.Connection.RuntimeRef do
  @moduledoc false

  @type table :: :ets.tid()

  @spec new() :: table()
  def new do
    :ets.new(__MODULE__, [:set, :protected, read_concurrency: true])
  end

  @spec child_spec(Supervisor.child_spec(), table()) :: Supervisor.child_spec()
  def child_spec(%{id: id, start: start} = spec, table) do
    %{spec | start: {__MODULE__, :start_child, [table, id, start]}}
  end

  @doc false
  @spec start_child(table(), term(), {module(), atom(), [term()]}) ::
          {:ok, pid()} | {:ok, pid(), term()} | :ignore | {:error, term()}
  def start_child(table, id, {module, function, arguments}) do
    case apply(module, function, arguments) do
      {:ok, pid} = result when is_pid(pid) ->
        true = :ets.insert(table, {id, pid})
        result

      {:ok, pid, _extra} = result when is_pid(pid) ->
        true = :ets.insert(table, {id, pid})
        result

      other ->
        other
    end
  end

  @spec fetch(table(), term()) :: pid() | nil
  def fetch(table, id) do
    case :ets.lookup(table, id) do
      [{^id, pid}] when is_pid(pid) ->
        if Process.alive?(pid), do: pid

      [] ->
        nil
    end
  rescue
    ArgumentError -> nil
  end
end
