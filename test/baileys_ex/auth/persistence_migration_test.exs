defmodule BaileysEx.Auth.PersistenceMigrationTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Auth.FilePersistence
  alias BaileysEx.Auth.NativeFilePersistence
  alias BaileysEx.Auth.PersistenceMigration
  alias BaileysEx.Signal.Group.SenderKeyRecord
  alias BaileysEx.TestSupport.DeterministicAuth

  @file_manifest ".baileys_ex_file_persistence.json"
  @native_manifest ".baileys_ex_native_file_persistence.etf"

  @tag :tmp_dir
  test "file persistence writes a version manifest and still loads the current shipped layout without it",
       %{
         tmp_dir: tmp_dir
       } do
    state = DeterministicAuth.state(301) |> Map.put(:platform, "compat")
    sender_key_id = "14156521415-1397622199@g.us::15550001111::0"
    sender_key_record = sender_key_record()

    assert :ok = FilePersistence.save_credentials(tmp_dir, state)

    assert :ok =
             FilePersistence.save_keys(tmp_dir, :"sender-key", sender_key_id, sender_key_record)

    manifest_path = Path.join(tmp_dir, @file_manifest)
    assert File.exists?(manifest_path)

    assert %{
             "backend" => "file_persistence",
             "version" => 1,
             "key_index" => %{"sender-key" => [^sender_key_id]}
           } = manifest_path |> File.read!() |> JSON.decode!()

    File.rm!(manifest_path)

    assert {:ok, ^state} = FilePersistence.load_credentials(tmp_dir)

    assert {:ok, ^sender_key_record} =
             FilePersistence.load_keys(tmp_dir, :"sender-key", sender_key_id)
  end

  @tag :tmp_dir
  test "native file persistence writes a version manifest and still loads the current shipped layout without it",
       %{
         tmp_dir: tmp_dir
       } do
    state =
      DeterministicAuth.state(302)
      |> Map.put(:platform, "native")
      |> Map.put(:additional_data, %{labels: [:alpha], nested: {:ok, 42}})

    assert :ok = NativeFilePersistence.save_credentials(tmp_dir, state)

    assert :ok =
             NativeFilePersistence.save_keys(tmp_dir, :"device-list", "5511999887766", ["0", "2"])

    manifest_path = Path.join(tmp_dir, @native_manifest)
    assert File.exists?(manifest_path)

    assert %{
             "backend" => "native_file_persistence",
             "version" => 1,
             "key_index" => %{"device-list" => ["5511999887766"]}
           } = manifest_path |> File.read!() |> :erlang.binary_to_term([:safe])

    File.rm!(manifest_path)

    assert {:ok, ^state} = NativeFilePersistence.load_credentials(tmp_dir)

    assert {:ok, ["0", "2"]} =
             NativeFilePersistence.load_keys(tmp_dir, :"device-list", "5511999887766")
  end

  @tag :tmp_dir
  test "migrate_compat_json_to_native/2 migrates current shipped JSON directories to versioned native storage",
       %{
         tmp_dir: tmp_dir
       } do
    source_path = Path.join(tmp_dir, "compat")
    target_path = Path.join(tmp_dir, "native")

    state = DeterministicAuth.state(303) |> Map.put(:platform, "migrated")
    sender_key_id = "14156521415-1397622199@g.us::15550001111::0"
    sender_key_record = sender_key_record()

    assert :ok = FilePersistence.save_credentials(source_path, state)

    assert :ok =
             FilePersistence.save_keys(
               source_path,
               :"sender-key",
               sender_key_id,
               sender_key_record
             )

    assert :ok =
             FilePersistence.save_keys(source_path, :"device-list", "5511999887766", ["0", "2"])

    File.rm!(Path.join(source_path, @file_manifest))

    assert {:ok,
            %{
              source_backend: FilePersistence,
              target_backend: NativeFilePersistence,
              migrated_keys: 2
            }} =
             PersistenceMigration.migrate_compat_json_to_native(source_path, target_path)

    assert {:ok, ^state} = NativeFilePersistence.load_credentials(target_path)

    assert {:ok, ^sender_key_record} =
             NativeFilePersistence.load_keys(target_path, :"sender-key", sender_key_id)

    assert {:ok, ["0", "2"]} =
             NativeFilePersistence.load_keys(target_path, :"device-list", "5511999887766")
  end

  @tag :tmp_dir
  test "unsupported persistence versions fail clearly instead of silently resetting auth state",
       %{
         tmp_dir: tmp_dir
       } do
    state = DeterministicAuth.state(304) |> Map.put(:platform, "unsupported")
    source_path = Path.join(tmp_dir, "compat")
    target_path = Path.join(tmp_dir, "native")

    assert :ok = FilePersistence.save_credentials(source_path, state)

    File.write!(
      Path.join(source_path, @file_manifest),
      JSON.encode!(%{"backend" => "file_persistence", "version" => 99, "key_index" => %{}})
    )

    assert {:error, {:unsupported_persistence_version, FilePersistence, 99}} =
             FilePersistence.load_credentials(source_path)

    assert {:error, {:unsupported_persistence_version, FilePersistence, 99}} =
             PersistenceMigration.migrate_compat_json_to_native(source_path, target_path)
  end

  @tag :tmp_dir
  test "migrate_compat_json_to_native/2 does not publish partial native data when key migration fails",
       %{
         tmp_dir: tmp_dir
       } do
    source_path = Path.join(tmp_dir, "compat")
    target_path = Path.join(tmp_dir, "native")
    state = DeterministicAuth.state(305) |> Map.put(:platform, "staged")

    assert :ok = FilePersistence.save_credentials(source_path, state)

    assert :ok =
             FilePersistence.save_keys(source_path, :"device-list", "5511999887766", ["0", "2"])

    assert :ok =
             FilePersistence.save_keys(source_path, :session, "16268980123.0", %{"ok" => true})

    File.write!(Path.join(source_path, "session-16268980123.0.json"), "{}")
    File.rm!(Path.join(source_path, @file_manifest))

    assert {:error, %ArgumentError{}} =
             PersistenceMigration.migrate_compat_json_to_native(source_path, target_path)

    refute File.exists?(Path.join(target_path, "creds.etf"))
    refute File.exists?(Path.join(target_path, @native_manifest))
  end

  @tag :tmp_dir
  test "migrate_compat_json_to_native/2 propagates target path access errors", %{tmp_dir: tmp_dir} do
    source_path = Path.join(tmp_dir, "compat")
    target_path = Path.join(tmp_dir, "native-target")
    state = DeterministicAuth.state(306) |> Map.put(:platform, "blocked")

    assert :ok = FilePersistence.save_credentials(source_path, state)
    assert :ok = File.write(target_path, "not a directory")

    assert {:error, {:invalid_migration_target, ^target_path, :enotdir}} =
             PersistenceMigration.migrate_compat_json_to_native(source_path, target_path)
  end

  defp sender_key_record do
    SenderKeyRecord.new()
    |> SenderKeyRecord.add_state(7, 1, <<1, 2, 3>>, <<4, 5, 6>>)
  end
end
