alias Wyram.Engine.{Native, PluginManager, World}
alias Wyram.Engine.Scenery.{Fetch, Plan, Store}

rounds = System.fetch_env!("WYRAM_GENERATION_BENCH_ROUNDS") |> String.to_integer()
true = rounds in 1..10
model = World.scenery_read_model()
config = PluginManager.scenery()
{:ok, plan} = Plan.new({672, 300, 672}, model.generation.bounds, config)

fetch = fn source ->
  Enum.flat_map(Enum.chunk_every(plan.order, 2), fn keys ->
    {:ok, bytes} = Fetch.run(source, keys)
    bytes
  end)
end

measure = fn source ->
  {us, bytes} = :timer.tc(fn -> fetch.(source) end)

  %{
    milliseconds: us / 1000,
    bytes: Enum.reduce(bytes, 0, &(byte_size(&1) + &2)),
    sha256:
      bytes
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
  }
end

samples =
  for round <- 1..rounds do
    baseline = measure.(model)
    directory = Path.join(model.cache_directory, "benchmark-#{round}")
    options = [name: nil, directory: directory]
    {:ok, cold_owner} = Store.start_link(options)
    cold = measure.(Map.put(model, :cache, cold_owner))
    cold_stats = Store.stats(cold_owner)
    true = cold_stats.enabled and cold_stats.hits == 0 and cold_stats.misses == length(plan.order)
    GenServer.stop(cold_owner)
    {:ok, restored_owner} = Store.start_link(options)

    try do
      warm = measure.(Map.put(model, :cache, restored_owner))
      warm_stats = Store.stats(restored_owner)

      true =
        warm_stats.enabled and warm_stats.hits == length(plan.order) and warm_stats.misses == 0

      true = baseline.sha256 == cold.sha256 and cold.sha256 == warm.sha256
      true = baseline.bytes == cold.bytes and cold.bytes == warm.bytes

      %{
        baseline: baseline,
        cold: cold,
        warm: warm,
        cold_store: cold_stats,
        warm_store: warm_stats
      }
    after
      GenServer.stop(restored_owner)
    end
  end

library = Native.library_path()
{profile, opt_level} = Native.build_info()
hash = File.read!(library) |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
expected = System.fetch_env!("WYRAM_NATIVE_PROFILE")
true = profile == if(expected == "dev", do: "debug", else: "perf")
true = opt_level == if(expected == "dev", do: "0", else: "3")
true = hash == System.fetch_env!("WYRAM_NATIVE_BUILD_HASH")
safe_directory = File.cwd!() |> String.replace("\\", "/")

git = fn args ->
  {output, 0} = System.cmd("git", ["-c", "safe.directory=#{safe_directory}" | args])
  String.trim(output)
end

report = %{
  schema: 1,
  workload: "scenery_fetch_cache",
  timestamp_utc: DateTime.utc_now() |> DateTime.to_iso8601(),
  commit: git.(["rev-parse", "HEAD"]),
  dirty_worktree: git.(["status", "--porcelain"]) != "",
  runtime: %{os: inspect(:os.type()), otp: System.otp_release(), elixir: System.version()},
  plugin_versions: PluginManager.plugin_versions(),
  seed: model.generation.seed,
  generator_identity: model.generation.identity,
  tile_count: length(plan.order),
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
