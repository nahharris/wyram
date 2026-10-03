defmodule WyramMods.WorldGeneration do
  @moduledoc "Wyram's first wilderness palette over the public generation pipeline; specialized biomes follow later."
  use Wyram.WorldGen
  alias Wyram.WorldGen.{Config, Feature}
  alias WyramMods.Wyram.Blocks

  defbiome Wilderness do
    %{
      id: "wyram:wilds",
      surface: Blocks.Grass.ref(),
      soil: Blocks.Dirt.ref(),
      rock: Blocks.Stone.ref(),
      water: Blocks.Water.ref(),
      features: [
        Feature.new!(%{
          kind: :tree,
          block: Blocks.Wood.ref(),
          accent: Blocks.Leaves.ref(),
          spacing: 32,
          density: 0.4,
          radius: 4,
          height: 14,
          salt: 101
        }),
        Feature.new!(%{
          kind: :tree,
          block: Blocks.Wood.ref(),
          accent: Blocks.Leaves.ref(),
          spacing: 128,
          density: 0.18,
          radius: 12,
          height: 48,
          salt: 103
        }),
        Feature.new!(%{
          kind: :boulder,
          block: Blocks.Stone.ref(),
          accent: Blocks.Stone.ref(),
          spacing: 64,
          density: 0.25,
          radius: 5,
          height: 7,
          salt: 107
        }),
        Feature.new!(%{
          kind: :boulder,
          block: Blocks.Stone.ref(),
          accent: Blocks.Stone.ref(),
          spacing: 64,
          density: 0.2,
          radius: 4,
          height: 6,
          salt: 109,
          domain: :island
        })
      ]
    }
  end

  def build do
    Config.new!(%{min_y: -192, height: 512, sea_level: 0, biomes: biomes()})
  end
end
