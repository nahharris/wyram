defmodule Wyram.WorldGen.Config do
  @moduledoc "Versioned data-only generation pipeline. Default datum is sea level zero within a 512-block world (-192 through 319)."
  alias Wyram.WorldGen.{Biome, Carver, Field, Islands, Schema}

  @fields %{
    continentalness: %Field{scale: 1536.0, salt: 11},
    erosion: %Field{scale: 256.0, salt: 23},
    tectonics: %Field{scale: 640.0, salt: 31},
    temperature: %Field{scale: 1024.0, salt: 43},
    humidity: %Field{scale: 768.0, salt: 53},
    detail: %Field{scale: 64.0, salt: 61}
  }
  defstruct version: 1,
            seed: 2026,
            min_y: -192,
            height: 512,
            sea_level: 0,
            relief: 140,
            blend: 0.2,
            fields: @fields,
            carvers: [%Carver{}],
            islands: %Islands{},
            biomes: []

  @type t :: %__MODULE__{}
  def new!(attrs), do: Schema.new!(__MODULE__, attrs)
  def bounds(value), do: {value.min_y, value.min_y + value.height - 1}
  def references(value), do: Enum.flat_map(value.biomes, &Biome.references/1)

  def validate(value) do
    Schema.result(
      Schema.complete?(value, __MODULE__) and value.version == 1 and
        Schema.integer?(value.seed, 0, 18_446_744_073_709_551_615) and
        valid_vertical?(value) and valid_pipeline?(value)
    )
  end

  defp valid_vertical?(value) do
    Schema.integer?(value.min_y, -4096, 3584) and rem(value.min_y, 16) == 0 and
      Schema.integer?(value.height, 64, 512) and rem(value.height, 16) == 0 and
      Schema.integer?(value.sea_level, value.min_y + 8, value.min_y + value.height - 8)
  end

  defp valid_pipeline?(value) do
    Schema.integer?(value.relief, 0, 192) and Schema.number?(value.blend, 0.01, 1) and
      valid_fields?(value.fields) and valid_carvers?(value.carvers, bounds(value)) and
      valid_islands?(value.islands, bounds(value)) and valid_biomes?(value.biomes)
  end

  defp valid_fields?(fields) when is_map(fields),
    do:
      Enum.sort(Map.keys(fields)) == Enum.sort(Map.keys(@fields)) and
        Enum.all?(Map.values(fields), &(Field.validate(&1) == :ok))

  defp valid_fields?(_), do: false

  defp valid_carvers?(carvers, {low, high}) when is_list(carvers) and length(carvers) <= 4,
    do:
      Enum.all?(
        carvers,
        &(Carver.validate(&1) == :ok and &1.min_y >= low + 1 and &1.max_y <= high)
      )

  defp valid_carvers?(_, _), do: false
  defp valid_islands?(nil, _), do: true

  defp valid_islands?(islands, {low, high}),
    do:
      Islands.validate(islands) == :ok and islands.base_y - islands.thickness >= low and
        islands.base_y + islands.relief <= high

  defp valid_biomes?(biomes) when is_list(biomes) and length(biomes) in 1..32,
    do:
      Enum.all?(biomes, &(Biome.validate(&1) == :ok)) and
        length(Enum.uniq_by(biomes, & &1.id)) == length(biomes) and
        Enum.sum(Enum.map(biomes, &length(&1.features))) <= 64

  defp valid_biomes?(_), do: false
end
