defmodule WyramGame.Blocks.Wooden do
  @moduledoc false
  use Wyram.Plugin.Catalog, plugin: WyramGame, kind: :block
  alias Wyram.Capability.Material

  defblock Wood, id: "wood" do
    template(WyramGame.Blocks.Solid)
    capability(%Material{color: {135, 94, 54}}, override: true)
  end

  defblock Leaves, id: "leaves" do
    template(WyramGame.Blocks.Solid)
    capability(%Material{color: {65, 116, 67}}, override: true)
  end
end
