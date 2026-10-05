defmodule Wyram.Engine.LodWorldTest do
  use ExUnit.Case, async: false
  alias Wyram.Engine.World

  test "distant queries use durable edits without creating simulation region owners" do
    key = {5678, 0, 5678}
    tile = {2, 1419, 0, 1419}
    count = Registry.count(Wyram.Engine.RegionRegistry)
    before = World.lod_edit_snapshot(tile)
    assert :ok = World.persist_edit(key, %{data: :binary.copy(<<0>>, 8192), revision: 1})
    assert %{revision: revision, chunks: chunks} = World.lod_edit_snapshot(tile)
    assert revision > before.revision
    assert {key, :binary.copy(<<0>>, 8192)} in chunks
    assert World.lod_revision(tile) == revision
    assert Registry.count(Wyram.Engine.RegionRegistry) == count
  end
end
