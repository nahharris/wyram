defmodule Wyram.WorldGen.Biome do
  @moduledoc "Public biome data, used by defbiome declarations and game builders. Climate centers blend continuously; materials and features use seeded selection."
  alias Wyram.WorldGen.{Feature, Schema}
  @axes [:temperature, :humidity, :continentalness, :erosion, :elevation, :tectonics]
  defstruct id: nil,
            climate: Map.new(@axes, &{&1, 0.5}),
            surface: nil,
            soil: nil,
            rock: nil,
            water: nil,
            elevation_offset: 0,
            features: []

  def axes, do: @axes

  def new!(attrs) do
    attrs =
      Map.update(
        attrs,
        :climate,
        Map.new(@axes, &{&1, 0.5}),
        &Map.merge(Map.new(@axes, fn axis -> {axis, 0.5} end), &1)
      )

    Schema.new!(__MODULE__, attrs)
  end

  def validate(value) do
    Schema.result(
      Schema.complete?(value, __MODULE__) and is_binary(value.id) and
        byte_size(value.id) in 1..64 and String.valid?(value.id) and valid_climate?(value.climate) and
        valid_materials?(value) and
        Schema.integer?(value.elevation_offset, -64, 64) and
        valid_features?(value.features)
    )
  end

  def references(value),
    do:
      Enum.reject(
        [value.surface, value.soil, value.rock, value.water] ++
          Enum.flat_map(value.features, &[&1.block, &1.accent]),
        &is_nil/1
      )

  defp valid_materials?(value),
    do:
      Enum.all?([value.surface, value.soil, value.rock], &Schema.ref?/1) and
        (is_nil(value.water) or Schema.ref?(value.water))

  defp valid_climate?(climate) when is_map(climate),
    do:
      Enum.sort(Map.keys(climate)) == Enum.sort(@axes) and
        Enum.all?(Map.values(climate), &Schema.number?(&1, 0, 1))

  defp valid_climate?(_), do: false

  defp valid_features?(features) when is_list(features) and length(features) <= 8,
    do:
      Enum.all?(features, &(Feature.validate(&1) == :ok)) and
        length(Enum.uniq_by(features, & &1.salt)) == length(features)

  defp valid_features?(_), do: false
end
