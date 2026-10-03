defmodule Wyram.WorldGen.Terrain do
  @moduledoc "Local relief, erosion valleys and buildable shelves. Strengths range from zero to one; dimensions are blocks."
  alias Wyram.WorldGen.Schema

  defstruct roughness: 12.0,
            valley_depth: 20.0,
            plains_strength: 0.8,
            shelf_height: 8,
            shelf_strength: 0.65

  def new!(attrs), do: Schema.new!(__MODULE__, attrs)

  def validate(value) do
    Schema.result(
      Schema.complete?(value, __MODULE__) and
        Schema.number?(value.roughness, 0, 32) and Schema.number?(value.valley_depth, 0, 64) and
        Schema.number?(value.plains_strength, 0, 1) and Schema.integer?(value.shelf_height, 2, 16) and
        Schema.number?(value.shelf_strength, 0, 1)
    )
  end
end
