defmodule BaileysEx.Auth.FilePersistenceTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Auth.FilePersistence
  alias BaileysEx.Auth.KeyStore
  alias BaileysEx.Auth.State
  alias BaileysEx.Signal.SessionRecord
  alias BaileysEx.TestSupport.DeterministicAuth

  @tag :tmp_dir
  test "load_credentials/1 initializes fresh credentials when creds.json is missing", %{
    tmp_dir: tmp_dir
  } do
    assert {:ok, %State{} = state} = FilePersistence.load_credentials(tmp_dir)

    assert state.registered == false
    refute File.exists?(Path.join(tmp_dir, "creds.json"))
  end

  @tag :tmp_dir
  test "save_credentials/2 roundtrips the auth state with explicit binary encoding", %{
    tmp_dir: tmp_dir
  } do
    state =
      DeterministicAuth.state(50)
      |> Map.put(:platform, "macOS")
      |> Map.put(:routing_info, <<1, 2, 3, 4>>)
      |> Map.put(:pairing_code, "123-456")
      |> Map.put(:additional_data, %{labels: [:alpha, :beta], nested: %{token: <<5, 6, 7>>}})

    assert :ok = FilePersistence.save_credentials(tmp_dir, state)
    assert {:ok, ^state} = FilePersistence.load_credentials(tmp_dir)

    contents = File.read!(Path.join(tmp_dir, "creds.json"))
    assert contents =~ "\"type\":\"Buffer\""
    assert contents =~ "\"routing_info\""
    assert contents =~ "\"platform\":\"macOS\""
  end

  @tag :tmp_dir
  test "key data is stored in sanitized per-key files and can be deleted", %{tmp_dir: tmp_dir} do
    assert :ok =
             FilePersistence.save_keys(
               tmp_dir,
               :"device-list",
               "alice/device:0",
               ["primary", "companion"]
             )

    assert {:ok, ["primary", "companion"]} =
             FilePersistence.load_keys(tmp_dir, :"device-list", "alice/device:0")

    assert File.exists?(Path.join(tmp_dir, "device-list-alice__device-0.json"))

    assert :ok = FilePersistence.delete_keys(tmp_dir, :"device-list", "alice/device:0")

    assert {:error, :not_found} =
             FilePersistence.load_keys(tmp_dir, :"device-list", "alice/device:0")
  end

  @tag :tmp_dir
  test "session records with non-UTF-8 binary keys roundtrip through key persistence", %{
    tmp_dir: tmp_dir
  } do
    session_key =
      <<5, 47, 94, 146, 126, 20, 145, 64, 167, 132, 196, 186, 86, 38, 23, 215, 31, 144, 133, 214,
        230, 196, 84, 64, 227, 163, 144, 29, 239, 76, 133, 227, 35>>

    session_record =
      SessionRecord.new()
      |> SessionRecord.put_session(session_key, session(session_key))

    assert :ok = FilePersistence.save_keys(tmp_dir, :session, "16268980123.0", session_record)

    assert {:ok, ^session_record} =
             FilePersistence.load_keys(tmp_dir, :session, "16268980123.0")
  end

  @tag :tmp_dir
  test "concurrent writes to the same creds file remain decodable", %{tmp_dir: tmp_dir} do
    first_state = DeterministicAuth.state(60) |> Map.put(:platform, "alpha")
    second_state = DeterministicAuth.state(70) |> Map.put(:platform, "beta")

    tasks = [
      Task.async(fn -> FilePersistence.save_credentials(tmp_dir, first_state) end),
      Task.async(fn -> FilePersistence.save_credentials(tmp_dir, second_state) end)
    ]

    assert [:ok, :ok] = Enum.map(tasks, &Task.await(&1, 1_000))

    assert {:ok, %State{platform: platform}} = FilePersistence.load_credentials(tmp_dir)
    assert platform in ["alpha", "beta"]
  end

  @tag :tmp_dir
  test "use_multi_file_auth_state/1 returns connect opts for the file-backed Signal store", %{
    tmp_dir: tmp_dir
  } do
    state = DeterministicAuth.state(80) |> Map.put(:platform, "ios")
    assert :ok = FilePersistence.save_credentials(tmp_dir, state)

    assert {:ok, persisted_auth} = FilePersistence.use_multi_file_auth_state(tmp_dir)

    assert persisted_auth.state == state
    assert persisted_auth.connect_opts[:signal_store_module] == KeyStore

    assert Keyword.take(persisted_auth.connect_opts[:signal_store_opts], [
             :persistence_module,
             :persistence_context
           ]) == [persistence_module: FilePersistence, persistence_context: tmp_dir]

    updated_state = persisted_auth.state |> Map.put(:pairing_code, "ABC-123")

    assert :ok = persisted_auth.save_creds.(updated_state)
    assert {:ok, %State{pairing_code: "ABC-123"}} = FilePersistence.load_credentials(tmp_dir)
  end

  defp session(base_key) do
    %{
      current_ratchet: %{
        root_key: :binary.copy(<<0xAA>>, 32),
        ephemeral_key_pair: %{
          public: :binary.copy(<<0x01>>, 32),
          private: :binary.copy(<<0x02>>, 32)
        },
        last_remote_ephemeral: :binary.copy(<<0x03>>, 32),
        previous_counter: 0
      },
      index_info: %{
        remote_identity_key: <<5>> <> :binary.copy(<<0x04>>, 32),
        local_identity_key: <<5>> <> :binary.copy(<<0x05>>, 32),
        base_key: base_key,
        base_key_type: :sending,
        closed: nil
      },
      chains: %{},
      pending_pre_key: nil,
      registration_id: 42
    }
  end
end
