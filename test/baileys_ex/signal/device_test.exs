defmodule BaileysEx.Signal.DeviceTest do
  use ExUnit.Case, async: true

  alias BaileysEx.BinaryNode
  alias BaileysEx.Signal.Device
  alias BaileysEx.Signal.Store

  test "get_devices/3 returns cached device JIDs without issuing a USync query" do
    {:ok, store} = Store.start_link()

    assert :ok = Store.set(store, %{:"device-list" => %{"15551234567" => ["0", "2"]}})

    context = %{
      signal_store: store,
      me_id: "15550001111:1@s.whatsapp.net",
      query_fun: fn _node -> flunk("cache hit should not issue USync query") end
    }

    assert {:ok, _context, ["15551234567:0@s.whatsapp.net", "15551234567:2@s.whatsapp.net"]} =
             Device.get_devices(context, ["15551234567@s.whatsapp.net"])
  end

  test "get_devices/3 fetches uncached devices via USync and persists the cache" do
    {:ok, store} = Store.start_link()

    context = %{
      signal_store: store,
      me_id: "15550001111:1@s.whatsapp.net",
      query_fun: fn node ->
        assert %BinaryNode{tag: "iq", attrs: %{"xmlns" => "usync"}} = node

        {:ok,
         %BinaryNode{
           tag: "iq",
           attrs: %{"type" => "result"},
           content: [
             %BinaryNode{
               tag: "usync",
               attrs: %{},
               content: [
                 %BinaryNode{
                   tag: "list",
                   attrs: %{},
                   content: [
                     %BinaryNode{
                       tag: "user",
                       attrs: %{"jid" => "15551234567@s.whatsapp.net"},
                       content: [
                         %BinaryNode{
                           tag: "devices",
                           attrs: %{},
                           content: [
                             %BinaryNode{
                               tag: "device-list",
                               attrs: %{},
                               content: [
                                 %BinaryNode{tag: "device", attrs: %{"id" => "0"}},
                                 %BinaryNode{tag: "device", attrs: %{"id" => "2"}}
                               ]
                             }
                           ]
                         }
                       ]
                     }
                   ]
                 }
               ]
             }
           ]
         }}
      end
    }

    assert {:ok, _context, ["15551234567:0@s.whatsapp.net", "15551234567:2@s.whatsapp.net"]} =
             Device.get_devices(context, ["15551234567@s.whatsapp.net"])

    assert %{"15551234567" => ["0", "2"]} = Store.get(store, :"device-list", ["15551234567"])
  end
end
