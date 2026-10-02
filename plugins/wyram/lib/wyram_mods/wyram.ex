defmodule WyramMods.Wyram do
  @moduledoc "The default creative voxel game, declared through the public plugin API."
  use Wyram.Plugin,
    id: "wyram",
    declarations: [WyramMods.Wyram.BlockCatalog],
    game: WyramMods.Wyram.Game
end

defmodule WyramMods.Wyram.BlockCatalog do
  @moduledoc false
  use Wyram.Plugin.Declarations, plugin: WyramMods.Wyram
  alias Wyram.Capability.Material

  defblock Solid, template: true do
    capability(%Material{color: {160, 160, 160}})
  end

  defblock Grass, id: "grass" do
    template(WyramMods.Wyram.Blocks.Solid)
    capability(%Material{color: {96, 150, 76}}, override: true)
  end

  defblock Dirt, id: "dirt" do
    template(WyramMods.Wyram.Blocks.Solid)
    capability(%Material{color: {118, 82, 54}}, override: true)
  end

  defblock Stone, id: "stone" do
    template(WyramMods.Wyram.Blocks.Solid)
    capability(%Material{color: {126, 128, 134}}, override: true)
  end

  defblock Wood, id: "wood" do
    template(WyramMods.Wyram.Blocks.Solid)
    capability(%Material{color: {135, 94, 54}}, override: true)
  end
end

defmodule WyramMods.Wyram.Game do
  @moduledoc false
  @behaviour Wyram.Game.Provider
  alias Wyram.Game.Config
  alias WyramMods.Wyram.Blocks

  @impl true
  def build do
    Config.new!(%{
      terrain: %{surface: Blocks.Grass.ref(), soil: Blocks.Dirt.ref(), rock: Blocks.Stone.ref()},
      profile: WyramMods.Characters.player_profile(),
      models: WyramMods.Characters.models(),
      characters: WyramMods.Characters.definitions()
    })
  end
end
