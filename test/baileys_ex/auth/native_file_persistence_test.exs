defmodule BaileysEx.Auth.NativeFilePersistenceTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Auth.KeyStore
  alias BaileysEx.Auth.NativeFilePersistence
  alias BaileysEx.Auth.State
  alias BaileysEx.Signal.SessionRecord
  alias BaileysEx.TestSupport.DeterministicAuth

  @tag :tmp_dir
  test "load_credentials/1 initializes fresh credentials when creds.etf is missing", %{
    tmp_dir: tmp_dir
  } do
    assert {:ok, %State{} = state} = NativeFilePersistence.load_credentials(tmp_dir)

    assert state.registered == false
    refute File.exists?(Path.join(tmp_dir, "creds.etf"))
  end

  @tag :tmp_dir
  test "save_credentials/2 roundtrips BEAM terms through ETF", %{tmp_dir: tmp_dir} do
    state =
      DeterministicAuth.state(150)
      |> Map.put(:platform, "macOS")
      |> Map.put(:routing_info, <<1, 2, 3, 4>>)
      |> Map.put(:pairing_code, "123-456")
      |> Map.put(:additional_data, %{
        labels: [:alpha, :beta],
        nested: %{token: <<5, 6, 7>>, status: {:ok, 42}}
      })

    assert :ok = NativeFilePersistence.save_credentials(tmp_dir, state)
    assert {:ok, ^state} = NativeFilePersistence.load_credentials(tmp_dir)

    encoded = File.read!(Path.join(tmp_dir, "creds.etf"))

    assert %State{platform: "macOS", additional_data: %{labels: [:alpha, :beta]}} =
             :erlang.binary_to_term(encoded, [:safe])
  end

  @tag :tmp_dir
  test "key data is stored in sanitized per-key ETF files and can be deleted", %{tmp_dir: tmp_dir} do
    assert :ok =
             NativeFilePersistence.save_keys(
               tmp_dir,
               :"device-list",
               "alice/device:0",
               ["primary", "companion"]
             )

    assert {:ok, ["primary", "companion"]} =
             NativeFilePersistence.load_keys(tmp_dir, :"device-list", "alice/device:0")

    assert File.exists?(Path.join(tmp_dir, "device-list-alice__device-0.etf"))

    assert :ok = NativeFilePersistence.delete_keys(tmp_dir, :"device-list", "alice/device:0")

    assert {:error, :not_found} =
             NativeFilePersistence.load_keys(tmp_dir, :"device-list", "alice/device:0")
  end

  @tag :tmp_dir
  test "load_credentials/1 ignores orphan temp files from interrupted writes and keeps the last committed state",
       %{tmp_dir: tmp_dir} do
    committed_state = DeterministicAuth.state(160) |> Map.put(:platform, "stable")
    orphan_state = DeterministicAuth.state(161) |> Map.put(:platform, "orphan")
    assert :ok = NativeFilePersistence.save_credentials(tmp_dir, committed_state)

    File.write!(
      Path.join(tmp_dir, "creds.etf.tmp-orphan"),
      :erlang.term_to_binary(orphan_state)
    )

    assert {:ok, ^committed_state} = NativeFilePersistence.load_credentials(tmp_dir)
  end

  @tag :tmp_dir
  test "load_keys/3 ignores orphan temp files from interrupted writes and keeps the last committed key data",
       %{tmp_dir: tmp_dir} do
    assert :ok =
             NativeFilePersistence.save_keys(
               tmp_dir,
               :"device-list",
               "15551234567",
               ["0", "2"]
             )

    File.write!(
      Path.join(tmp_dir, "device-list-15551234567.etf.tmp-orphan"),
      :erlang.term_to_binary(["9"])
    )

    assert {:ok, ["0", "2"]} =
             NativeFilePersistence.load_keys(tmp_dir, :"device-list", "15551234567")
  end

  @tag :tmp_dir
  test "session records with non-UTF-8 binary keys roundtrip through ETF key persistence", %{
    tmp_dir: tmp_dir
  } do
    session_key =
      <<5, 47, 94, 146, 126, 20, 145, 64, 167, 132, 196, 186, 86, 38, 23, 215, 31, 144, 133, 214,
        230, 196, 84, 64, 227, 163, 144, 29, 239, 76, 133, 227, 35>>

    session_record =
      SessionRecord.new()
      |> SessionRecord.put_session(session_key, session(session_key))

    assert :ok =
             NativeFilePersistence.save_keys(tmp_dir, :session, "16268980123.0", session_record)

    assert {:ok, ^session_record} =
             NativeFilePersistence.load_keys(tmp_dir, :session, "16268980123.0")
  end

  @tag :tmp_dir
  test "use_native_file_auth_state/1 returns connect opts for the native file-backed Signal store",
       %{
         tmp_dir: tmp_dir
       } do
    state = DeterministicAuth.state(170) |> Map.put(:platform, "ios")
    assert :ok = NativeFilePersistence.save_credentials(tmp_dir, state)

    assert {:ok, persisted_auth} = NativeFilePersistence.use_native_file_auth_state(tmp_dir)

    assert persisted_auth.state == state
    assert persisted_auth.connect_opts[:signal_store_module] == KeyStore

    assert Keyword.take(persisted_auth.connect_opts[:signal_store_opts], [
             :persistence_module,
             :persistence_context
           ]) == [persistence_module: NativeFilePersistence, persistence_context: tmp_dir]

    updated_state =
      persisted_auth.state
      |> Map.put(:pairing_code, "ABC-123")
      |> Map.put(:additional_data, %{labels: [:native]})

    assert :ok = persisted_auth.save_creds.(updated_state)

    assert {:ok, %State{pairing_code: "ABC-123", additional_data: %{labels: [:native]}}} =
             NativeFilePersistence.load_credentials(tmp_dir)
  end

  defp session(session_key) do
    %{
      current_ratchet: %{
        root_key: <<11, 12, 13>>,
        ephemeral_key_pair: %{public: <<14, 15, 16>>, private: <<17, 18, 19>>},
        last_remote_ephemeral: <<20, 21, 22>>,
        previous_counter: 7
      },
      index_info: %{
        remote_identity_key: <<23, 24, 25>>,
        local_identity_key: <<26, 27, 28>>,
        base_key: session_key,
        base_key_type: :sending,
        closed: -1
      },
      pending_pre_key: %{signed_pre_key_id: 9, base_key: <<29, 30>>, pre_key_id: 10},
      registration_id: 12_345,
      chains: %{
        <<31, 32, 33>> => %{
          chain_key: %{counter: 1, key: <<34, 35, 36>>},
          chain_type: :receiving,
          message_keys: %{}
        }
      }
    }
  end
end
