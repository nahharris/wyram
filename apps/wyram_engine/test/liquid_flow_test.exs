defmodule Wyram.Engine.LiquidFlowTest do
  use ExUnit.Case, async: true
  alias Wyram.Engine.LiquidFlow

  # source=10, horizontal levels=11..13, falling=14; another liquid uses 20..24.
  defp table do
    for source <- [10, 20], level <- 0..4, into: %{} do
      {source + level,
       %{
         source: source,
         level: level,
         max_level: 3,
         flow_ms: 100,
         falling: level == 4,
         variants: [source, source + 1, source + 2, source + 3, source + 4]
       }}
    end
  end

  defp step(id, above, sides), do: LiquidFlow.next(id, above, sides, table())

  test "sources persist, falling takes priority, and different liquids never overwrite" do
    assert step(10, 0, []) == 10
    assert step(0, 10, [{20, 1}]) == 14
    assert step(20, 10, []) == 20
    assert step(1, 10, []) == 1
    assert step(21, 10, []) == 0
  end

  test "only supported liquid spreads sideways with diminishing strength" do
    assert step(0, 0, [{10, 1}]) == 11
    assert step(0, 0, [{11, 1}]) == 12
    assert step(0, 0, [{12, 1}]) == 13
    assert step(0, 0, [{13, 1}]) == 0
    assert step(0, 0, [{10, 0}]) == 0
    assert step(0, 0, [{14, 1}]) == 11
    assert step(0, 0, [{14, 14}]) == 0
  end

  test "flow drains without supply and equal-strength ties use persistent source order" do
    assert step(11, 0, []) == 0
    assert step(14, 0, []) == 0
    assert step(11, 0, [{11, 1}]) == 12
    assert step(0, 0, [{20, 1}, {10, 1}]) == step(0, 0, [{10, 1}, {20, 1}])
    assert step(11, 0, [{20, 1}]) == 0
  end
end
