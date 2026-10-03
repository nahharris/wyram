defmodule Wyram.WorldGen.Feature do
  @moduledoc "A seeded grid placement rule. Trees, boulders and crystal spires are native bulk primitives; block refs remain plugin-owned."
  alias Wyram.WorldGen.Schema

  defstruct kind: :boulder,
            block: nil,
            accent: nil,
            spacing: 32,
            density: 0.3,
            radius: 3,
            height: 6,
            salt: 1,
            domain: :surface,
            support_depth: 0

  def new!(attrs), do: Schema.new!(__MODULE__, attrs)

  def validate(value) do
    Schema.result(
      Schema.complete?(value, __MODULE__) and value.kind in [:tree, :boulder, :crystal] and
        Schema.ref?(value.block) and Schema.ref?(value.accent) and valid_placement?(value)
    )
  end

  defp valid_placement?(value) do
    value.domain in [:surface, :island] and Schema.integer?(value.support_depth, 0, 64) and
      Schema.integer?(value.spacing, 16, 128) and
      Schema.number?(value.density, 0, 1) and Schema.integer?(value.radius, 1, 16) and
      Schema.integer?(value.height, 1, 64) and Schema.integer?(value.salt, 0, 4_294_967_295)
  end
end
