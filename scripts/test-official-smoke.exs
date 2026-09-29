alias Wyram.Engine.{PluginManager, World}

blocks = PluginManager.blocks()
true = PluginManager.plugin_versions() == %{"official" => "0.1.0"}

true =
  PluginManager.terrain_palette() ==
    Enum.map(
      ["official:grass", "official:dirt", "official:stone"],
      &Map.fetch!(blocks, &1)
    )

true = World.get_block(0, 0, 0) == blocks["official:stone"]
