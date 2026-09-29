Code.require_file(Path.join(__DIR__, "metrics.exs"))

alias Wyram.Bench.Metrics
alias Wyram.Engine.{PluginManager, World}

rounds = System.get_env("WYRAM_BENCH_ROUNDS", "5") |> String.to_integer()
true = rounds in 1..20
output = System.fetch_env!("WYRAM_BENCH_OUTPUT")

regions = fn offset ->
  for region <- 0..3 do
    for x <- 0..3, z <- 0..3, do: {offset + region * 4 + x, 3, z}
  end
end

run_chunks = fn offset, parallel? ->
  worker = fn chunks ->
    Enum.each(chunks, fn {cx, cy, cz} ->
      %{data: data} = World.get_chunk(cx, cy, cz)
      8192 = byte_size(data)
    end)
  end

  :erlang.garbage_collect()

  {microseconds, _} =
    :timer.tc(fn ->
      if parallel? do
        offset
        |> regions.()
        |> Enum.map(&Task.async(fn -> worker.(&1) end))
        |> Task.await_many(60_000)
      else
        offset |> regions.() |> Enum.each(worker)
      end
    end)

  microseconds / 1000
end

# Compile and populate the first region before sampling.
World.get_chunk(0, 3, 0)

chunk_samples =
  for round <- 0..(rounds - 1) do
    serial_offset = 1_000 + round * 128
    parallel_offset = serial_offset + 64

    if rem(round, 2) == 0 do
      {run_chunks.(serial_offset, false), run_chunks.(parallel_offset, true)}
    else
      parallel = run_chunks.(parallel_offset, true)
      serial = run_chunks.(serial_offset, false)
      {serial, parallel}
    end
  end

World.get_block(0, 60, 0)

read_samples =
  for _ <- 1..30 do
    {microseconds, _} =
      :timer.tc(fn -> Enum.each(1..1_000, fn _ -> World.get_block(0, 60, 0) end) end)

    microseconds / 1_000_000
  end

block_id = Map.fetch!(PluginManager.blocks(), "test_terrain:violet")

edit_samples =
  for index <- 1..30 do
    id = if rem(index, 2) == 0, do: 0, else: block_id
    {microseconds, {:ok, _revision}} = :timer.tc(fn -> World.set_block(20, 80, 20, id) end)
    microseconds / 1000
  end

serial = chunk_samples |> Enum.map(&elem(&1, 0)) |> Metrics.summary()
parallel = chunk_samples |> Enum.map(&elem(&1, 1)) |> Metrics.summary()
safe_directory = File.cwd!() |> String.replace("\\", "/")

git = fn args ->
  {output, 0} = System.cmd("git", ["-c", "safe.directory=#{safe_directory}" | args])
  String.trim(output)
end

result = %{
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
  workload: %{
    rounds: rounds,
    chunks_per_round: 64,
    read_samples: 30,
    reads_per_sample: 1_000,
    edit_samples: 30
  },
  metrics: %{
    serial_chunks: Map.put(serial, :chunks_per_second, 64_000 / serial.mean_ms),
    parallel_chunks: Map.put(parallel, :chunks_per_second, 64_000 / parallel.mean_ms),
    warm_block_read: Metrics.summary(read_samples),
    durable_block_edit: Metrics.summary(edit_samples)
  }
}

File.mkdir_p!(Path.dirname(output))
File.write!(output, Jason.encode!(result))
IO.puts("benchmark: #{output}")

IO.puts(
  "chunk p50: serial #{Float.round(serial.p50_ms, 2)} ms, parallel #{Float.round(parallel.p50_ms, 2)} ms"
)
