defmodule Wyram.Engine.Scenery.InvalidationTest do
  use ExUnit.Case, async: true
  alias Wyram.Block.Ref
  alias Wyram.Engine.{Native, WorldGenerator}
  alias Wyram.Engine.Scenery.Invalidation
  alias Wyram.Scenery.Key
  alias Wyram.WorldGen.{Biome, Config}

  test "negative chunk boundaries invalidate all wanted ancestors and no neighboring volume" do
    ancestors =
      for level <- 1..6 do
        %Key{position: {-1, -1, -1}, level: level}
      end

    neighbors =
      for level <- 1..6 do
        %Key{position: {0, -1, -1}, level: level}
      end

    plan = %{order: ancestors ++ neighbors}
    assert Invalidation.keys([{-1, -1, -1}], plan) == MapSet.new(ancestors)
    assert Invalidation.keys([{-64, -64, -64}], plan) == MapSet.new([List.last(ancestors)])
    assert Invalidation.keys([{1024, 0, 1024}], plan) == MapSet.new()
  end

  test "actual native sample chunks including shifted sea strata remain in the invalidated tile" do
    stone = Ref.new!("game", "stone")

    for sea <- [-17, 0, 16] do
      config =
        Config.new!(%{
          sea_level: sea,
          biomes: [Biome.new!(%{id: "wilds", surface: stone, soil: stone, rock: stone})]
        })

      {:ok, generation} = WorldGenerator.compile(config, 41, [], %{"game:stone" => 42})

      for level <- 1..6 do
        scale = Integer.pow(2, level)
        key = %Key{position: {-1, Integer.floor_div(sea, scale * 16), -1}, level: level}
        {:ok, chunks} = Native.scenic_sample_chunks(generation.resource, {key.position, level})
        assert chunks != []

        assert Enum.all?(chunks, fn {x, y, z} ->
                 {Integer.floor_div(x, scale), Integer.floor_div(y, scale),
                  Integer.floor_div(z, scale)} == key.position
               end)

        for chunk <- [hd(chunks), Enum.at(chunks, div(length(chunks), 2)), List.last(chunks)] do
          assert Invalidation.keys([chunk], %{order: [key]}) == MapSet.new([key])
        end
      end
    end
  end
end
