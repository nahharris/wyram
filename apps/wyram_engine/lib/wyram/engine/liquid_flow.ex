defmodule Wyram.Engine.LiquidFlow do
  @moduledoc "Pure source-driven flow rules over a single immutable neighborhood."

  def next(id, above, sides, table) do
    current = table[id]

    cond do
      current && current.level == 0 -> id
      id != 0 and is_nil(current) -> id
      true -> supplied(current, above, sides, table)
    end
  end

  defp supplied(current, above, sides, table) do
    top = table[above]

    if top && same_liquid?(current, top) do
      List.last(top.variants)
    else
      sides
      |> Enum.flat_map(&side_supply(&1, current, table))
      |> Enum.min(fn -> {0, "", 0} end)
      |> elem(2)
    end
  end

  defp side_supply({neighbor, below}, current, table) do
    side = table[neighbor]

    if side && same_liquid?(current, side) && supported?(below, table[below]),
      do: attenuate(side),
      else: []
  end

  defp attenuate(side) do
    level = if side.falling, do: 1, else: side.level + 1

    if level <= side.max_level,
      do: [{level, Map.get(side, :identity, side.source), Enum.at(side.variants, level)}],
      else: []
  end

  defp same_liquid?(nil, _), do: true
  defp same_liquid?(current, other), do: current.source == other.source
  defp supported?(0, _), do: false
  defp supported?(_, nil), do: true
  defp supported?(_, liquid), do: liquid.level == 0
end
