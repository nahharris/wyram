defmodule WyramMods.CrossPluginAddon.Plugin do
  use Wyram.Plugin,
    id: "fixture-addon",
    dependencies: ["fixture-base"],
    declarations: [WyramMods.CrossPluginAddon.Blocks]
end

defmodule WyramMods.CrossPluginAddon.Blocks do
  use Wyram.Plugin.Declarations, plugin: WyramMods.CrossPluginAddon.Plugin

  defblock Cobble, id: "cobble" do
    template(WyramMods.CrossPluginBase.Plugin.Blocks.Stone)
  end
end
