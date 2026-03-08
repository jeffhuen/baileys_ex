defmodule BaileysExTest do
  use ExUnit.Case
  doctest BaileysEx

  test "greets the world" do
    assert BaileysEx.hello() == :world
  end
end
