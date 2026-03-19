defmodule BaileysEx.Parity.NodeBridge do
  @moduledoc false

  @repo_root Path.expand("../../..", __DIR__)
  @runner_path Path.join(@repo_root, "dev/tools/run_baileys_reference.mts")
  @tsx_path Path.join(@repo_root, "dev/reference/Baileys-master/node_modules/.bin/tsx")

  @spec run!(String.t(), map()) :: map()
  def run!(operation, input) when is_binary(operation) and is_map(input) do
    case run(operation, input) do
      {:ok, result} -> result
      {:error, reason} -> raise "Baileys reference runner failed: #{inspect(reason)}"
    end
  end

  @spec run(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def run(operation, input) when is_binary(operation) and is_map(input) do
    payload = JSON.encode!(%{"operation" => operation, "input" => input})

    with :ok <- ensure_runner_files_exist(),
         {output, 0} <- run_command(payload),
         {:ok, decoded} <- JSON.decode(output),
         {:ok, result} <- normalize_response(decoded, output) do
      {:ok, result}
    else
      {output, status} when is_integer(status) ->
        {:error, {:runner_exit, status, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_runner_files_exist do
    cond do
      not File.exists?(@tsx_path) -> {:error, {:missing_tsx, @tsx_path}}
      not File.exists?(@runner_path) -> {:error, {:missing_runner, @runner_path}}
      true -> :ok
    end
  end

  defp run_command(payload) do
    payload_path =
      Path.join(
        System.tmp_dir!(),
        "baileys-reference-#{System.unique_integer([:positive])}.json"
      )

    try do
      File.write!(payload_path, payload)

      System.cmd(@tsx_path, [@runner_path, payload_path],
        cd: @repo_root,
        env: [{"NODE_NO_WARNINGS", "1"}],
        stderr_to_stdout: true
      )
    rescue
      error in ErlangError -> {:error, {:system_cmd_failed, error.original}}
    after
      File.rm(payload_path)
    end
  end

  defp normalize_response(%{"ok" => true, "result" => result}, _output) when is_map(result),
    do: {:ok, result}

  defp normalize_response(%{"ok" => false, "error" => error}, _output),
    do: {:error, {:reference_error, error}}

  defp normalize_response(decoded, output),
    do: {:error, {:unexpected_response, decoded, output}}
end
