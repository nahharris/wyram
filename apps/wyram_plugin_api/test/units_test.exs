defmodule Wyram.UnitsTest do
  use ExUnit.Case, async: true
  alias Wyram.Units

  test "eight design pixels make a block and notation preserves authored parts" do
    assert Units.pixels_per_block() == 8
    assert Units.blocks(1, 3) == 1.375
    assert Units.blocks(1, 4) - Units.blocks(1, 3) == Units.pixels(1)
    assert Units.notation(1, 3) == "1\\3"
    assert Units.pixels(6) == 0.75
    assert_raise ArgumentError, fn -> Units.blocks(1, 8) end
    assert_raise ArgumentError, fn -> Units.blocks(-1, 3) end
  end
end
