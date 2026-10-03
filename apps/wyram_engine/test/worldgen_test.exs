defmodule Wyram.Engine.WorldGenTest do
  use ExUnit.Case, async: true
  alias Wyram.Block.Ref
  alias Wyram.Engine.{Native, WorldGenerator}
  alias Wyram.WorldGen.{Biome, Config}

  test "shared native generation preserves seed, datum, finite height and block handles" do
    config = config()

    assert {:ok, context} =
             WorldGenerator.compile(config, 2026, [], %{"game:stone" => 42, "game:water" => 17})

    assert context.bounds == {-192, 319}
    [{_, bedrock}, {_, ceiling}] = WorldGenerator.chunks(context, [{0, -12, 0}, {0, 20, 0}])
    assert {:ok, 42} = Native.read_block(bedrock, 0, 0, 0)
    assert ceiling == :binary.copy(<<0>>, 8192)
    assert {:ok, columns} = Native.sample_world(context.resource, [{0, 0}, {-4096, 2048}])
    assert Enum.all?(columns, &(length(&1.climate) == 6 and Enum.sum(&1.weights) == 1.0))
    assert WorldGenerator.identity(config) == WorldGenerator.identity(%{config | seed: 7})
    refute WorldGenerator.identity(config) == WorldGenerator.identity(%{config | relief: 80})
  end

  test "native decoder rejects invalid field counts and oversized generation batches" do
    wire = WorldGenerator.wire(config(), %{"game:stone" => 42, "game:water" => 17})
    assert {:error, _} = Native.compile_generator(1, %{wire | fields: []})
    assert {:error, _} = Native.compile_generator(1, %{wire | height: 513})

    assert {:ok, context} =
             WorldGenerator.compile(config(), 1, [], %{"game:stone" => 42, "game:water" => 17})

    assert {:error, _} =
             Native.generate_world_chunks(context.resource, List.duplicate({0, 0, 0}, 33))
  end

  defp config do
    ref = Ref.new!("game", "stone")

    Config.new!(%{
      biomes: [
        Biome.new!(%{
          id: "wilds",
          surface: ref,
          soil: ref,
          rock: ref,
          water: Ref.new!("game", "water")
        })
      ]
    })
  end
end
