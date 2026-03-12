defmodule BaileysEx.Message.OfflineQueue do
  @moduledoc """
  FIFO offline node batching owned by the caller's process state.

  This mirrors Baileys' offline queue semantics without introducing a separate
  process: the owner keeps the queue in its state, drains up to 10 nodes per
  pass, and lets the caller reschedule the next drain when work remains.
  """

  alias BaileysEx.BinaryNode
  alias BaileysEx.Connection.EventEmitter

  @valid_types [:message, :call, :receipt, :notification]

  defstruct queue: :queue.new(), batch_size: 10, buffering?: false

  @type node_type :: :message | :call | :receipt | :notification

  @type t :: %__MODULE__{
          queue: term(),
          batch_size: pos_integer(),
          buffering?: boolean()
        }

  @type drain_result :: %{
          processed_count: non_neg_integer(),
          continue?: boolean()
        }

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{batch_size: Keyword.get(opts, :batch_size, 10)}
  end

  @spec enqueue(t(), node_type(), BinaryNode.t()) :: t()
  def enqueue(%__MODULE__{} = state, type, %BinaryNode{} = node) when type in @valid_types do
    %{state | queue: :queue.in({type, node}, state.queue)}
  end

  @spec drain(t(), map(), (node_type(), BinaryNode.t() -> :ok | {:error, term()})) ::
          {:ok, t(), drain_result()} | {:error, term(), t()}
  def drain(%__MODULE__{} = state, context, processor) when is_function(processor, 2) do
    state = maybe_begin_buffering(state, context)

    case drain_batch(state, processor, 0) do
      {:ok, state, processed_count} ->
        continue? = not :queue.is_empty(state.queue)
        state = maybe_finish_buffering(state, context, continue?)
        {:ok, state, %{processed_count: processed_count, continue?: continue?}}

      {:error, reason, state, processed_count} ->
        state = maybe_finish_buffering(state, context, false)
        {:error, {:drain_failed, reason, processed_count}, state}
    end
  end

  defp drain_batch(%__MODULE__{batch_size: batch_size} = state, _processor, processed_count)
       when processed_count >= batch_size do
    {:ok, state, processed_count}
  end

  defp drain_batch(%__MODULE__{} = state, processor, processed_count) do
    if :queue.is_empty(state.queue) do
      {:ok, state, processed_count}
    else
      {{:value, {type, node}}, queue} = :queue.out(state.queue)
      state = %{state | queue: queue}

      case processor.(type, node) do
        :ok ->
          drain_batch(state, processor, processed_count + 1)

        {:error, reason} ->
          {:error, reason, state, processed_count}
      end
    end
  end

  defp maybe_begin_buffering(%__MODULE__{buffering?: true} = state, _context), do: state

  defp maybe_begin_buffering(%__MODULE__{} = state, %{event_emitter: event_emitter}) do
    if not :queue.is_empty(state.queue) and not is_nil(event_emitter) do
      :ok = EventEmitter.buffer(event_emitter)
      %{state | buffering?: true}
    else
      state
    end
  end

  defp maybe_begin_buffering(%__MODULE__{} = state, _context), do: state

  defp maybe_finish_buffering(%__MODULE__{buffering?: false} = state, _context, _continue?),
    do: state

  defp maybe_finish_buffering(%__MODULE__{} = state, %{event_emitter: event_emitter}, true)
       when not is_nil(event_emitter),
       do: state

  defp maybe_finish_buffering(%__MODULE__{} = state, %{event_emitter: event_emitter}, false)
       when not is_nil(event_emitter) do
    _ = EventEmitter.flush(event_emitter)
    %{state | buffering?: false}
  end

  defp maybe_finish_buffering(%__MODULE__{} = state, _context, _continue?), do: state
end
