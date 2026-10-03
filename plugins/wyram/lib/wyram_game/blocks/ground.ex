defmodule WyramGame.Blocks.Ground do
  @moduledoc false
  use Wyram.Plugin.Catalog, plugin: WyramGame, kind: :block
  alias Wyram.Capability.Material

  defblock Grass, id: "grass" do
    template(WyramGame.Blocks.Solid)
    capability(%Material{color: {96, 150, 76}}, override: true)
  end

  defblock Dirt, id: "dirt" do
    template(WyramGame.Blocks.Solid)
    capability(%Material{color: {118, 82, 54}}, override: true)
  end

  defblock Stone, id: "stone" do
    template(WyramGame.Blocks.Solid)
    capability(%Material{color: {126, 128, 134}}, override: true)
  end
end
