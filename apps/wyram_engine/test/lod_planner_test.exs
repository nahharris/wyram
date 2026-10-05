defmodule Wyram.Engine.LodPlannerTest do
  use ExUnit.Case, async: true

  alias Wyram.Engine.LodPlanner

  test "desired size keeps the exact near circle and inclusive outward bands" do
    radius = 11

    circle =
      for x <- -radius..radius,
          z <- -radius..radius,
          x * x + z * z <= radius * radius,
          do: {x, z}

    assert length(circle) == 377
    assert Enum.all?(circle, &(LodPlanner.desired_size(&1, {0, -12, 0}, radius) == 1))
    assert LodPlanner.desired_size({11, 1}, {0, 0, 0}, radius) == 2
    assert LodPlanner.desired_size({22, 0}, {0, 0, 0}, radius) == 2
    assert LodPlanner.desired_size({23, 0}, {0, 0, 0}, radius) == 4
    assert LodPlanner.desired_size({44, 0}, {0, 0, 0}, radius) == 4
    assert LodPlanner.desired_size({45, 0}, {0, 0, 0}, radius) == 8
    assert LodPlanner.desired_size({88, 0}, {0, 0, 0}, radius) == 8
    assert LodPlanner.desired_size({89, 0}, {0, 0, 0}, radius) == 16
    assert LodPlanner.desired_size({176, 0}, {0, 0, 0}, radius) == 16
    assert LodPlanner.desired_size({177, 0}, {0, 0, 0}, radius) == 0
  end

  test "maximum size stops at its matching outer band" do
    center = {0, 0, 0}

    assert LodPlanner.desired_size({0, 0}, center, 11, 2) == 1
    assert LodPlanner.desired_size({22, 0}, center, 11, 2) == 2
    assert LodPlanner.desired_size({23, 0}, center, 11, 2) == 0
    assert LodPlanner.desired_size({44, 0}, center, 11, 4) == 4
    assert LodPlanner.desired_size({45, 0}, center, 11, 4) == 0
    assert LodPlanner.desired_size({89, 0}, center, 11, 8) == 0
  end

  test "tile coordinates are origin-aligned with floor division at negative positions" do
    assert LodPlanner.tile_bounds({2, -1, -1, -2}) == {{-66, -66, -130}, {1, 1, -63}}
  end

  test "planner covers every vertical slab and orders stable keys nearest first" do
    low = LodPlanner.plan({-3, -12, 5}, {-192, 319}, 11)
    high = LodPlanner.plan({-3, 19, 5}, {-192, 319}, 11)

    assert MapSet.new(low) == MapSet.new(high)
    assert low == Enum.sort_by(low, &order_key(&1, {-3, -12, 5}))
    assert high == Enum.sort_by(high, &order_key(&1, {-3, 19, 5}))

    for size <- [2, 4, 8, 16] do
      keys = Enum.filter(low, &(elem(&1, 0) == size))
      span = 32 * size
      vertical = keys |> Enum.map(&elem(&1, 2)) |> Enum.uniq() |> Enum.sort()
      assert vertical == Enum.to_list(Integer.floor_div(-192, span)..Integer.floor_div(319, span))
    end

    assert hd(low) != hd(high)
  end

  test "two-chunk band buffer keeps overlapping candidates without dropping whole tiles" do
    keys = MapSet.new(LodPlanner.plan({0, 0, 0}, {-192, 319}, 11, 2))

    # This tile's chunk centres are all inside the protected near circle, but
    # its two-chunk overlap keeps it available while the boundary moves.
    assert MapSet.member?(keys, {2, 1, 0, 1})

    # This tile begins beyond the expanded 2R outer edge.
    refute MapSet.member?(keys, {2, 7, 0, 0})

    # A tile crossing the near-circle edge remains selected for its far cells.
    assert MapSet.member?(keys, {2, 2, 0, 0})
    assert LodPlanner.desired_size({8, 0}, {0, 0, 0}, 11) == 1
    assert LodPlanner.desired_size({12, 0}, {0, 0, 0}, 11) == 2
  end

  test "all default-radius candidates stay within a fixed bound and world limits" do
    keys = LodPlanner.plan({0, 0, 0}, {-192, 319}, 11)

    assert length(keys) <= 4_608
    assert length(keys) == length(Enum.uniq(keys))

    assert Enum.all?(keys, fn key ->
             {minimum, maximum} = LodPlanner.tile_bounds(key)

             Enum.all?(Tuple.to_list(minimum) ++ Tuple.to_list(maximum), &(abs(&1) <= 1_000_000))
           end)
  end

  test "affected tiles include edited chunks intersecting the one-cell halo" do
    keys = LodPlanner.affected_tiles({3, 0, 0})

    assert {2, 0, 0, 0} in keys
    assert {2, 1, 0, 0} in keys
    assert {4, 0, 0, 0} in keys
    assert {8, 0, 0, 0} in keys
    assert {16, 0, 0, 0} in keys

    chunk_minimum = {48, 0, 0}
    chunk_maximum = {63, 15, 15}

    for key <- keys do
      {minimum, maximum} = LodPlanner.tile_bounds(key)
      assert overlaps?(chunk_minimum, chunk_maximum, minimum, maximum)
    end

    refute {2, 2, 0, 0} in keys
  end

  test "invalid inputs fail explicitly" do
    assert_raise ArgumentError, fn -> LodPlanner.plan({0, 0, 0}, {-192, 319}, 0) end
    assert_raise ArgumentError, fn -> LodPlanner.plan({0, 0, 0}, {1, 0}, 11) end
    assert_raise ArgumentError, fn -> LodPlanner.plan({0, 0, 0}, {-300, 300}, 11) end
    assert_raise ArgumentError, fn -> LodPlanner.plan({0, 0, 0}, {-192, 319}, 11, 3) end
    assert_raise ArgumentError, fn -> LodPlanner.desired_size({0, 0}, {0, 0, 0}, 11, 3) end
    assert_raise ArgumentError, fn -> LodPlanner.tile_bounds({3, 0, 0, 0}) end
    assert_raise ArgumentError, fn -> LodPlanner.affected_tiles({62_501, 0, 0}) end
  end

  defp order_key({size, tx, ty, tz}, {cx, cy, cz}) do
    tile_chunks = 2 * size
    observer_x = 2 * cx + 1
    observer_z = 2 * cz + 1
    minimum_x = 2 * tx * tile_chunks + 1
    maximum_x = 2 * (tx + 1) * tile_chunks - 1
    minimum_z = 2 * tz * tile_chunks + 1
    maximum_z = 2 * (tz + 1) * tile_chunks - 1
    dx = axis_min_distance(observer_x, minimum_x, maximum_x)
    dz = axis_min_distance(observer_z, minimum_z, maximum_z)
    vertical_distance = abs(2 * ty * 2 * size + 2 * size - (2 * cy + 1))
    {dx * dx + dz * dz, size, vertical_distance, ty, tx, tz}
  end

  defp axis_min_distance(point, minimum, maximum) do
    cond do
      point < minimum -> minimum - point
      point > maximum -> point - maximum
      true -> 0
    end
  end

  defp overlaps?(left_min, left_max, right_min, right_max) do
    Enum.zip([
      Tuple.to_list(left_min),
      Tuple.to_list(left_max),
      Tuple.to_list(right_min),
      Tuple.to_list(right_max)
    ])
    |> Enum.all?(fn {left_low, left_high, right_low, right_high} ->
      left_low <= right_high and right_low <= left_high
    end)
  end
end
