defmodule BaileysEx.WAM.EncoderTest do
  use ExUnit.Case, async: true

  alias BaileysEx.WAM
  alias BaileysEx.WAM.Definitions

  test "loads the generated Baileys rc9 registry" do
    definitions = Definitions.all()

    assert map_size(definitions.events) == 313
    assert map_size(definitions.globals) == 48

    assert {:ok, %{id: 4358, weight: 1}} = Definitions.event("WamDroppedEvent")

    assert {:ok, %{id: 21, channels: ["regular", "private"]}} =
             Definitions.global("appIsBetaRelease")
  end

  test "encodes mixed globals and event fields with the Baileys wire format" do
    binary_info =
      WAM.new(sequence: 7)
      |> WAM.put_event(
        "WamDroppedEvent",
        [droppedEventCode: 5, droppedEventCount: 300, isFromWamsys: true],
        appIsBetaRelease: true,
        appVersion: "2.24.7"
      )

    assert WAM.encode(binary_info) ==
             Base.decode16!(
               "57414D05010007002015801106322E32342E37390611FF31010541022C012603",
               case: :mixed
             )
  end

  test "encodes events without props and preserves nil globals" do
    binary_info =
      WAM.new()
      |> WAM.put_event("GroupJoinC", [], commitTime: nil)

    assert WAM.encode(binary_info) ==
             Base.decode16!("57414D0501000000002F359EFF", case: :mixed)
  end

  test "encodes 32-bit integers and trailing strings like Baileys" do
    binary_info =
      WAM.new(sequence: 42)
      |> WAM.put_event(
        "UiRevokeAction",
        [messageAction: 5, uiRevokeActionDuration: 40_000, uiRevokeActionSessionId: "rev-1"],
        commitTime: 123
      )

    assert WAM.encode(binary_info) ==
             Base.decode16!(
               "57414D0501002A00302F7B39E20CFF3101055102409C00008603057265762D31",
               case: :mixed
             )
  end
end
