defmodule BaileysEx.Auth.FilePersistenceTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Auth.FilePersistence
  alias BaileysEx.Auth.State

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
      State.new()
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
  test "concurrent writes to the same creds file remain decodable", %{tmp_dir: tmp_dir} do
    first_state = State.new() |> Map.put(:platform, "alpha")
    second_state = State.new() |> Map.put(:platform, "beta")

    tasks = [
      Task.async(fn -> FilePersistence.save_credentials(tmp_dir, first_state) end),
      Task.async(fn -> FilePersistence.save_credentials(tmp_dir, second_state) end)
    ]

    assert [:ok, :ok] = Enum.map(tasks, &Task.await(&1, 1_000))

    assert {:ok, %State{platform: platform}} = FilePersistence.load_credentials(tmp_dir)
    assert platform in ["alpha", "beta"]
  end
end
