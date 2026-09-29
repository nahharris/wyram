[baseline_path, candidate_path] = System.argv()
baseline = baseline_path |> File.read!() |> Jason.decode!()
candidate = candidate_path |> File.read!() |> Jason.decode!()
true = baseline["schema"] == 1 and candidate["schema"] == 1
if baseline["workload"] != candidate["workload"], do: IO.puts("warning: workloads differ")

IO.puts("baseline: #{baseline["commit"]} (#{baseline["timestamp_utc"]})")
IO.puts("candidate: #{candidate["commit"]} (#{candidate["timestamp_utc"]})")

for metric <- ["serial_chunks", "parallel_chunks", "warm_block_read", "durable_block_edit"] do
  old = baseline["metrics"][metric]["p50_ms"]
  new = candidate["metrics"][metric]["p50_ms"]
  change = if old > 0, do: "#{Float.round((new / old - 1) * 100, 1)}%", else: "n/a"

  IO.puts(
    "#{metric}: #{Float.round(old * 1.0, 3)} -> #{Float.round(new * 1.0, 3)} ms (#{change})"
  )
end
