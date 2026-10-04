defmodule Wyram.GameSetup do
  @moduledoc false
  use Wyram.Game
  alias Wyram.{Characters, WorldGen}
  worldgen WorldGen.Wilderness

  scenery(
    distance: 1024,
    max_level: 5,
    detail_distance: 128,
    max_tiles: 4096,
    cache_bytes: 268_435_456,
    mesh_bytes: 268_435_456
  )

  player Characters.Player
  spawn Characters.Companion, id: "companion", position: {2.5, 71.38, -2.5}
  spawn_policy :surface
end
