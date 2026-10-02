defmodule Wyram.Engine.WorldTest do
  use ExUnit.Case, async: false

  alias Wyram.Engine.{Native, Paths, PluginManager, World}

  test "packaged manifests bind compiled catalogs to their owned modules" do
    for {id, entry, dependencies} <- [
          {"test_terrain", "Elixir.WyramMods.TestTerrain", []},
          {"test_addon", "Elixir.WyramMods.TestAddon", ["test_terrain"]}
        ] do
      package = Path.join(Paths.data_dir(), "plugins/#{id}.wyrplug")
      assert {:ok, files} = :zip.extract(String.to_charlist(package), [:memory])
      {_, bytes} = Enum.find(files, fn {name, _} -> name == ~c"manifest.json" end)
      manifest = Jason.decode!(bytes)
      %Version{major: major, minor: minor} = Version.parse!(System.version())

      assert manifest == %{
               "id" => id,
               "version" => "0.1.0",
               "otp" => System.otp_release(),
               "elixir" => "#{major}.#{minor}",
               "entry" => entry,
               "modules" => manifest["modules"],
               "dependencies" => dependencies,
               "catalog" => "catalog.term",
               "catalog_sha256" => manifest["catalog_sha256"]
             }

      {_, catalog_bytes} = Enum.find(files, fn {name, _} -> name == ~c"catalog.term" end)

      assert manifest["catalog_sha256"] ==
               Base.encode16(:crypto.hash(:sha256, catalog_bytes), case: :lower)

      artifact = :erlang.binary_to_term(catalog_bytes, [:safe])
      assert artifact.plugin.id == id
      assert artifact.plugin.dependencies == dependencies
      assert Enum.sort(artifact.plugin.owned_modules) == manifest["modules"]
      assert entry in manifest["modules"]
      assert length(manifest["modules"]) > 1
      assert Enum.any?(manifest["modules"], &String.starts_with?(&1, entry <> ".Blocks."))
      assert Enum.all?(artifact.catalog.blocks, &(&1.kind == :block and &1.plugin_id == id))

      refute File.exists?(
               Path.expand("../../../test/fixtures/plugins/#{id}/manifest.json", __DIR__)
             )
    end
  end

  test "compiled test terrain defines the native palette without game block names" do
    blocks = PluginManager.blocks()

    assert PluginManager.terrain_palette() ==
             Enum.map(
               ["test_terrain:violet", "test_terrain:ochre", "test_terrain:slate"],
               &Map.fetch!(blocks, &1)
             )

    assert PluginManager.plugin_versions()["test_terrain"] == "0.1.0"
    assert World.get_block(0, 0, 0) == blocks["test_terrain:slate"]
    assert World.get_block(0, 100, 0) == 0
  end

  test "a separately packaged plugin contributes a selectable block" do
    id = Map.fetch!(PluginManager.blocks(), "test_addon:prism")
    assert PluginManager.block_colors()[id] == [33, 211, 177]
    assert PluginManager.plugin_versions()["test_addon"] == "0.1.0"
    assert {:error, :unknown_block} = World.set_block(0, 75, 0, 65_535)
  end

  test "loader rejects a compiled addon with a missing dependency" do
    directory = Path.join(Paths.data_dir(), "missing-dependency")
    File.mkdir_p!(directory)

    File.cp!(
      Path.join(Paths.data_dir(), "plugins/test_addon.wyrplug"),
      Path.join(directory, "test_addon.wyrplug")
    )

    assert {:stop, :missing_dependency} = PluginManager.init(directory: directory)
  end

  test "loader rejects duplicate plugin IDs across packages" do
    directory = Path.join(Paths.data_dir(), "duplicate-plugin")
    File.mkdir_p!(directory)
    package = Path.join(Paths.data_dir(), "plugins/test_terrain.wyrplug")
    File.cp!(package, Path.join(directory, "first.wyrplug"))
    File.cp!(package, Path.join(directory, "second.wyrplug"))

    assert {:stop, :duplicate_plugin_id} = PluginManager.init(directory: directory)
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
    replacement = if original == 0, do: PluginManager.blocks()["test_addon:prism"], else: 0
    assert {:ok, _revision} = World.set_block(64, 60, 0, replacement)
    assert :ok = DynamicSupervisor.terminate_child(Wyram.Engine.RegionSupervisor, right)
    assert World.get_block(64, 60, 0) == replacement
    assert World.region_pid(4, 0) != right
  end
end
