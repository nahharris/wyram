defmodule WyramGame.Biomes do
  @moduledoc "Wyram's first wilderness palette over the public generation pipeline; specialized biomes follow later."
  use Wyram.Plugin.Catalog, plugin: WyramGame, kind: :biome
  alias Wyram.WorldGen.Feature
  alias WyramGame.Blocks

  defbiome Wilderness, id: "wilds" do
    %{
      surface: Blocks.Grass,
      soil: Blocks.Dirt,
      rock: Blocks.Stone,
      water: Blocks.Water,
      features: [
        %Feature{
          kind: :tree,
          block: Blocks.Wood,
          accent: Blocks.Leaves,
          spacing: 32,
          density: 0.4,
          radius: 4,
          height: 14,
          support_depth: 16,
          salt: 101
        },
        %Feature{
          kind: :tree,
          block: Blocks.Wood,
          accent: Blocks.Leaves,
          spacing: 128,
          density: 0.18,
          radius: 12,
          height: 48,
          support_depth: 24,
          salt: 103
        },
        %Feature{
          kind: :boulder,
          block: Blocks.Stone,
          accent: Blocks.Stone,
          spacing: 64,
          density: 0.25,
          radius: 5,
          height: 7,
          support_depth: 24,
          salt: 107
        },
        %Feature{
          kind: :boulder,
          block: Blocks.Stone,
          accent: Blocks.Stone,
          spacing: 64,
          density: 0.2,
          radius: 4,
          height: 6,
          support_depth: 16,
          salt: 109,
          domain: :island
        }
      ]
    }
  end
end
