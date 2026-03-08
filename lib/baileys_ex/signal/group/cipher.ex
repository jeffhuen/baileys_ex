defmodule BaileysEx.Signal.Group.Cipher do
  @moduledoc false

  alias BaileysEx.Crypto
  alias BaileysEx.Signal.Group.SenderChainKey
  alias BaileysEx.Signal.Group.SenderKeyMessage
  alias BaileysEx.Signal.Group.SenderKeyRecord
  alias BaileysEx.Signal.Group.SenderKeyState

  @max_future_messages 2000

  @spec encrypt(SenderKeyRecord.t(), binary()) ::
          {:ok, SenderKeyRecord.t(), binary()} | {:error, term()}
  def encrypt(%SenderKeyRecord{} = record, plaintext) when is_binary(plaintext) do
    with %SenderKeyState{} = state <- SenderKeyRecord.current_state(record),
         {:ok, state, sender_message_key} <- sender_key_for_encrypt(state),
         {:ok, ciphertext} <-
           Crypto.aes_cbc_encrypt(sender_message_key.cipher_key, sender_message_key.iv, plaintext),
         {:ok, sender_key_message} <-
           SenderKeyMessage.new(
             state.sender_key_id,
             sender_message_key.iteration,
             ciphertext,
             state.sender_signing_key.private
           ) do
      updated_record = SenderKeyRecord.put_state(record, state)
      {:ok, updated_record, SenderKeyMessage.serialize(sender_key_message)}
    else
      nil -> {:error, :no_sender_key_state}
      {:error, _reason} = error -> error
    end
  end

  @spec decrypt(SenderKeyRecord.t(), binary()) ::
          {:ok, SenderKeyRecord.t(), binary()} | {:error, term()}
  def decrypt(%SenderKeyRecord{} = record, message_bytes) when is_binary(message_bytes) do
    with %SenderKeyState{} = state <- sender_key_state_for_message(record, message_bytes),
         {:ok, sender_key_message} <- SenderKeyMessage.decode(message_bytes),
         true <-
           SenderKeyMessage.verify_signature(
             sender_key_message,
             SenderKeyState.signing_key_public(state)
           ),
         {:ok, state, sender_message_key} <-
           sender_key_for_iteration(state, sender_key_message.iteration),
         {:ok, plaintext} <-
           Crypto.aes_cbc_decrypt(
             sender_message_key.cipher_key,
             sender_message_key.iv,
             sender_key_message.ciphertext
           ) do
      updated_record = SenderKeyRecord.put_state(record, state)
      {:ok, updated_record, plaintext}
    else
      nil -> {:error, :no_sender_key_state}
      false -> {:error, :invalid_signature}
      {:error, _reason} = error -> error
    end
  end

  defp sender_key_state_for_message(record, message_bytes) do
    with {:ok, sender_key_message} <- SenderKeyMessage.decode(message_bytes) do
      SenderKeyRecord.state_for_key_id(record, sender_key_message.id)
    end
  end

  defp sender_key_for_encrypt(%SenderKeyState{} = state) do
    iteration =
      case state.sender_chain_key.iteration do
        0 -> 0
        current_iteration -> current_iteration + 1
      end

    sender_key_for_iteration(state, iteration)
  end

  defp sender_key_for_iteration(%SenderKeyState{} = state, iteration) do
    chain_key = state.sender_chain_key

    cond do
      chain_key.iteration > iteration ->
        sender_key_from_cache(state, iteration)

      iteration - chain_key.iteration > @max_future_messages ->
        {:error, :sender_key_too_far_in_future}

      true ->
        advance_sender_key(state, chain_key, iteration)
    end
  end

  defp sender_key_from_cache(%SenderKeyState{} = state, iteration) do
    if SenderKeyState.has_sender_message_key?(state, iteration) do
      {state, sender_message_key} = SenderKeyState.remove_sender_message_key(state, iteration)
      {:ok, state, sender_message_key}
    else
      {:error, :stale_sender_key_iteration}
    end
  end

  defp advance_sender_key(%SenderKeyState{} = state, chain_key, iteration) do
    {state, chain_key} = cache_intermediate_keys(state, chain_key, iteration)
    state = SenderKeyState.put_sender_chain_key(state, SenderChainKey.next(chain_key))
    {:ok, state, SenderChainKey.sender_message_key(chain_key)}
  end

  defp cache_intermediate_keys(%SenderKeyState{} = state, chain_key, iteration) do
    if chain_key.iteration < iteration do
      state =
        state
        |> SenderKeyState.add_sender_message_key(SenderChainKey.sender_message_key(chain_key))

      cache_intermediate_keys(state, SenderChainKey.next(chain_key), iteration)
    else
      {state, chain_key}
    end
  end
end
