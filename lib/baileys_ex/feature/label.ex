defmodule BaileysEx.Feature.Label do
  @moduledoc """
  Label CRUD and association helpers backed by Baileys app-state patches.
  """

  alias BaileysEx.Feature.AppState

  @doc "Create or edit a label via the `addLabel` patch shape."
  @spec add_or_edit(term(), map()) :: {:ok, map()} | {:error, term()}
  def add_or_edit(conn, %{} = label), do: AppState.push_patch(conn, :add_label, "", label)

  @doc "Associate a label with a chat."
  @spec add_to_chat(term(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def add_to_chat(conn, jid, label_id) when is_binary(jid) and is_binary(label_id) do
    AppState.push_patch(conn, :add_chat_label, jid, %{label_id: label_id})
  end

  @doc "Remove a label association from a chat."
  @spec remove_from_chat(term(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def remove_from_chat(conn, jid, label_id) when is_binary(jid) and is_binary(label_id) do
    AppState.push_patch(conn, :remove_chat_label, jid, %{label_id: label_id})
  end

  @doc "Associate a label with a specific message."
  @spec add_to_message(term(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def add_to_message(conn, jid, message_id, label_id)
      when is_binary(jid) and is_binary(message_id) and is_binary(label_id) do
    AppState.push_patch(conn, :add_message_label, jid, %{
      message_id: message_id,
      label_id: label_id
    })
  end

  @doc "Remove a label association from a specific message."
  @spec remove_from_message(term(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def remove_from_message(conn, jid, message_id, label_id)
      when is_binary(jid) and is_binary(message_id) and is_binary(label_id) do
    AppState.push_patch(conn, :remove_message_label, jid, %{
      message_id: message_id,
      label_id: label_id
    })
  end
end
