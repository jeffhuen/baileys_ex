defmodule BaileysEx.Feature.QuickReplyTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Feature.QuickReply

  test "add_or_edit and remove map to Baileys quick-reply patches" do
    parent = self()

    push_fun = fn patch ->
      send(parent, {:patch, patch})
      {:ok, patch}
    end

    assert {:ok, %{index: ["quick_reply", "1710000000"], type: :regular}} =
             QuickReply.add_or_edit(push_fun, %{
               timestamp: "1710000000",
               shortcut: "/hi",
               message: "Hello there"
             })

    assert_receive {:patch,
                    %{
                      sync_action: %{
                        quick_reply_action: %{
                          shortcut: "/hi",
                          message: "Hello there",
                          keywords: [],
                          count: 0,
                          deleted: false
                        },
                        timestamp: ts1
                      },
                      api_version: 2
                    }}

    assert is_integer(ts1)

    assert {:ok, %{index: ["quick_reply", "1710000000"], type: :regular}} =
             QuickReply.remove(push_fun, "1710000000")

    assert_receive {:patch,
                    %{
                      sync_action: %{
                        quick_reply_action: %{
                          shortcut: "",
                          message: "",
                          keywords: [],
                          count: 0,
                          deleted: true
                        },
                        timestamp: ts2
                      },
                      operation: :set
                    }}

    assert is_integer(ts2)
  end
end
