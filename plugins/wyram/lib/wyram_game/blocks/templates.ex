defmodule WyramGame.Blocks.Templates do
  @moduledoc false
  use Wyram.Plugin.Catalog, plugin: WyramGame, kind: :block
  alias Wyram.Capability.{Collision, Material}

  defblock Solid, template: true do
    capability(%Material{color: {160, 160, 160}})
  end

  defblock Fluid, template: true do
    capability(%Collision{shape: :none})
  end
end
