defmodule Wyram.Engine.ChunkStream do
  @moduledoc "Finite full-height residency, ordered near the observer for bounded transport batches."
  def keys({cx, cy, cz}, {low, high}, radius) do
    keys =
      for x <- (cx - radius)..(cx + radius),
          z <- (cz - radius)..(cz + radius),
          y <- Integer.floor_div(low, 16)..Integer.floor_div(high, 16),
          do: {x, y, z}

    Enum.sort_by(keys, fn {x, y, z} ->
      {(x - cx) * (x - cx) + (y - cy) * (y - cy) + (z - cz) * (z - cz), y, x, z}
    end)
  end
end
