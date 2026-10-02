defmodule WyramMods.CrossPluginAddon.Plugin do
  use Wyram.Plugin,
    id: "fixture-addon",
    dependencies: ["fixture-base"],
    declarations: [WyramMods.CrossPluginAddon.Blocks],
    game: WyramMods.CrossPluginAddon.Game
end

defmodule WyramMods.CrossPluginAddon.Blocks do
  use Wyram.Plugin.Declarations, plugin: WyramMods.CrossPluginAddon.Plugin

  defblock Cobble, id: "cobble" do
    template(WyramMods.CrossPluginBase.Plugin.Blocks.Stone)
  end
end

defmodule WyramMods.CrossPluginAddon.Game do
  @behaviour Wyram.Game.Provider

  alias Wyram.Game.Config
  alias WyramMods.CrossPluginBase.Plugin.Blocks.Stone

  @impl true
  def build do
    stone = Stone.ref()

    Config.new!(%{
      terrain: Map.new([:surface, :soil, :rock], &{&1, stone})
    })
  end
end
