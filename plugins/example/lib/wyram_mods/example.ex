defmodule WyramMods.Example do
  @moduledoc "An independently packaged content plugin."
  use Wyram.Plugin,
    id: "example",
    dependencies: ["wyram"],
    declarations: [WyramMods.Example.BlockCatalog]
end

defmodule WyramMods.Example.BlockCatalog do
  @moduledoc false
  use Wyram.Plugin.Declarations, plugin: WyramMods.Example
  alias Wyram.Capability.Material

  defblock Amber, id: "amber" do
    template(WyramMods.Wyram.Blocks.Solid)
    capability(%Material{color: {232, 154, 44}}, override: true)
  end
end
