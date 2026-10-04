# Flight and full-height streaming benchmark

Measured on 2026-10-03 at `bd82100e6b7e11f31bccf0ed5c81976457a4ba74` plus the benchmark scripts in this change. Windows, Intel Core Ultra 7 155H (16 cores, 22 logical processors), Rust 1.98.1, Elixir 1.20.4, OTP 29.1.1. Installed GPUs are RTX 4050 Laptop and Intel Arc; the active adapter and GPU execution time were not captured. Window request: 1280 × 720 logical pixels, ordinary presentation pacing. The reported problem occurred with `mise run dev`.

## The view contains 800 chunks

`ClientPort` uses radius 2: 5 × 5 horizontal columns. `ChunkStream.keys/3` includes every vertical layer within the game's -192..319 bounds, giving 32 layers per column and **800 resident chunks**, rather than 25 individual 16³ chunks. Residency is not a draw-call count: chunks with no mesh have no opaque GPU buffer.

A fresh initial view at the actual spawn contained 466 entirely empty chunks, 154 chunks with every voxel occupied, and 180 mixed chunks. These occupancy categories do not imply material opacity or visible-face count. Retrieving all 800 snapshots sequentially took 2,091.52 ms with the debug generator in one inventory run. The packed payload is 6,553,600 bytes; a single JSON/base64 representation of the same snapshots is 8,772,653 bytes before transport framing. The runtime splits these snapshots into batches of at most 16. This is an inventory observation, not a repeated throughput benchmark.

## Desktop measurements

`bench/flight_route.exs` uses the real game plugin and fresh seed-2026 data. It teleports above spawn, requests flight through authoritative Elixir input, hovers for 15 seconds to load terrain, records another 6 seconds of hover, flies forward for 12 seconds, then hovers for 12 seconds to drain work. Inputs are refreshed every 100 ms. It verifies that flight was accepted, movement crossed at least two chunk widths, and the final character remains in flight with available collision terrain.

Two lower-altitude runs per client profile alternate debug/perf/debug/perf, at spawn eye height +48 blocks (approximately y=61.175). Both client profiles use the **same debug NIF**. Three ceiling-altitude runs per client profile alternate order across rounds at y≈311 and use the same release NIF. No builds, tests or other benchmark workloads run during these captures.

Phase boundaries use complete lines already written by the buffered telemetry writer. Percentiles exclude at least one second of measured frame durations at both edges of each phase. Boundaries are approximate, rather than event-aligned timestamps. Movement uses wall-clock duration and the real fixed-step simulation, so travel varies with scheduler load: 107.28–113.76 blocks in the lower route and 102.24–108.96 blocks in the ceiling route. These are repeated comparable gameplay routes, not identical frame-by-frame geometry workloads.

| Lower-altitude client | Flight frame p95, ms | Flight frame p99, ms | Drain frame p95, ms | First fully meshed residency, seconds | Maximum dirty chunks during flight |
| --- | ---: | ---: | ---: | ---: | ---: |
| Debug, two runs | 27.61–33.43 | 30.93–34.09 | 40.37–54.07 | 8.48–10.07 | 622–632 |
| Perf, two runs | 17.39–17.64 | 17.87–18.49 | 17.37–17.38 | 8.22–8.29 | 579–582 |

The debug drain phases include individual 51.34–72.50 ms frames. Across the full lower route, summed worker CPU was 11.02–12.64 seconds in debug versus 0.880–0.885 seconds in perf. Submitted mesh vertex bytes were 13.06–15.02 MB in debug versus 15.97–16.13 MB in perf; different scheduling and travel affect remesh totals, so these are not geometry-reduction claims.

The ceiling route is less demanding visually: debug flight p95 was 18.06–32.25 ms and perf was 17.37–17.53 ms. First fully meshed residency remained 8.20–8.50 seconds in perf. This corroborates the loading backlog while showing why a sky-heavy route alone is insufficient to characterize the reported rendering problem.

All ten completed captures finish with 800 resident chunks, zero dirty chunks, zero mesh jobs in flight, zero queued outbound messages, and zero dropped telemetry samples. Stale jobs were rejected where present. Redraw duration includes presentation/swapchain waits. Worker CPU is summed across consumed results, not frame-thread time. Mesh upload telemetry excludes the blended buffer rewritten inside `Graphics::render`; low measured mesh-upload time does **not** exclude a transparency upload bottleneck. GPU execution, time to first useful terrain, and the exact share of transparency sorting versus presentation wait remain unmeasured.

## Region actor experiment

`bench/worldgen_parallel.exs` generates the same 128 chunks across four existing 4 × 4 region ownership areas, at layers 0 and 8. Each cold actor variant runs in a separate fresh engine with the same plugin, seed and keys. Serial retrieval uses `World.get_chunks/1`; the experiment issues one request per region concurrently with a maximum of four tasks. Three serial and three parallel engine instances alternate order within each native profile.

Each instance also warms the native generator and performs six alternating serial/concurrent rounds on identical keys, with the same 32-key native batch boundaries. The generator has no result cache. Packed chunk sizes and SHA-256 digests of sorted keyed output must match between actor retrieval and both direct-generation paths. All twelve actor instances and all native rounds produced the same digest: `2DCF90BF53289B8BDAAA652787EBACA33C8CD75E0AABFA18AA27E430DA04BE93`.

| Native profile | Cold serial actors, median ms | Cold concurrent actors, median ms | Direct serial generation, median ms | Direct concurrent generation, median ms |
| --- | ---: | ---: | ---: | ---: |
| Debug | 235.83 | 79.16 | 236.441 | 68.915 |
| Release | 25.91 | 9.32 | 23.552 | 7.372 |

Actor medians use three samples each; direct medians pool 36 samples per variant per profile. Debug cold samples were 227.12–240.13 ms serial and 63.38–79.46 ms concurrent; release samples were 25.39–26.21 ms serial and 7.88–9.52 ms concurrent. These demonstrate useful independent-region concurrency and native dirty-CPU scheduling on this machine. They do not establish a full-game FPS gain or cancellation/edit-order correctness for a future asynchronous streamer.

The benchmark records the actual loaded DLL hash. On Windows, compiling another Mix environment can copy its NIF into the shared source `priv` directory and then into a subsequent development build. **Mix environment alone does not prove the loaded native profile.** The verified hashes for this checkout were:

- Debug: `D362F34B7CA7303070986F876CF28DEF158B35903B63FD1C082B03A8E5D0C723`
- Release: `35E04EAC6060D37AD3B35A393D9F8380741F70F9ED8AD2546ED83C689C89EEFD`

## Ranked candidates

| Priority | Candidate and evidence | Ownership and validation |
| --- | --- | --- |
| 1 | **Separate mesh dispatch/completion from redraw and handle empty results cheaply.** `MeshPipeline` has two outstanding jobs, clears worker availability while consuming results during redraw, then dispatches replacements. At 60 Hz, jobs that complete between frames are limited to roughly 120 dispatches/s. Empty meshes still consume upload admission. Hundreds of dirty chunks persist even with sub-millisecond optimized meshing. | Native bounded worker/result queues; retain nearest useful work, immutable snapshots, monotonic generations, stale rejection, and unload behavior. Separate CPU work admission from GPU upload budgets. Prove faster time to useful terrain and lower dirty-queue age; adding workers alone leaves other limits. |
| 2 | **Profile and reduce unnecessary blended mesh rebuilds.** `BlendedMeshes::replace` marks the entire blended collection dirty even for an empty/opaque-only chunk whose blended entry did not change. `prepare` clones and globally sorts all blended quads and rewrites the GPU buffer whenever dirty or eye position changes. This occurs inside redraw and outside upload telemetry. Debug drain tails are high while replacement jobs arrive. The attribution is a source-grounded hypothesis, not an isolated timing result. | Native presentation. Instrument collection, sorting, staging/write, surface acquisition and submission separately, plus quad/byte counts. First avoid invalidation when blended content did not change; consider cached distance keys, reusable scratch storage and bounded worker sorting with camera/version checks. Preserve back-to-front order and alpha parity. |
| 3 | **Retrieve region batches asynchronously and concurrently.** `World.get_chunk_snapshots` waits for each region in turn, and `ClientPort.handle_info(:stream_batch)` blocks on retrieval, encoding and `Port.command`. The cold actor experiment supports about 2.8–3.0× throughput for four independent owners. | Elixir remains the streaming coordinator and authority; existing region actors own dense data and execute dirty native batches. Bound in-flight region requests, use stream generations to reject obsolete views, preserve revision ordering and edit responsiveness. Avoid tasks per block and unbounded fan-out. Measure mailbox delay and character input latency under load. |
| 4 | **Reuse column/feature calculations and introduce conservative empty-chunk summaries.** Native generation recomputes horizontal climate, height, biome and feature anchors for every vertical chunk. Full-height residency multiplies that work by 32. Air also crosses JSON/base64 transport and enters meshing; 58.25% of the initial view is empty. | Elixir defines generation policy; native batches reuse immutable horizontal calculations and packed occupancy summaries. Compare byte-for-byte output across columns, negative coordinates, carvers, features, islands and edits. An empty snapshot must still remove a previously visible mesh. Reducing visual residency must preserve flight visibility, seams and authoritative collision availability. |
| 5 | **Measure remaining graphics and transport costs.** Opaque meshes are all submitted without frustum culling; blended geometry may be uploaded repeatedly. Base64 decoding and invalidation occur on the event thread. Current timings cannot isolate GPU cost. | Add adapter/physical-size metadata, actual draw/vertex/alpha-byte counters and supported GPU timestamps. Evaluate culling and binary/background intake after phase attribution. Buffer pooling and GPU meshing need evidence before adoption. |

Region retention is another scaling concern: region actors keep generated chunks without eviction as the player explores. This pass did not measure long-flight memory growth. A future residency/cache policy must retain edits and ownership/recovery guarantees.

For immediate development, `mise run dev:perf` substantially reduces native client cost on these routes. It does not itself select an optimized engine NIF, and it leaves the mesh dispatch backlog intact. No runtime optimization is included in this benchmark change.

## Reproduction and artifacts

Build both clients and package the game before timed runs:

```powershell
mise exec -- cargo build --manifest-path native/Cargo.toml --locked -p wyram_client
mise exec -- cargo build --manifest-path native/Cargo.toml --profile perf --locked -p wyram_client
mise exec -- powershell -NoProfile -ExecutionPolicy Bypass -File scripts/pack-plugin.ps1 -Name wyram
```

For each route, choose a new directory, stage the same package, and select the client. Repeat alternating profiles while no builds/tests run:

```powershell
$runDir = Join-Path $PWD 'bench/results/flight-debug-01'
New-Item -ItemType Directory -Path "$runDir/data/plugins" -Force | Out-Null
Copy-Item dist/wyram.wyrplug "$runDir/data/plugins/wyram.wyrplug"
$env:MIX_ENV = 'dev'
$env:WYRAM_DATA_DIR = "$runDir/data"
$env:WYRAM_CLIENT = Join-Path $PWD 'native/target/debug/wyram_client.exe'
$env:WYRAM_CLIENT_METRICS = "$runDir/frames.jsonl"
$env:WYRAM_FLIGHT_PHASES = "$runDir/phases.json"
$env:WYRAM_FLIGHT_HEIGHT_OFFSET = '48' # unset for the ceiling route
$env:WYRAM_CONTROL_PORT = $null
mise exec -- mix run bench/flight_route.exs
mise run perf:report -- "$runDir/frames.jsonl" # whole capture; segment for phase comparisons
```

For the actor experiment, use a fresh staged game directory for **each** serial/parallel invocation. Disable the client and metrics, set `WYRAM_WORLDGEN_BENCH_MODE` to `serial` or `parallel` and `WYRAM_WORLDGEN_BENCH_OUTPUT` to a new result path, then run `mise exec -- mix run bench/worldgen_parallel.exs`. The script requires the real compiled worldgen plugin, not `test_terrain`.

To build native profiles use `MIX_ENV=dev`/`prod` with `mix compile --force` before timing. On this Windows checkout, explicitly select the intended compiled `native/target/{debug,release}/wyram_nif.dll` by copying it into both `apps/wyram_engine/priv/native/` and the selected `_build/{dev,prod}/lib/wyram_engine/priv/native/` before starting an engine; verify the reported hash. Preserve and restore previous DLLs if working in a shared checkout. Do not rebuild or copy DLLs during a running capture. Restore environment variables after the experiment.

Raw artifacts are ignored under `.tools/flight-pass/`: `route-{debug,perf}-{0,1,2}/`, `route-near-{debug,perf}-{0,1,2,3}/` (only the matching profile/index combinations exist), `actors-{debug,release}-{serial,parallel}-{0,1,2}/`, `inventory/result.log`, and `summary.json`. Exploratory and unverified-profile engine runs in other subdirectories are excluded. Generated captures, packages, DLLs and isolated world data are not committed.

Local validation passed: `mise run check`, `mise run test`, optimized client unit tests (58 passed, two manual benchmarks ignored), all ten recorded route phase checks, and byte parity in all twelve profile-verified actor experiments. These checks do not replace the workload-specific validation gates listed for future optimizations.
