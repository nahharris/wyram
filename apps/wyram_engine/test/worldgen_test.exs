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

  test "scenic generation shares the resource, preserves leaf data and bounds native batches" do
    assert {:ok, context} =
             WorldGenerator.compile(config(), 2026, [], %{"game:stone" => 42, "game:water" => 17})

    keys = [{{0, -12, 0}, 0}, {{-1, -1, -1}, 1}]
    assert {:ok, [leaf, parent]} = Native.generate_scenic_tiles(context.resource, keys)
    [{_, data}] = WorldGenerator.chunks(context, [{0, -12, 0}])
    assert {:ok, [^leaf]} = Native.import_visual_chunks([{{0, -12, 0}, data}])
    assert <<"WSL1", 1, _::binary>> = parent
    assert Native.generate_scenic_tiles(context.resource, []) == {:ok, []}

    assert Native.generate_scenic_tiles(context.resource, List.duplicate(hd(keys), 3)) ==
             {:error, "oversized scenic generation batch"}

    assert Native.generate_scenic_tiles(context.resource, [{{0, 0, 0}, 11}]) ==
             {:error, "invalid scenic tile key"}

    assert Native.generate_scenic_tiles(context.resource, [{{0, 0, 0}, 7}]) ==
             {:error, "unsupported scenic generation level"}

    assert Native.generate_scenic_tiles(context.resource, [{{2_147_483_647, 0, 0}, 1}]) ==
             {:error, "world coordinate out of bounds"}
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
