alias Wyram.Engine.{Native, PluginManager, World, WorldGenerator}
alias Wyram.Engine.Scenery.Plan

rounds = System.fetch_env!("WYRAM_GENERATION_BENCH_ROUNDS") |> String.to_integer()
true = rounds in 1..10
generation = World.generation()
{:ok, plan} = Plan.new({672, 300, 672}, generation.bounds, PluginManager.scenery())
tile_keys = Enum.map(plan.order, &{&1.position, &1.level})
{low, high} = generation.bounds
chunk_keys = for x <- 38..46, z <- 38..46, y <- div(low, 16)..div(high, 16), do: {x, y, z}

scenery = fn ->
  tile_keys
  |> Enum.chunk_every(2)
  |> Enum.flat_map(fn batch ->
    {:ok, tiles} = Native.generate_scenic_tiles(generation.resource, batch)
    Enum.zip(batch, tiles)
  end)
end

measure = fn work ->
  for _ <- 1..rounds do
    {us, result} = :timer.tc(work)

    %{
      milliseconds: us / 1000,
      bytes: Enum.reduce(result, 0, fn {_, data}, sum -> sum + byte_size(data) end),
      sha256:
        result
        |> :erlang.term_to_binary([:deterministic])
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)
    }
  end
end

path = Native.library_path()
{profile, opt_level} = Native.build_info()

native_sha256 =
  File.read!(path) |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

expected = System.fetch_env!("WYRAM_NATIVE_PROFILE")
true = profile == if(expected == "dev", do: "debug", else: "perf")
true = opt_level == if(expected == "dev", do: "0", else: "3")
true = native_sha256 == System.fetch_env!("WYRAM_NATIVE_BUILD_HASH")
safe_directory = File.cwd!() |> String.replace("\\", "/")

git = fn args ->
  {output, 0} = System.cmd("git", ["-c", "safe.directory=#{safe_directory}" | args])
  String.trim(output)
end

report = %{
  schema: 1,
  timestamp_utc: DateTime.utc_now() |> DateTime.to_iso8601(),
  commit: git.(["rev-parse", "HEAD"]),
  dirty_worktree: git.(["status", "--porcelain"]) != "",
  runtime: %{
    os: inspect(:os.type()),
    otp: System.otp_release(),
    elixir: System.version(),
    schedulers: System.schedulers_online()
  },
  plugin_versions: PluginManager.plugin_versions(),
  seed: generation.seed,
  tile_count: length(tile_keys),
  chunk_count: length(chunk_keys),
  generator_identity: generation.identity,
  native_library: path,
  native_profile: profile,
  opt_level: opt_level,
  native_sha256: native_sha256,
  scenery: measure.(scenery),
  chunks: measure.(fn -> WorldGenerator.chunks(generation, chunk_keys) end)
}

output = System.fetch_env!("WYRAM_GENERATION_BENCH_OUTPUT")
File.mkdir_p!(Path.dirname(output))
File.write!(output, Jason.encode!(report, pretty: true), [:exclusive])
IO.puts(Jason.encode!(report))
