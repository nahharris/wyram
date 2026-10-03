defmodule Wyram.Engine.ChunkStreamTest do
  use ExUnit.Case, async: true
  alias Wyram.Engine.ChunkStream

  test "all 32 vertical layers are streamed and nearest chunks are prioritized" do
    keys = ChunkStream.keys({0, -1, 0}, {-192, 319}, 2)
    assert length(keys) == 800
    assert hd(keys) == {0, -1, 0}
    assert Enum.any?(keys, &(elem(&1, 1) == -12))
    assert Enum.any?(keys, &(elem(&1, 1) == 19))
    refute Enum.any?(keys, &(elem(&1, 1) in [-13, 20]))
    assert MapSet.new(keys) == MapSet.new(ChunkStream.keys({0, 18, 0}, {-192, 319}, 2))
  end
end
