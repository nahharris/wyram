alias Wyram.Engine.{Native, PluginManager, Scenery, World, WorldGenerator}
alias Wyram.Engine.Scenery.Fetch

defmodule SceneryEditBenchmark do
  def receive_view(service, epoch \\ nil, tiles \\ %{}, fetched \\ 0) do
    receive do
      {:scenery_plan, next, _, plan, _} ->
        receive_tiles(service, next, length(plan.order), tiles, fetched)

      {:benchmark_fetch, _, keys} ->
        receive_view(service, epoch, tiles, fetched + length(keys))
    after
      60_000 -> raise "scenery plan timed out"
    end
  end

  defp receive_tiles(service, epoch, count, tiles, fetched) when map_size(tiles) == count do
    state = :sys.get_state(service)
    true = map_size(state.loader.tasks) == 0
    %{epoch: epoch, tiles: tiles, fetched: fetched}
  end

  defp receive_tiles(service, epoch, count, tiles, fetched) do
    receive do
      {:scenery_tiles, ^epoch, token, entries} ->
        Scenery.acknowledge(service, epoch, token)
        receive_tiles(service, epoch, count, Map.merge(tiles, Map.new(entries)), fetched)

      {:benchmark_fetch, _, keys} ->
        receive_tiles(service, epoch, count, tiles, fetched + length(keys))
    after
      60_000 -> raise "scenery delivery timed out"
    end
  end

  def signature(tiles) do
    tiles
    |> Enum.sort()
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end

rounds = System.fetch_env!("WYRAM_GENERATION_BENCH_ROUNDS") |> String.to_integer()
true = rounds in 1..10
owner = self()
{:ok, supervisor} = Task.Supervisor.start_link()

fetch = fn model, keys ->
  send(owner, {:benchmark_fetch, model.stamp, keys})
  Fetch.run(model, keys)
end

{:ok, service} =
  Scenery.start_link(
    name: nil,
    cache: nil,
    supervisor: supervisor,
    fetch: fetch,
    config: PluginManager.scenery()
  )

Scenery.view(service, self(), {672, 300, 672})
initial = SceneryEditBenchmark.receive_view(service)
model = World.scenery_read_model()
true = initial.fetched == map_size(initial.tiles)
air = :binary.copy(<<0>>, 8192)

tile =
  initial.tiles
  |> Enum.reject(fn {_, <<"WSL", _, _, mode, _::binary>>} -> mode == 0 end)
  |> Enum.min_by(fn {key, _} -> {key.level, key.position} end)
  |> elem(0)

{:ok, chunks} =
  Native.scenic_sample_chunks(model.generation.resource, {tile.position, tile.level})

{changed_chunk, original} =
  Enum.find_value(chunks, fn chunk ->
    [{^chunk, bytes}] = WorldGenerator.chunks(model.generation, [chunk])
    if bytes != air, do: {chunk, bytes}
  end)

initial_hash = SceneryEditBenchmark.signature(initial.tiles)

samples =
  for round <- 1..rounds do
    data = if rem(round, 2) == 1, do: air, else: original
    :ok = :sys.suspend(service)

    try do
      # Save I/O is excluded. The suspended service resumes only after the real
      # World owner publishes the durable snapshot and its change notification.
      :ok = GenServer.call(World, {:persist_edit, changed_chunk, %{data: data, revision: round}})

      {us, result} =
        :timer.tc(fn ->
          :ok = :sys.resume(service)
          SceneryEditBenchmark.receive_view(service)
        end)

      current = World.scenery_read_model()
      state = :sys.get_state(service)
      true = map_size(result.tiles) == map_size(initial.tiles)
      true = length(Task.Supervisor.children(supervisor)) == 0
      true = state.loader.cache == result.tiles

      reference =
        state.plan.order
        |> Enum.chunk_every(2)
        |> Enum.flat_map(fn keys ->
          {:ok, bytes} = Fetch.run(current, keys)
          Enum.zip(keys, bytes)
        end)
        |> Map.new()

      true = result.tiles == reference
      hash = SceneryEditBenchmark.signature(result.tiles)
      true = if rem(round, 2) == 1, do: hash != initial_hash, else: hash == initial_hash

      %{
        milliseconds: us / 1000,
        fetched_tiles: result.fetched,
        delivered_tiles: map_size(result.tiles),
        bytes: Enum.reduce(result.tiles, 0, fn {_, bytes}, sum -> sum + byte_size(bytes) end),
        stamp: current.stamp,
        epoch: result.epoch,
        sha256: hash,
        exact_reference_match: true
      }
    after
      :sys.resume(service)
    end
  end

library = Native.library_path()
{profile, opt_level} = Native.build_info()
hash = File.read!(library) |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
true = profile == "perf" and opt_level == "3"
true = hash == System.fetch_env!("WYRAM_NATIVE_BUILD_HASH")

report = %{
  schema: 1,
  workload: "scenery_durable_edit",
  timestamp_utc: DateTime.utc_now() |> DateTime.to_iso8601(),
  seed: model.generation.seed,
  generator_identity: model.generation.identity,
  tile_count: map_size(initial.tiles),
  changed_chunk: Tuple.to_list(changed_chunk),
  native_profile: profile,
  opt_level: opt_level,
  native_library: library,
  native_sha256: hash,
  samples: samples
}

output = System.fetch_env!("WYRAM_GENERATION_BENCH_OUTPUT")
File.mkdir_p!(Path.dirname(output))
File.write!(output, Jason.encode!(report, pretty: true), [:exclusive])
IO.puts(Jason.encode!(report))
