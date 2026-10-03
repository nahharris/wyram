defmodule Wyram.Engine.LiquidSimulation do
  @moduledoc "Coordinates bounded neighborhood snapshots; regions own cells and pending work."
  use GenServer
  alias Wyram.Engine.{LiquidFlow, PluginManager, World}

  @sides [{1, 0, 0}, {-1, 0, 0}, {0, 0, 1}, {0, 0, -1}]
  @interval 100
  @region_budget 8
  @cell_budget 64

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)
  def changed(positions, delay), do: GenServer.cast(__MODULE__, {:changed, positions, delay})

  def affected({x, y, z} = position) do
    [
      position,
      {x, y + 1, z},
      {x, y - 1, z}
      | Enum.flat_map(@sides, fn {dx, _, dz} -> [{x + dx, y, z + dz}, {x + dx, y + 1, z + dz}] end)
    ]
  end

  @impl true
  def init(_) do
    Enum.each(regions(), fn {_key, pid} -> GenServer.cast(pid, :seed_liquids) end)
    Process.send_after(self(), :tick, @interval)
    {:ok, %{table: PluginManager.liquids(), cursor: 0}}
  end

  @impl true
  def handle_cast({:changed, positions, delay}, state) do
    positions
    |> Enum.flat_map(&affected/1)
    |> Enum.uniq()
    |> World.schedule_liquids(System.monotonic_time(:millisecond) + delay)

    {:noreply, state}
  end

  @impl true
  def handle_info(:tick, state) do
    owners = regions()
    selected = owners |> Enum.drop(state.cursor) |> Enum.take(@region_budget)
    now = System.monotonic_time(:millisecond)
    positions = Enum.flat_map(selected, fn {_key, pid} -> take_frontier(pid, now) end)
    advance(positions, state.table)
    next = state.cursor + @region_budget
    Process.send_after(self(), :tick, @interval)
    {:noreply, %{state | cursor: if(next >= length(owners), do: 0, else: next)}}
  end

  defp regions do
    Registry.select(Wyram.Engine.RegionRegistry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.sort()
  end

  defp take_frontier(pid, now) do
    GenServer.call(pid, {:liquid_frontier, now, @cell_budget})
  catch
    :exit, _ -> []
  end

  defp advance([], _table), do: :ok

  defp advance(positions, table) do
    samples = positions |> Enum.flat_map(&neighborhood/1) |> Enum.uniq() |> World.get_blocks()

    edits =
      Enum.flat_map(positions, fn {x, y, z} = position ->
        id = samples[position]

        sides =
          Enum.map(@sides, fn {dx, _, dz} ->
            {samples[{x + dx, y, z + dz}], samples[{x + dx, y - 1, z + dz}]}
          end)

        next = LiquidFlow.next(id, samples[{x, y + 1, z}], sides, table)
        if next == id, do: [], else: [{position, id, next}]
      end)

    World.apply_liquid_edits(edits)
  catch
    :exit, _ -> changed(positions, @interval)
  end

  defp neighborhood({x, y, z} = position) do
    [
      position,
      {x, y + 1, z}
      | Enum.flat_map(@sides, fn {dx, _, dz} -> [{x + dx, y, z + dz}, {x + dx, y - 1, z + dz}] end)
    ]
  end
end
