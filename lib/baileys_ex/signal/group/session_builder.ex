defmodule BaileysEx.Signal.Group.SessionBuilder do
  @moduledoc false

  alias BaileysEx.Crypto
  alias BaileysEx.Signal.Curve
  alias BaileysEx.Signal.Group.SenderKeyDistributionMessage
  alias BaileysEx.Signal.Group.SenderKeyRecord
  alias BaileysEx.Signal.Group.SenderKeyState

  @max_sender_key_id 2_147_483_647

  @spec create(SenderKeyRecord.t()) ::
          {:ok, SenderKeyRecord.t(), binary()} | {:error, term()}
  def create(%SenderKeyRecord{} = record) do
    record =
      if SenderKeyRecord.empty?(record) do
        key_id = :rand.uniform(@max_sender_key_id) - 1
        sender_key = Crypto.random_bytes(32)
        signing_key = Curve.generate_key_pair()
        SenderKeyRecord.set_state(record, key_id, 0, sender_key, signing_key)
      else
        record
      end

    state = SenderKeyRecord.current_state(record)

    distribution_message =
      SenderKeyDistributionMessage.new(
        state.sender_key_id,
        state.sender_chain_key.iteration,
        state.sender_chain_key.seed,
        SenderKeyState.signing_key_public(state)
      )

    {:ok, record, SenderKeyDistributionMessage.encode(distribution_message)}
  end

  @spec process(SenderKeyRecord.t(), binary() | SenderKeyDistributionMessage.t()) ::
          {:ok, SenderKeyRecord.t()} | {:error, term()}
  def process(%SenderKeyRecord{} = record, %SenderKeyDistributionMessage{} = message) do
    {:ok,
     SenderKeyRecord.add_state(
       record,
       message.id,
       message.iteration,
       message.chain_key,
       message.signing_key
     )}
  end

  def process(%SenderKeyRecord{} = record, distribution_message)
      when is_binary(distribution_message) do
    with {:ok, message} <- SenderKeyDistributionMessage.decode(distribution_message) do
      process(record, message)
    end
  end
end
