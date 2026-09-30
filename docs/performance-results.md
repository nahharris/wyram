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
