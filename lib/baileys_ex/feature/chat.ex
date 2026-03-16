defmodule BaileysEx.Feature.Chat do
  @moduledoc """
  Chat-level operations backed by app-state patches.
  """

  alias BaileysEx.Feature.AppState

  @doc "Archive or unarchive a chat using the Baileys archive patch shape."
  @spec archive(term(), String.t(), boolean(), list()) :: {:ok, map()} | {:error, term()}
  def archive(conn, jid, archive?, last_messages)
      when is_binary(jid) and is_list(last_messages) do
    AppState.push_patch(conn, :archive, jid, %{archive: archive?, last_messages: last_messages})
  end

  @doc "Mute a chat until the given Unix timestamp, or pass `nil` to unmute."
  @spec mute(term(), String.t(), integer() | nil) :: {:ok, map()} | {:error, term()}
  def mute(conn, jid, duration) when is_binary(jid),
    do: AppState.push_patch(conn, :mute, jid, duration)

  @doc "Pin or unpin a chat."
  @spec pin(term(), String.t(), boolean()) :: {:ok, map()} | {:error, term()}
  def pin(conn, jid, pin?) when is_binary(jid), do: AppState.push_patch(conn, :pin, jid, pin?)

  @doc "Star or unstar one or more messages in a chat."
  @spec star(term(), String.t(), [map()], boolean()) :: {:ok, map()} | {:error, term()}
  def star(conn, jid, messages, star?) when is_binary(jid) and is_list(messages) do
    AppState.push_patch(conn, :star, jid, %{messages: messages, star: star?})
  end

  @doc "Delete a chat using the last-message range required by Syncd."
  @spec delete(term(), String.t(), list()) :: {:ok, map()} | {:error, term()}
  def delete(conn, jid, last_messages) when is_binary(jid) and is_list(last_messages) do
    AppState.push_patch(conn, :delete, jid, %{last_messages: last_messages})
  end

  @doc "Clear a chat history using the last-message range required by Syncd."
  @spec clear(term(), String.t(), list()) :: {:ok, map()} | {:error, term()}
  def clear(conn, jid, last_messages) when is_binary(jid) and is_list(last_messages) do
    AppState.push_patch(conn, :clear, jid, %{last_messages: last_messages})
  end

  @doc "Mark a chat read or unread."
  @spec mark_read(term(), String.t(), boolean(), list()) :: {:ok, map()} | {:error, term()}
  def mark_read(conn, jid, read?, last_messages) when is_binary(jid) and is_list(last_messages) do
    AppState.push_patch(conn, :mark_read, jid, %{read: read?, last_messages: last_messages})
  end

  @doc "Delete a specific message for the current device."
  @spec delete_message_for_me(term(), String.t(), map(), integer(), boolean()) ::
          {:ok, map()} | {:error, term()}
  def delete_message_for_me(conn, jid, message_key, timestamp, delete_media? \\ false)
      when is_binary(jid) and is_map(message_key) and is_integer(timestamp) do
    AppState.push_patch(conn, :delete_for_me, jid, %{
      key: message_key,
      timestamp: timestamp,
      delete_media: delete_media?
    })
  end

  @doc "Toggle the privacy setting that disables link previews server-side."
  @spec update_disable_link_previews_privacy(term(), boolean()) ::
          {:ok, map()} | {:error, term()}
  def update_disable_link_previews_privacy(conn, disabled?) do
    AppState.push_patch(conn, :disable_link_previews, "", disabled?)
  end

  @doc "Elixir-friendly alias for `update_disable_link_previews_privacy/2`."
  @spec update_link_previews(term(), boolean()) :: {:ok, map()} | {:error, term()}
  def update_link_previews(conn, disabled?),
    do: update_disable_link_previews_privacy(conn, disabled?)
end
