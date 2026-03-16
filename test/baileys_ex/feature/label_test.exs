defmodule BaileysEx.Feature.LabelTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Feature.Label

  test "label CRUD and associations map to Baileys app-state patches" do
    parent = self()

    push_fun = fn patch ->
      send(parent, {:patch, patch})
      {:ok, patch}
    end

    assert {:ok, %{index: ["label_edit", "label-1"], type: :regular}} =
             Label.add_or_edit(push_fun, %{
               id: "label-1",
               name: "Important",
               color: 3,
               predefined_id: 7,
               deleted: false
             })

    assert_receive {:patch,
                    %{
                      sync_action: %{
                        label_edit_action: %{
                          name: "Important",
                          color: 3,
                          predefined_id: 7,
                          deleted: false
                        },
                        timestamp: ts1
                      },
                      api_version: 3
                    }}

    assert is_integer(ts1)

    assert {:ok, %{index: ["label_jid", "label-1", "15551234567@s.whatsapp.net"], type: :regular}} =
             Label.add_to_chat(push_fun, "15551234567@s.whatsapp.net", "label-1")

    assert_receive {:patch,
                    %{
                      sync_action: %{label_association_action: %{labeled: true}, timestamp: ts2}
                    }}

    assert is_integer(ts2)

    assert {:ok, %{index: ["label_jid", "label-1", "15551234567@s.whatsapp.net"], type: :regular}} =
             Label.remove_from_chat(push_fun, "15551234567@s.whatsapp.net", "label-1")

    assert_receive {:patch,
                    %{
                      sync_action: %{label_association_action: %{labeled: false}, timestamp: ts3}
                    }}

    assert is_integer(ts3)

    assert {:ok,
            %{
              index: [
                "label_message",
                "label-1",
                "15551234567@s.whatsapp.net",
                "wamid-1",
                "0",
                "0"
              ]
            }} =
             Label.add_to_message(push_fun, "15551234567@s.whatsapp.net", "wamid-1", "label-1")

    assert_receive {:patch,
                    %{
                      sync_action: %{label_association_action: %{labeled: true}, timestamp: ts4}
                    }}

    assert is_integer(ts4)

    assert {:ok,
            %{
              index: [
                "label_message",
                "label-1",
                "15551234567@s.whatsapp.net",
                "wamid-1",
                "0",
                "0"
              ]
            }} =
             Label.remove_from_message(
               push_fun,
               "15551234567@s.whatsapp.net",
               "wamid-1",
               "label-1"
             )

    assert_receive {:patch,
                    %{
                      sync_action: %{label_association_action: %{labeled: false}, timestamp: ts5}
                    }}

    assert is_integer(ts5)
  end

  test "label operations propagate push-patch errors" do
    assert {:error, :denied} =
             Label.add_to_chat(
               fn _patch -> {:error, :denied} end,
               "15551234567@s.whatsapp.net",
               "label-1"
             )
  end
end
