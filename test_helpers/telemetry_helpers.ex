defmodule BaileysEx.TestHelpers.TelemetryHelpers do
  @moduledoc false

  @spec attach_events(pid(), [list(atom())]) :: String.t()
  def attach_events(test_pid, events) when is_pid(test_pid) and is_list(events) do
    handler_id = "telemetry-#{System.unique_integer([:positive])}"
    :ok = :telemetry.attach_many(handler_id, events, &__MODULE__.handle_event/4, test_pid)
    handler_id
  end

  @spec detach(String.t()) :: :ok | {:error, :not_found}
  def detach(handler_id) when is_binary(handler_id), do: :telemetry.detach(handler_id)

  @spec handle_event(list(atom()), map(), map(), pid()) :: :ok
  def handle_event(event, measurements, metadata, test_pid) do
    send(test_pid, {:telemetry, event, measurements, metadata})
    :ok
  end
end
