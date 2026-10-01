defmodule WyramCrossPluginAddon.Plugin do
  use Wyram.Plugin,
    id: "fixture-addon",
    dependencies: ["fixture-base"],
    declarations: [WyramCrossPluginAddon.Blocks]
end

defmodule WyramCrossPluginAddon.Blocks do
  use Wyram.Plugin.Declarations, plugin: WyramCrossPluginAddon.Plugin

  defblock Cobble, id: "cobble" do
    template(WyramCrossPluginBase.Plugin.Blocks.Stone)
  end
end
