defmodule Wyram.Engine.Scenery.Wire do
  @moduledoc "Portable visual plans and credited packed tile batches."
  alias Wyram.Scenery.{Config, Key}
  @max_u64 18_446_744_073_709_551_615

  def plan(epoch, stamp, %{content: content} = plan, %Config{} = config)
      when epoch in 1..@max_u64 and stamp in 0..@max_u64 and content in 1..@max_u64 do
    :ok = Config.validate(config)
    indices = plan.order |> Enum.with_index() |> Map.new()
    count = map_size(indices)

    if count != length(plan.order) or count != map_size(plan.nodes) or count > config.max_tiles,
      do: raise(ArgumentError, "invalid scenery plan")

    roots = Enum.map(plan.roots, &<<Map.fetch!(indices, &1)::16>>)
    nodes = Enum.map(plan.order, &node(&1, Map.fetch!(plan.nodes, &1), indices))

    [
      <<"WSP1", epoch::64, content::64, stamp::64, config.distance::16, config.cache_bytes::32,
        config.mesh_bytes::32, count::16, length(roots)::16>>,
      roots,
      nodes
    ]
  end

  def plan(_, _, _, _), do: raise(ArgumentError, "invalid scenery plan")

  def tiles(epoch, delivery, tiles)
      when epoch in 1..@max_u64 and delivery in 1..@max_u64 and is_list(tiles) do
    keys = Enum.map(tiles, &elem(&1, 0))

    if length(tiles) not in 1..2 or length(Enum.uniq(keys)) != length(keys),
      do: raise(ArgumentError, "invalid scenery batch")

    [<<"WST1", epoch::64, delivery::64, length(tiles)::16>> | Enum.map(tiles, &tile/1)]
  end

  def tiles(_, _, _), do: raise(ArgumentError, "invalid scenery batch")

  defp node(%Key{position: {x, y, z}, level: level} = key, children, indices)
       when level in 1..6 and length(children) in [0, 8] do
    :ok = Key.validate(key)

    [
      <<x::signed-32, y::signed-32, z::signed-32, level, length(children)>>
      | Enum.map(children, &<<Map.fetch!(indices, &1)::16>>)
    ]
  end

  defp node(_, _, _), do: raise(ArgumentError, "invalid scenery node")

  @doc false
  def valid_tile?(
        {%Key{position: {x, y, z}, level: level},
         <<"WSL", version, level, mode, 0, 0, x::little-signed-32, y::little-signed-32,
           z::little-signed-32, payload::binary>>}
      )
      when version in [?1, ?2] do
    cell = if version == ?2, do: 10, else: 8

    expected =
      case mode do
        0 -> 0
        1 -> cell
        2 -> cell * 4096
        _ -> -1
      end

    byte_size(payload) == expected
  end

  def valid_tile?(_), do: false

  defp tile({_, bytes} = entry) do
    if not valid_tile?(entry), do: raise(ArgumentError, "invalid scenery tile")
    [<<byte_size(bytes)::32>>, bytes]
  end

  defp tile(_), do: raise(ArgumentError, "invalid scenery tile")
end
