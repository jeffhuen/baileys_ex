defmodule BaileysEx.Signal.DeviceTest do
  use ExUnit.Case, async: true

  alias BaileysEx.BinaryNode
  alias BaileysEx.Signal.Device
  alias BaileysEx.Signal.LIDMappingStore
  alias BaileysEx.Signal.Store

  test "get_devices/3 returns cached device JIDs without issuing a USync query" do
    {:ok, store} = Store.start_link()

    assert :ok = Store.set(store, %{:"device-list" => %{"15551234567" => ["0", "2"]}})

    context = %{
      signal_store: store,
      me_id: "15550001111:1@s.whatsapp.net",
      query_fun: fn _node -> flunk("cache hit should not issue USync query") end
    }

    assert {:ok, _context, ["15551234567@s.whatsapp.net", "15551234567:2@s.whatsapp.net"]} =
             Device.get_devices(context, ["15551234567@s.whatsapp.net"])
  end

  test "get_devices/3 fetches uncached devices via USync and persists the cache" do
    {:ok, store} = Store.start_link()

    context = %{
      signal_store: store,
      me_id: "15550001111:1@s.whatsapp.net",
      query_fun: fn node ->
        assert %BinaryNode{tag: "iq", attrs: %{"xmlns" => "usync"}} = node
        assert %BinaryNode{tag: "usync", content: usync_content} = hd(node.content)
        assert %BinaryNode{tag: "query", content: query_protocols} = Enum.at(usync_content, 0)
        assert Enum.map(query_protocols, & &1.tag) == ["devices", "lid"]

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
                           tag: "lid",
                           attrs: %{"val" => "12345@lid"},
                           content: nil
                         },
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

    assert {:ok, _context, ["15551234567@s.whatsapp.net", "15551234567:2@s.whatsapp.net"]} =
             Device.get_devices(context, ["15551234567@s.whatsapp.net"])

    assert %{"15551234567" => ["0", "2"]} = Store.get(store, :"device-list", ["15551234567"])

    assert {:ok, "12345@lid"} =
             LIDMappingStore.get_lid_for_pn(store, "15551234567@s.whatsapp.net")
  end

  test "get_devices/3 keeps pn-addressed device jids for cached pn device lists" do
    {:ok, store} = Store.start_link()

    assert :ok = Store.set(store, %{:"device-list" => %{"15551234567" => ["0", "2"]}})

    assert :ok =
             LIDMappingStore.store_lid_pn_mappings(store, [
               %{pn: "15551234567@s.whatsapp.net", lid: "12345@lid"}
             ])

    context = %{
      signal_store: store,
      me_id: "15550001111:1@s.whatsapp.net",
      query_fun: fn _node ->
        flunk("cached lookups with a stored mapping should not issue USync")
      end
    }

    assert {:ok, _context, ["15551234567@s.whatsapp.net", "15551234567:2@s.whatsapp.net"]} =
             Device.get_devices(context, ["15551234567@s.whatsapp.net"])
  end

  test "get_devices/3 returns lid-addressed device jids when the requested jid is a lid" do
    {:ok, store} = Store.start_link()

    assert :ok = Store.set(store, %{:"device-list" => %{"12345" => ["0", "2"]}})

    context = %{
      signal_store: store,
      me_id: "15550001111:1@s.whatsapp.net",
      query_fun: fn _node -> flunk("cache hit should not issue USync query") end
    }

    assert {:ok, _context, ["12345@lid", "12345:2@lid"]} =
             Device.get_devices(context, ["12345@lid"])
  end

  test "get_devices/3 maps hosted and zero-device entries to Baileys-style JIDs" do
    {:ok, store} = Store.start_link()

    context = %{
      signal_store: store,
      me_id: "15550001111:1@s.whatsapp.net",
      query_fun: fn _node ->
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
                                 %BinaryNode{
                                   tag: "device",
                                   attrs: %{
                                     "id" => "99",
                                     "key-index" => "7",
                                     "is_hosted" => "true"
                                   }
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
             }
           ]
         }}
      end
    }

    assert {:ok, _context, ["15551234567@s.whatsapp.net", "15551234567:99@hosted"]} =
             Device.get_devices(context, ["15551234567@s.whatsapp.net"])
  end
end
