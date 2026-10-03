defmodule Wyram.Blocks.Ground do
  @moduledoc false
  use Wyram.Plugin.Catalog, kind: :block
  alias Wyram.Capability.Material

  defblock Grass do
    template Wyram.Blocks.Solid
    capability %Material{color: {96, 150, 76}}, override: true
  end

  defblock Dirt do
    template Wyram.Blocks.Solid
    capability %Material{color: {118, 82, 54}}, override: true
  end

  defblock Stone do
    template Wyram.Blocks.Solid
    capability %Material{color: {126, 128, 134}}, override: true
  end
end
