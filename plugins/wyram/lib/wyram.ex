defmodule Wyram do
  @moduledoc "The default creative voxel game, authored through the public plugin API."
  use Wyram.Plugin

  catalog Wyram.Blocks
  catalog Wyram.Biomes
  catalog Wyram.Profiles
  catalog Wyram.Models
  catalog Wyram.Characters
  catalog Wyram.WorldGen

  game Wyram.GameSetup
end
