defmodule WyramCrossPluginBase.Plugin do
  use Wyram.Plugin,
    id: "fixture-base",
    declarations: [WyramCrossPluginBase.Blocks],
    providers: [WyramCrossPluginBase.ProviderHelper]
end

defmodule WyramCrossPluginBase.Blocks do
  use Wyram.Plugin.Declarations, plugin: WyramCrossPluginBase.Plugin

  defblock Stone, id: "stone" do
    capability(%WyramCrossPluginBase.TintConfig{channel: :base})
  end
end
