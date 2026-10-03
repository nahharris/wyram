# Same native input/output on both paths; actors are measured separately by
# mode in fresh engine instances. Never apply this experiment to ClientPort.
Code.require_file(Path.join(__DIR__, "metrics.exs"))
alias Wyram.Bench.Metrics
alias Wyram.Engine.{PluginManager, World, WorldGenerator}

output = System.fetch_env!("WYRAM_WORLDGEN_BENCH_OUTPUT")
false = File.exists?(output)
context = World.generation()
%{resource: resource} = context
true = not is_nil(resource)
mode = System.get_env("WYRAM_WORLDGEN_BENCH_MODE", "serial")
true = mode in ["serial", "parallel"]
keys = for x <- 0..7, z <- 0..7, y <- [0, 8], do: {x, y, z}
groups = keys |> Enum.group_by(fn {x, _, z} -> {div(x, 4), div(z, 4)} end) |> Map.values()

digest = fn chunks ->
  chunks
  |> Enum.sort()
  |> :erlang.term_to_binary()
  |> then(&:crypto.hash(:sha256, &1))
  |> Base.encode16()
end

parallel = fn groups, worker ->
  groups
  |> Task.async_stream(worker, max_concurrency: 4, timeout: 60_000)
  |> Enum.flat_map(fn {:ok, chunks} -> chunks end)
end

timed = fn worker ->
  {us, chunks} = :timer.tc(worker)
  Enum.each(chunks, fn {_key, data} -> 8192 = byte_size(data) end)
  {us / 1000, digest.(chunks)}
end

# Identical cold actor workload across separate serial/parallel invocations.
fetch = fn owned -> World.get_chunks(owned) end

{actor_ms, actor_digest} =
  timed.(fn ->
    if mode == "parallel", do: parallel.(groups, fetch), else: fetch.(keys)
  end)

# Direct generator has no cache. Every round generates exactly the same keys.
generate = fn owned -> WorldGenerator.chunks(context, owned) end
expected = digest.(generate.(keys))
true = actor_digest == expected

samples =
  for round <- 0..5 do
    serial = fn -> timed.(fn -> Enum.flat_map(groups, generate) end) end
    concurrent = fn -> timed.(fn -> parallel.(groups, generate) end) end

    {{s, s_hash}, {p, p_hash}} =
      if rem(round, 2) == 0 do
        {serial.(), concurrent.()}
      else
        p = concurrent.()
        {serial.(), p}
      end

    true = s_hash == expected and p_hash == expected
    {s, p}
  end

nif_hash =
  Path.join(to_string(:code.priv_dir(:wyram_engine)), "native/wyram_nif.dll")
  |> File.read!()
  |> then(&:crypto.hash(:sha256, &1))
  |> Base.encode16()

nif_profile =
  Enum.find(["debug", "release"], "unknown", fn profile ->
    path = "native/target/#{profile}/wyram_nif.dll"

    File.exists?(path) and
      File.read!(path) |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16() == nif_hash
  end)

result = %{
  schema: 1,
  timestamp_utc: DateTime.utc_now(),
  commit: System.cmd("git", ["rev-parse", "HEAD"]) |> elem(0) |> String.trim(),
  dirty_worktree: System.cmd("git", ["status", "--porcelain"]) |> elem(0) != "",
  mix_env: Mix.env(),
  nif_profile: nif_profile,
  nif_sha256: nif_hash,
  runtime: %{
    otp: System.otp_release(),
    elixir: System.version(),
    schedulers: System.schedulers_online()
  },
  plugin_versions: PluginManager.plugin_versions(),
  workload: %{
    keys: keys |> Enum.map(&Tuple.to_list/1),
    groups: length(groups),
    rounds: 6,
    concurrency: 4
  },
  digest: expected,
  actor_mode: mode,
  cold_actor_ms: actor_ms,
  serial_native: samples |> Enum.map(&elem(&1, 0)) |> Metrics.summary(),
  parallel_native: samples |> Enum.map(&elem(&1, 1)) |> Metrics.summary()
}

File.mkdir_p!(Path.dirname(output))
File.write!(output, Jason.encode!(result))
IO.puts("worldgen benchmark: #{output}, cold #{mode} actors #{Float.round(actor_ms, 2)} ms")
