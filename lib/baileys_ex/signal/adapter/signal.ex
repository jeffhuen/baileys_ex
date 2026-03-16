defmodule BaileysEx.Signal.Adapter.Signal do
  @moduledoc false

  @behaviour BaileysEx.Signal.Repository.Adapter

  alias BaileysEx.Signal.Address
  alias BaileysEx.Signal.Curve
  alias BaileysEx.Signal.Group.Cipher, as: GroupCipher
  alias BaileysEx.Signal.Group.SenderKeyName
  alias BaileysEx.Signal.Group.SenderKeyRecord
  alias BaileysEx.Signal.Group.SessionBuilder, as: GroupSessionBuilder
  alias BaileysEx.Signal.Identity
  alias BaileysEx.Signal.SessionBuilder
  alias BaileysEx.Signal.SessionCipher
  alias BaileysEx.Signal.SessionRecord
  alias BaileysEx.Signal.Store

  @type state :: %{
          store: Store.t(),
          identity_key_pair: %{public: binary(), private: binary()},
          registration_id: non_neg_integer(),
          signed_pre_key: %{
            key_id: non_neg_integer(),
            key_pair: %{public: binary(), private: binary()}
          }
        }

  @spec new(keyword()) :: state()
  def new(opts) do
    %{
      store: Keyword.fetch!(opts, :store),
      identity_key_pair: Keyword.fetch!(opts, :identity_key_pair),
      registration_id: Keyword.fetch!(opts, :registration_id),
      signed_pre_key: Keyword.fetch!(opts, :signed_pre_key)
    }
  end

  # -- 1:1 callbacks --

  @impl true
  def inject_e2e_session(state, %Address{} = address, session) do
    session_key = session_key(address)

    case Store.transaction(state.store, "session:#{session_key}", fn ->
           persist_outgoing_session(state, session_key, address, session)
         end) do
      :ok -> {:ok, state}
      {:error, _} = error -> error
    end
  end

  @impl true
  def validate_session(state, %Address{} = address) do
    session_key = session_key(address)
    record = load_session_record(state.store, session_key)

    cond do
      SessionRecord.empty?(record) -> {:ok, :no_session}
      SessionRecord.have_open_session?(record) -> {:ok, :exists}
      true -> {:ok, :no_open_session}
    end
  end

  @impl true
  def encrypt_message(state, %Address{} = address, plaintext) do
    session_key = session_key(address)

    result =
      Store.transaction(state.store, "session:#{session_key}", fn ->
        record = load_session_record(state.store, session_key)

        case SessionCipher.encrypt(record, plaintext, registration_id: state.registration_id) do
          {:ok, record, encrypted} ->
            save_session_record(state.store, session_key, record)
            {:ok, encrypted}

          {:error, _} = error ->
            error
        end
      end)

    case result do
      {:ok, encrypted} -> {:ok, state, encrypted}
      {:error, _} = error -> error
    end
  end

  @impl true
  def decrypt_message(state, %Address{} = address, type, ciphertext) do
    session_key = session_key(address)

    result =
      Store.transaction(state.store, "session:#{session_key}", fn ->
        record = load_session_record(state.store, session_key)
        do_decrypt(state, address, session_key, record, type, ciphertext)
      end)

    case result do
      {:ok, plaintext} -> {:ok, state, plaintext}
      {:error, _} = error -> error
    end
  end

  defp do_decrypt(state, address, session_key, record, :pkmsg, ciphertext) do
    record = prepare_pkmsg_record(state.store, address, session_key, record, ciphertext)
    opts = build_pkmsg_opts(state, ciphertext)

    case SessionCipher.decrypt_pre_key_whisper_message(record, ciphertext, opts) do
      {:ok, record, plaintext, used_pre_key_id} ->
        save_session_record(state.store, session_key, record)
        maybe_remove_pre_key(state.store, used_pre_key_id)
        {:ok, plaintext}

      {:error, _} = error ->
        error
    end
  end

  defp do_decrypt(state, _address, session_key, record, :msg, ciphertext) do
    case SessionCipher.decrypt_whisper_message(record, ciphertext) do
      {:ok, record, plaintext} ->
        save_session_record(state.store, session_key, record)
        {:ok, plaintext}

      {:error, _} = error ->
        error
    end
  end

  defp build_pkmsg_opts(state, ciphertext) do
    opts = [
      identity_key_pair: state.identity_key_pair,
      signed_pre_key_pair: state.signed_pre_key.key_pair,
      registration_id: state.registration_id
    ]

    case load_pre_key(state.store, ciphertext) do
      nil -> opts
      pre_key_pair -> Keyword.put(opts, :pre_key_pair, pre_key_pair)
    end
  end

  defp prepare_pkmsg_record(store, address, session_key, record, ciphertext) do
    with {:ok, pkmsg} <- BaileysEx.Signal.PreKeyWhisperMessage.decode(ciphertext) do
      case Identity.save(store, address, pkmsg.identity_key) do
        {:ok, :changed} ->
          Store.set(store, %{session: %{session_key => nil}})
          SessionRecord.new()

        {:ok, _save_result} ->
          record

        {:error, _reason} ->
          record
      end
    else
      _ -> record
    end
  end

  @impl true
  def delete_sessions(state, addresses) do
    Enum.each(addresses, fn address ->
      session_key = session_key(address)
      Store.set(state.store, %{session: %{session_key => nil}})
    end)

    {:ok, state}
  end

  @impl true
  def migrate_sessions(state, operations) do
    {migrated, skipped, total} =
      Enum.reduce(operations, {0, 0, 0}, fn op, {m, s, t} ->
        from_key = session_key(op.from)
        to_key = session_key(op.to)

        case load_session_raw(state.store, from_key) do
          %SessionRecord{} = session_data ->
            if SessionRecord.have_open_session?(session_data) do
              Store.set(state.store, %{
                session: %{to_key => session_data, from_key => nil}
              })

              {m + 1, s, t + 1}
            else
              {m, s + 1, t + 1}
            end

          _ ->
            {m, s + 1, t + 1}
        end
      end)

    {:ok, state, %{migrated: migrated, skipped: skipped, total: total}}
  end

  # -- Group callbacks (delegate to existing group modules) --

  @impl true
  def encrypt_group_message(state, %SenderKeyName{} = sender_key_name, plaintext) do
    sk_key = SenderKeyName.serialize(sender_key_name)

    result =
      Store.transaction(state.store, "sender-key:#{sk_key}", fn ->
        record = load_sender_key_record(state.store, sk_key)

        with {:ok, record, distribution_message} <- GroupSessionBuilder.create(record),
             {:ok, record, ciphertext} <- GroupCipher.encrypt(record, plaintext) do
          save_sender_key_record(state.store, sk_key, record)

          {:ok, %{ciphertext: ciphertext, sender_key_distribution_message: distribution_message}}
        end
      end)

    case result do
      {:ok, encrypted} -> {:ok, state, encrypted}
      {:error, _} = error -> error
    end
  end

  @impl true
  def process_sender_key_distribution_message(
        state,
        %SenderKeyName{} = sender_key_name,
        distribution_message
      ) do
    sk_key = SenderKeyName.serialize(sender_key_name)

    Store.transaction(state.store, "sender-key:#{sk_key}", fn ->
      record = load_sender_key_record(state.store, sk_key)

      case GroupSessionBuilder.process(record, distribution_message) do
        {:ok, record} ->
          save_sender_key_record(state.store, sk_key, record)
          :ok

        {:error, _} = error ->
          error
      end
    end)
    |> case do
      :ok -> {:ok, state}
      {:error, _} = error -> error
    end
  end

  @impl true
  def decrypt_group_message(state, %SenderKeyName{} = sender_key_name, ciphertext) do
    sk_key = SenderKeyName.serialize(sender_key_name)

    result =
      Store.transaction(state.store, "sender-key:#{sk_key}", fn ->
        record = load_sender_key_record(state.store, sk_key)

        case GroupCipher.decrypt(record, ciphertext) do
          {:ok, record, plaintext} ->
            save_sender_key_record(state.store, sk_key, record)
            {:ok, plaintext}

          {:error, _} = error ->
            error
        end
      end)

    case result do
      {:ok, plaintext} -> {:ok, state, plaintext}
      {:error, _} = error -> error
    end
  end

  # -- Helpers --

  defp session_key(%Address{} = address), do: Address.to_string(address)

  defp load_session_record(store, session_key) do
    case Store.get(store, :session, [session_key]) do
      %{^session_key => %SessionRecord{} = record} -> record
      _ -> SessionRecord.new()
    end
  end

  defp load_session_raw(store, session_key) do
    case Store.get(store, :session, [session_key]) do
      %{^session_key => data} -> data
      _ -> nil
    end
  end

  defp save_session_record(store, session_key, record) do
    Store.set(store, %{session: %{session_key => record}})
  end

  defp load_sender_key_record(store, sk_key) do
    case Store.get(store, :"sender-key", [sk_key]) do
      %{^sk_key => %SenderKeyRecord{} = record} -> record
      _ -> SenderKeyRecord.new()
    end
  end

  defp save_sender_key_record(store, sk_key, record) do
    Store.set(store, %{:"sender-key" => %{sk_key => record}})
  end

  defp load_pre_key(store, ciphertext) do
    with {:ok, pkmsg} <- BaileysEx.Signal.PreKeyWhisperMessage.decode(ciphertext),
         pre_key_id when is_integer(pre_key_id) <- pkmsg.pre_key_id do
      key = Integer.to_string(pre_key_id)

      case Store.get(store, :"pre-key", [key]) do
        %{^key => %{public: _, private: _} = key_pair} -> key_pair
        _ -> nil
      end
    else
      _ -> nil
    end
  end

  defp maybe_remove_pre_key(_store, nil), do: :ok

  defp maybe_remove_pre_key(store, pre_key_id) do
    key = Integer.to_string(pre_key_id)
    Store.set(store, %{:"pre-key" => %{key => nil}})
  end

  defp persist_outgoing_session(state, session_key, address, session) do
    record = load_session_record(state.store, session_key)

    with {:ok, bundle, their_identity_key} <- build_outgoing_bundle(session),
         {:ok, record, _base_key} <-
           SessionBuilder.init_outgoing(record, bundle,
             identity_key_pair: state.identity_key_pair,
             base_key_pair: Curve.generate_key_pair()
           ),
         {:ok, _save_result} <- Identity.save(state.store, address, their_identity_key) do
      save_session_record(state.store, session_key, record)
      :ok
    end
  end

  defp build_outgoing_bundle(session) do
    their_identity_key = session.identity_key
    their_signed_pre_key = session.signed_pre_key.public_key
    their_signed_pre_key_sig = session.signed_pre_key.signature

    if Curve.verify(their_identity_key, their_signed_pre_key, their_signed_pre_key_sig) do
      {:ok,
       %{
         identity_key: strip_signal_prefix(their_identity_key),
         signed_pre_key: strip_signal_prefix(their_signed_pre_key),
         pre_key: extract_pre_key(session.pre_key),
         registration_id: session.registration_id,
         signed_pre_key_id: session.signed_pre_key.key_id,
         pre_key_id: get_in(session, [:pre_key, :key_id])
       }, their_identity_key}
    else
      {:error, :invalid_signature}
    end
  end

  defp extract_pre_key(%{key_id: _, public_key: pk}) when is_binary(pk) and byte_size(pk) >= 32,
    do: strip_signal_prefix(pk)

  defp extract_pre_key(_pre_key), do: nil

  defp strip_signal_prefix(<<5, key::binary-32>>), do: key
  defp strip_signal_prefix(<<key::binary-32>>), do: key
  defp strip_signal_prefix(key), do: key
end
