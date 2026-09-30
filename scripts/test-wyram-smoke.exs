alias Wyram.Engine.{PluginManager, World}

package = Path.join(System.fetch_env!("WYRAM_DATA_DIR"), "plugins/wyram.wyrplug")
{:ok, files} = :zip.extract(String.to_charlist(package), [:memory])
{_, manifest_bytes} = Enum.find(files, fn {name, _} -> name == ~c"manifest.json" end)
manifest = Jason.decode!(manifest_bytes)
true = manifest["modules"] == ["Elixir.WyramMods.Wyram"]

blocks = PluginManager.blocks()
true = PluginManager.plugin_versions() == %{"wyram" => "0.1.0"}

true =
  PluginManager.terrain_palette() ==
    Enum.map(
      ["wyram:grass", "wyram:dirt", "wyram:stone"],
      &Map.fetch!(blocks, &1)
    )

true = World.get_block(0, 0, 0) == blocks["wyram:stone"]

true = PluginManager.player_profile() == Wyram.Character.Profile.default()
