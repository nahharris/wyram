defmodule Wyram.Engine.ChunkStreamTest do
  use ExUnit.Case, async: true
  alias Wyram.Engine.ChunkStream

  test "LOD prefetch preserves the complete baseline near queue before extra work" do
    center = {-3, -1, 5}
    bounds = {-192, 319}
    baseline = ChunkStream.keys(center, bounds, 11)
    streamed = ChunkStream.streaming_keys(center, bounds, 11, 13)
    assert Enum.take(streamed, length(baseline)) == baseline
    assert length(streamed) == 529 * 32
    assert MapSet.new(streamed) == MapSet.new(ChunkStream.keys(center, bounds, 13))
    assert length(Enum.uniq(streamed)) == length(streamed)
    assert ChunkStream.streaming_keys(center, bounds, 11, 11) == baseline
  end

  test "unloads are bounded batches for capable clients and preserve legacy messages" do
    keys = for y <- -12..19, do: {11, y, 0}
    packets = ChunkStream.forget_packets(keys, 1)
    assert Enum.map(packets, &length(&1.keys)) == [16, 16]
    assert Enum.all?(packets, &(&1.type == "forget_chunks"))
    assert Enum.flat_map(packets, & &1.keys) == Enum.map(keys, &Tuple.to_list/1)
    assert ChunkStream.forget_packets([], 1) == []

    assert ChunkStream.forget_packets([{11, -12, 0}], 0) == [
             %{type: "forget", key: [11, -12, 0]}
           ]
  end

  test "radius eleven circle keeps full height and excludes square corners" do
    keys = ChunkStream.keys({-3, -1, 5}, {-192, 319}, 11)
    assert length(keys) == 377 * 32
    assert hd(keys) == {-3, -1, 5}
    assert {8, -12, 5} in keys
    assert {-14, 19, 5} in keys
    refute {8, -1, 16} in keys
    assert Enum.all?(keys, fn {x, _, z} -> (x + 3) ** 2 + (z - 5) ** 2 <= 121 end)
    assert MapSet.new(keys) == MapSet.new(ChunkStream.keys({-3, 18, 5}, {-192, 319}, 11))
  end

  test "radius eleven is the default and invalid radii safely fall back" do
    assert ChunkStream.view_radius("11") == 11

    for value <- [nil, "0", "12", "invalid", "11junk"] do
      assert ChunkStream.view_radius(value) == 11
    end

    assert ChunkStream.view_radius("4") == 4
  end

  test "all 32 vertical layers are streamed and nearest chunks are prioritized" do
    keys = ChunkStream.keys({0, -1, 0}, {-192, 319}, 2)
    assert length(keys) == 416
    assert hd(keys) == {0, -1, 0}
    assert Enum.any?(keys, &(elem(&1, 1) == -12))
    assert Enum.any?(keys, &(elem(&1, 1) == 19))
    refute Enum.any?(keys, &(elem(&1, 1) in [-13, 20]))
    assert MapSet.new(keys) == MapSet.new(ChunkStream.keys({0, 18, 0}, {-192, 319}, 2))
  end

  test "prefetch ordering completes inner full-height columns before farther columns" do
    center = {-3, -1, 5}

    keys = for {x, z} <- [{-1, 5}, {-3, 6}, {-3, 5}, {-4, 5}], y <- -2..0, do: {x, y, z}

    assert ChunkStream.column_order(keys, center) == [
             {-3, -1, 5},
             {-3, -2, 5},
             {-3, 0, 5},
             {-4, -1, 5},
             {-3, -1, 6},
             {-4, -2, 5},
             {-4, 0, 5},
             {-3, -2, 6},
             {-3, 0, 6},
             {-1, -1, 5},
             {-1, -2, 5},
             {-1, 0, 5}
           ]
  end

  test "baseline chunk ordering stays three-dimensional and deterministic" do
    assert ChunkStream.keys({-3, -1, 5}, {-16, -1}, 1) == [
             {-3, -1, 5},
             {-4, -1, 5},
             {-3, -1, 4},
             {-3, -1, 6},
             {-2, -1, 5}
           ]
  end
end
