defmodule Wyram.WorldGenConfigTest do
  use ExUnit.Case, async: true
  alias Wyram.Block.Ref
  alias Wyram.Game.Config

  alias Wyram.WorldGen.{Biome, Field}
  alias Wyram.WorldGen.Config, as: WorldGenConfig

  test "legacy games explicitly opt out of the world generator" do
    ref = Ref.new!("game", "stone")

    assert {:ok, config} =
             Config.new(%{terrain: %{surface: ref, soil: ref, rock: ref}, worldgen: nil})

    assert Map.fetch!(config, :worldgen) == nil
  end

  test "surface spawning is an explicit game policy and compiled structs are complete" do
    ref = Ref.new!("game", "stone")
    attrs = %{terrain: %{surface: ref, soil: ref, rock: ref}, spawn: :surface}
    assert {:ok, config} = Config.new(attrs)
    assert config.spawn == :surface
    assert {:error, :invalid_spawn_policy} = Config.new(%{attrs | spawn: :guess})
    assert {:error, :invalid_game_config} = Config.validate(Map.delete(config, :worldgen))
  end

  test "bounded generation data rejects forged structs and unknown nested settings" do
    config = generator()
    assert config.min_y == -192
    assert config.sea_level == 0
    assert WorldGenConfig.bounds(config) == {-192, 319}
    assert :ok == WorldGenConfig.validate(config)

    for invalid <- [
          %{config | height: 513},
          %{config | sea_level: 319},
          Map.delete(config, :blend),
          Map.put(config, :custom_callback, &Function.identity/1)
        ] do
      assert {:error, :invalid_worldgen} = WorldGenConfig.validate(invalid)
    end

    assert_raise ArgumentError, fn -> Field.new!(%{scale: 0}) end

    assert_raise ArgumentError, fn ->
      WorldGenConfig.new!(%{biomes: config.biomes, callback: :runtime})
    end

    [biome] = config.biomes

    assert {:error, :invalid_worldgen} =
             WorldGenConfig.validate(%{config | biomes: [biome, biome]})

    assert {:error, :invalid_worldgen} =
             Biome.validate(%{biome | climate: %{humidity: 0.5}})

    assert length(WorldGenConfig.references(config)) == 4
  end

  defp generator do
    ref = Ref.new!("game", "stone")

    biome =
      Biome.new!(%{id: "wilds", surface: ref, soil: ref, rock: ref, water: ref})

    WorldGenConfig.new!(%{biomes: [biome]})
  end
end
