defmodule TestAddon do
  @moduledoc "Test-only content package loaded after a world already exists."
  use Wyram.Plugin
  catalog(:blocks, TestAddon.BlockCatalog)
end

defmodule TestAddon.BlockCatalog do
  @moduledoc false
  use Wyram.Plugin.Catalog, kind: :block, plugin: TestAddon
  alias Wyram.Capability.Material

  defblock Prism, id: "prism" do
    template(TestTerrain.Blocks.Violet)
    capability(%Material{color: {33, 211, 177}}, override: true)
  end
end
