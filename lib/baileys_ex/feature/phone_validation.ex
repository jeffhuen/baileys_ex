defmodule BaileysEx.Feature.PhoneValidation do
  @moduledoc """
  Phone-number registration checks via the USync contact protocol.
  """

  alias BaileysEx.BinaryNode
  import BaileysEx.Connection.TransportAdapter, only: [query: 3]
  alias BaileysEx.Protocol.USync

  @doc """
  Check one or more phone numbers with the USync contact protocol.

  This mirrors Baileys `onWhatsApp`: LID inputs are skipped, and only users
  confirmed as WhatsApp contacts are returned.
  """
  @spec on_whatsapp(term(), [String.t()], keyword()) ::
          {:ok, [%{exists: boolean(), jid: String.t()}]} | {:error, term()}
  def on_whatsapp(queryable, phone_numbers, opts \\ []) when is_list(phone_numbers) do
    query =
      Enum.reduce(
        phone_numbers,
        USync.new(context: :interactive) |> USync.with_protocol(:contact),
        fn phone_number, acc ->
          case normalize_phone(phone_number) do
            nil ->
              acc

            phone ->
              USync.with_user(acc, %{phone: phone})
          end
        end
      )

    if query.users == [] do
      {:ok, []}
    else
      sid =
        Keyword.get_lazy(opts, :sid, fn ->
          Integer.to_string(System.unique_integer([:positive]))
        end)

      timeout = Keyword.get(opts, :query_timeout, 60_000)

      with {:ok, node} <-
             USync.to_node(query, sid),
           {:ok, %BinaryNode{} = response} <- query(queryable, node, timeout),
           {:ok, %{list: list}} <- USync.parse_result(query, response) do
        {:ok,
         list
         |> Enum.filter(& &1.contact)
         |> Enum.map(&%{jid: &1.id, exists: true})}
      end
    end
  end

  defp normalize_phone(phone_number) when is_binary(phone_number) do
    if String.ends_with?(phone_number, "@lid") do
      nil
    else
      "+" <>
        (phone_number
         |> String.trim_leading("+")
         |> String.split("@")
         |> List.first()
         |> String.split(":")
         |> List.first())
    end
  end
end
