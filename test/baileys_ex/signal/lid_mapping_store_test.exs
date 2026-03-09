defmodule BaileysEx.Signal.LIDMappingStoreTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Signal.LIDMappingStore
  alias BaileysEx.Signal.Store

  setup do
    {:ok, store} = Store.start_link()
    %{store: store}
  end

  describe "store_lid_pn_mappings/2" do
    test "stores valid mappings and resolves device-specific LIDs for PN lookups", %{store: store} do
      assert :ok =
               LIDMappingStore.store_lid_pn_mappings(store, [
                 %{lid: "12345@lid", pn: "5511999887766@s.whatsapp.net"}
               ])

      assert {:ok, "12345@lid"} =
               LIDMappingStore.get_lid_for_pn(store, "5511999887766@s.whatsapp.net")

      assert {:ok, "12345:2@lid"} =
               LIDMappingStore.get_lid_for_pn(store, "5511999887766:2@s.whatsapp.net")
    end

    test "preserves Baileys-style forward and reverse entry keys", %{store: store} do
      assert :ok =
               LIDMappingStore.store_lid_pn_mappings(store, [
                 %{lid: "12345@lid", pn: "5511999887766@s.whatsapp.net"}
               ])

      assert %{"5511999887766" => "12345", "12345_reverse" => "5511999887766"} =
               Store.get(store, :"lid-mapping", ["5511999887766", "12345_reverse"])
    end

    test "maps a standard LID with device 99 back to a standard PN with the same device", %{
      store: store
    } do
      assert :ok =
               LIDMappingStore.store_lid_pn_mappings(store, [
                 %{lid: "12345@lid", pn: "5511999887766@s.whatsapp.net"}
               ])

      assert {:ok, "5511999887766:99@s.whatsapp.net"} =
               LIDMappingStore.get_pn_for_lid(store, "12345:99@lid")
    end

    test "ignores invalid pairs and keeps valid ones", %{store: store} do
      assert :ok =
               LIDMappingStore.store_lid_pn_mappings(store, [
                 %{lid: "12345@lid", pn: "5511999887766@s.whatsapp.net"},
                 %{lid: "120363001234567890@g.us", pn: "5511999887766@s.whatsapp.net"}
               ])

      assert {:ok, "12345@lid"} =
               LIDMappingStore.get_lid_for_pn(store, "5511999887766@s.whatsapp.net")
    end
  end

  describe "misses" do
    test "uses the lookup function for missing PN mappings and preserves hosted devices", %{
      store: store
    } do
      lookup = fn ["5511999887766@s.whatsapp.net"] ->
        [%{lid: "12345@lid", pn: "5511999887766@s.whatsapp.net"}]
      end

      assert {:ok, "12345:99@hosted.lid"} =
               LIDMappingStore.get_lid_for_pn(store, "5511999887766:99@hosted", lookup: lookup)
    end

    test "coalesces concurrent misses through the store transaction boundary", %{store: store} do
      parent = self()

      lookup = fn ["5511999887766@s.whatsapp.net"] ->
        send(parent, :lookup_called)
        Process.sleep(50)
        [%{lid: "12345@lid", pn: "5511999887766@s.whatsapp.net"}]
      end

      first =
        Task.async(fn ->
          LIDMappingStore.get_lid_for_pn(store, "5511999887766:2@s.whatsapp.net", lookup: lookup)
        end)

      second =
        Task.async(fn ->
          LIDMappingStore.get_lid_for_pn(store, "5511999887766:99@hosted", lookup: lookup)
        end)

      assert_receive :lookup_called
      refute_receive :lookup_called, 20

      assert {:ok, "12345:2@lid"} = Task.await(first)
      assert {:ok, "12345:99@hosted.lid"} = Task.await(second)
    end

    test "returns nil when no reverse mapping exists", %{store: store} do
      assert {:ok, nil} = LIDMappingStore.get_pn_for_lid(store, "nonexistent@lid")
    end

    test "does not reverse-resolve hosted.lid addresses", %{store: store} do
      assert :ok =
               LIDMappingStore.store_lid_pn_mappings(store, [
                 %{lid: "12345@lid", pn: "5511999887766@s.whatsapp.net"}
               ])

      assert {:ok, nil} = LIDMappingStore.get_pn_for_lid(store, "12345:99@hosted.lid")
    end
  end
end
