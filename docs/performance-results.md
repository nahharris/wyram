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

Source review checks snapshot lifetime, neighbor invalidation, valid packed-data indexing, rectangle coverage, material boundaries, profile selection, environment restoration, capture provenance and CI parity. Debug/perf native tests and `mise run check`/`mise run test` pass locally. Windows CI verifies both profiles and packaging. GPU resource lifetime tests, reliable IPC saturation policies, walking routes and GPU timestamps remain tracked in the [issue plan](performance-plan.md).

Raw artifacts are intentionally ignored: `.tools/perf-pass/repro-perf.json`, `mesh-debug-final.json`, and `routes-final/*/frames.jsonl`. Reproduce CPU results with `mise run bench:mesh`; reproduce desktop routes using the documented fresh-data configuration. Do not commit generated captures or preserved executables.
