defmodule Wyram.GameSetup do
  @moduledoc false
  use Wyram.Game
  alias Wyram.{Characters, WorldGen}
  worldgen WorldGen.Wilderness
  player Characters.Player
  spawn Characters.Companion, id: "companion", position: {2.5, 71.38, -2.5}
  spawn_policy :surface
end
