defmodule Wyram.Engine.ChunkStreamTest do
  use ExUnit.Case, async: true
  alias Wyram.Engine.ChunkStream

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
end
