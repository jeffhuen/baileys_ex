defmodule BaileysEx.Feature.QuickReply do
  @moduledoc """
  Quick reply helpers backed by Baileys app-state patches.
  """

  alias BaileysEx.Feature.AppState

  @doc "Create or edit a quick reply."
  @spec add_or_edit(term(), map()) :: {:ok, map()} | {:error, term()}
  def add_or_edit(conn, %{} = quick_reply),
    do: AppState.push_patch(conn, :quick_reply, "", quick_reply)

  @doc "Remove a quick reply by timestamp."
  @spec remove(term(), String.t() | integer()) :: {:ok, map()} | {:error, term()}
  def remove(conn, timestamp) when is_binary(timestamp) or is_integer(timestamp) do
    AppState.push_patch(conn, :quick_reply, "", %{timestamp: timestamp, deleted: true})
  end
end
