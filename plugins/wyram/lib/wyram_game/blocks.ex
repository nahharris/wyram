defmodule WyramGame.Blocks do
  @moduledoc false
  use Wyram.Plugin.Catalog, plugin: WyramGame, kind: :block

  include(WyramGame.Blocks.Templates)
  include(WyramGame.Blocks.Ground)
  include(WyramGame.Blocks.Wooden)
  include(WyramGame.Blocks.Liquids)
end
