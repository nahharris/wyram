defmodule WyramGame.Models do
  @moduledoc false
  use Wyram.Plugin.Catalog, plugin: WyramGame, kind: :model

  defmodel(Player, id: "player", build: {WyramGame.Models.DwarfBuilder, :player})
  defmodel(Companion, id: "companion", build: {WyramGame.Models.DwarfBuilder, :companion})
end
