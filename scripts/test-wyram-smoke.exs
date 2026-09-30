alias Wyram.Engine.{PluginManager, World}

package = Path.join(System.fetch_env!("WYRAM_DATA_DIR"), "plugins/wyram.wyrplug")
{:ok, files} = :zip.extract(String.to_charlist(package), [:memory])
{_, manifest_bytes} = Enum.find(files, fn {name, _} -> name == ~c"manifest.json" end)
manifest = Jason.decode!(manifest_bytes)
true = Enum.sort(manifest["modules"]) == ["Elixir.WyramMods.Characters", "Elixir.WyramMods.Wyram"]

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

models = PluginManager.character_models()
true = length(models) == 2
true = Enum.map(PluginManager.character_definitions(), & &1.id) == ["player", "companion"]
source_models = WyramMods.Wyram.character_models()
true = Enum.all?(source_models, &(Wyram.Character.Model.validate(&1) == :ok))
[first, second] = source_models
true = Wyram.Character.Model.compatible?(first, second)
File.mkdir_p!(".tools")
File.write!(".tools/character-models.json", Jason.encode!(models))
