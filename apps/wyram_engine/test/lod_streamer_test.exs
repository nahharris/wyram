defmodule Wyram.Engine.LodStreamerTest do
  use ExUnit.Case, async: true
  alias Wyram.Engine.LodStreamer

  test "liquid IDs accept native integer catalog keys" do
    assert LodStreamer.liquid_ids(%{3 => %{liquid: 1}, 4 => %{liquid: 0}}) == [3]
  end

  test "staged launch settings are explicit and validated before starting the client" do
    assert LodStreamer.max_cell_size(nil) == 16
    for size <- [0, 2, 4, 8, 16], do: assert(LodStreamer.max_cell_size("#{size}") == size)

    for invalid <- ["1", "32", "2junk", "", "-1"] do
      assert_raise ArgumentError, ~r/WYRAM_LOD_MAX_CELL_SIZE/, fn ->
        LodStreamer.max_cell_size(invalid)
      end
    end
  end

  test "liquid identities come from the public rendering catalog" do
    assert LodStreamer.liquid_ids(%{
             "7" => %{liquid: 7},
             "9" => %{liquid: 7},
             "11" => %{liquid: 0}
           }) == [7, 9]
  end
end
