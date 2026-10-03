defmodule Wyram.Engine.ChunkLoader do
  @moduledoc "Bounded snapshot requests to distinct dense region owners, with view and revision rejection."
  alias Wyram.Engine.World

  @limit 4
  @batch 16
  defstruct pending: [], wanted: MapSet.new(), revisions: %{}, tasks: %{}

  def new, do: %__MODULE__{}

  def reset(loader, keys) do
    loader = cancel(loader)
    revisions = Map.take(loader.revisions, keys)

    %{
      loader
      | pending: Enum.reject(keys, &Map.has_key?(revisions, &1)),
        wanted: MapSet.new(keys),
        revisions: revisions
    }
  end

  def cancel(loader) do
    Enum.each(loader.tasks, fn {ref, %{task: task}} ->
      Process.exit(task.pid, :kill)
      Process.demonitor(ref, [:flush])
    end)

    %{loader | tasks: %{}}
  end

  def dispatch(loader, fetch \\ &World.get_chunk_snapshots/1)
  def dispatch(%{tasks: tasks} = loader, _fetch) when map_size(tasks) >= @limit, do: loader

  def dispatch(loader, fetch) do
    busy = loader.tasks |> Map.values() |> MapSet.new(& &1.region)

    case Enum.find(loader.pending, &(not MapSet.member?(busy, region(&1)))) do
      nil ->
        loader

      key ->
        owner = region(key)
        batch = loader.pending |> Enum.filter(&(region(&1) == owner)) |> Enum.take(@batch)
        selected = MapSet.new(batch)
        pending = Enum.reject(loader.pending, &MapSet.member?(selected, &1))

        task =
          Task.Supervisor.async_nolink(Wyram.Engine.StreamSupervisor, fn -> fetch.(batch) end)

        next = %{
          loader
          | pending: pending,
            tasks: Map.put(loader.tasks, task.ref, %{task: task, region: owner})
        }

        dispatch(next, fetch)
    end
  end

  def complete(loader, ref, chunks) do
    case Map.pop(loader.tasks, ref) do
      {nil, _} ->
        {loader, []}

      {_, tasks} ->
        Process.demonitor(ref, [:flush])

        {accepted, loader} =
          Enum.reduce(chunks, {[], %{loader | tasks: tasks}}, &accept_snapshot/2)

        {loader, Enum.reverse(accepted)}
    end
  end

  def publish(loader, key, revision) do
    if MapSet.member?(loader.wanted, key) and revision > Map.get(loader.revisions, key, -1) do
      {%{loader | revisions: Map.put(loader.revisions, key, revision)}, true}
    else
      {loader, false}
    end
  end

  defp accept_snapshot({key, chunk} = snapshot, {accepted, loader}) do
    case publish(loader, key, chunk.revision) do
      {loader, true} -> {[snapshot | accepted], loader}
      {loader, false} -> {accepted, loader}
    end
  end

  defp region({x, _, z}), do: {Integer.floor_div(x, 4), Integer.floor_div(z, 4)}
end
