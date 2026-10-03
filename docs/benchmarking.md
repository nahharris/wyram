# Benchmarks

The [2026-10-03 flight investigation](flight-performance.md) measures real game flight, full-height residency, debug/perf client differences, and bounded concurrency across existing region actors. Reproduce the desktop route with `bench/flight_route.exs` and the byte-parity-checked generation experiment with `bench/worldgen_parallel.exs`. The report ranks follow-up candidates and distinguishes measured bottlenecks from hypotheses.

`mise run bench:outbound` compares synchronous sends with background writer admission using the same 64 ordered edit packets and a receiver that delays each flush by 2 ms. Six rounds alternate order, assert packet count/order, and record raw admission latencies and complete drain time under `bench/results/`. Use `-- -Profile dev` for debug or `-- -Output path.jsonl` for a chosen new output. This measures producer responsiveness under controlled backpressure, not faster engine delivery or ordinary FPS. See [outbound design](outbound-ipc.md) for capacity and failure policy. Frame captures now include outbound queue depth, sent/coalesced counters and lifetime queue/write maxima; `perf:report` prints these separately from frame percentiles.

`mise run bench:mesh` compares the retained simple mesher and greedy mesher on identical empty, solid, terrain and checkerboard chunks. Both implementations run in the same optimized profile, with warmup and 30 alternating-order rounds of 10 iterations. Results contain raw milliseconds per mesh, vertex counts, compiled profile/optimization level, commit and dirty-worktree state. Run `mise run bench:mesh -- -Profile dev` for a separate debug-profile comparison. The benchmark asserts oriented unit-face coverage and color parity before timing. It is an isolated CPU/geometry benchmark, not GPU execution time or full-game throughput. Generated outputs stay under `bench/results/`.

Use `mise run dev:perf` or `mise run dev:agent:perf` for optimized native development with symbols. They share plugin staging/cleanup with debug development and select `native/target/perf/wyram_client.exe`. Ordinary `dev` selects the debug client. An explicit `WYRAM_CLIENT` override remains authoritative for both commands; unset it to use the selected built client. Frame samples record `build_profile` and `opt_level` compiled into the executable; release packaging still uses Cargo's release profile.

For a repeatable desktop stress route, `bench/renderer_route.exs` performs eight teleports at fixed 800 ms intervals after waiting for the client and warming up for two seconds. It shuts down the isolated engine afterward. Run it with `mise exec -- mix run bench/renderer_route.exs`, setting `WYRAM_DATA_DIR` to a fresh directory containing `plugins/wyram.wyrplug`, `WYRAM_CLIENT` to the chosen executable, and `WYRAM_CLIENT_METRICS` to a new capture path. Use the same plugin, seed, window size, route, profile and machine for baseline/candidate captures. Repeat with alternating order while no builds/tests are running. This stress route is not a walking route or a substitute for GPU timing; issue #8 remains open.

For renderer frame captures, set `WYRAM_CLIENT_METRICS` to a new JSONL path before `mise dev` or `mise run dev:agent`. For example, in Nushell:

```nu
$env.WYRAM_CLIENT_METRICS = ($env.PWD | path join 'bench' 'results' 'walk-01.jsonl')
mise run dev:agent
```

In PowerShell, use `$env:WYRAM_CLIENT_METRICS = "$PWD\bench\results\walk-01.jsonl"`. Close the game window to flush the capture. Run `mise run perf:report -- bench/results/walk-01.jsonl` to print p50/p95/p99/max values. Files must be new; an existing file is preserved and capture is disabled with a warning. Unset the variable to disable capture.

Frame records contain frame intervals, CPU redraw duration, accumulated chunk decoding time, worker meshing time for results consumed that frame, CPU buffer creation/upload submission time, uploaded bytes/meshes, discarded stale results, resident/dirty chunks, jobs in flight, and cumulative dropped samples. Capture uses a bounded background writer; a full queue drops samples instead of blocking rendering. GPU execution time is not measured. Worker times are summed across completed results, not frame-thread cost. Redraw duration can include waiting for the swapchain. Frame intervals include event processing and presentation waits. Capture includes startup, so keep startup and steady movement samples separate when comparing runs.

The renderer uses two mesh workers with at most one outstanding job each. Snapshots share immutable chunk storage and include six face neighbors. Changes invalidate the chunk and its loaded neighbors; results must match a monotonic mesh generation, including neighbor and palette changes. Old meshes remain visible until replacement; unloaded chunks lose their GPU mesh immediately. Nearest dirty chunks are scheduled first. Upload admission is capped at two meshes, 2 MiB, and a 1 ms elapsed budget per frame. One indivisible mesh is allowed even if oversized to prevent starvation; these are admission limits, not a hard bound on driver-call latency. CPU meshing never runs on the render thread.

Deferred work is tracked in GitHub:

- [GPU buffer reuse and large uploads](https://github.com/nahharris/wyram/issues/2)
- [Batched binary transport and background decoding](https://github.com/nahharris/wyram/issues/3)
- [Asynchronous Elixir streaming](https://github.com/nahharris/wyram/issues/4)
- [GPU meshing experiment](https://github.com/nahharris/wyram/issues/7)
- [Matched routes and GPU timing](https://github.com/nahharris/wyram/issues/8)

Run `mise run bench` after setup. The task starts a fresh headless world with the test terrain plugin, measures the workloads, and writes a JSON result under the ignored `bench/results/` directory. For a shorter run or a chosen output path, call `scripts/bench.ps1 -Rounds 2 -Output C:\path\result.json` through `mise exec -- powershell -NoProfile -ExecutionPolicy Bypass -File ...`.

Compare two results with `mise exec -- mix run --no-start bench/compare.exs baseline.json candidate.json`. The comparator prints p50 latency changes and warns if the workload definitions differ. Results record the commit, whether the worktree was dirty, UTC time, OTP/Elixir versions, OS, scheduler count, plugin versions, workload size, raw samples, p50/p95/mean latencies, and chunk throughput. Save representative result files elsewhere if you want a long-term baseline; generated results are intentionally ignored by Git.

Each round generates 64 new chunks sequentially in four regions and another 64 in parallel across those regions. Order alternates by round to reduce ordering bias. The suite also times warm block reads in batches of 1,000 to overcome Windows timer granularity, and 30 durable block edits. It isolates game data for each run. These are engine measurements, not renderer frame times or a claim that the full game is faster by the parallel-chunk ratio. Compare runs on the same machine and toolchain under similar load; CI checks the result format but does not impose performance thresholds.
