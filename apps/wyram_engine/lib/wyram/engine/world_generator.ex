defmodule Wyram.Engine.WorldGenerator do
  @moduledoc "Compiles public generation data into one shared immutable native resource."
  alias Wyram.Block.Ref
  alias Wyram.Engine.Native
  alias Wyram.WorldGen.{Biome, Config}
  @field_order [:continentalness, :erosion, :tectonics, :temperature, :humidity, :detail]

  def normalize(nil), do: nil

  def normalize(config) do
    biomes =
      config.biomes
      |> Enum.sort_by(& &1.id)
      |> Enum.map(&%{&1 | features: Enum.sort_by(&1.features, fn feature -> feature.salt end)})

    %{config | biomes: biomes}
  end

  def identity(nil), do: "legacy-v1"

  def identity(config) do
    config
    |> normalize()
    |> Map.from_struct()
    |> Map.delete(:seed)
    |> then(&:erlang.term_to_binary({:density_v1, &1}, [:deterministic]))
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  def compile(nil, seed, palette, _blocks),
    do:
      {:ok,
       %{resource: nil, seed: seed, palette: palette, bounds: {0, 511}, identity: identity(nil)}}

  def compile(config, seed, _palette, blocks) do
    with {:ok, resource} <- Native.compile_generator(seed, wire(normalize(config), blocks)) do
      {:ok,
       %{
         resource: resource,
         seed: seed,
         bounds: Config.bounds(config),
         identity: identity(config)
       }}
    end
  end

  def chunks(%{resource: nil} = context, keys) do
    Enum.map(keys, fn {x, y, z} = key ->
      {low, high} = context.bounds

      data =
        if y * 16 + 15 < low or y * 16 > high,
          do: :binary.copy(<<0>>, 8192),
          else: apply(Native, :generate_chunk, [context.seed, x, y, z] ++ context.palette)

      {key, data}
    end)
  end

  def chunks(context, keys) do
    keys
    |> Enum.chunk_every(32)
    |> Enum.flat_map(fn batch ->
      {:ok, chunks} = Native.generate_world_chunks(context.resource, batch)
      chunks
    end)
  end

  def wire(config, blocks) do
    %{
      min_y: config.min_y,
      height: config.height,
      sea_level: config.sea_level,
      relief: config.relief,
      blend: config.blend,
      fields: Enum.map(@field_order, &field(config.fields[&1])),
      carvers: Enum.map(config.carvers, &carver/1),
      islands: islands(config.islands),
      biomes: Enum.map(config.biomes, &biome(&1, blocks))
    }
  end

  defp field(value), do: {value.scale / 1, value.octaves, value.salt}

  defp carver(value),
    do:
      {Enum.find_index([:caves, :rift], &(&1 == value.kind)), field(value.field),
       value.threshold / 1, value.min_y, value.max_y, value.surface_buffer}

  defp islands(nil), do: nil

  defp islands(value),
    do: {field(value.field), value.base_y, value.thickness, value.relief, value.threshold / 1}

  defp biome(value, blocks) do
    %{
      climate: Enum.map(Biome.axes(), &(value.climate[&1] / 1)),
      surface: handle(value.surface, blocks),
      soil: handle(value.soil, blocks),
      rock: handle(value.rock, blocks),
      water: handle(value.water, blocks),
      elevation_offset: value.elevation_offset,
      features: Enum.map(value.features, &feature(&1, blocks))
    }
  end

  defp feature(value, blocks),
    do:
      {Enum.find_index([:tree, :boulder, :crystal], &(&1 == value.kind)),
       handle(value.block, blocks), handle(value.accent, blocks), value.spacing,
       value.density / 1,
       {value.radius, value.height, value.salt,
        Enum.find_index([:surface, :island], &(&1 == value.domain))}}

  defp handle(nil, _), do: 0
  defp handle(ref, blocks), do: Map.fetch!(blocks, Ref.canonical_id(ref))
end
