defmodule Wyram.Engine.WorldTest do
  use ExUnit.Case, async: false

  alias Wyram.Engine.{Native, Paths, PluginManager, World}

  test "compiled official plugin defines the native terrain palette" do
    blocks = PluginManager.blocks()

    assert PluginManager.terrain_palette() ==
             Enum.map(
               ["official:grass", "official:dirt", "official:stone"],
               &Map.fetch!(blocks, &1)
             )

    assert PluginManager.plugin_versions()["official"] == "0.1.0"
  end

  test "chunk operations return binaries and preserve revisioned edits" do
    chunk = World.get_chunk(-100, 3, -100)
    assert is_binary(chunk.data)
    assert byte_size(chunk.data) == 8192
    assert chunk.revision >= 0

    x = -1600
    y = 55
    z = -1600
    old = World.get_block(x, y, z)
    assert old != 0
    assert {:ok, revision} = World.set_block(x, y, z, 0)
    assert World.get_block(x, y, z) == 0
    assert World.get_chunk(-100, 3, -100).revision == revision
    assert File.exists?(Path.join(Paths.data_dir(), "worlds/world.json"))
    assert {:ok, ^old} = Native.read_block(chunk.data, 0, 7, 0)

    assert {:ok, next_revision} = World.set_block(x, y, z, old)
    assert next_revision == revision + 1
    assert World.get_block(x, y, z) == old

    assert {:ok, reloaded} = World.init(directory: Path.join(Paths.data_dir(), "worlds"))
    assert reloaded.edited[{-100, 3, -100}].revision == next_revision
  end

  test "regions have separate owners and reload durable edits after a restart" do
    left = World.region_pid(0, 0)
    right = World.region_pid(4, 0)
    assert left != right

    original = World.get_block(64, 60, 0)
    replacement = if original == 0, do: 1, else: 0
    assert {:ok, _revision} = World.set_block(64, 60, 0, replacement)
    assert :ok = DynamicSupervisor.terminate_child(Wyram.Engine.RegionSupervisor, right)
    assert World.get_block(64, 60, 0) == replacement
    assert World.region_pid(4, 0) != right
  end
end
