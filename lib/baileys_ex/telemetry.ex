defmodule BaileysEx.Telemetry do
  @moduledoc """
  Shared telemetry helpers for BaileysEx runtime instrumentation.

  All events are emitted under the `[:baileys_ex]` prefix.
  """

  @prefix [:baileys_ex]

  @type event_name :: [atom()]

  @doc "Return the shared telemetry prefix."
  @spec prefix() :: [atom()]
  def prefix, do: @prefix

  @doc "Build a fully-qualified telemetry event name."
  @spec event(event_name()) :: [atom()]
  def event(event_name) when is_list(event_name), do: @prefix ++ event_name

  @doc "Emit a one-off telemetry event."
  @spec execute(event_name(), map(), map()) :: :ok
  def execute(event_name, measurements \\ %{}, metadata \\ %{})
      when is_list(event_name) and is_map(measurements) and is_map(metadata) do
    :telemetry.execute(event(event_name), measurements, metadata)
  end

  @doc """
  Emit `:start`, `:stop`, and `:exception` events around `fun`.
  """
  @spec span(event_name(), map(), (-> result)) :: result when result: var
  def span(event_name, metadata, fun) when is_list(event_name) and is_map(metadata) do
    span_with_result(event_name, metadata, fn _result -> %{} end, fun)
  end

  @doc false
  @spec span_with_result(event_name(), map(), (result -> map()), (-> result)) :: result
        when result: var
  def span_with_result(event_name, metadata, result_metadata_fun, fun)
      when is_list(event_name) and is_map(metadata) and is_function(result_metadata_fun, 1) and
             is_function(fun, 0) do
    start_time = System.monotonic_time()
    execute(event_name ++ [:start], %{system_time: System.system_time()}, metadata)

    try do
      result = fun.()

      stop_metadata =
        metadata
        |> Map.merge(status_metadata(result))
        |> Map.merge(normalize_metadata(result_metadata_fun.(result)))

      execute(
        event_name ++ [:stop],
        %{duration: System.monotonic_time() - start_time},
        stop_metadata
      )

      result
    rescue
      error ->
        exception_metadata = %{
          kind: :error,
          reason: error,
          stacktrace: __STACKTRACE__
        }

        execute(
          event_name ++ [:exception],
          %{duration: System.monotonic_time() - start_time},
          Map.merge(metadata, exception_metadata)
        )

        reraise(error, __STACKTRACE__)
    catch
      kind, reason ->
        exception_metadata = %{
          kind: kind,
          reason: reason,
          stacktrace: __STACKTRACE__
        }

        execute(
          event_name ++ [:exception],
          %{duration: System.monotonic_time() - start_time},
          Map.merge(metadata, exception_metadata)
        )

        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp normalize_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata(_metadata), do: %{}

  defp status_metadata(:ok), do: %{status: :ok}
  defp status_metadata({:ok, _value}), do: %{status: :ok}
  defp status_metadata({:ok, _first, _second}), do: %{status: :ok}
  defp status_metadata({:ok, _first, _second, _third}), do: %{status: :ok}
  defp status_metadata({:error, reason}), do: %{status: :error, reason: reason}
  defp status_metadata({:error, reason, _state}), do: %{status: :error, reason: reason}
  defp status_metadata(_result), do: %{}
end
