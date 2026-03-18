defmodule BaileysEx.Signal.RepositoryTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Signal.Repository
  alias BaileysEx.Signal.Group.Cipher, as: GroupCipher
  alias BaileysEx.Signal.Group.SessionBuilder, as: GroupSessionBuilder
  alias BaileysEx.Signal.Group.SenderKeyName
  alias BaileysEx.Signal.Group.SenderKeyRecord
  alias BaileysEx.Signal.Store
  alias BaileysEx.TestHelpers.TelemetryHelpers

  defmodule FakeAdapter do
    @behaviour Repository.Adapter

    @impl true
    def inject_e2e_session(state, address, session) do
      key = Repository.Adapter.session_key(address)

      new_state =
        state
        |> Map.put(key, %{open?: true, session: session, history: []})
        |> Map.put(:last_injected, %{address: key, session: session})

      {:ok, new_state}
    end

    @impl true
    def validate_session(state, address) do
      case Map.get(state, Repository.Adapter.session_key(address)) do
        nil -> {:ok, :no_session}
        %{open?: true} -> {:ok, :exists}
        %{open?: false} -> {:ok, :no_open_session}
      end
    end

    @impl true
    def encrypt_message(state, address, plaintext) do
      key = Repository.Adapter.session_key(address)

      case Map.get(state, key) do
        %{open?: true} = session ->
          ciphertext = <<key::binary, "|", plaintext::binary>>

          updated_session =
            session
            |> Map.update!(:history, &[{:encrypted, plaintext} | &1])
            |> Map.put(:last_ciphertext, ciphertext)

          {:ok, Map.put(state, key, updated_session), %{type: :pkmsg, ciphertext: ciphertext}}

        _ ->
          {:error, :no_session}
      end
    end

    @impl true
    def decrypt_message(state, address, type, ciphertext) do
      key = Repository.Adapter.session_key(address)

      case {Map.get(state, key), type, ciphertext} do
        {%{open?: true} = session, :pkmsg, <<^key::binary, "|", plaintext::binary>>} ->
          updated_session = Map.update!(session, :history, &[{:decrypted, plaintext} | &1])
          {:ok, Map.put(state, key, updated_session), plaintext}

        {%{open?: true}, :msg, <<^key::binary, "|", plaintext::binary>>} ->
          {:ok, state, plaintext}

        {%{open?: true}, _, _} ->
          {:error, :invalid_ciphertext}

        _ ->
          {:error, :no_session}
      end
    end

    @impl true
    def delete_sessions(state, addresses) do
      new_state =
        Enum.reduce(addresses, state, fn address, acc ->
          Map.delete(acc, Repository.Adapter.session_key(address))
        end)

      {:ok, new_state}
    end

    @impl true
    def migrate_sessions(state, operations) do
      {new_state, migrated, total} =
        Enum.reduce(operations, {state, 0, 0}, fn operation, {acc, migrated, total} ->
          from_key = Repository.Adapter.session_key(operation.from)
          to_key = Repository.Adapter.session_key(operation.to)

          case Map.get(acc, from_key) do
            nil ->
              {acc, migrated, total}

            %{open?: true} = session ->
              updated_state =
                acc
                |> Map.put(to_key, session)
                |> Map.delete(from_key)

              {updated_state, migrated + 1, total + 1}

            _closed_session ->
              {acc, migrated, total + 1}
          end
        end)

      {:ok, new_state, %{migrated: migrated, skipped: total - migrated, total: total}}
    end

    @impl true
    def encrypt_group_message(state, sender_key_name, plaintext) do
      record =
        Map.get(
          state,
          {:sender_key, SenderKeyName.serialize(sender_key_name)},
          SenderKeyRecord.new()
        )

      with {:ok, record, distribution_message} <- GroupSessionBuilder.create(record),
           {:ok, record, ciphertext} <- GroupCipher.encrypt(record, plaintext) do
        state =
          Map.put(state, {:sender_key, SenderKeyName.serialize(sender_key_name)}, record)

        {:ok, state,
         %{ciphertext: ciphertext, sender_key_distribution_message: distribution_message}}
      end
    end

    @impl true
    def process_sender_key_distribution_message(state, sender_key_name, distribution_message) do
      record =
        Map.get(
          state,
          {:sender_key, SenderKeyName.serialize(sender_key_name)},
          SenderKeyRecord.new()
        )

      with {:ok, record} <- GroupSessionBuilder.process(record, distribution_message) do
        state = Map.put(state, {:sender_key, SenderKeyName.serialize(sender_key_name)}, record)
        {:ok, state}
      end
    end

    @impl true
    def decrypt_group_message(state, sender_key_name, ciphertext) do
      record =
        Map.get(
          state,
          {:sender_key, SenderKeyName.serialize(sender_key_name)},
          SenderKeyRecord.new()
        )

      with {:ok, record, plaintext} <- GroupCipher.decrypt(record, ciphertext) do
        state = Map.put(state, {:sender_key, SenderKeyName.serialize(sender_key_name)}, record)
        {:ok, state, plaintext}
      end
    end
  end

  defp new_repo(opts \\ []) do
    {:ok, store} = Store.start_link()
    Repository.new(Keyword.merge([adapter: FakeAdapter, store: store], opts))
  end

  describe "jid_to_signal_protocol_address/1" do
    test "requires store in direct struct construction" do
      assert_raise ArgumentError, fn ->
        struct!(Repository, adapter: FakeAdapter)
      end
    end

    test "translates WhatsApp JIDs to Baileys-compatible signal addresses" do
      assert {:ok, "5511999887766.0"} =
               Repository.jid_to_signal_protocol_address("5511999887766@s.whatsapp.net")

      assert {:ok, "5511999887766.2"} =
               Repository.jid_to_signal_protocol_address("5511999887766:2@s.whatsapp.net")

      assert {:ok, "abc123_1.0"} = Repository.jid_to_signal_protocol_address("abc123@lid")
      assert {:ok, "user_128.99"} = Repository.jid_to_signal_protocol_address("user:99@hosted")

      assert {:ok, "user_129.99"} =
               Repository.jid_to_signal_protocol_address("user:99@hosted.lid")
    end

    test "uses agent field as domain type for standard servers" do
      assert {:ok, "12345_128.0"} =
               Repository.jid_to_signal_protocol_address("12345_128@s.whatsapp.net")

      assert {:ok, "12345_128.3"} =
               Repository.jid_to_signal_protocol_address("12345_128:3@s.whatsapp.net")

      assert {:ok, "12345_128.0"} =
               Repository.jid_to_signal_protocol_address("12345_128@c.us")
    end

    test "rejects invalid device 99 addresses outside hosted domains" do
      assert {:error, :invalid_signal_address} =
               Repository.jid_to_signal_protocol_address("user:99@s.whatsapp.net")
    end
  end

  describe "repository delegation" do
    test "injects sessions, validates them, encrypts, decrypts, and deletes them" do
      repo = new_repo()

      session = %{
        registration_id: 42,
        identity_key: fixed_bytes(32, 1),
        signed_pre_key: %{
          key_id: 7,
          public_key: fixed_bytes(32, 2),
          signature: fixed_bytes(64, 3)
        },
        pre_key: %{
          key_id: 8,
          public_key: fixed_bytes(32, 4)
        }
      }

      assert {:ok, repo} =
               Repository.inject_e2e_session(repo, %{
                 jid: "5511999887766@s.whatsapp.net",
                 session: session
               })

      assert %{last_injected: %{address: "5511999887766.0", session: normalized_session}} =
               repo.adapter_state

      assert byte_size(normalized_session.identity_key) == 33
      assert byte_size(normalized_session.signed_pre_key.public_key) == 33
      assert byte_size(normalized_session.pre_key.public_key) == 33

      assert {:ok, %{exists: true}} =
               Repository.validate_session(repo, "5511999887766@s.whatsapp.net")

      assert {:ok, repo, %{type: :pkmsg, ciphertext: ciphertext}} =
               Repository.encrypt_message(repo, %{
                 jid: "5511999887766@s.whatsapp.net",
                 data: "hello"
               })

      assert ciphertext == "5511999887766.0|hello"

      assert {:ok, repo, "hello"} =
               Repository.decrypt_message(repo, %{
                 jid: "5511999887766@s.whatsapp.net",
                 type: :pkmsg,
                 ciphertext: ciphertext
               })

      assert {:ok, repo} =
               Repository.delete_session(repo, ["5511999887766@s.whatsapp.net"])

      assert {:ok, %{exists: false, reason: :no_session}} =
               Repository.validate_session(repo, "5511999887766@s.whatsapp.net")
    end

    test "encrypt and decrypt emit signal telemetry" do
      telemetry_id =
        TelemetryHelpers.attach_events(self(), [
          [:baileys_ex, :nif, :signal, :encrypt],
          [:baileys_ex, :nif, :signal, :decrypt]
        ])

      on_exit(fn -> TelemetryHelpers.detach(telemetry_id) end)

      repo = new_repo()

      session = %{
        registration_id: 42,
        identity_key: fixed_bytes(32, 1),
        signed_pre_key: %{
          key_id: 7,
          public_key: fixed_bytes(32, 2),
          signature: fixed_bytes(64, 3)
        },
        pre_key: %{
          key_id: 8,
          public_key: fixed_bytes(32, 4)
        }
      }

      assert {:ok, repo} =
               Repository.inject_e2e_session(repo, %{
                 jid: "5511999887766@s.whatsapp.net",
                 session: session
               })

      assert {:ok, repo, %{ciphertext: ciphertext}} =
               Repository.encrypt_message(repo, %{
                 jid: "5511999887766@s.whatsapp.net",
                 data: "hello"
               })

      assert_receive {:telemetry, [:baileys_ex, :nif, :signal, :encrypt], %{bytes: 5},
                      %{jid: "5511999887766@s.whatsapp.net", mode: :direct}}

      assert {:ok, _repo, "hello"} =
               Repository.decrypt_message(repo, %{
                 jid: "5511999887766@s.whatsapp.net",
                 type: :pkmsg,
                 ciphertext: ciphertext
               })

      ciphertext_bytes = byte_size(ciphertext)

      assert_receive {:telemetry, [:baileys_ex, :nif, :signal, :decrypt],
                      %{bytes: ^ciphertext_bytes},
                      %{jid: "5511999887766@s.whatsapp.net", mode: :direct}}
    end

    test "returns a structured missing-session response" do
      repo = new_repo()

      assert {:ok, %{exists: false, reason: :no_session}} =
               Repository.validate_session(repo, "5511999887766@s.whatsapp.net")
    end

    test "stores LID mappings and resolves device-specific LIDs through the repository" do
      repo = new_repo()

      assert {:ok, repo} =
               Repository.store_lid_pn_mappings(repo, [
                 %{lid: "12345@lid", pn: "5511999887766@s.whatsapp.net"}
               ])

      assert {:ok, repo, "12345:2@lid"} =
               Repository.get_lid_for_pn(repo, "5511999887766:2@s.whatsapp.net")

      assert {:ok, _repo, "5511999887766:99@s.whatsapp.net"} =
               Repository.get_pn_for_lid(repo, "12345:99@lid")
    end

    test "encrypts and validates through mapped LID sessions for PN device JIDs" do
      repo = new_repo()

      session = %{
        registration_id: 42,
        identity_key: fixed_bytes(32, 1),
        signed_pre_key: %{
          key_id: 7,
          public_key: fixed_bytes(32, 2),
          signature: fixed_bytes(64, 3)
        },
        pre_key: %{
          key_id: 8,
          public_key: fixed_bytes(32, 4)
        }
      }

      assert {:ok, repo} =
               Repository.store_lid_pn_mappings(repo, [
                 %{lid: "12345@lid", pn: "5511999887766@s.whatsapp.net"}
               ])

      assert {:ok, repo} =
               Repository.inject_e2e_session(repo, %{
                 jid: "12345:2@lid",
                 session: session
               })

      assert {:ok, %{exists: true}} =
               Repository.validate_session(repo, "5511999887766:2@s.whatsapp.net")

      assert {:ok, _repo, %{type: :pkmsg, ciphertext: ciphertext}} =
               Repository.encrypt_message(repo, %{
                 jid: "5511999887766:2@s.whatsapp.net",
                 data: "hello"
               })

      refute String.starts_with?(ciphertext, "5511999887766")
      assert String.starts_with?(ciphertext, "12345")
      assert String.ends_with?(ciphertext, "|hello")
    end

    test "trusts first use and loads identity keys through the repository" do
      {:ok, store} = Store.start_link()
      repo = new_repo(store: store)
      identity_key = fixed_bytes(32, 5)
      expected_identity_key = <<5, identity_key::binary>>

      assert {:ok, repo, true} =
               Repository.save_identity(repo, %{
                 jid: "5511999887766@s.whatsapp.net",
                 identity_key: identity_key
               })

      assert {:ok, _repo, ^expected_identity_key} =
               Repository.load_identity_key(repo, "5511999887766@s.whatsapp.net")
    end

    test "clears the canonical session when a trusted identity changes" do
      {:ok, store} = Store.start_link()

      repo =
        new_repo(
          store: store,
          adapter_state: %{
            "12345_1.0" => %{open?: true, session: %{id: 0}, history: []}
          }
        )

      assert {:ok, repo} =
               Repository.store_lid_pn_mappings(repo, [
                 %{lid: "12345@lid", pn: "5511999887766@s.whatsapp.net"}
               ])

      first_identity = fixed_bytes(32, 6)
      second_identity = fixed_bytes(32, 7)
      expected_second_identity = <<5, second_identity::binary>>

      assert {:ok, repo, true} =
               Repository.save_identity(repo, %{
                 jid: "5511999887766@s.whatsapp.net",
                 identity_key: first_identity
               })

      assert Map.has_key?(repo.adapter_state, "12345_1.0")

      assert {:ok, repo, true} =
               Repository.save_identity(repo, %{
                 jid: "5511999887766@s.whatsapp.net",
                 identity_key: second_identity
               })

      refute Map.has_key?(repo.adapter_state, "12345_1.0")

      assert {:ok, _repo, ^expected_second_identity} =
               Repository.load_identity_key(repo, "5511999887766@s.whatsapp.net")
    end

    test "migrates all open device sessions from PN to LID addresses" do
      {:ok, store} = Store.start_link()
      assert :ok = Store.set(store, %{:"device-list" => %{"5511999887766" => ["0", "2", "3"]}})

      repo =
        new_repo(
          store: store,
          adapter_state: %{
            "5511999887766.0" => %{open?: true, session: %{id: 0}, history: []},
            "5511999887766.2" => %{open?: true, session: %{id: 2}, history: []},
            "5511999887766.3" => %{open?: false, session: %{id: 3}, history: []}
          }
        )

      assert {:ok, repo, %{migrated: 2, skipped: 1, total: 3}} =
               Repository.migrate_session(
                 repo,
                 "5511999887766@s.whatsapp.net",
                 "12345@lid"
               )

      assert Map.has_key?(repo.adapter_state, "12345_1.0")
      assert Map.has_key?(repo.adapter_state, "12345_1.2")
      refute Map.has_key?(repo.adapter_state, "5511999887766.0")
      refute Map.has_key?(repo.adapter_state, "5511999887766.2")

      assert %{open?: false} = repo.adapter_state["5511999887766.3"]
      refute Map.has_key?(repo.adapter_state, "12345_1.3")
    end

    test "includes the source device even when it is missing from the stored device list" do
      {:ok, store} = Store.start_link()
      assert :ok = Store.set(store, %{:"device-list" => %{"5511999887766" => ["0", "2"]}})

      repo =
        new_repo(
          store: store,
          adapter_state: %{
            "5511999887766.4" => %{open?: true, session: %{id: 4}, history: []}
          }
        )

      assert {:ok, repo, %{migrated: 1, skipped: 0, total: 1}} =
               Repository.migrate_session(
                 repo,
                 "5511999887766:4@s.whatsapp.net",
                 "12345@lid"
               )

      assert Map.has_key?(repo.adapter_state, "12345_1.4")
      refute Map.has_key?(repo.adapter_state, "5511999887766.4")
    end

    test "preserves hosted LID targets for hosted companion sessions" do
      {:ok, store} = Store.start_link()
      assert :ok = Store.set(store, %{:"device-list" => %{"5511999887766" => ["99"]}})

      repo =
        new_repo(
          store: store,
          adapter_state: %{
            "5511999887766_128.99" => %{open?: true, session: %{id: 99}, history: []}
          }
        )

      assert {:ok, repo, %{migrated: 1, skipped: 0, total: 1}} =
               Repository.migrate_session(
                 repo,
                 "5511999887766:99@hosted",
                 "12345@hosted.lid"
               )

      assert Map.has_key?(repo.adapter_state, "12345_129.99")
      refute Map.has_key?(repo.adapter_state, "5511999887766_128.99")
    end

    test "encrypts group messages, processes sender key distribution, and decrypts them" do
      sender_repo = new_repo()
      recipient_repo = new_repo()

      assert {:ok, next_sender_repo,
              %{ciphertext: ciphertext, sender_key_distribution_message: distribution_message}} =
               Repository.encrypt_group_message(sender_repo, %{
                 group: "120363001234567890@g.us",
                 me_id: "5511999887766@s.whatsapp.net",
                 data: "hello group"
               })

      assert {:ok, recipient_repo} =
               Repository.process_sender_key_distribution_message(recipient_repo, %{
                 author_jid: "5511999887766@s.whatsapp.net",
                 item: %{
                   group_id: "120363001234567890@g.us",
                   axolotl_sender_key_distribution_message: distribution_message
                 }
               })

      assert {:ok, _recipient_repo, "hello group"} =
               Repository.decrypt_group_message(recipient_repo, %{
                 group: "120363001234567890@g.us",
                 author_jid: "5511999887766@s.whatsapp.net",
                 msg: ciphertext
               })

      refute next_sender_repo.adapter_state == %{}
    end
  end

  describe "error paths" do
    test "inject_e2e_session rejects malformed session data" do
      repo = new_repo()

      assert {:error, :invalid_session} =
               Repository.inject_e2e_session(repo, %{jid: "user@s.whatsapp.net", session: %{}})

      assert {:error, :invalid_session} =
               Repository.inject_e2e_session(repo, %{
                 jid: "user@s.whatsapp.net",
                 session: %{
                   registration_id: -1,
                   identity_key: fixed_bytes(32, 8),
                   signed_pre_key: %{
                     key_id: 1,
                     public_key: fixed_bytes(32, 9),
                     signature: fixed_bytes(64, 10)
                   },
                   pre_key: %{key_id: 1, public_key: fixed_bytes(32, 11)}
                 }
               })
    end

    test "inject_e2e_session rejects session with wrong-size public keys" do
      repo = new_repo()

      assert {:error, :invalid_session} =
               Repository.inject_e2e_session(repo, %{
                 jid: "user@s.whatsapp.net",
                 session: %{
                   registration_id: 1,
                   identity_key: <<1, 2, 3>>,
                   signed_pre_key: %{
                     key_id: 1,
                     public_key: fixed_bytes(32, 12),
                     signature: fixed_bytes(64, 13)
                   },
                   pre_key: %{key_id: 1, public_key: fixed_bytes(32, 14)}
                 }
               })
    end

    test "inject_e2e_session rejects invalid JIDs" do
      repo = new_repo()

      assert {:error, :invalid_signal_address} =
               Repository.inject_e2e_session(repo, %{
                 jid: "user@g.us",
                 session: %{
                   registration_id: 1,
                   identity_key: fixed_bytes(32, 15),
                   signed_pre_key: %{
                     key_id: 1,
                     public_key: fixed_bytes(32, 16),
                     signature: fixed_bytes(64, 17)
                   },
                   pre_key: %{key_id: 1, public_key: fixed_bytes(32, 18)}
                 }
               })
    end

    test "inject_e2e_session rejects non-map second argument" do
      repo = new_repo()
      assert {:error, :invalid_session} = Repository.inject_e2e_session(repo, "not a map")
    end

    test "encrypt_message rejects non-binary data" do
      repo = new_repo()

      assert {:error, :invalid_session} =
               Repository.encrypt_message(repo, %{jid: "u@s.whatsapp.net", data: 123})
    end

    test "encrypt_message propagates adapter no_session error" do
      repo = new_repo()

      assert {:error, :no_session} =
               Repository.encrypt_message(repo, %{
                 jid: "user@s.whatsapp.net",
                 data: "hello"
               })
    end

    test "decrypt_message rejects invalid type" do
      repo = new_repo()

      assert {:error, :invalid_ciphertext} =
               Repository.decrypt_message(repo, %{
                 jid: "user@s.whatsapp.net",
                 type: :unknown,
                 ciphertext: "data"
               })
    end

    test "decrypt_message propagates adapter no_session error" do
      repo = new_repo()

      assert {:error, :no_session} =
               Repository.decrypt_message(repo, %{
                 jid: "user@s.whatsapp.net",
                 type: :pkmsg,
                 ciphertext: "garbage"
               })
    end

    test "delete_session rejects invalid JIDs in the list" do
      repo = new_repo()

      assert {:error, :invalid_signal_address} =
               Repository.delete_session(repo, ["valid@s.whatsapp.net", "invalid@g.us"])
    end

    test "delete_session rejects non-list argument" do
      repo = new_repo()
      assert {:error, :invalid_signal_address} = Repository.delete_session(repo, "not a list")
    end

    test "validate_session rejects invalid JIDs" do
      repo = new_repo()

      assert {:error, :invalid_signal_address} =
               Repository.validate_session(repo, "user@g.us")
    end

    test "jid_to_signal_protocol_address rejects invalid JIDs" do
      assert {:error, :invalid_signal_address} =
               Repository.jid_to_signal_protocol_address("no-at-sign")

      assert {:error, :invalid_signal_address} =
               Repository.jid_to_signal_protocol_address("user@g.us")
    end

    test "save_identity rejects invalid JIDs and invalid identity keys" do
      repo = new_repo()

      assert {:error, :invalid_signal_address} =
               Repository.save_identity(repo, %{
                 jid: "user@g.us",
                 identity_key: fixed_bytes(32, 19)
               })

      assert {:error, :invalid_identity_key} =
               Repository.save_identity(repo, %{
                 jid: "user@s.whatsapp.net",
                 identity_key: <<1, 2, 3>>
               })
    end

    test "migrate_session returns zero work for unsupported direction changes" do
      repo = new_repo()

      assert {:ok, ^repo, %{migrated: 0, skipped: 0, total: 0}} =
               Repository.migrate_session(repo, "12345@lid", "5511999887766@s.whatsapp.net")
    end

    test "migrate_session returns zero work when the device list is unavailable" do
      repo =
        new_repo(
          adapter_state: %{
            "5511999887766.0" => %{open?: true, session: %{id: 0}, history: []}
          }
        )

      assert {:ok, ^repo, %{migrated: 0, skipped: 0, total: 0}} =
               Repository.migrate_session(repo, "5511999887766@s.whatsapp.net", "12345@lid")
    end

    test "decrypt_group_message propagates missing sender key state" do
      repo = new_repo()
      sender_record = SenderKeyRecord.new()

      assert {:ok, sender_record, _distribution_message} =
               GroupSessionBuilder.create(sender_record)

      assert {:ok, _sender_record, ciphertext} =
               GroupCipher.encrypt(sender_record, "hello group")

      assert {:error, :no_sender_key_state} =
               Repository.decrypt_group_message(repo, %{
                 group: "120363001234567890@g.us",
                 author_jid: "5511999887766@s.whatsapp.net",
                 msg: ciphertext
               })
    end
  end

  defp fixed_bytes(size, value), do: :binary.copy(<<value>>, size)
end
