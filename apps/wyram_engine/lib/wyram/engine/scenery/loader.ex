defmodule Wyram.Engine.Scenery.Loader do
  @moduledoc "Bounded scenery work with immutable cache data and revision rejection."
  defstruct [:config, stamp: 0, pending: [], wanted: MapSet.new(), cache: %{}, tasks: %{}]
  alias Wyram.Scenery.Key
  def new(config), do: %__MODULE__{config: config}

  def reset(loader, plan, stamp) do
    cache = if stamp == loader.stamp, do: Map.take(loader.cache, plan.order), else: %{}

    %{
      loader
      | stamp: stamp,
        wanted: MapSet.new(Map.keys(plan.nodes)),
        cache: cache,
        pending: Enum.reject(plan.order, &Map.has_key?(cache, &1))
    }
  end

  def dispatch(%{tasks: tasks, config: config} = loader, _supervisor, _fetch)
      when map_size(tasks) >= config.workers, do: loader

  def dispatch(loader, supervisor, fetch) do
    busy = loader.tasks |> Map.values() |> Enum.flat_map(& &1.keys) |> MapSet.new()
    keys = loader.pending |> Enum.reject(&MapSet.member?(busy, &1)) |> Enum.take(2)

    if keys == [] or length(Task.Supervisor.children(supervisor)) >= loader.config.workers do
      loader
    else
      task = Task.Supervisor.async_nolink(supervisor, fn -> fetch.(keys) end)
      selected = MapSet.new(keys)
      job = %{task: task, keys: keys, stamp: loader.stamp}

      next = %{
        loader
        | pending: Enum.reject(loader.pending, &MapSet.member?(selected, &1)),
          tasks: Map.put(loader.tasks, task.ref, job)
      }

      dispatch(next, supervisor, fetch)
    end
  end

  def complete(loader, ref, result) do
    case Map.pop(loader.tasks, ref) do
      {nil, _} ->
        {loader, []}

      {job, tasks} ->
        Process.demonitor(ref, [:flush])
        loader = %{loader | tasks: tasks}
        accept(loader, job, result)
    end
  end

  defp accept(loader, %{stamp: stamp}, _) when stamp != loader.stamp, do: {loader, []}

  defp accept(loader, job, {:ok, binaries}) when is_list(binaries) do
    if length(binaries) == length(job.keys) and
         Enum.zip(job.keys, binaries) |> Enum.all?(&valid_output?/1) do
      accepted =
        Enum.zip(job.keys, binaries)
        |> Enum.filter(fn {key, _} -> MapSet.member?(loader.wanted, key) end)

      cache = Map.merge(loader.cache, Map.new(accepted))
      pending = Enum.reject(loader.pending, &Map.has_key?(cache, &1))
      {%{loader | cache: cache, pending: pending}, accepted}
    else
      {loader, {:error, :invalid_scenery_batch}}
    end
  end

  defp accept(loader, _, {:error, reason}), do: {loader, {:error, reason}}
  defp accept(loader, _, _), do: {loader, {:error, :invalid_scenery_batch}}

  # Native generation validates cells. This boundary checks batch identity and
  # storage length before accepting the immutable native outputs into a cache.
  defp valid_output?(
         {%Key{position: position, level: level},
          <<"WSL1", level, mode, 0, 0, x::little-signed-32, y::little-signed-32,
            z::little-signed-32, payload::binary>>}
       ) do
    expected =
      case mode do
        0 -> 0
        1 -> 8
        2 -> 32_768
        _ -> -1
      end

    {x, y, z} == position and byte_size(payload) == expected
  end

  defp valid_output?(_), do: false
end
