defmodule BaileysEx.Feature.Contact do
  @moduledoc """
  Contact CRUD helpers backed by Baileys app-state patches.
  """

  alias BaileysEx.Feature.AppState

  @doc "Add or edit a contact."
  @spec add_or_edit(term(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def add_or_edit(conn, jid, %{} = contact_action) when is_binary(jid) do
    AppState.push_patch(conn, :contact, jid, contact_action)
  end

  @doc "Remove a contact."
  @spec remove(term(), String.t()) :: {:ok, map()} | {:error, term()}
  def remove(conn, jid) when is_binary(jid), do: AppState.push_patch(conn, :contact, jid, nil)
end
