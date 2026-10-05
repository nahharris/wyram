defmodule Wyram.Engine.LodEditsTest do
  use ExUnit.Case, async: true
  alias Wyram.Engine.{LodEdits, LodPlanner}

  test "coherent snapshots include saved halo edits without activating regions" do
    chunk_key = {-1, -1, -1}
    chunk = %{data: :binary.copy(<<7, 0>>, 4096), revision: 1}
    saved = %{chunk_key => chunk, {10_000, 0, 0} => chunk}
    index = LodEdits.new(saved)

    for tile <- LodPlanner.affected_tiles(chunk_key) do
      assert %{revision: 1, chunks: [{^chunk_key, bytes}]} = LodEdits.snapshot(index, tile, saved)
      assert bytes == chunk.data
    end

    assert LodEdits.snapshot(index, {2, 20, 0, 20}, saved) == %{revision: 0, chunks: []}
  end

  test "only intersecting tile revisions advance and edited empty chunks remain overrides" do
    key = {0, 0, 0}
    empty = %{data: :binary.copy(<<0>>, 8192), revision: 2}
    saved = %{key => empty}
    index = LodEdits.new(%{}) |> LodEdits.put(key)
    first = LodEdits.snapshot(index, {2, 0, 0, 0}, saved)
    assert first == %{revision: 1, chunks: [{key, empty.data}]}
    next = LodEdits.put(index, key)
    assert LodEdits.snapshot(next, {2, 0, 0, 0}, saved).revision == 2
    assert first.revision == 1
    assert LodEdits.snapshot(next, {2, 20, 0, 20}, saved).revision == 0
  end
end
