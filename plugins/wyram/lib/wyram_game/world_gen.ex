defmodule WyramGame.WorldGen do
  @moduledoc false
  use Wyram.Plugin.Catalog, plugin: WyramGame, kind: :worldgen

  defworldgen Wilderness, id: "wilderness" do
    %{
      min_y: -192,
      height: 512,
      sea_level: 0,
      terrain: WyramGame.Terrains.Wilderness,
      biomes: [WyramGame.Biomes.Wilderness]
    }
  end
end
