defmodule BaileysEx.Application do
  @moduledoc """
  Application supervisor for BaileysEx runtime services.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: BaileysEx.Registry},
      {DynamicSupervisor, name: BaileysEx.ConnectionSupervisor, strategy: :one_for_one},
      {Task.Supervisor, name: BaileysEx.TaskSupervisor}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: BaileysEx.Supervisor)
  end
end
