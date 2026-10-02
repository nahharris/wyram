defmodule WyramMods.TestTerrain do
  @moduledoc "Test-only terrain with names unrelated to the Wyram game."
  use Wyram.Plugin,
    id: "test_terrain",
    declarations: [WyramMods.TestTerrain.BlockCatalog],
    game: WyramMods.TestTerrain.Game
end

defmodule WyramMods.TestTerrain.BlockCatalog do
  @moduledoc false
  use Wyram.Plugin.Declarations, plugin: WyramMods.TestTerrain
  alias Wyram.Capability.Material

  defblock Violet, id: "violet" do
    capability(%Material{color: {73, 39, 177}})
  end

  defblock Ochre, id: "ochre" do
    capability(%Material{color: {201, 113, 37}})
  end

  defblock Slate, id: "slate" do
    capability(%Material{color: {42, 63, 84}})
  end
end

defmodule WyramMods.TestTerrain.Game do
  @moduledoc false
  @behaviour Wyram.Game.Provider
  alias Wyram.Game.Config
  alias WyramMods.TestTerrain.Blocks

  @impl true
  def build do
    Config.new!(%{
      terrain: %{surface: Blocks.Violet.ref(), soil: Blocks.Ochre.ref(), rock: Blocks.Slate.ref()}
    })
  end
end
