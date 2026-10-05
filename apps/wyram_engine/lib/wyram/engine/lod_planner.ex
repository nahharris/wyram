defmodule Wyram.Engine.LodPlanner do
  @moduledoc """
  Plans aligned, full-height LOD tiles around a chunk-centered observer.

  Tile keys are `{size, tx, ty, tz}`. Each tile contains 32 cubed cells of
  `size` blocks, and its position is a tile-grid index. `tile_bounds/1`
  returns the inclusive world-block bounds including its one-cell halo.
  """

  @coordinate_limit 1_000_000
  @sizes [2, 4, 8, 16]
  @height_limit 512

  @type tile_key :: {2 | 4 | 8 | 16, integer(), integer(), integer()}

  @spec plan({integer(), integer(), integer()}, {integer(), integer()}, integer(), integer()) ::
          [tile_key()]
  def plan({cx, cy, cz} = center, {min_y, max_y} = bounds, radius, max_size \\ 16) do
    validate_center!(center)
    validate_bounds!(bounds)
    validate_radius!(radius)
    validate_max_size!(max_size)

    @sizes
    |> Enum.take_while(&(&1 <= max_size))
    |> Enum.flat_map(fn size ->
      {inner_multiplier, outer_multiplier} = band(size)
      inner_radius = inner_multiplier * radius
      outer_radius = outer_multiplier * radius
      chunk_span = 2 * size
      low_tile_y = Integer.floor_div(min_y, 32 * size)
      high_tile_y = Integer.floor_div(max_y, 32 * size)

      for tx <- tile_range(cx, outer_radius + 2, chunk_span),
          tz <- tile_range(cz, outer_radius + 2, chunk_span),
          ty <- low_tile_y..high_tile_y,
          key = {size, tx, ty, tz},
          valid_tile_bounds?(key),
          intersects_band?(key, center, inner_radius, outer_radius),
          do: key
    end)
    |> Enum.uniq()
    |> Enum.sort_by(&order_key(&1, {cx, cy, cz}))
  end

  @spec desired_size(
          {integer(), integer()},
          {integer(), integer(), integer()},
          integer(),
          integer()
        ) ::
          0 | 1 | 2 | 4 | 8 | 16
  def desired_size({chunk_x, chunk_z}, {cx, cy, cz}, radius, max_size \\ 16) do
    validate_chunk_position!({chunk_x, chunk_z})
    validate_center!({cx, cy, cz})
    validate_radius!(radius)
    validate_max_size!(max_size)

    distance_squared = (chunk_x - cx) * (chunk_x - cx) + (chunk_z - cz) * (chunk_z - cz)

    if distance_squared <= radius * radius,
      do: 1,
      else: distant_size(distance_squared, radius, max_size)
  end

  defp distant_size(distance_squared, radius, max_size) do
    Enum.find_value(@sizes, 0, fn size ->
      if size <= max_size and distance_squared <= size * radius * (size * radius), do: size
    end)
  end

  @spec tile_bounds(tile_key()) ::
          {{integer(), integer(), integer()}, {integer(), integer(), integer()}}
  def tile_bounds({size, tx, ty, tz} = key) do
    validate_tile_key!(key)
    span = 32 * size
    origin = {tx * span, ty * span, tz * span}
    halo = size

    bounds =
      {{elem(origin, 0) - halo, elem(origin, 1) - halo, elem(origin, 2) - halo},
       {elem(origin, 0) + span + halo - 1, elem(origin, 1) + span + halo - 1,
        elem(origin, 2) + span + halo - 1}}

    unless valid_bounds_coordinates?(bounds),
      do: invalid!("tile bounds exceed world coordinate limits")

    bounds
  end

  @spec affected_tiles({integer(), integer(), integer()}) :: [tile_key()]
  def affected_tiles({chunk_x, chunk_y, chunk_z} = chunk_key) do
    validate_chunk_position!({chunk_x, chunk_z})
    validate_chunk_position!({chunk_y, 0})

    chunk_minimum = {chunk_x * 16, chunk_y * 16, chunk_z * 16}
    chunk_maximum = {chunk_x * 16 + 15, chunk_y * 16 + 15, chunk_z * 16 + 15}

    @sizes
    |> Enum.flat_map(fn size ->
      span = 32 * size

      [base_x, base_y, base_z] =
        Enum.map(Tuple.to_list(chunk_key), &Integer.floor_div(&1 * 16, span))

      for tx <- (base_x - 1)..(base_x + 1),
          ty <- (base_y - 1)..(base_y + 1),
          tz <- (base_z - 1)..(base_z + 1),
          key = {size, tx, ty, tz},
          valid_tile_bounds?(key),
          bounds_overlap?(chunk_minimum, chunk_maximum, tile_bounds(key)),
          do: key
    end)
    |> Enum.uniq()
    |> Enum.sort_by(fn {size, tx, ty, tz} -> {size, ty, tx, tz} end)
  end

  defp band(2), do: {1, 2}
  defp band(4), do: {2, 4}
  defp band(8), do: {4, 8}
  defp band(16), do: {8, 16}

  defp tile_range(center_chunk, radius, tile_chunk_span) do
    first = Integer.floor_div(center_chunk - radius - tile_chunk_span, tile_chunk_span)
    last = Integer.floor_div(center_chunk + radius + tile_chunk_span, tile_chunk_span)
    first..last
  end

  defp intersects_band?({size, tx, _ty, tz}, {cx, _cy, cz}, inner_radius, outer_radius) do
    tile_chunk_span = 2 * size
    observer_x = 2 * cx + 1
    observer_z = 2 * cz + 1
    min_x = 2 * tx * tile_chunk_span + 1
    max_x = 2 * (tx + 1) * tile_chunk_span - 1
    min_z = 2 * tz * tile_chunk_span + 1
    max_z = 2 * (tz + 1) * tile_chunk_span - 1
    min_dx = axis_min_distance(observer_x, min_x, max_x)
    min_dz = axis_min_distance(observer_z, min_z, max_z)
    max_dx = max(abs(observer_x - min_x), abs(observer_x - max_x))
    max_dz = max(abs(observer_z - min_z), abs(observer_z - max_z))
    minimum_distance_squared = min_dx * min_dx + min_dz * min_dz
    maximum_distance_squared = max_dx * max_dx + max_dz * max_dz
    buffered_inner = max(0, inner_radius - 2)
    buffered_outer = outer_radius + 2

    minimum_distance_squared <= 2 * buffered_outer * (2 * buffered_outer) and
      maximum_distance_squared >= 2 * buffered_inner * (2 * buffered_inner)
  end

  defp order_key({size, tx, ty, tz}, {cx, cy, cz}) do
    tile_chunk_span = 2 * size
    observer_x = 2 * cx + 1
    observer_z = 2 * cz + 1
    min_x = 2 * tx * tile_chunk_span + 1
    max_x = 2 * (tx + 1) * tile_chunk_span - 1
    min_z = 2 * tz * tile_chunk_span + 1
    max_z = 2 * (tz + 1) * tile_chunk_span - 1
    dx = axis_min_distance(observer_x, min_x, max_x)
    dz = axis_min_distance(observer_z, min_z, max_z)
    vertical_distance = abs(2 * ty * tile_chunk_span + tile_chunk_span - (2 * cy + 1))
    {dx * dx + dz * dz, size, vertical_distance, ty, tx, tz}
  end

  defp axis_min_distance(point, minimum, maximum) do
    cond do
      point < minimum -> minimum - point
      point > maximum -> point - maximum
      true -> 0
    end
  end

  defp bounds_overlap?(
         {left_min_x, left_min_y, left_min_z},
         {left_max_x, left_max_y, left_max_z},
         {{right_min_x, right_min_y, right_min_z}, {right_max_x, right_max_y, right_max_z}}
       ) do
    left_min_x <= right_max_x and right_min_x <= left_max_x and
      left_min_y <= right_max_y and right_min_y <= left_max_y and
      left_min_z <= right_max_z and right_min_z <= left_max_z
  end

  defp valid_tile_bounds?(key) do
    tile_bounds(key)
    true
  rescue
    ArgumentError -> false
  end

  defp valid_bounds_coordinates?({minimum, maximum}) do
    Enum.all?(
      Tuple.to_list(minimum) ++ Tuple.to_list(maximum),
      &(is_integer(&1) and abs(&1) <= @coordinate_limit)
    )
  end

  defp validate_center!({cx, cy, cz}) do
    unless Enum.all?([cx, cy, cz], &(is_integer(&1) and abs(&1 * 16) <= @coordinate_limit)) do
      invalid!("center chunks exceed world coordinate limits")
    end
  end

  defp validate_chunk_position!({x, y}) do
    unless Enum.all?([x, y], &(is_integer(&1) and abs(&1 * 16) <= @coordinate_limit)) do
      invalid!("chunk coordinates exceed world coordinate limits")
    end
  end

  defp validate_bounds!({min_y, max_y}) do
    unless is_integer(min_y) and is_integer(max_y) and min_y <= max_y and
             max_y - min_y + 1 <= @height_limit and
             abs(min_y) <= @coordinate_limit and abs(max_y) <= @coordinate_limit do
      invalid!("bounds must be finite, ordered, and no taller than the world limit")
    end
  end

  defp validate_radius!(radius) do
    unless is_integer(radius) and radius in 1..11,
      do: invalid!("radius must be between 1 and 11 chunks")
  end

  defp validate_max_size!(max_size) do
    unless max_size in @sizes, do: invalid!("max_size must be one of 2, 4, 8, or 16")
  end

  defp validate_tile_key!({size, tx, ty, tz}) do
    unless size in @sizes and Enum.all?([tx, ty, tz], &is_integer/1) do
      invalid!("tile key must use an allowed size and integer coordinates")
    end
  end

  defp invalid!(message), do: raise(ArgumentError, message)
end
