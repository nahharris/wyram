defmodule Wyram.Engine.LodStreamerIntegrationTest do
  use ExUnit.Case, async: false

  alias Wyram.Block.Ref

  alias Wyram.Engine.{
    LodCache,
    LodPlanner,
    LodScheduler,
    LodStreamer,
    LodWorkers,
    World,
    WorldGenerator
  }

  alias Wyram.WorldGen.{Biome, Config}

  @wait_ms 30_000

  setup do
    original = :sys.get_state(LodStreamer)
    assert original.scheduler.tasks == %{}

    on_exit(fn ->
      drain_streamer()
      :sys.replace_state(LodStreamer, fn _state -> original end)
    end)

    :ok
  end

  test "real generation pauses, fills bounded transport, acknowledges empty tiles, and retires stale work" do
    {:ok, generation} = fixture_generation()
    bounds = {0, 31}
    generation = %{generation | bounds: bounds}
    initial = :sys.get_state(LodStreamer)
    original_region_count = Registry.count(Wyram.Engine.RegionRegistry)

    initial = %{
      initial
      | overrides: %{generation: nil, meshing: nil},
        dirty: :erlang.system_info(:dirty_cpu_schedulers_online),
        workers: nil,
        generation: generation,
        max_size: 2,
        radius: 1,
        liquids: [7],
        scheduler: LodScheduler.new(4),
        cache: LodCache.new(),
        center: nil,
        epoch: nil,
        near_busy: true,
        configured: false,
        serial: 0,
        completed: 0,
        rejected: 0
    }

    :sys.replace_state(LodStreamer, fn _state -> initial end)

    center = {256, 2, 256}
    keys = LodPlanner.plan(center, bounds, 1, 2)
    assert keys != []

    Enum.each(keys, fn key ->
      assert %{revision: 0, chunks: []} = World.lod_edit_snapshot(key)
    end)

    assert Registry.count(Wyram.Engine.RegionRegistry) == original_region_count

    LodStreamer.configure(22)
    LodStreamer.view(center, 77, true)
    configured = await_state(&(&1.configured and &1.epoch == 77 and &1.center == center))
    assert configured.scheduler.generation_workers == configured.workers.generation
    assert configured.scheduler.pending == keys
    assert configured.scheduler.tasks == %{}
    assert configured.scheduler.outstanding == %{}
    assert configured.workers == LodWorkers.resolve(22, initial.dirty, initial.overrides)
    assert configured.max_size == 2
    assert configured.radius == 1
    assert configured.cache.limit == 256 * 1024 * 1024

    Process.sleep(40)
    paused = :sys.get_state(LodStreamer)
    assert paused.scheduler.tasks == %{}
    assert paused.scheduler.pending == keys

    LodStreamer.near_busy(false)

    generated =
      await_state(fn state ->
        state.scheduler.pending == [] and state.scheduler.tasks == %{} and
          map_size(state.scheduler.outstanding) == length(keys)
      end)

    assert generated.completed == length(keys)

    assert MapSet.new(Enum.map(Map.keys(generated.scheduler.outstanding), &elem(&1, 1))) ==
             MapSet.new(keys)

    Enum.each(generated.scheduler.outstanding, fn {{epoch, key, revision}, byte_count} ->
      assert epoch == 77
      assert byte_count in 4..1_048_576
      assert {:ok, payload} = LodCache.get(generated.cache, {key, revision}) |> elem(1)
      assert byte_size(payload) == byte_count
      assert <<"LT01", _::binary>> = payload
      LodStreamer.acknowledge(epoch, key, revision, true)
    end)

    acknowledged =
      await_state(
        &(map_size(&1.scheduler.outstanding) == 0 and
            MapSet.size(&1.scheduler.published) == length(keys))
      )

    assert acknowledged.scheduler.published == MapSet.new(keys)
    assert Registry.count(Wyram.Engine.RegionRegistry) == original_region_count

    # A one-run LT01 tile is a valid all-air summary. Republish it through the
    # real cache-hit path to model a client mesh that completes with no geometry.
    empty_key = hd(keys)
    empty_tile = <<"LT01", 39_304::little-16, 0::80>>
    assert byte_size(empty_tile) == 16
    {cache, :ok} = LodCache.put(acknowledged.cache, {empty_key, 0}, empty_tile)
    :sys.replace_state(LodStreamer, fn state -> %{state | cache: cache} end)

    LodStreamer.request(77, [empty_key])

    empty_result =
      await_state(fn state ->
        Enum.any?(state.scheduler.outstanding, fn {{epoch, key, _revision}, _bytes} ->
          epoch == 77 and key == empty_key
        end)
      end)

    {old_id, 16} =
      Enum.find(empty_result.scheduler.outstanding, fn {{epoch, key, _revision}, _bytes} ->
        epoch == 77 and key == empty_key
      end)

    assert {:ok, ^empty_tile} = LodCache.get(empty_result.cache, {empty_key, 0}) |> elem(1)

    workers = empty_result.workers
    LodStreamer.configure(4)
    LodStreamer.status()
    configured_once = :sys.get_state(LodStreamer)
    assert configured_once.workers == workers
    assert configured_once.max_size == 2
    assert configured_once.radius == 1
    assert configured_once.cache.limit == 256 * 1024 * 1024

    next_center = {512, 2, 512}
    LodStreamer.view(next_center, 78, true)
    teleported = await_state(&(&1.epoch == 78 and &1.center == next_center))
    refute MapSet.member?(teleported.scheduler.published, empty_key)
    assert Map.has_key?(teleported.scheduler.outstanding, old_id)

    {77, old_key, old_revision} = old_id
    LodStreamer.acknowledge(77, old_key, old_revision, true)
    after_old_ack = await_state(&(not Map.has_key?(&1.scheduler.outstanding, old_id)))
    refute MapSet.member?(after_old_ack.scheduler.published, old_key)

    # Hold real generation workers in World’s read call, teleport, then verify
    # the obsolete worker remains charged against scheduler capacity until it exits.
    :ok = :sys.suspend(World)
    final_center = {768, 2, 768}

    try do
      LodStreamer.near_busy(false)
      blocked = await_state(&(map_size(&1.scheduler.tasks) > 0))
      old_refs = Map.keys(blocked.scheduler.tasks)
      assert length(old_refs) <= 8

      assert Enum.all?(blocked.scheduler.tasks, fn {_ref, job} -> Process.alive?(job.task.pid) end)

      LodStreamer.view(final_center, 79, true)

      obsolete =
        await_state(fn state ->
          state.epoch == 79 and state.center == final_center and
            Enum.all?(old_refs, fn ref -> state.scheduler.tasks[ref].obsolete? end)
        end)

      assert map_size(obsolete.scheduler.tasks) == length(old_refs)
      assert map_size(obsolete.scheduler.tasks) + map_size(obsolete.scheduler.outstanding) <= 8
    after
      :sys.resume(World)
    end

    drained = await_state(&(&1.scheduler.tasks == %{}))
    assert drained.scheduler.outstanding == %{}
    assert drained.scheduler.pending == LodPlanner.plan(final_center, bounds, 1, 2)
    assert Registry.count(Wyram.Engine.RegionRegistry) == original_region_count
  end

  defp fixture_generation do
    solid = Ref.new!("lod_fixture", "solid")
    liquid = Ref.new!("lod_fixture", "liquid")

    biome =
      Biome.new!(%{id: "lod_fixture", surface: solid, soil: solid, rock: solid, water: liquid})

    # The public generator contract requires at least 64 blocks. The planner
    # fixture narrows its logical vertical plan to 32 blocks after compilation.
    config =
      Config.new!(%{
        min_y: 0,
        height: 64,
        sea_level: 32,
        relief: 8,
        carvers: [],
        islands: nil,
        biomes: [biome]
      })

    WorldGenerator.compile(config, 2026, [], %{
      "lod_fixture:solid" => 17,
      "lod_fixture:liquid" => 7
    })
  end

  defp await_state(predicate, timeout_ms \\ @wait_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_state(predicate, deadline)
  end

  defp do_await_state(predicate, deadline) do
    state = :sys.get_state(LodStreamer)
    assert map_size(state.scheduler.tasks) + map_size(state.scheduler.outstanding) <= 8

    if predicate.(state) do
      state
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk(
          "LOD streamer did not reach the expected integration state: #{inspect(LodStreamer.status())}"
        )
      else
        Process.sleep(10)
        do_await_state(predicate, deadline)
      end
    end
  end

  defp drain_streamer do
    LodStreamer.near_busy(true)
    LodStreamer.status()
    drain_streamer_until(System.monotonic_time(:millisecond) + @wait_ms)
  end

  defp drain_streamer_until(deadline) do
    state = :sys.get_state(LodStreamer)

    Enum.each(state.scheduler.outstanding, fn {{epoch, key, revision}, _bytes} ->
      LodStreamer.acknowledge(epoch, key, revision, true)
    end)

    LodStreamer.status()
    state = :sys.get_state(LodStreamer)

    if state.scheduler.tasks == %{} and state.scheduler.outstanding == %{} do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        raise "LOD streamer integration cleanup timed out"
      else
        Process.sleep(10)
        drain_streamer_until(deadline)
      end
    end
  end
end
