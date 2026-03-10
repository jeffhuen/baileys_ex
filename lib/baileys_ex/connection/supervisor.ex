defmodule BaileysEx.Connection.Supervisor do
  @moduledoc """
  Connection runtime supervisor with rc.9-style socket, store, and event layers.
  """

  use Elixir.Supervisor

  alias BaileysEx.Connection.Coordinator
  alias BaileysEx.Connection.EventEmitter
  alias BaileysEx.Connection.Socket
  alias BaileysEx.Connection.Store

  @spec start_link(keyword()) :: Elixir.Supervisor.on_start()
  def start_link(opts) when is_list(opts) do
    {start_opts, init_opts} = split_start_opts(opts)
    Elixir.Supervisor.start_link(__MODULE__, init_opts, start_opts)
  end

  @spec which_children(GenServer.server()) ::
          [
            {term(), :restarting | :undefined | pid(), :supervisor | :worker,
             :dynamic | [module()]}
          ]
  def which_children(supervisor), do: Elixir.Supervisor.which_children(supervisor)

  @impl true
  def init(opts) do
    instance_id = Keyword.get(opts, :name, make_ref())
    coordinator_name = {:global, {__MODULE__, instance_id, Coordinator}}
    emitter_name = {:global, {__MODULE__, instance_id, EventEmitter}}
    store_name = {:global, {__MODULE__, instance_id, Store}}

    socket_opts =
      opts
      |> Keyword.drop([:name])
      |> Keyword.put_new(:event_emitter, emitter_name)

    children = [
      Elixir.Supervisor.child_spec({Socket, socket_opts}, id: Socket),
      Elixir.Supervisor.child_spec({Store, [name: store_name, auth_state: opts[:auth_state]]},
        id: Store
      ),
      Elixir.Supervisor.child_spec({EventEmitter, [name: emitter_name]}, id: EventEmitter),
      Elixir.Supervisor.child_spec(
        {Coordinator,
         [
           name: coordinator_name,
           config: Keyword.get(opts, :config),
           supervisor: self(),
           event_emitter: emitter_name,
           store: store_name
         ]},
        id: Coordinator
      )
    ]

    Elixir.Supervisor.init(children, strategy: :rest_for_one)
  end

  defp split_start_opts(opts) do
    case Keyword.fetch(opts, :name) do
      {:ok, name} ->
        if valid_name?(name) do
          {[name: name], opts}
        else
          {[], opts}
        end

      _ ->
        {[], opts}
    end
  end

  defp valid_name?(name) when is_atom(name), do: true
  defp valid_name?({:global, _}), do: true
  defp valid_name?({:via, _, _}), do: true
  defp valid_name?(_name), do: false
end
