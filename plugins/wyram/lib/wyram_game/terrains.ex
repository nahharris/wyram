defmodule WyramGame.Terrains do
  @moduledoc false
  use Wyram.Plugin.Catalog, plugin: WyramGame, kind: :terrain

  defterrain(Wilderness, id: "wilderness")
end
