defmodule Wyram.Engine.SceneryPlanesTest do
  use ExUnit.Case, async: true
  alias Wyram.Block.Ref
  alias Wyram.Engine.WorldGenerator

  test "world surface planes use configured biome materials and public render heights" do
    source = Ref.new!("land", "liquid")
    config = %{sea_level: -17, biomes: [%{water: source}, %{water: nil}, %{water: source}]}
    blocks = %{Ref.canonical_id(source) => 73}

    assert WorldGenerator.scenery_planes(config, blocks, %{73 => %{height: 0.75}}) == %{
             73 => -16.25
           }

    assert WorldGenerator.scenery_planes(nil, blocks, %{}) == %{}
  end
end
