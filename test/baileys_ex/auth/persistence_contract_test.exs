defmodule BaileysEx.Auth.PersistenceContractTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Auth.FilePersistence
  alias BaileysEx.Auth.KeyStore
  alias BaileysEx.Auth.NativeFilePersistence
  alias BaileysEx.Auth.State
  alias BaileysEx.Signal.SessionRecord
  alias BaileysEx.TestSupport.DeterministicAuth

  @backends [
    {:compat_json, FilePersistence, :use_multi_file_auth_state},
    {:native_file, NativeFilePersistence, :use_native_file_auth_state}
  ]
  @contract_seed 410

  @tag :tmp_dir
  test "built-in persistence backends roundtrip the same logical auth state and key datasets",
       %{tmp_dir: tmp_dir} do
    Enum.each(@backends, fn {name, persistence_module, helper_fun} ->
      path = Path.join(tmp_dir, Atom.to_string(name))
      assert_backend_roundtrip(persistence_module, helper_fun, path, @contract_seed)
    end)
  end

  @tag :tmp_dir
  test "built-in persistence backends expose the same helper contract and persisted key index",
       %{tmp_dir: tmp_dir} do
    expected_key_index = %{
      :"device-list" => ["15551234567"],
      :"identity-key" => ["alice.0"],
      :session => ["16268980123.0"],
      :tctoken => ["15551234567@s.whatsapp.net"]
    }

    Enum.each(@backends, fn {name, persistence_module, helper_fun} ->
      path = Path.join(tmp_dir, Atom.to_string(name))
      state = contract_state(@contract_seed)

      assert :ok = persistence_module.save_credentials(path, state)
      assert :ok = persistence_module.save_keys(path, :"device-list", "15551234567", ["0", "2"])
      assert :ok = persistence_module.save_keys(path, :"identity-key", "alice.0", <<1, 2, 3>>)

      assert :ok =
               persistence_module.save_keys(
                 path,
                 :session,
                 "16268980123.0",
                 session_record(@contract_seed)
               )

      assert :ok =
               persistence_module.save_keys(
                 path,
                 :tctoken,
                 "15551234567@s.whatsapp.net",
                 %{token: <<9, 8, 7>>, timestamp: "1710000000"}
               )

      assert {:ok, persisted_auth} = apply(persistence_module, helper_fun, [path])
      assert %State{} = persisted_auth.state
      assert persisted_auth.connect_opts[:signal_store_module] == KeyStore

      assert Keyword.take(persisted_auth.connect_opts[:signal_store_opts], [
               :persistence_module,
               :persistence_context
             ]) == [persistence_module: persistence_module, persistence_context: path]

      assert is_function(persisted_auth.save_creds, 1)
      assert {:ok, ^expected_key_index} = persistence_module.list_persisted_keys(path)
    end)
  end

  defp assert_backend_roundtrip(persistence_module, helper_fun, path, seed) do
    state = contract_state(seed)
    session_record = session_record(seed)

    assert :ok = persistence_module.save_credentials(path, state)
    assert :ok = persistence_module.save_keys(path, :"device-list", "15551234567", ["0", "2"])
    assert :ok = persistence_module.save_keys(path, :"identity-key", "alice.0", <<1, 2, 3>>)
    assert :ok = persistence_module.save_keys(path, :session, "16268980123.0", session_record)

    assert :ok =
             persistence_module.save_keys(
               path,
               :tctoken,
               "15551234567@s.whatsapp.net",
               %{token: <<9, 8, 7>>, timestamp: "1710000000"}
             )

    assert {:ok, ^state} = persistence_module.load_credentials(path)
    assert {:ok, ["0", "2"]} = persistence_module.load_keys(path, :"device-list", "15551234567")
    assert {:ok, <<1, 2, 3>>} = persistence_module.load_keys(path, :"identity-key", "alice.0")
    assert {:ok, ^session_record} = persistence_module.load_keys(path, :session, "16268980123.0")

    assert {:ok, %{token: <<9, 8, 7>>, timestamp: "1710000000"}} =
             persistence_module.load_keys(path, :tctoken, "15551234567@s.whatsapp.net")

    assert {:ok, persisted_auth} = apply(persistence_module, helper_fun, [path])
    assert persisted_auth.state == state

    updated_state =
      state
      |> Map.put(:pairing_code, "PAIR-#{seed}")
      |> Map.put(:platform, "contract-updated-#{seed}")

    assert :ok = persisted_auth.save_creds.(updated_state)
    assert {:ok, ^updated_state} = persistence_module.load_credentials(path)
  end

  defp contract_state(seed) do
    DeterministicAuth.state(seed)
    |> Map.put(:platform, "contract-#{seed}")
    |> Map.put(:routing_info, <<1, 2, 3, rem(seed, 256)>>)
    |> Map.put(:pairing_code, "PAIR-#{seed}")
    |> Map.put(:additional_data, %{
      "labels" => ["alpha", "beta"],
      "nested" => %{"token" => <<5, 6, 7>>}
    })
    |> Map.put(:processed_history_messages, [
      %{
        key: %{
          id: "hist-#{seed}",
          remote_jid: "15551234567@s.whatsapp.net",
          remote_jid_alt: nil,
          participant: nil,
          participant_alt: nil,
          from_me: false,
          addressing_mode: :pn,
          server_id: nil
        },
        message_timestamp: 1_710_000_000 + seed
      }
    ])
  end

  defp session_record(seed) do
    base_key = :binary.copy(<<rem(seed, 256)>>, 32)

    SessionRecord.new()
    |> SessionRecord.put_session(base_key, %{
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
    })
  end
end
