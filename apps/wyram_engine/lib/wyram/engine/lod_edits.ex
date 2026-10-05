defmodule Wyram.Engine.LodEdits do
  @moduledoc "Spatial keys and revisions for visual-only snapshots of durable edits."
  alias Wyram.Engine.LodPlanner
  defstruct index: %{}, revisions: %{}

  def new(saved), do: Enum.reduce(Map.keys(saved), %__MODULE__{}, &put(&2, &1))

  def put(state, chunk_key) do
    Enum.reduce(LodPlanner.affected_tiles(chunk_key), state, fn tile, acc ->
      %{
        acc
        | index: Map.update(acc.index, tile, MapSet.new([chunk_key]), &MapSet.put(&1, chunk_key)),
          revisions: Map.update(acc.revisions, tile, 1, &(&1 + 1))
      }
    end)
  end

  def revision(state, tile), do: Map.get(state.revisions, tile, 0)

  def snapshot(state, tile, saved) do
    chunks =
      state.index
      |> Map.get(tile, MapSet.new())
      |> Enum.sort()
      |> Enum.map(fn key -> {key, Map.fetch!(saved, key).data} end)

    %{revision: revision(state, tile), chunks: chunks}
  end
end
