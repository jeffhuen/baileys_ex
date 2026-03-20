defmodule BaileysEx.Auth.PersistenceIO do
  @moduledoc false

  @spec atomic_write(Path.t(), iodata() | binary(), keyword()) :: :ok | {:error, term()}
  def atomic_write(file_path, contents, opts \\ [])
      when is_binary(file_path) and is_list(opts) do
    temp_path = temporary_path(file_path)
    fsync? = Keyword.get(opts, :fsync?, true)
    sync_parent? = Keyword.get(opts, :sync_parent?, fsync?)

    with :ok <- write_temp_file(temp_path, contents, fsync?),
         :ok <- File.rename(temp_path, file_path),
         :ok <- maybe_sync_parent_directory(file_path, sync_parent?) do
      :ok
    else
      {:error, _reason} = error ->
        _ = File.rm(temp_path)
        error
    end
  end

  @spec sync_parent_directory(Path.t()) :: :ok | {:error, term()}
  def sync_parent_directory(file_path) when is_binary(file_path) do
    dir_path = Path.dirname(file_path)

    case :file.open(String.to_charlist(dir_path), [:read, :raw, :directory]) do
      {:ok, device} ->
        try do
          :file.sync(device)
        after
          :ok = :file.close(device)
        end

      {:error, reason} when reason in [:enotsup, :eacces, :einval, :eperm] ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write_temp_file(path, contents, true), do: write_and_sync_file(path, contents)
  defp write_temp_file(path, contents, false), do: File.write(path, contents)

  defp maybe_sync_parent_directory(_file_path, false), do: :ok
  defp maybe_sync_parent_directory(file_path, true), do: sync_parent_directory(file_path)

  defp write_and_sync_file(path, contents) do
    case :file.open(String.to_charlist(path), [:write, :exclusive, :binary, :raw]) do
      {:ok, device} ->
        try do
          case :file.write(device, contents) do
            :ok -> :file.sync(device)
            {:error, reason} -> {:error, reason}
          end
        after
          :ok = :file.close(device)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp temporary_path(file_path) do
    suffix = System.unique_integer([:positive, :monotonic])
    "#{file_path}.tmp-#{suffix}"
  end
end
