defmodule Wyram.Engine.NativeLodTest do
  use ExUnit.Case, async: true
  alias Wyram.Block.Ref
  alias Wyram.Engine.{Native, WorldGenerator}
  alias Wyram.WorldGen.{Biome, Config}

  setup_all do
    solid = Ref.new!("fixture", "solid")
    liquid = Ref.new!("fixture", "liquid")
    biome = Biome.new!(%{id: "lod", surface: solid, soil: solid, rock: solid, water: liquid})
    config = Config.new!(%{biomes: [biome]})

    {:ok, context} =
      WorldGenerator.compile(config, 2026, [], %{"fixture:solid" => 42, "fixture:liquid" => 17})

    {:ok, resource: context.resource}
  end

  test "visual-only generation and edit batches are deterministic", %{resource: resource} do
    key = {2, 0, -1, 0}
    assert {:ok, data} = Native.generate_lod_tile(resource, key, [17])
    assert <<"LT01", _::binary>> = data
    assert byte_size(data) <= 1_048_576
    assert Native.generate_lod_tile(resource, key, [17]) == {:ok, data}
    edits = [{{0, -1, 0}, :binary.copy(<<0>>, 8192)}]
    assert {:ok, changed} = Native.apply_lod_edits(key, data, edits, [17])
    refute changed == data
    assert Native.apply_lod_edits(key, data, edits, [17]) == {:ok, changed}
  end

  test "malformed keys, blobs and edit batches fail without partial output", %{resource: resource} do
    assert {:error, _} = Native.generate_lod_tile(resource, {32, 0, 0, 0}, [17])
    assert {:error, _} = Native.generate_lod_tile(resource, {2, 50_000, 0, 0}, [17])
    key = {2, 0, 0, 0}
    assert {:error, _} = Native.apply_lod_edits(key, "bad", [], [17])
    assert {:ok, data} = Native.generate_lod_tile(resource, key, [17])
    assert {:error, _} = Native.apply_lod_edits(key, data, [{{0, 0, 0}, "bad"}], [17])

    assert {:error, _} =
             Native.apply_lod_edits(
               key,
               data,
               List.duplicate({{0, 0, 0}, :binary.copy(<<0>>, 8192)}, 129),
               [17]
             )

    assert {:error, _} = Native.generate_lod_tile(resource, key, List.duplicate(17, 257))
  end
end
