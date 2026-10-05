defmodule Wyram.Engine.LodStreamer do
  @moduledoc "Visual-only distant planning and bounded generation, independent of nearby streaming."
  use GenServer
  require Logger

  alias Wyram.Engine.{
    ChunkStream,
    ClientPort,
    LodCache,
    LodPlanner,
    LodScheduler,
    LodWire,
    LodWorkers,
    Native,
    PluginManager,
    World
  }

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)
  def configure(parallelism), do: GenServer.cast(__MODULE__, {:configure, parallelism})

  def view(center, epoch, near_busy),
    do: GenServer.cast(__MODULE__, {:view, center, epoch, near_busy})

  def near_busy(busy), do: GenServer.cast(__MODULE__, {:near_busy, busy})
  def invalidate(key), do: GenServer.cast(__MODULE__, {:invalidate, key})

  def acknowledge(epoch, key, revision, ready),
    do: GenServer.cast(__MODULE__, {:ack, epoch, key, revision, ready})

  def status, do: GenServer.call(__MODULE__, :status)
  def request(epoch, keys), do: GenServer.cast(__MODULE__, {:request, epoch, keys})

  def max_cell_size(value \\ System.get_env("WYRAM_LOD_MAX_CELL_SIZE")) do
    case Integer.parse(value || "16") do
      {size, ""} when size in [0, 2, 4, 8, 16] -> size
      _ -> raise ArgumentError, "WYRAM_LOD_MAX_CELL_SIZE must be 0, 2, 4, 8 or 16"
    end
  end

  def liquid_ids(descriptors) do
    descriptors
    |> Enum.filter(fn {_id, descriptor} -> descriptor.liquid != 0 end)
    |> Enum.map(fn {id, _} -> if is_integer(id), do: id, else: String.to_integer(id) end)
    |> Enum.sort()
  end

  @impl true
  def init(_) do
    overrides = LodWorkers.overrides()
    dirty = :erlang.system_info(:dirty_cpu_schedulers_online)
    generation = World.generation()

    {:ok,
     %{
       overrides: overrides,
       dirty: dirty,
       workers: nil,
       generation: generation,
       max_size: max_cell_size(),
       radius: ChunkStream.view_radius(),
       liquids: liquid_ids(PluginManager.render_descriptors()),
       scheduler: LodScheduler.new(1),
       cache: LodCache.new(),
       center: nil,
       epoch: nil,
       near_busy: true,
       configured: false,
       serial: 0,
       completed: 0,
       rejected: 0
     }}
  end

  @impl true
  def handle_cast({:configure, _}, %{configured: true} = state), do: {:noreply, state}

  def handle_cast({:configure, parallelism}, state) do
    workers = LodWorkers.resolve(parallelism, state.dirty, state.overrides)
    enabled = state.max_size != 0 and state.generation.resource != nil

    ClientPort.publish_lod(%{
      type: "lod_config",
      protocol: 1,
      enabled: enabled,
      generation_workers: workers.generation,
      meshing_workers: workers.meshing,
      parallelism: workers.parallelism,
      worker_budget: workers.budget,
      near_radius: state.radius,
      max_cell_size: state.max_size,
      min_y: elem(state.generation.bounds, 0),
      max_y: elem(state.generation.bounds, 1)
    })

    state = %{
      state
      | configured: true,
        workers: workers,
        scheduler: LodScheduler.new(workers.generation)
    }

    {:noreply, plan(state)}
  end

  def handle_cast({:view, center, epoch, busy}, state) do
    changed = center != state.center or epoch != state.epoch
    state = %{state | center: center, epoch: epoch, near_busy: busy}
    {:noreply, if(changed, do: plan(state), else: dispatch(state))}
  end

  def handle_cast({:near_busy, busy}, state), do: {:noreply, dispatch(%{state | near_busy: busy})}

  def handle_cast({:request, epoch, keys}, %{epoch: epoch} = state) do
    keys = Enum.filter(keys, &MapSet.member?(state.scheduler.wanted, &1))
    {:noreply, dispatch(%{state | scheduler: LodScheduler.invalidate(state.scheduler, keys)})}
  end

  def handle_cast({:request, _, _}, state), do: {:noreply, state}

  def handle_cast({:invalidate, chunk}, state) do
    keys = LodPlanner.affected_tiles(chunk)

    state = %{
      state
      | cache: LodCache.invalidate(state.cache, keys),
        scheduler: LodScheduler.invalidate(state.scheduler, keys)
    }

    if state.configured and state.epoch != nil do
      ClientPort.publish_lod(%{
        type: "lod_invalidate",
        epoch: state.epoch,
        tiles: Enum.map(keys, fn key -> Tuple.to_list(key) ++ [World.lod_revision(key)] end)
      })
    end

    {:noreply, dispatch(state)}
  end

  def handle_cast({:ack, epoch, key, revision, ready}, state) do
    scheduler =
      if ready,
        do: LodScheduler.acknowledge(state.scheduler, epoch, key, revision),
        else: LodScheduler.reject(state.scheduler, epoch, key, revision)

    # Rejected admissions retry on a timer rather than spinning against GPU pressure.
    if not ready, do: Process.send_after(self(), :dispatch, 100)
    next = %{state | scheduler: scheduler, rejected: state.rejected + if(ready, do: 0, else: 1)}
    {:noreply, if(ready, do: dispatch(next), else: next)}
  end

  @impl true
  def handle_call({:cache, key, revision}, _, state) do
    {cache, value} = LodCache.get(state.cache, {key, revision})
    {:reply, value, %{state | cache: cache}}
  end

  def handle_call(:status, _, state) do
    {:reply,
     %{
       workers: state.workers,
       max_cell_size: state.max_size,
       cache_bytes: state.cache.bytes,
       generation_jobs: map_size(state.scheduler.tasks),
       transport_jobs: map_size(state.scheduler.outstanding),
       pending_tiles: length(state.scheduler.pending),
       resident_tiles: MapSet.size(state.scheduler.published),
       generated_tiles: state.completed,
       rejected_tiles: state.rejected
     }, state}
  end

  @impl true
  def handle_info(:dispatch, state), do: {:noreply, dispatch(state)}

  def handle_info({ref, result}, state) when is_reference(ref) do
    state =
      case state.scheduler.tasks[ref] do
        %{key: key, obsolete?: false} when is_map(result) ->
          if Map.get(result, :revision) != World.lod_revision(key),
            do: %{state | scheduler: LodScheduler.invalidate(state.scheduler, [key])},
            else: state

        _ ->
          state
      end

    {scheduler, accepted} = LodScheduler.complete(state.scheduler, ref, result)

    cache =
      Enum.reduce(accepted, state.cache, fn {epoch, key, revision, data}, cache ->
        ClientPort.publish_lod(LodWire.encode(epoch, [{key, revision, data}]))
        {cache, :ok} = LodCache.put(cache, {key, revision}, data)
        cache
      end)

    {:noreply,
     dispatch(%{
       state
       | scheduler: scheduler,
         cache: cache,
         completed: state.completed + length(accepted)
     })}
  end

  def handle_info({:DOWN, ref, :process, _, reason}, state) do
    if Map.has_key?(state.scheduler.tasks, ref),
      do: Logger.warning("LOD generation failed: #{inspect(reason)}")

    {:noreply, dispatch(%{state | scheduler: LodScheduler.failed(state.scheduler, ref)})}
  end

  defp plan(%{configured: false} = state), do: state
  defp plan(%{center: nil} = state), do: state
  defp plan(%{max_size: 0} = state), do: state
  defp plan(%{generation: %{resource: nil}} = state), do: state

  defp plan(state) do
    keys = LodPlanner.plan(state.center, state.generation.bounds, state.radius, state.max_size)
    serial = state.serial + 1

    ClientPort.publish_lod(%{
      type: "lod_plan",
      epoch: state.epoch,
      serial: serial,
      center: Tuple.to_list(state.center),
      keys: Enum.map(keys, &Tuple.to_list/1)
    })

    dispatch(%{
      state
      | serial: serial,
        scheduler: LodScheduler.reset(state.scheduler, keys, state.epoch)
    })
  end

  defp dispatch(%{configured: false} = state), do: state
  defp dispatch(%{max_size: 0} = state), do: state

  defp dispatch(state) do
    context = state.generation
    liquids = state.liquids

    fetch = &fetch_tile(&1, context, liquids)

    %{state | scheduler: LodScheduler.dispatch(state.scheduler, fetch, state.near_busy)}
  end

  defp fetch_tile(key, context, liquids) do
    snapshot = World.lod_edit_snapshot(key)
    cached = GenServer.call(__MODULE__, {:cache, key, snapshot.revision}, :infinity)

    %{
      revision: snapshot.revision,
      data: tile_data(cached, key, context, liquids, snapshot.chunks)
    }
  end

  defp tile_data({:ok, cached}, _key, _context, _liquids, _chunks), do: cached

  defp tile_data(:miss, key, context, liquids, chunks) do
    {:ok, data} = Native.generate_lod_tile(context.resource, key, liquids)

    Enum.reduce(Enum.chunk_every(chunks, 128), data, fn edits, data ->
      {:ok, changed} = Native.apply_lod_edits(key, data, edits, liquids)
      changed
    end)
  end
end
