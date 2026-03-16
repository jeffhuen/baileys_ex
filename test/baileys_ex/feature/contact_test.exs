defmodule BaileysEx.Feature.ContactTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Feature.Contact

  test "add_or_edit and remove map to Baileys contact patches" do
    parent = self()

    push_fun = fn patch ->
      send(parent, {:patch, patch})
      {:ok, patch}
    end

    assert {:ok, %{index: ["contact", "15551234567@s.whatsapp.net"], type: :critical_unblock_low}} =
             Contact.add_or_edit(push_fun, "15551234567@s.whatsapp.net", %{
               full_name: "Ada Lovelace",
               first_name: "Ada",
               pn_jid: "15551234567@s.whatsapp.net",
               save_on_primary_addressbook: true
             })

    assert_receive {:patch,
                    %{
                      operation: :set,
                      sync_action: %{
                        contact_action: %{
                          full_name: "Ada Lovelace",
                          first_name: "Ada",
                          pn_jid: "15551234567@s.whatsapp.net",
                          save_on_primary_addressbook: true
                        },
                        timestamp: ts1
                      },
                      api_version: 2
                    }}

    assert is_integer(ts1)

    assert {:ok, %{index: ["contact", "15551234567@s.whatsapp.net"], type: :critical_unblock_low}} =
             Contact.remove(push_fun, "15551234567@s.whatsapp.net")

    assert_receive {:patch,
                    %{
                      operation: :remove,
                      sync_action: %{contact_action: %{}, timestamp: ts2}
                    }}

    assert is_integer(ts2)
  end
end
