defmodule BaileysEx.Signal.LIDMappingStoreTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Signal.LIDMappingStore

  describe "store_lid_pn_mappings/2" do
    test "stores valid mappings and resolves device-specific LIDs for PN lookups" do
      store = LIDMappingStore.new()

      assert {:ok, store} =
               LIDMappingStore.store_lid_pn_mappings(store, [
                 %{lid: "12345@lid", pn: "5511999887766@s.whatsapp.net"}
               ])

      assert {:ok, store, "12345@lid"} =
               LIDMappingStore.get_lid_for_pn(store, "5511999887766@s.whatsapp.net")

      assert {:ok, _store, "12345:2@lid"} =
               LIDMappingStore.get_lid_for_pn(store, "5511999887766:2@s.whatsapp.net")
    end

    test "preserves Baileys-style forward and reverse entry keys" do
      store = LIDMappingStore.new()

      assert {:ok, store} =
               LIDMappingStore.store_lid_pn_mappings(store, [
                 %{lid: "12345@lid", pn: "5511999887766@s.whatsapp.net"}
               ])

      assert {:ok, entries} = Map.fetch(store, :entries)
      assert %{"5511999887766" => "12345", "12345_reverse" => "5511999887766"} = entries
    end

    test "maps a standard LID with device 99 back to a standard PN with the same device" do
      store = LIDMappingStore.new()

      assert {:ok, store} =
               LIDMappingStore.store_lid_pn_mappings(store, [
                 %{lid: "12345@lid", pn: "5511999887766@s.whatsapp.net"}
               ])

      assert {:ok, _store, "5511999887766:99@s.whatsapp.net"} =
               LIDMappingStore.get_pn_for_lid(store, "12345:99@lid")
    end

    test "ignores invalid pairs and keeps valid ones" do
      store = LIDMappingStore.new()

      assert {:ok, store} =
               LIDMappingStore.store_lid_pn_mappings(store, [
                 %{lid: "12345@lid", pn: "5511999887766@s.whatsapp.net"},
                 %{lid: "120363001234567890@g.us", pn: "5511999887766@s.whatsapp.net"}
               ])

      assert {:ok, _store, "12345@lid"} =
               LIDMappingStore.get_lid_for_pn(store, "5511999887766@s.whatsapp.net")
    end
  end

  describe "misses" do
    test "uses the lookup function for missing PN mappings and preserves hosted devices" do
      store =
        LIDMappingStore.new(
          pn_to_lid_lookup: fn ["5511999887766@s.whatsapp.net"] ->
            [%{lid: "12345@lid", pn: "5511999887766@s.whatsapp.net"}]
          end
        )

      assert {:ok, _store, "12345:99@hosted.lid"} =
               LIDMappingStore.get_lid_for_pn(store, "5511999887766:99@hosted")
    end

    test "returns nil when no reverse mapping exists" do
      store = LIDMappingStore.new()

      assert {:ok, _store, nil} =
               LIDMappingStore.get_pn_for_lid(store, "nonexistent@lid")
    end
  end
end
