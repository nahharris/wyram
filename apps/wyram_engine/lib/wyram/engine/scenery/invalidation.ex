defmodule Wyram.Engine.Scenery.Invalidation do
  @moduledoc "Conservative tile dependencies for bounded saved-chunk changes."
  alias Wyram.Scenery.Key

  def keys(chunks, plan) do
    # All generation samples, including shifted sea samples, remain within the
    # tile's volume. Invalidate its ancestor at every supported visual level.
    # Mesh-neighbor dependencies belong to presentation, not tile generation.
    ancestors =
      for {x, y, z} <- chunks, level <- 1..6, into: MapSet.new() do
        scale = Integer.pow(2, level)

        %Key{
          position:
            {Integer.floor_div(x, scale), Integer.floor_div(y, scale),
             Integer.floor_div(z, scale)},
          level: level
        }
      end

    MapSet.intersection(ancestors, MapSet.new(plan.order))
  end
end
