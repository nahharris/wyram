alias Wyram.Engine.{PluginManager, World}

Code.require_file("test-liquids.exs", __DIR__)

package = Path.join(System.fetch_env!("WYRAM_DATA_DIR"), "plugins/wyram.wyrplug")
{:ok, files} = :zip.extract(String.to_charlist(package), [:memory])
{_, manifest_bytes} = Enum.find(files, fn {name, _} -> name == ~c"manifest.json" end)
manifest = Jason.decode!(manifest_bytes)
true = "Elixir.WyramMods.Characters" in manifest["modules"]
true = "Elixir.WyramMods.Wyram.Blocks.Grass" in manifest["modules"]
false = Map.has_key?(manifest, "api")
{_, catalog_bytes} = Enum.find(files, fn {name, _} -> name == ~c"catalog.term" end)

true =
  manifest["catalog_sha256"] == Base.encode16(:crypto.hash(:sha256, catalog_bytes), case: :lower)

artifact = :erlang.binary_to_term(catalog_bytes, [:safe])
true = Enum.sort(artifact.plugin.owned_modules) == manifest["modules"]

blocks = PluginManager.blocks()
true = PluginManager.plugin_versions() == %{"wyram" => "0.1.0"}

true =
  PluginManager.terrain_palette() ==
    Enum.map(
      ["wyram:grass", "wyram:dirt", "wyram:stone"],
      &Map.fetch!(blocks, &1)
    )

true = World.get_block(0, 0, 0) == blocks["wyram:stone"]

true = PluginManager.player_profile() == WyramMods.Characters.player_profile()

models = PluginManager.character_models()
true = length(models) == 2
true = Enum.map(PluginManager.character_definitions(), & &1.id) == ["player", "companion"]
source_models = artifact.catalog.game.models
true = Enum.all?(source_models, &(Wyram.Character.Model.validate(&1) == :ok))
[first, second] = source_models
true = Wyram.Character.Model.compatible?(first, second)
File.mkdir_p!(".tools")
File.write!(".tools/character-models.json", Jason.encode!(models))

profile = PluginManager.player_profile()
true = profile.standing_height == Wyram.Units.blocks(1, 3)
true = Wyram.Units.blocks(1, 4) - profile.standing_height == Wyram.Units.pixels(1)
true = profile.standing_eye < profile.standing_height
true = profile.crouch_height == Wyram.Units.pixels(10)
true = profile.prone_height == Wyram.Units.pixels(7)
true = Enum.all?(source_models, &(&1.base_height == profile.standing_height))

y_min = fn box -> Enum.at(box.center, 1) - Enum.at(box.size, 1) / 2 end
y_max = fn box -> Enum.at(box.center, 1) + Enum.at(box.size, 1) / 2 end

for model <- source_models do
  [belt] = Enum.find(model.bones, &(&1.role == "hips")).boxes
  [shirt] = Enum.find(model.bones, &(&1.role == "torso")).boxes
  true = y_min.(shirt) >= y_max.(belt)

  for role <- ["left_leg", "right_leg"] do
    leg = Enum.find(model.bones, &(&1.role == role))
    true = Enum.all?(leg.boxes, &(y_max.(&1) < y_min.(belt)))
  end

  head = Enum.find(model.bones, &(&1.role == "head"))
  [skull | face] = head.boxes
  true = Enum.at(skull.size, 1) > model.base_height / 2
  true = Enum.all?(face, &(Enum.at(&1.size, 2) < Wyram.Units.pixels(0.1)))
  true = Wyram.Character.Profile.validate(profile) == :ok
end

snapshot = Wyram.Engine.Characters.snapshot()
true = snapshot.height == profile.standing_height
true = snapshot.eye_height == profile.standing_eye
true = snapshot.radius == profile.radius
true = Enum.all?(Wyram.Engine.Characters.latest(), &(&1.height == profile.standing_height))
