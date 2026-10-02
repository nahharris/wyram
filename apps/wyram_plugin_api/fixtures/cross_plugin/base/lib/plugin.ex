defmodule WyramMods.CrossPluginBase.Plugin do
  use Wyram.Plugin,
    id: "fixture-base",
    declarations: [WyramMods.CrossPluginBase.Blocks],
    providers: [WyramMods.CrossPluginBase.ProviderHelper]
end

defmodule WyramMods.CrossPluginBase.Blocks do
  use Wyram.Plugin.Declarations, plugin: WyramMods.CrossPluginBase.Plugin

  defblock Stone, id: "stone" do
    capability(%WyramMods.CrossPluginBase.TintConfig{
      channel: :base,
      marker: :terrain_catalog_only_atom
    })
  end
end
