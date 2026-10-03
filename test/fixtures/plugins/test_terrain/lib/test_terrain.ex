defmodule TestTerrain do
  @moduledoc "Test-only palette with names unrelated to the Wyram game."
  use Wyram.Plugin
  catalog TestTerrain.BlockCatalog
  game TestTerrain.Game
end

defmodule TestTerrain.BlockCatalog do
  @moduledoc false
  use Wyram.Plugin.Catalog, kind: :block
  alias Wyram.Capability.Material

  defblock Violet, id: "violet" do
    capability %Material{color: {73, 39, 177}}
  end

  defblock Ochre, id: "ochre" do
    capability %Material{color: {201, 113, 37}}
  end

  defblock Slate, id: "slate" do
    capability %Material{color: {42, 63, 84}}
  end
end

defmodule TestTerrain.Game do
  @moduledoc false
  @behaviour Wyram.Game.Provider
  alias TestTerrain.Blocks
  alias Wyram.Game.Config

  @impl true
  def build do
    Config.new!(%{
      palette: %{surface: Blocks.Violet.ref(), soil: Blocks.Ochre.ref(), rock: Blocks.Slate.ref()}
    })
  end
end
