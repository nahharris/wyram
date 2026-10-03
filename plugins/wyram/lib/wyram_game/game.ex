defmodule WyramGame.Game do
  @moduledoc false
  use Wyram.Game, plugin: WyramGame
  alias WyramGame.{Blocks, Characters, WorldGen}

  terrain(surface: Blocks.Grass, soil: Blocks.Dirt, rock: Blocks.Stone)
  worldgen(WorldGen.Wilderness)
  player(Characters.Player)
  spawn(Characters.Companion, id: "companion", position: {2.5, 71.38, -2.5})
  spawn_policy(:surface)
end
