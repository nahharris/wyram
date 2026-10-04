# Greedy meshing and optimized development measurements

Measured on 2026-09-29 on Windows with an Intel Core Ultra 7 155H (16 cores, 22 logical processors), Rust 1.98.1, Elixir 1.20.4 and OTP 29.1.1. The machine has NVIDIA RTX 4050 Laptop and Intel Arc graphics; these captures do not identify adapter execution times. Baseline renderer: commit `7de44e9`, preserved debug executable. Candidate: this pass's greedy mesher. Window size: 1280 by 720; observed frame intervals are approximately 60 Hz. Measurements are local observations, not CI timing thresholds.

## Matched CPU measurements

`mise run bench:mesh` warms both implementations, alternates order for 30 rounds, and times 10 meshes per round. Both run in the same `perf` profile, optimized with symbols. The simple implementation is retained as a test oracle. Surface coverage and colors are checked before timing. Reported values are median milliseconds per isolated mesh; compilation and fixture generation are excluded.

| Workload | Simple ms | Greedy ms | Simple vertices | Greedy vertices |
| --- | ---: | ---: | ---: | ---: |
| Empty | 0.01775 | 0.00191 | 0 | 0 |
| Solid isolated chunk | 0.71291 | 0.09869 | 9,216 | 36 |
| Procedural terrain | 0.55894 | 0.11891 | 10,404 | 3,834 |
| Checkerboard | 1.24220 | 1.13865 | 73,728 | 73,728 |

**VERIFIED:** less CPU work and geometry on the measured terrain workload: approximately 79% lower worker latency and 63% fewer vertices. Repeated earlier same-profile runs also showed terrain improvements (0.519 to 0.144 ms and 0.579 to 0.146 ms); individual timings vary with machine load. These are algorithm comparisons, not debug-versus-release comparisons.

The debug-profile checkerboard case regressed from 5.672 to 7.375 ms. Its isolated faces cannot merge, so greedy mask/rectangle work adds overhead. This is a disclosed development-profile tradeoff, not a universal performance improvement claim. Ordinary debug development remains available; use `dev:perf` for representative performance work. The optimized checkerboard case improved modestly in these runs, but its vertex count is unchanged.

## Desktop route measurements

The deterministic route source is `bench/renderer_route.exs`. Three runs per variant use fresh seed-2026 worlds and the same plugin, wait for client startup, warm up for two seconds, then perform eight fixed teleports. Variant order alternates. Final captures run with no concurrent builds/tests; exploratory captures made during development are excluded. The first 120 frames are omitted from these summaries. These are teleport stress routes, not walking/gameplay benchmarks.

| Variant | Completed mesh jobs per run | Uploaded bytes per run | Worker CPU ms, range | Frame p95 ms, range | Frame p99 ms, range |
| --- | ---: | ---: | ---: | ---: | ---: |
| Simple, debug | 360 | 21,665,520 | 632.881–640.672 | 17.268–17.350 | 17.576–17.694 |
| Greedy, debug | 360 | 10,456,272 | 266.654–270.907 | 17.299–17.353 | 17.621–17.833 |
| Greedy, perf | 360 | 10,456,272 | 35.721–39.065 | 17.024–17.036 | 17.186–17.286 |

**VERIFIED:** in the same debug profile and with the same 360 completed jobs, greedy meshing reduces worker CPU by about 58% and submitted geometry bytes by about 52%. All nine final captures end with 75 resident chunks, no dirty chunks, no outstanding mesh jobs, and no dropped telemetry samples.

**INCONCLUSIVE:** a full-frame improvement from greedy meshing alone. Debug frame-time tails are effectively unchanged within run variation. Presentation pacing and other phases dominate this route. The optimized-profile comparison is separate: its worker CPU cost is much lower, but the small frame-tail difference is not evidence that greedy alone makes the full game faster. GPU execution was not timed.

## Behavior and review

Tests compare expanded oriented unit-face coverage, winding, and exact colors against the old mesher for empty/solid chunks, layered materials, equal-colored distinct materials, cavities, checkerboards, randomized voxels, procedural terrain, negative-coordinate seams, and edits. Worker bounds, stale-result rejection, palette changes, unload/reload and collision tests remain active. Gameplay authority, packed voxel data, plugin contracts and transport are unchanged. Rectangles merge only identical material IDs in the same face direction; future texture/lighting attributes will need to participate in merge compatibility.

Source review checks snapshot lifetime, neighbor invalidation, valid packed-data indexing, rectangle coverage, material boundaries, profile selection, environment restoration, capture provenance and CI parity. Debug/perf native tests and `mise run check`/`mise run test` pass locally. Windows CI verifies both profiles and packaging. GPU resource lifetime tests, walking routes and GPU timestamps remain tracked in the [issue plan](performance-plan.md).

Raw artifacts are intentionally ignored: `.tools/perf-pass/repro-perf.json`, `mesh-debug-final.json`, and `routes-final/*/frames.jsonl`. Reproduce CPU results with `mise run bench:mesh`; reproduce desktop routes using the documented fresh-data configuration. Do not commit generated captures or preserved executables.

## Background outbound IPC (#5)

Measured on the same Windows machine in the debug profile. The matched benchmark alternates synchronous sends and background admission for six rounds, 64 identical edits per variant per round, with a 2 ms delay on every receiver flush. No poses are used in this comparison, so coalescing cannot explain the reduction. Each run delivers all 64 edits in order and exactly 2,934 framed bytes.

| Path | Producer p95 ms | Producer p99 ms | Complete drain, mean ms |
| --- | ---: | ---: | ---: |
| Synchronous serialization/write/flush | 2.6504 | 2.7598 | 152.745 |
| Background writer admission | 0.0003 | 0.0025 | 151.534 |

**VERIFIED:** producer responsiveness under controlled slow-receiver backpressure. The renderer no longer performs serialization or pipe I/O; total delivery time is effectively unchanged. These are subsystem timings, not frame times or a universal admission-latency bound. The gated regression additionally proves submissions finish while the receiver is blocked, without relying on a performance threshold. Real Windows delayed/closed anonymous pipes verify byte parity and error propagation.

Three alternating ordinary desktop routes per variant use the previously validated greedy debug executable at parent `3ea1c5b` as baseline and the new writer as candidate. Both use fresh worlds and `bench/renderer_route.exs`, with no concurrent builds/tests. Frame percentiles omit the first 120 frames; upload totals include startup.

| Variant | Frame p95 ms, range | Frame p99 ms, range | Uploaded meshes / bytes per run |
| --- | ---: | ---: | ---: |
| Synchronous outbound | 17.321–17.354 | 17.752–17.798 | 435 / 12,620,160 |
| Background outbound | 17.251–17.329 | 17.585–17.755 | 435 / 12,620,160 |

All six runs finish with 75 resident chunks, zero dirty chunks, zero mesh jobs in flight and zero dropped samples. Candidates finish with an empty send queue, 52–53 successfully flushed poses and zero coalesced poses. Lifetime queue maxima are 0.041–0.136 ms and serialization/write/flush maxima are 0.067–0.090 ms. Ordinary outbound writes are small on this route, which explains the limited frame effect.

**INCONCLUSIVE:** ordinary full-frame improvement. Tail ranges overlap, and the small difference does not establish a causal FPS gain. Full-renderer frame tails during a deliberately stalled engine have not been measured; the backpressure result above is isolated producer behavior. Pose coalescing and explicit saturation/disconnect behavior are intentional semantics under overload; delivery is not acknowledged and shutdown may abandon queued edits. See [the design](outbound-ipc.md) for these limits.

Raw captures stay ignored under `.tools/outbound-pass/`: `matched-debug.jsonl`, `route-{baseline,candidate}-{0,1,2}/frames.jsonl`, and `routes-summary.json`. Reproduce the controlled receiver comparison with `mise run bench:outbound -- -Profile dev`.

## Generation profiles and distant loading

Measured on 2026-10-04 with the same Windows toolchain. The performance launcher
previously optimized the client while retaining debug generation. It now uses
optimized generation as well. This is a build-profile correction, not an
algorithm comparison. Normal debug development remains available.

The headless fixture in `bench/native_generation.exs` generates the official
seed-2026 plan at `{672, 300, 672}` (1,018 scenery tiles in two-tile batches), then
2,592 near chunks at horizontal chunk coordinates 38 through 46 across the
configured vertical range. Four runs alternate debug/perf/debug/perf, with three
passes per workload per run. Startup and hashing are excluded from the timer.

| Workload | Debug median ms | Perf median ms | Ratio |
| --- | ---: | ---: | ---: |
| Scenery generation | 22,463.69 | 2,028.54 | 11.07× |
| Near-chunk generation | 2,200.99 | 224.87 | 9.79× |

Every scenery result contains 6,418,312 bytes with deterministic SHA-256
`a612a0306dc131ac939082e1ddf599b19d6bc8fce19ece41976212b5469e1dec`.
Every near result contains 21,233,664 bytes with SHA-256
`154058d009b69e8cee2b7a5eccd53eb0407a4db920b2198ec6c0aab8889895ad`.
The output is byte-identical across profiles. Reproduce the fixture with
`mise run bench:generation` and `mise run bench:generation -- -Profile dev`.

Four stationary desktop pairs use debug/perf/perf/debug generation order and
the same optimized client, seed and presentation viewpoint `{672.5, 300, 672.5}`.
Each pair includes near-only and distant drawing, fresh data and a 35-second
automatic exit. The adapter is RTX 4050 Laptop, Vulkan driver 591.74,
2240×1260 pixels with FIFO presentation. No builds or tests run during capture.
All 1,018 scenery tiles become ready at 23.26 and 23.80 seconds with debug
generation, versus 13.05 seconds in both optimized runs. All four distant BMP
captures have the same SHA-256, so this viewpoint's settled image is identical.
There are no failed tiles or dropped samples; at most two scenery mesh jobs and
one upload occur per redraw. Each run finishes with 897 selected tiles.

The settled 25–35 second interval gives frame p95 17.40–17.60 ms in debug and
17.30–17.34 ms in perf. GPU p95 is 0.98–0.99 ms and 1.08–1.10 ms respectively.
Faster arrivals change off-screen budget fallback: final reserved mesh bytes are
12,918,768 versus 16,123,488; opaque vertices 160,080 versus 184,026; degraded
tiles 34 versus 22. These values remain within the configured bounds. This
verifies faster cold completion, not an FPS improvement or final visual quality.
Shoreline approximations and mixed-resolution acceptance remain open.

Raw CPU reports and the game manifest/summary stay ignored under
`.tools/distant-scenery`. Reproduce game cases with the following commands,
reversing order for the second pair:

```powershell
mise exec -- powershell -NoProfile -ExecutionPolicy Bypass -File scripts/bench-scenery.ps1 -Rounds 1 -Stationary -NativeProfile dev
mise exec -- powershell -NoProfile -ExecutionPolicy Bypass -File scripts/bench-scenery.ps1 -Rounds 1 -Stationary -NativeProfile perf
```

Each capture records the actual loaded
generation profile and library hash alongside client and adapter metadata.

## Persistent scenery cache

The optimized saved-edit fetch fixture uses the same seed-2026, 1,018-tile plan
at `{672, 300, 672}`. Three rounds each measure fetch without a disk store,
an empty bounded store, then that store after an owner restart. Native generation
remains optimized in every case. Sample collection and file I/O are included;
startup and output hashing are excluded.

| Fetch path | Samples ms | Median ms |
| --- | --- | ---: |
| No disk store | 2652.672, 2699.776, 2645.913 | 2652.672 |
| Empty disk store | 3454.668, 3295.436, 3314.995 | 3314.995 |
| Restarted warm store | 905.728, 911.155, 906.035 | 906.035 |

Warm fetch is 2.93 times faster than no-store fetch in this fixture; initial
persistence adds approximately 25% to median fetch time. Every result contains
6,418,312 identical bytes with deterministic binary-list SHA-256
`8386acbcfe11da4099495f5ce6296251b1b2ef1db0e67d60de67a17c1b795f28`.
Each warm round reports 1,018 hits and zero misses after restart; storage occupies
6,491,616 bytes including headers. Reproduce with
`mise run bench:generation -- -Cache`. Loaded-NIF tracing tests separately prove
that cache hits bypass generation and an unrelated saved edit does not miss.

Two stationary desktop cold/warm pairs restart the same isolated world and
cache within each pair. They use optimized generation and rendering, seed 2026,
the fixed presentation viewpoint `{672.5, 300, 672.5}`, and the same adapter,
resolution and FIFO presentation as the profile comparison above. Four
35-second captures produce identical settled BMPs and geometry: 1,018 ready,
897 selected, 184,026 opaque vertices, 16,123,488 reserved mesh bytes and 22
degraded tiles. Failures and dropped samples remain zero; jobs stay at most two
and uploads at most one per redraw.

All-ready times are 13.062/13.107 seconds cold and 13.057/13.069 seconds warm.
This does not establish a game loading or FPS improvement. Warm runs record
1,342/1,326 cache hits and 244/232 misses; these totals include transient plans
at spawn before the authenticated teleport. Cache occupancy stays below 20 MiB.
The settled 25–35 second frame p95 ranges are 17.35–17.69 ms cold and
17.29–17.35 ms warm; GPU p95 ranges are 1.07–1.09 ms and 1.05–1.09 ms. The cache
reduces repeated generation work, while delivery/meshing/upload still require
separate phase measurements before identifying the game loading bottleneck.

Raw fixture output is ignored at `.tools/distant-scenery/cache-fetch-perf.json`;
the accepted game captures and summary are under
`.tools/scenery-flight/cache-a757fce6ad5049f3b24aa7248ee8f752`. An earlier pair
failed warm positioning through a stale control endpoint and is excluded.

## Empty-tile mesh scheduling

Frame captures now distinguish the active view epoch, planned tiles, received
tiles and mesh-ready tiles. Four stationary baseline games receive all 1,018
tiles at 8.616–8.646 seconds, but finish meshing at 13.050–13.078 seconds. Completed
workers report 643–674 ms of total CPU work and uploads 26–29 ms. Empty tiles
still consumed the two worker slots and frame-driven completion rounds.

The scheduler now completes decoded empty tiles directly, without neighbor
availability or a worker roundtrip. An empty replacement still clears old GPU
geometry. Missing data keeps the parent selected, and retired occupied jobs
retain their slots until their results are drained. Occupied jobs and nonempty
uploads keep the existing limits.

Two candidate cold/warm pairs use the same isolated world policy, optimized
native builds, seed, viewpoint, resolution and adapter as the four baseline
games. A further baseline pair runs afterward to check drift; its published
scheduler source is restored temporarily and the candidate source is restored
byte-for-byte before validation.

| Scheduling | All received, seconds | All ready, seconds | Tail after reception, seconds |
| --- | --- | --- | --- |
| Baseline, four runs | 8.616–8.646 | 13.050–13.078 | 4.432–4.434 |
| Empty completion, four runs | 8.619–8.654 | 9.553–9.587 | 0.933–0.934 |
| Repeated baseline, two runs | 8.611–8.614 | 13.044–13.048 | 4.433 |

The first four baseline runs have median all-ready time 13.061 seconds; the
candidate median is 9.567 seconds, approximately 27% less loading time on this
route. Every settled image has SHA-256
`9b54474259e63c04eacae768d5dd37bd191128c8dbe46c9943dd93b100e8e34f`,
with identical final geometry: 897 selected tiles, 184,026 opaque vertices,
16,123,488 reserved mesh bytes and 22 degraded tiles. All runs finish with
1,018 ready tiles and 2,592 near chunks, no failures or dropped samples, at most
two mesh jobs and one nonempty upload per redraw. Candidate completed-worker
CPU totals remain 678–689 ms; this is a scheduling improvement rather than faster
meshing arithmetic. Data reception remains about 8.6 seconds and is the next
loading phase to investigate. No steady FPS or broader visual-quality claim is
made from these stationary runs.

Ignored raw captures are `cache-65d8eed082b04079b946c090de69ca5e` (baseline),
`cache-6c4aed8caa8042e0ad68b07b81a0dcc4` (candidate), and
`cache-237fc61e77294173b6e1b8969a291490` (baseline confirmation), under
`.tools/scenery-flight`. The phase summary is
`.tools/distant-scenery/loading-summary.json`. `bench:scenery` records the same
arrival/readiness counters for new captures; the report keeps old files readable.
