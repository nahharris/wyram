defmodule Wyram.Engine.ChunkStream do
  @moduledoc "Finite full-height residency, ordered near the observer for bounded transport batches."
  def forget_packets(keys, 1) do
    keys
    |> Enum.chunk_every(16)
    |> Enum.map(fn batch -> %{type: "forget_chunks", keys: Enum.map(batch, &Tuple.to_list/1)} end)
  end

  def forget_packets(keys, _protocol),
    do: Enum.map(keys, &%{type: "forget", key: Tuple.to_list(&1)})

  def view_radius(value \\ System.get_env("WYRAM_NEAR_VIEW_RADIUS")) do
    case Integer.parse(value || "11") do
      {radius, ""} when radius in 1..11 -> radius
      _ -> 11
    end
  end

  def keys({cx, cy, cz}, {low, high}, radius) do
    keys =
      for x <- (cx - radius)..(cx + radius),
          z <- (cz - radius)..(cz + radius),
          (x - cx) * (x - cx) + (z - cz) * (z - cz) <= radius * radius,
          y <- Integer.floor_div(low, 16)..Integer.floor_div(high, 16),
          do: {x, y, z}

    Enum.sort_by(keys, fn {x, y, z} ->
      {(x - cx) * (x - cx) + (y - cy) * (y - cy) + (z - cz) * (z - cz), y, x, z}
    end)
  end

  def column_order(keys, {cx, cy, cz}) do
    Enum.sort_by(keys, fn {x, y, z} = key ->
      {(x - cx) * (x - cx) + (z - cz) * (z - cz), abs(y - cy), key}
    end)
  end
end
