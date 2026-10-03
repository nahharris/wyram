defmodule CrossPluginBase.Plugin do
  use Wyram.Plugin
  catalog(:blocks, CrossPluginBase.Blocks)
  provider(CrossPluginBase.ProviderHelper)
end

defmodule CrossPluginBase.Blocks do
  use Wyram.Plugin.Catalog, kind: :block, plugin: CrossPluginBase.Plugin

  defblock Stone, id: "stone" do
    capability(%CrossPluginBase.TintConfig{
      channel: :base,
      marker: :terrain_catalog_only_atom
    })
  end
end
