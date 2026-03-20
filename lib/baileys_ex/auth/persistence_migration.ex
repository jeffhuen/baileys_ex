defmodule BaileysEx.Auth.PersistenceMigration do
  @moduledoc """
  Explicit migration helpers between built-in auth persistence backends.

  Phase 15 keeps `BaileysEx.Auth.FilePersistence` as the Baileys-compatible
  JSON helper and introduces `BaileysEx.Auth.NativeFilePersistence` as the
  recommended durable backend. This module provides the one-step migration path
  between those built-in backends without forcing users to re-pair.

  Migration is explicit. The built-in auth helpers do not convert existing auth
  directories automatically during `connect/2`.
  """

  alias BaileysEx.Auth.FilePersistence
  alias BaileysEx.Auth.NativeFilePersistence
  alias BaileysEx.Auth.PersistenceIO
  alias BaileysEx.Auth.State

  @typedoc """
  Summary returned after a successful built-in backend migration.
  """
  @type migration_summary :: %{
          required(:source_backend) => module(),
          required(:target_backend) => module(),
          required(:source_path) => Path.t(),
          required(:target_path) => Path.t(),
          required(:migrated_keys) => non_neg_integer()
        }

  @doc """
  Migrates a compatibility JSON auth directory into the native durable backend.

  The source directory is left untouched. By default the target path must be
  missing or empty and must not already contain native backend artifacts unless
  `overwrite?: true` is given.
  """
  @spec migrate_compat_json_to_native(Path.t(), Path.t(), keyword()) ::
          {:ok, migration_summary()} | {:error, term()}
  def migrate_compat_json_to_native(source_path, target_path, opts \\ [])
      when is_binary(source_path) and is_binary(target_path) and is_list(opts) do
    with {:ok, publish_mode} <- ensure_native_target_ready(target_path, opts),
         {:ok, %State{} = state} <- FilePersistence.load_credentials(source_path),
         {:ok, persisted_keys} <- FilePersistence.list_persisted_keys(source_path) do
      staging_path = staging_path(target_path)

      with :ok <- reset_staging_path(staging_path),
           :ok <- NativeFilePersistence.save_credentials(staging_path, state),
           {:ok, migrated_keys} <- migrate_keys(source_path, staging_path, persisted_keys),
           :ok <- publish_staged_target(staging_path, target_path, publish_mode) do
        {:ok,
         %{
           source_backend: FilePersistence,
           target_backend: NativeFilePersistence,
           source_path: source_path,
           target_path: target_path,
           migrated_keys: migrated_keys
         }}
      else
        {:error, _reason} = error ->
          cleanup_staging_path(staging_path)
          error
      end
    end
  end

  defp migrate_keys(source_path, target_path, persisted_keys) do
    persisted_keys
    |> Enum.sort_by(fn {type, _ids} -> Atom.to_string(type) end)
    |> Enum.reduce_while({:ok, 0}, fn {type, ids}, {:ok, migrated_count} ->
      case migrate_type_keys(source_path, target_path, type, ids, migrated_count) do
        {:ok, count} -> {:cont, {:ok, count}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp migrate_type_keys(source_path, target_path, type, ids, migrated_count) do
    ids
    |> Enum.sort()
    |> Enum.reduce_while({:ok, migrated_count}, fn id, {:ok, count} ->
      case migrate_key(source_path, target_path, type, id) do
        :ok -> {:cont, {:ok, count + 1}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp migrate_key(source_path, target_path, type, id) do
    case FilePersistence.load_keys(source_path, type, id) do
      {:ok, value} -> NativeFilePersistence.save_keys(target_path, type, id, value)
      {:error, _reason} = error -> error
    end
  end

  defp ensure_native_target_ready(target_path, opts) do
    overwrite? = Keyword.get(opts, :overwrite?, false)

    case inspect_target_path(target_path) do
      {:ok, :missing} ->
        {:ok, :missing}

      {:ok, :empty} ->
        {:ok, :replace_empty}

      {:ok, :native_present} when overwrite? ->
        {:ok, :replace_existing}

      {:ok, :native_present} ->
        {:error, {:target_already_contains_native_data, target_path}}

      {:ok, :occupied} when overwrite? ->
        {:ok, :replace_existing}

      {:ok, :occupied} ->
        {:error, {:target_not_empty, target_path}}

      {:error, reason} ->
        {:error, {:invalid_migration_target, target_path, reason}}
    end
  end

  defp inspect_target_path(target_path) do
    case File.ls(target_path) do
      {:ok, entries} ->
        cond do
          entries == [] ->
            {:ok, :empty}

          Enum.any?(entries, &native_persistence_artifact?/1) ->
            {:ok, :native_present}

          true ->
            {:ok, :occupied}
        end

      {:error, :enoent} ->
        {:ok, :missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp native_persistence_artifact?(entry) do
    String.ends_with?(entry, ".etf") and not String.contains?(entry, ".tmp-")
  end

  defp staging_path(target_path) do
    suffix = System.unique_integer([:positive, :monotonic])
    "#{target_path}.migration-stage-#{suffix}"
  end

  defp reset_staging_path(staging_path) do
    case File.rm_rf(staging_path) do
      {:ok, _} ->
        :ok

      {:error, reason, _path} ->
        {:error, reason}
    end
  end

  defp cleanup_staging_path(staging_path) do
    case File.rm_rf(staging_path) do
      {:ok, _} -> :ok
      {:error, _reason, _path} -> :ok
    end
  end

  defp publish_staged_target(staging_path, target_path, :missing) do
    with :ok <- File.rename(staging_path, target_path) do
      PersistenceIO.sync_parent_directory(target_path)
    end
  end

  defp publish_staged_target(staging_path, target_path, :replace_empty) do
    publish_staged_target(staging_path, target_path, :replace_existing)
  end

  defp publish_staged_target(staging_path, target_path, :replace_existing) do
    backup_path =
      "#{target_path}.migration-backup-#{System.unique_integer([:positive, :monotonic])}"

    with :ok <- File.rename(target_path, backup_path),
         :ok <- File.rename(staging_path, target_path),
         :ok <- PersistenceIO.sync_parent_directory(target_path) do
      _ = File.rm_rf(backup_path)
      :ok
    else
      {:error, _reason} = error ->
        restore_original_target(target_path, backup_path)
        error
    end
  end

  defp restore_original_target(target_path, backup_path) do
    if File.exists?(backup_path) and not File.exists?(target_path) do
      _ = File.rename(backup_path, target_path)
      _ = PersistenceIO.sync_parent_directory(target_path)
    end

    :ok
  end
end
