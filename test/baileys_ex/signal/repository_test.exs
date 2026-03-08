defmodule BaileysEx.Signal.RepositoryTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Signal.Repository

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
  end

  describe "jid_to_signal_protocol_address/1" do
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
      repo = Repository.new(adapter: FakeAdapter)

      session = %{
        registration_id: 42,
        identity_key: :crypto.strong_rand_bytes(32),
        signed_pre_key: %{
          key_id: 7,
          public_key: :crypto.strong_rand_bytes(32),
          signature: :crypto.strong_rand_bytes(64)
        },
        pre_key: %{
          key_id: 8,
          public_key: :crypto.strong_rand_bytes(32)
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

    test "returns a structured missing-session response" do
      repo = Repository.new(adapter: FakeAdapter)

      assert {:ok, %{exists: false, reason: :no_session}} =
               Repository.validate_session(repo, "5511999887766@s.whatsapp.net")
    end
  end

  describe "error paths" do
    test "inject_e2e_session rejects malformed session data" do
      repo = Repository.new(adapter: FakeAdapter)

      assert {:error, :invalid_session} =
               Repository.inject_e2e_session(repo, %{jid: "user@s.whatsapp.net", session: %{}})

      assert {:error, :invalid_session} =
               Repository.inject_e2e_session(repo, %{
                 jid: "user@s.whatsapp.net",
                 session: %{
                   registration_id: -1,
                   identity_key: :crypto.strong_rand_bytes(32),
                   signed_pre_key: %{
                     key_id: 1,
                     public_key: :crypto.strong_rand_bytes(32),
                     signature: :crypto.strong_rand_bytes(64)
                   },
                   pre_key: %{key_id: 1, public_key: :crypto.strong_rand_bytes(32)}
                 }
               })
    end

    test "inject_e2e_session rejects session with wrong-size public keys" do
      repo = Repository.new(adapter: FakeAdapter)

      assert {:error, :invalid_session} =
               Repository.inject_e2e_session(repo, %{
                 jid: "user@s.whatsapp.net",
                 session: %{
                   registration_id: 1,
                   identity_key: <<1, 2, 3>>,
                   signed_pre_key: %{
                     key_id: 1,
                     public_key: :crypto.strong_rand_bytes(32),
                     signature: :crypto.strong_rand_bytes(64)
                   },
                   pre_key: %{key_id: 1, public_key: :crypto.strong_rand_bytes(32)}
                 }
               })
    end

    test "inject_e2e_session rejects invalid JIDs" do
      repo = Repository.new(adapter: FakeAdapter)

      assert {:error, :invalid_signal_address} =
               Repository.inject_e2e_session(repo, %{
                 jid: "user@g.us",
                 session: %{
                   registration_id: 1,
                   identity_key: :crypto.strong_rand_bytes(32),
                   signed_pre_key: %{
                     key_id: 1,
                     public_key: :crypto.strong_rand_bytes(32),
                     signature: :crypto.strong_rand_bytes(64)
                   },
                   pre_key: %{key_id: 1, public_key: :crypto.strong_rand_bytes(32)}
                 }
               })
    end

    test "inject_e2e_session rejects non-map second argument" do
      repo = Repository.new(adapter: FakeAdapter)
      assert {:error, :invalid_session} = Repository.inject_e2e_session(repo, "not a map")
    end

    test "encrypt_message rejects non-binary data" do
      repo = Repository.new(adapter: FakeAdapter)

      assert {:error, :invalid_session} =
               Repository.encrypt_message(repo, %{jid: "u@s.whatsapp.net", data: 123})
    end

    test "encrypt_message propagates adapter no_session error" do
      repo = Repository.new(adapter: FakeAdapter)

      assert {:error, :no_session} =
               Repository.encrypt_message(repo, %{
                 jid: "user@s.whatsapp.net",
                 data: "hello"
               })
    end

    test "decrypt_message rejects invalid type" do
      repo = Repository.new(adapter: FakeAdapter)

      assert {:error, :invalid_ciphertext} =
               Repository.decrypt_message(repo, %{
                 jid: "user@s.whatsapp.net",
                 type: :unknown,
                 ciphertext: "data"
               })
    end

    test "decrypt_message propagates adapter no_session error" do
      repo = Repository.new(adapter: FakeAdapter)

      assert {:error, :no_session} =
               Repository.decrypt_message(repo, %{
                 jid: "user@s.whatsapp.net",
                 type: :pkmsg,
                 ciphertext: "garbage"
               })
    end

    test "delete_session rejects invalid JIDs in the list" do
      repo = Repository.new(adapter: FakeAdapter)

      assert {:error, :invalid_signal_address} =
               Repository.delete_session(repo, ["valid@s.whatsapp.net", "invalid@g.us"])
    end

    test "delete_session rejects non-list argument" do
      repo = Repository.new(adapter: FakeAdapter)
      assert {:error, :invalid_signal_address} = Repository.delete_session(repo, "not a list")
    end

    test "validate_session rejects invalid JIDs" do
      repo = Repository.new(adapter: FakeAdapter)

      assert {:error, :invalid_signal_address} =
               Repository.validate_session(repo, "user@g.us")
    end

    test "jid_to_signal_protocol_address rejects invalid JIDs" do
      assert {:error, :invalid_signal_address} =
               Repository.jid_to_signal_protocol_address("no-at-sign")

      assert {:error, :invalid_signal_address} =
               Repository.jid_to_signal_protocol_address("user@g.us")
    end
  end
end
