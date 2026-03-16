defmodule BaileysEx.Signal.SessionCipher do
  @moduledoc false

  alias BaileysEx.Crypto
  alias BaileysEx.Signal.Curve
  alias BaileysEx.Signal.PreKeyWhisperMessage
  alias BaileysEx.Signal.SessionBuilder
  alias BaileysEx.Signal.SessionRecord
  alias BaileysEx.Signal.WhisperMessage

  @message_key_seed <<1>>
  @chain_key_seed <<2>>
  @whisper_message_keys "WhisperMessageKeys"
  @whisper_ratchet "WhisperRatchet"
  @zero_salt <<0::256>>
  @max_skipped_keys 2000

  @doc """
  Encrypt plaintext using the session in `record`.

  Returns `{:ok, updated_record, %{type: :pkmsg | :msg, ciphertext: binary()}}`.
  """
  @spec encrypt(SessionRecord.t(), binary(), keyword()) ::
          {:ok, SessionRecord.t(), %{type: :pkmsg | :msg, ciphertext: binary()}}
          | {:error, term()}
  def encrypt(%SessionRecord{} = record, plaintext, opts \\ []) do
    case SessionRecord.get_open_session(record) do
      nil ->
        {:error, :no_session}

      {base_key, session} ->
        do_encrypt(record, base_key, session, plaintext, opts)
    end
  end

  @doc """
  Decrypt a PreKeyWhisperMessage (new session establishment + message).
  """
  @spec decrypt_pre_key_whisper_message(SessionRecord.t(), binary(), keyword()) ::
          {:ok, SessionRecord.t(), binary(), non_neg_integer() | nil} | {:error, term()}
  def decrypt_pre_key_whisper_message(%SessionRecord{} = record, ciphertext, opts \\ []) do
    with {:ok, pkmsg} <- PreKeyWhisperMessage.decode(ciphertext),
         our_keys <- build_our_keys(opts),
         {:ok, record, used_pre_key_id} <-
           init_or_reuse_incoming_session(record, pkmsg, our_keys, opts),
         {:ok, record, plaintext} <- decrypt_whisper_message(record, pkmsg.message, opts) do
      {:ok, record, plaintext, used_pre_key_id}
    end
  end

  @doc """
  Decrypt a WhisperMessage (established session).
  """
  @spec decrypt_whisper_message(SessionRecord.t(), binary(), keyword()) ::
          {:ok, SessionRecord.t(), binary()} | {:error, term()}
  def decrypt_whisper_message(%SessionRecord{} = record, ciphertext, opts \\ []) do
    with {:ok, whisper_msg} <- WhisperMessage.decode(ciphertext) do
      try_decrypt_sessions(record, whisper_msg, opts)
    end
  end

  # -- Encryption internals --

  defp do_encrypt(record, base_key, session, plaintext, opts) do
    sending_chain_key_entry = get_sending_chain(session)

    if sending_chain_key_entry == nil do
      {:error, :no_sending_chain}
    else
      {chain_b64, chain} = sending_chain_key_entry
      chain_key = chain.chain_key

      # Derive message key from chain key
      message_key_seed = Crypto.hmac_sha256(chain_key.key, @message_key_seed)
      {:ok, derived} = Crypto.hkdf(message_key_seed, @whisper_message_keys, 80, @zero_salt)
      <<cipher_key::binary-32, mac_key::binary-32, iv::binary-16>> = derived

      # Advance chain key
      next_chain_key = Crypto.hmac_sha256(chain_key.key, @chain_key_seed)

      updated_chain = %{
        chain
        | chain_key: %{counter: chain_key.counter + 1, key: next_chain_key}
      }

      session = put_in(session.chains[chain_b64], updated_chain)

      # Encrypt
      {:ok, ciphertext} = Crypto.aes_cbc_encrypt(cipher_key, iv, plaintext)

      # Build WhisperMessage
      ratchet_key = session.current_ratchet.ephemeral_key_pair.public

      sender_identity = session.index_info.local_identity_key
      receiver_identity = session.index_info.remote_identity_key

      {:ok, whisper_msg} =
        WhisperMessage.new(
          ratchet_key,
          chain_key.counter,
          session.current_ratchet.previous_counter,
          ciphertext,
          mac_key,
          sender_identity,
          receiver_identity
        )

      # Wrap in PreKeyWhisperMessage if pending
      {type, final_ciphertext, session} =
        case session.pending_pre_key do
          nil ->
            {:msg, WhisperMessage.serialize(whisper_msg), session}

          pending ->
            registration_id = Keyword.get(opts, :registration_id, session.registration_id)

            {:ok, pkmsg} =
              PreKeyWhisperMessage.new(
                registration_id: registration_id,
                pre_key_id: pending.pre_key_id,
                signed_pre_key_id: pending.signed_pre_key_id,
                base_key: pending.base_key,
                identity_key: sender_identity,
                message: WhisperMessage.serialize(whisper_msg)
              )

            {:pkmsg, PreKeyWhisperMessage.serialize(pkmsg), session}
        end

      record = SessionRecord.put_session(record, base_key, session)
      {:ok, record, %{type: type, ciphertext: final_ciphertext}}
    end
  end

  defp get_sending_chain(session) do
    case session.current_ratchet.ephemeral_key_pair do
      nil ->
        nil

      ephemeral ->
        chain_key = Base.encode64(ephemeral.public)

        case Map.get(session.chains, chain_key) do
          nil -> nil
          %{chain_type: :sending} = chain -> {chain_key, chain}
          _ -> nil
        end
    end
  end

  # -- Decryption internals --

  defp try_decrypt_sessions(record, whisper_msg, opts) do
    # Try the open session first, then closed sessions
    sessions_to_try =
      case SessionRecord.get_open_session(record) do
        {base_key, session} ->
          closed =
            Enum.filter(record.sessions, fn {k, s} ->
              k != base_key and s.index_info.closed != nil
            end)

          [{base_key, session} | closed]

        nil ->
          Enum.filter(record.sessions, fn {_k, s} -> s.index_info.closed != nil end)
      end

    try_decrypt_session_list(record, sessions_to_try, whisper_msg, opts)
  end

  defp try_decrypt_session_list(_record, [], _whisper_msg, _opts) do
    {:error, :no_session}
  end

  defp try_decrypt_session_list(record, [{base_key, session} | rest], whisper_msg, opts) do
    case do_decrypt(session, whisper_msg, opts) do
      {:ok, updated_session, plaintext} ->
        record = SessionRecord.put_session(record, base_key, updated_session)
        {:ok, record, plaintext}

      {:error, _reason} ->
        try_decrypt_session_list(record, rest, whisper_msg, opts)
    end
  end

  defp do_decrypt(session, whisper_msg, opts) do
    their_ephemeral = ensure_signal_public_key!(whisper_msg.ratchet_key)
    their_ephemeral_b64 = Base.encode64(their_ephemeral)

    session =
      if Map.has_key?(session.chains, their_ephemeral_b64) do
        session
      else
        perform_ratchet_step(session, their_ephemeral, whisper_msg.previous_counter, opts)
      end

    chain = Map.get(session.chains, their_ephemeral_b64)

    if chain == nil do
      {:error, :no_chain}
    else
      decrypt_from_chain(session, their_ephemeral_b64, chain, whisper_msg)
    end
  end

  defp decrypt_from_chain(session, chain_b64, chain, whisper_msg) do
    counter = whisper_msg.counter
    chain_key = chain.chain_key

    cond do
      # Message key already cached (out-of-order)
      Map.has_key?(chain.message_keys, counter) ->
        message_key_seed = Map.fetch!(chain.message_keys, counter)
        updated_chain = %{chain | message_keys: Map.delete(chain.message_keys, counter)}
        session = put_in(session.chains[chain_b64], updated_chain)
        do_decrypt_with_key(session, whisper_msg, message_key_seed)

      is_nil(chain_key.key) ->
        {:error, :message_key_already_consumed}

      chain_key.counter > counter ->
        {:error, :message_key_already_consumed}

      counter - chain_key.counter > @max_skipped_keys ->
        {:error, :too_many_skipped_keys}

      true ->
        # Advance chain, caching intermediate keys
        {chain, message_key_seed} = advance_chain_to(chain, counter)
        session = put_in(session.chains[chain_b64], chain)
        do_decrypt_with_key(session, whisper_msg, message_key_seed)
    end
  end

  defp advance_chain_to(chain, target_counter) do
    chain_key = chain.chain_key

    if chain_key.counter == target_counter do
      # Derive and consume current
      message_key_seed = Crypto.hmac_sha256(chain_key.key, @message_key_seed)
      next_key = Crypto.hmac_sha256(chain_key.key, @chain_key_seed)
      chain = %{chain | chain_key: %{counter: chain_key.counter + 1, key: next_key}}
      {chain, message_key_seed}
    else
      # Cache intermediate key
      message_key_seed = Crypto.hmac_sha256(chain_key.key, @message_key_seed)
      next_key = Crypto.hmac_sha256(chain_key.key, @chain_key_seed)

      chain = %{
        chain
        | chain_key: %{counter: chain_key.counter + 1, key: next_key},
          message_keys: Map.put(chain.message_keys, chain_key.counter, message_key_seed)
      }

      advance_chain_to(chain, target_counter)
    end
  end

  defp do_decrypt_with_key(session, whisper_msg, message_key_seed) do
    {:ok, derived} = Crypto.hkdf(message_key_seed, @whisper_message_keys, 80, @zero_salt)
    <<cipher_key::binary-32, mac_key::binary-32, iv::binary-16>> = derived

    # Verify MAC
    sender_identity = session.index_info.remote_identity_key
    receiver_identity = session.index_info.local_identity_key

    if WhisperMessage.verify_mac(whisper_msg, mac_key, sender_identity, receiver_identity) do
      case Crypto.aes_cbc_decrypt(cipher_key, iv, whisper_msg.ciphertext) do
        {:ok, plaintext} -> {:ok, %{session | pending_pre_key: nil}, plaintext}
        {:error, _} -> {:error, :decrypt_failed}
      end
    else
      {:error, :bad_mac}
    end
  end

  # -- DH Ratchet step --

  defp perform_ratchet_step(session, their_new_ephemeral, previous_counter, opts) do
    ratchet = session.current_ratchet
    our_current_ephemeral = ratchet.ephemeral_key_pair

    session =
      maybe_close_receiving_chain(
        session,
        ratchet.last_remote_ephemeral,
        previous_counter
      )

    next_previous_counter = current_sending_counter(session, our_current_ephemeral)

    # Step 1: DH with their new ephemeral and our current ephemeral → receiving chain
    {:ok, receiving_secret} = Curve.shared_key(our_current_ephemeral.private, their_new_ephemeral)

    {:ok, receiving_derived} =
      Crypto.hkdf(receiving_secret, @whisper_ratchet, 64, ratchet.root_key)

    <<root_key_1::binary-32, receiving_chain_key::binary-32>> = receiving_derived

    # Step 2: Generate new ephemeral, DH with their new ephemeral → sending chain
    new_ephemeral =
      opts
      |> Keyword.get_lazy(:ratchet_key_pair, &Curve.generate_key_pair/0)
      |> ensure_signal_key_pair!()

    {:ok, sending_secret} = Curve.shared_key(new_ephemeral.private, their_new_ephemeral)
    {:ok, sending_derived} = Crypto.hkdf(sending_secret, @whisper_ratchet, 64, root_key_1)
    <<new_root_key::binary-32, sending_chain_key::binary-32>> = sending_derived

    session = maybe_drop_sending_chain(session, our_current_ephemeral)

    session = %{
      session
      | current_ratchet: %{
          root_key: new_root_key,
          ephemeral_key_pair: new_ephemeral,
          last_remote_ephemeral: their_new_ephemeral,
          previous_counter: next_previous_counter
        },
        chains:
          session.chains
          |> Map.put(Base.encode64(their_new_ephemeral), %{
            chain_key: %{counter: 0, key: receiving_chain_key},
            chain_type: :receiving,
            message_keys: %{}
          })
          |> Map.put(Base.encode64(new_ephemeral.public), %{
            chain_key: %{counter: 0, key: sending_chain_key},
            chain_type: :sending,
            message_keys: %{}
          })
    }

    session
  end

  defp build_our_keys(opts) do
    signed_pre_key = Keyword.fetch!(opts, :signed_pre_key_pair)
    pre_key = Keyword.get(opts, :pre_key_pair)

    keys = %{signed_pre_key: signed_pre_key}

    if pre_key do
      Map.put(keys, :pre_key, pre_key)
    else
      keys
    end
  end

  defp init_or_reuse_incoming_session(record, pkmsg, our_keys, opts) do
    if SessionRecord.get_session(record, pkmsg.base_key) do
      {:ok, record, nil}
    else
      with {:ok, record} <-
             SessionBuilder.init_incoming(
               record,
               %{identity_key: pkmsg.identity_key, base_key: pkmsg.base_key},
               our_keys,
               opts
             ) do
        {:ok, record, pkmsg.pre_key_id}
      end
    end
  end

  defp maybe_close_receiving_chain(session, nil, _previous_counter), do: session

  defp maybe_close_receiving_chain(session, remote_ephemeral, previous_counter) do
    chain_key = Base.encode64(remote_ephemeral)

    case Map.get(session.chains, chain_key) do
      %{chain_type: :receiving} = chain ->
        closed_chain = cache_message_keys_until(chain, previous_counter)
        put_in(session.chains[chain_key], put_in(closed_chain.chain_key.key, nil))

      _ ->
        session
    end
  end

  defp cache_message_keys_until(chain, previous_counter) do
    chain_key = chain.chain_key

    cond do
      is_nil(chain_key.key) ->
        chain

      chain_key.counter > previous_counter ->
        chain

      true ->
        message_key_seed = Crypto.hmac_sha256(chain_key.key, @message_key_seed)
        next_key = Crypto.hmac_sha256(chain_key.key, @chain_key_seed)

        updated_chain = %{
          chain
          | chain_key: %{counter: chain_key.counter + 1, key: next_key},
            message_keys: Map.put(chain.message_keys, chain_key.counter, message_key_seed)
        }

        cache_message_keys_until(updated_chain, previous_counter)
    end
  end

  defp current_sending_counter(_session, nil), do: 0

  defp current_sending_counter(session, %{public: public}) do
    case Map.get(session.chains, Base.encode64(public)) do
      %{chain_key: %{counter: counter}} -> max(counter - 1, 0)
      _ -> 0
    end
  end

  defp maybe_drop_sending_chain(session, nil), do: session

  defp maybe_drop_sending_chain(session, %{public: public}) do
    update_in(session.chains, &Map.delete(&1, Base.encode64(public)))
  end

  defp ensure_signal_key_pair!(%{public: public_key} = key_pair) do
    {:ok, signal_public_key} = Curve.generate_signal_pub_key(public_key)
    %{key_pair | public: signal_public_key}
  end

  defp ensure_signal_public_key!(public_key) do
    {:ok, signal_public_key} = Curve.generate_signal_pub_key(public_key)
    signal_public_key
  end
end
