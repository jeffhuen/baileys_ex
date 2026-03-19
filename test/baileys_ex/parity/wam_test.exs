defmodule BaileysEx.Parity.WAMTest do
  use BaileysEx.Parity.Case, async: true

  alias BaileysEx.WAM
  alias BaileysEx.WAM.Definitions

  test "Baileys WAM definition counts match the loaded Elixir registry" do
    expected =
      run_baileys_reference!("wam.registry_counts", %{})

    definitions = Definitions.all()

    assert map_size(definitions.events) == expected["events"]
    assert map_size(definitions.globals) == expected["globals"]
  end

  test "Baileys encodeWAM matches Elixir for a mixed globals and event payload" do
    expected_hex =
      run_baileys_reference!("wam.encode", %{
        "sequence" => 7,
        "events" => [
          %{
            "name" => "WamDroppedEvent",
            "props" => [
              ["droppedEventCode", 5],
              ["droppedEventCount", 300],
              ["isFromWamsys", true]
            ],
            "globals" => [
              ["appIsBetaRelease", true],
              ["appVersion", "2.24.7"]
            ]
          }
        ]
      })["wam_hex"]

    actual_hex =
      WAM.new(sequence: 7)
      |> WAM.put_event(
        "WamDroppedEvent",
        [droppedEventCode: 5, droppedEventCount: 300, isFromWamsys: true],
        appIsBetaRelease: true,
        appVersion: "2.24.7"
      )
      |> WAM.encode()
      |> Base.encode16(case: :lower)

    assert actual_hex == expected_hex
  end
end
