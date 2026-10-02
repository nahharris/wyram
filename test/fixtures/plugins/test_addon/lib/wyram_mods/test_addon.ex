defmodule WyramMods.TestAddon do
  @moduledoc "Test-only content package loaded after a world already exists."
  use Wyram.Plugin,
    id: "test_addon",
    dependencies: ["test_terrain"],
    declarations: [WyramMods.TestAddon.BlockCatalog]
end

defmodule WyramMods.TestAddon.BlockCatalog do
  @moduledoc false
  use Wyram.Plugin.Declarations, plugin: WyramMods.TestAddon
  alias Wyram.Capability.Material

  defblock Prism, id: "prism" do
    template(WyramMods.TestTerrain.Blocks.Violet)
    capability(%Material{color: {33, 211, 177}}, override: true)
  end
end
