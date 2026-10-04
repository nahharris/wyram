defmodule Wyram.Engine.Scenery.Plan do
  @moduledoc "Bounded visual refinement with complete sibling replacement groups."
  alias Wyram.Scenery.{Config, Key}
  @coordinate_limit 1_000_000

  def new({x, y, z} = observer, {low, high}, %Config{} = config)
      when is_integer(x) and is_integer(y) and is_integer(z) and is_integer(low) and
             is_integer(high) do
    with true <- Enum.all?([x, y, z, low, high], &(abs(&1) <= @coordinate_limit)),
         true <- (high - low) in 0..511,
         :ok <- Config.validate(config),
         {:ok, roots} <- roots(observer, {low, high}, config) do
      nodes = Map.new(roots, &{&1, []})
      {nodes, order} = refine(nodes, Enum.reverse(roots), roots, observer, {low, high}, config)
      {:ok, %{roots: roots, nodes: nodes, order: Enum.reverse(order)}}
    else
      {:error, :scenery_root_budget} = error -> error
      _ -> {:error, :invalid_scenery_view}
    end
  end

  def new(_, _, _), do: {:error, :invalid_scenery_view}

  defp roots({x, _, z} = observer, {low, high}, config) do
    width = 16 * Integer.pow(2, config.max_level)

    ranges = [
      tile_range(x - config.distance, x + config.distance, width),
      tile_range(low, high, width),
      tile_range(z - config.distance, z + config.distance, width)
    ]

    count = Enum.reduce(ranges, 1, &(Enum.count(&1) * &2))

    if count > config.max_tiles do
      {:error, :scenery_root_budget}
    else
      [xs, ys, zs] = ranges

      roots =
        for x <- xs, y <- ys, z <- zs, do: %Key{position: {x, y, z}, level: config.max_level}

      {:ok, Enum.sort_by(roots, &priority(&1, observer))}
    end
  end

  defp tile_range(low, high, width) do
    first = max(Integer.floor_div(low, width), -Integer.floor_div(@coordinate_limit, width))

    last =
      min(Integer.floor_div(high, width), Integer.floor_div(@coordinate_limit - width + 1, width))

    if first <= last, do: first..last, else: []
  end

  defp refine(nodes, order, [], _, _, _), do: {nodes, order}

  defp refine(nodes, order, [key | pending], observer, bounds, config) do
    if refinable?(key, observer, bounds, config) and map_size(nodes) + 8 <= config.max_tiles do
      children = children(key)
      nodes = Enum.reduce(children, Map.put(nodes, key, children), &Map.put(&2, &1, []))
      order = Enum.reverse(children, order)
      pending = Enum.sort_by(children ++ pending, &priority(&1, observer))
      refine(nodes, order, pending, observer, bounds, config)
    else
      refine(nodes, order, pending, observer, bounds, config)
    end
  end

  defp refinable?(%Key{level: level} = key, observer, {low, high}, config) do
    {:ok, {_, bottom, _}} = Key.origin(key)
    width = 16 * Integer.pow(2, level)
    threshold = config.detail_distance * Integer.pow(2, level)

    level > 1 and bottom <= high and bottom + width > low and
      distance_squared(key, observer) < threshold * threshold
  end

  defp children(%Key{position: {x, y, z}, level: level}) do
    for octant <- 0..7 do
      %Key{
        position:
          {x * 2 + rem(octant, 2), y * 2 + rem(div(octant, 2), 2), z * 2 + div(octant, 4)},
        level: level - 1
      }
    end
  end

  defp priority(key, observer), do: {distance_squared(key, observer), -key.level, key.position}

  defp distance_squared(key, observer) do
    {:ok, origin} = Key.origin(key)
    width = 16 * Integer.pow(2, key.level)

    Enum.zip(Tuple.to_list(origin), Tuple.to_list(observer))
    |> Enum.map(fn {low, point} -> max(max(low - point, point - low - width), 0) end)
    |> Enum.reduce(0, &(&1 * &1 + &2))
  end
end
