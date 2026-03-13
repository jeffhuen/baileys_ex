defmodule BaileysEx.TestHelpers.MessageSignalHelpers do
  @moduledoc false

  alias BaileysEx.Signal.Group.Cipher, as: GroupCipher
  alias BaileysEx.Signal.Group.SenderKeyName
  alias BaileysEx.Signal.Group.SenderKeyRecord
  alias BaileysEx.Signal.Group.SessionBuilder, as: GroupSessionBuilder
  alias BaileysEx.Signal.Repository
  alias BaileysEx.Signal.Store

  defmodule FakeAdapter do
    @moduledoc false
    @behaviour Repository.Adapter

    @impl true
    def inject_e2e_session(state, address, session) do
      key = Repository.Adapter.session_key(address)

      {:ok,
       state
       |> Map.put(key, %{open?: true, session: session, history: []})
       |> Map.put(:last_injected, %{address: key, session: session})}
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
          {:ok, Map.put(state, key, Map.update!(session, :history, &[{:decrypted, plaintext} | &1])), plaintext}

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
              {acc |> Map.put(to_key, session) |> Map.delete(from_key), migrated + 1, total + 1}

            _closed ->
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
        {:ok,
         Map.put(state, {:sender_key, SenderKeyName.serialize(sender_key_name)}, record),
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
        {:ok, Map.put(state, {:sender_key, SenderKeyName.serialize(sender_key_name)}, record)}
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
        {:ok, Map.put(state, {:sender_key, SenderKeyName.serialize(sender_key_name)}, record), plaintext}
      end
    end
  end

  def new_repo(opts \\ []) do
    {:ok, store} = Store.start_link()
    repo = Repository.new(Keyword.merge([adapter: FakeAdapter, store: store], opts))
    {repo, store}
  end

  def session_fixture do
    %{
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
  end
end
