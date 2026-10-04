defmodule Wyram.Engine.Scenery.FetchTest do
  use ExUnit.Case, async: true
  alias Wyram.Block.Ref
  alias Wyram.Engine.{Native, WorldGenerator}
  alias Wyram.Engine.Scenery.{EditView, Fetch}
  alias Wyram.Scenery.Key
  alias Wyram.WorldGen.{Biome, Config, Terrain}

  setup do
    stone = Ref.new!("game", "stone")

    config =
      Config.new!(%{
        biomes: [Biome.new!(%{id: "wilds", surface: stone, soil: stone, rock: stone})]
      })

    {:ok, generation} = WorldGenerator.compile(config, 41, [], %{"game:stone" => 42})
    {:ok, generation: generation}
  end

  test "edited sibling samples match the exact parent and leaf reductions", %{
    generation: generation
  } do
    {:ok, parent} = Key.new({-1, -1, -1}, 1)
    {:ok, chunk_keys} = Native.scenic_sample_chunks(generation.resource, wire(parent))
    [{chunk_key, original} | rest] = WorldGenerator.chunks(generation, chunk_keys)
    {:ok, added} = Native.write_block(original, 0, 0, 0, 65_535)
    {:ok, edited} = Native.write_block(added, 15, 15, 15, 0)
    table = EditView.new(%{chunk_key => %{data: edited}})
    model = %{generation: generation, edits: table, stamp: 0}
    {:ok, leaf} = Key.new(chunk_key, 0)
    assert {:ok, [actual, leaf_actual]} = Fetch.run(model, [parent, leaf])
    {:ok, leaves} = Native.import_visual_chunks([{chunk_key, edited} | rest])
    {:ok, [expected]} = Native.reduce_visual_tiles([leaves])
    {:ok, [leaf_expected]} = Native.import_visual_chunks([{chunk_key, edited}])
    assert actual == expected
    assert leaf_actual == leaf_expected
    {:ok, [unmodified]} = Native.generate_scenic_tiles(generation.resource, [wire(parent)])
    refute actual == unmodified
  end

  test "distant sample collection crosses bounded snapshots without losing sparse saved edits", %{
    generation: generation
  } do
    {:ok, key} = Key.new({0, 0, 0}, 6)
    {:ok, chunk_keys} = Native.scenic_sample_chunks(generation.resource, wire(key))
    assert length(chunk_keys) > 512
    selected = Enum.map([0, 256, length(chunk_keys) - 1], &Enum.at(chunk_keys, &1))
    chunks = Enum.map(selected, &{&1, :binary.copy(<<65_535::little-16>>, 4096)})
    table = EditView.new(Map.new(chunks, fn {k, data} -> {k, %{data: data}} end))
    model = %{generation: generation, edits: table, stamp: 0}
    assert {:ok, [actual]} = Fetch.run(model, [key])
    {:ok, samples} = Native.extract_scenic_samples(generation.resource, wire(key), chunks)

    {:ok, [expected]} =
      Native.generate_edited_scenic_tiles(generation.resource, [{wire(key), samples}])

    assert actual == expected
    {:ok, [unmodified]} = Native.generate_scenic_tiles(generation.resource, [wire(key)])
    refute actual == unmodified
  end

  test "saved sea surface edits follow the shifted sample across chunk boundaries" do
    stone = Ref.new!("game", "stone")
    water = Ref.new!("game", "water")

    config =
      Config.new!(%{
        relief: 0,
        terrain: Terrain.new!(%{roughness: 0.0}),
        islands: nil,
        carvers: [],
        biomes: [
          Biome.new!(%{
            id: "ocean",
            surface: stone,
            soil: stone,
            rock: stone,
            water: water,
            elevation_offset: -32
          })
        ]
      })

    {:ok, generation} =
      WorldGenerator.compile(config, 2026, [], %{"game:stone" => 42, "game:water" => 17})

    {:ok, key} = Key.new({0, 0, 0}, 6)
    {:ok, chunk_keys} = Native.scenic_sample_chunks(generation.resource, wire(key))
    assert {1, 0, 1} in chunk_keys
    refute {1, 1, 1} in chunk_keys
    [{{1, 0, 1}, original}] = WorldGenerator.chunks(generation, [{1, 0, 1}])
    {:ok, edited} = Native.write_block(original, 0, 0, 0, 0)
    table = EditView.new(%{{1, 0, 1} => %{data: edited}})
    assert {:ok, [actual]} = Fetch.run(%{generation: generation, edits: table, stamp: 0}, [key])

    assert <<"WSL1", 6, 2, 0, 0, 0::little-32, 0::little-32, 0::little-32, 17::little-16,
             98_304::little-32, 0x32, 0, _::binary>> = actual

    {:ok, [unmodified]} = Native.generate_scenic_tiles(generation.resource, [wire(key)])

    assert <<"WSL1", 6, 2, 0, 0, 0::little-32, 0::little-32, 0::little-32, 17::little-16,
             131_072::little-32, 0x33, 0, _::binary>> = unmodified
  end

  test "obsolete or deleted read models cannot publish results and work is bounded", %{
    generation: generation
  } do
    table = EditView.new(%{})
    model = %{generation: generation, edits: table, stamp: 0}
    {:ok, key} = Key.new({0, 0, 0}, 1)
    assert Fetch.run(model, List.duplicate(key, 3)) == {:error, :oversized_scenery_batch}
    assert Fetch.run(model, [%{key | level: 11}]) == {:error, :invalid_scenery_key}
    assert Fetch.run(model, [:invalid]) == {:error, :invalid_scenery_key}
    assert Fetch.run(model, []) == {:ok, []}

    assert Fetch.run(%{model | generation: %{resource: nil}}, [key]) ==
             {:error, :unsupported_scenery_generation}

    EditView.put(table, {0, 0, 0}, :binary.copy(<<0>>, 8192))
    assert Fetch.run(model, [key]) == {:error, :stale}
    :ets.delete(table)
    assert Fetch.run(model, [key]) == {:error, :unavailable}
  end

  defp wire(%Key{position: position, level: level}), do: {position, level}
end
