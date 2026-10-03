defmodule WyramGame.Blocks.Liquids do
  @moduledoc false
  use Wyram.Plugin.Catalog, plugin: WyramGame, kind: :block
  alias Wyram.Capability.{Liquid, Material}

  defblock Water, id: "water" do
    template(WyramGame.Blocks.Fluid)
    capability(%Liquid{flow_ms: 200, max_level: 7})
    capability(%Material{color: {40, 105, 220}, mode: :blended, opacity: 160})
  end

  defblock Lava, id: "lava" do
    template(WyramGame.Blocks.Fluid)
    capability(%Liquid{flow_ms: 800, max_level: 3})
    capability(%Material{color: {245, 90, 18}, mode: :emissive})
  end
end
