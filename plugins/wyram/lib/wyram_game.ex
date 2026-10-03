defmodule WyramGame do
  @moduledoc "The default creative voxel game, authored through the public plugin API."
  use Wyram.Plugin

  catalog(:blocks, WyramGame.Blocks)
  catalog(:biomes, WyramGame.Biomes)
  catalog(:terrains, WyramGame.Terrains)
  catalog(:profiles, WyramGame.Profiles)
  catalog(:models, WyramGame.Models)
  catalog(:characters, WyramGame.Characters)
  catalog(:worldgen, WyramGame.WorldGen)

  game(WyramGame.Game)
end
