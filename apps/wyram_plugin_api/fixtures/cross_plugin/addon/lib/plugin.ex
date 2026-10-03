defmodule CrossPluginAddon.Plugin do
  use Wyram.Plugin
  catalog(CrossPluginAddon.Blocks)
  game(CrossPluginAddon.Game)
end

defmodule CrossPluginAddon.Blocks do
  use Wyram.Plugin.Catalog, kind: :block

  defblock Cobble, id: "cobble" do
    template(CrossPluginBase.Plugin.Blocks.Stone)
  end
end

defmodule CrossPluginAddon.Game do
  @behaviour Wyram.Game.Provider

  alias Wyram.Game.Config
  alias CrossPluginBase.Plugin.Blocks.Stone

  @impl true
  def build do
    stone = Stone.ref()

    Config.new!(%{
      palette: Map.new([:surface, :soil, :rock], &{&1, stone})
    })
  end
end
