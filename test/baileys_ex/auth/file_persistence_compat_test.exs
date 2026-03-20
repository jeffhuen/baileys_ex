defmodule BaileysEx.Auth.FilePersistenceCompatTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Auth.FilePersistence
  alias BaileysEx.Protocol.Proto.ADVSignedDeviceIdentity
  alias BaileysEx.Signal.SessionRecord
  alias BaileysEx.TestSupport.DeterministicAuth

  @tag :tmp_dir
  test "save_credentials/2 writes explicit Baileys-shaped JSON without Elixir term tags", %{
    tmp_dir: tmp_dir
  } do
    state =
      DeterministicAuth.state(210)
      |> Map.put(:routing_info, <<1, 2, 3, 4>>)
      |> Map.put(:me, %{id: "15551234567@s.whatsapp.net", lid: "12345678901234@lid", name: "~"})
      |> Map.put(:account, %ADVSignedDeviceIdentity{
        details: <<5, 6, 7>>,
        account_signature: <<8, 9>>,
        account_signature_key: <<10, 11>>,
        device_signature: <<12, 13>>
      })
      |> Map.put(:processed_history_messages, [
        %{
          key: %{
            id: "hist-1",
            remote_jid: "15559999999@s.whatsapp.net",
            remote_jid_alt: nil,
            participant: nil,
            participant_alt: nil,
            from_me: false,
            addressing_mode: :pn,
            server_id: 42
          },
          message_timestamp: 1_710_000_600
        }
      ])
      |> Map.put(:additional_data, %{
        "labels" => ["alpha", "beta"],
        "token" => <<14, 15, 16>>
      })

    assert :ok = FilePersistence.save_credentials(tmp_dir, state)
    assert {:ok, ^state} = FilePersistence.load_credentials(tmp_dir)

    json = File.read!(Path.join(tmp_dir, "creds.json")) |> JSON.decode!()

    refute String.contains?(File.read!(Path.join(tmp_dir, "creds.json")), "\"__type__\"")
    refute String.contains?(File.read!(Path.join(tmp_dir, "creds.json")), "\"__atom_keys__\"")

    assert %{
             "noise_key" => %{"private" => %{"type" => "Buffer", "data" => _}, "public" => _},
             "routing_info" => %{"type" => "Buffer", "data" => "AQIDBA=="},
             "account" => %{
               "details" => %{"type" => "Buffer", "data" => _},
               "account_signature" => %{"type" => "Buffer", "data" => _}
             },
             "processed_history_messages" => [
               %{
                 "key" => %{
                   "id" => "hist-1",
                   "remote_jid" => "15559999999@s.whatsapp.net",
                   "addressing_mode" => "pn",
                   "from_me" => false,
                   "server_id" => 42
                 },
                 "message_timestamp" => 1_710_000_600
               }
             ],
             "additional_data" => %{
               "labels" => ["alpha", "beta"],
               "token" => %{"type" => "Buffer", "data" => "Dg8Q"}
             }
           } = json
  end

  @tag :tmp_dir
  test "save_keys/4 writes explicit session JSON without Elixir term tags", %{tmp_dir: tmp_dir} do
    session_key =
      <<5, 47, 94, 146, 126, 20, 145, 64, 167, 132, 196, 186, 86, 38, 23, 215, 31, 144, 133, 214,
        230, 196, 84, 64, 227, 163, 144, 29, 239, 76, 133, 227, 35>>

    record =
      SessionRecord.new()
      |> SessionRecord.put_session(session_key, session(session_key))

    assert :ok = FilePersistence.save_keys(tmp_dir, :session, "16268980123.0", record)
    assert {:ok, ^record} = FilePersistence.load_keys(tmp_dir, :session, "16268980123.0")

    contents = File.read!(Path.join(tmp_dir, "session-16268980123.0.json"))
    json = JSON.decode!(contents)
    encoded_session_key = Base.encode64(session_key)

    refute String.contains?(contents, "\"__type__\"")
    refute String.contains?(contents, "\"__atom_keys__\"")

    assert %{
             "sessions" => %{
               ^encoded_session_key => %{
                 "current_ratchet" => %{
                   "ephemeral_key_pair" => %{
                     "private" => %{"type" => "Buffer", "data" => _},
                     "public" => %{"type" => "Buffer", "data" => _}
                   }
                 },
                 "index_info" => %{
                   "base_key_type" => "sending",
                   "base_key" => %{"type" => "Buffer", "data" => ^encoded_session_key}
                 },
                 "chains" => chains
               }
             }
           } = json

    assert map_size(chains) == 1

    assert [
             {_,
              %{
                "chain_type" => "receiving",
                "message_keys" => %{"7" => %{"type" => "Buffer", "data" => "Kiss"}}
              }}
           ] = Map.to_list(chains)
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
          message_keys: %{7 => <<42, 43, 44>>}
        }
      }
    }
  end
end
