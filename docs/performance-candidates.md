# Performance candidate implementation and comparison

Objective: implement and validate every candidate from the flight investigation, compare each against the preserved current 9×9 baseline, and retain improvements supported by measurements. Gameplay authority remains in Elixir; packed work and presentation remain native. Each step receives a focused commit and explicit acceptance evidence before the next comparison. Generated artifacts stay ignored.

Baseline: `d0bcd3b`, radius four, 2,592 chunks. Preserved perf client, debug NIF, engine/dependency BEAM modules and game package are under `.tools/candidates/baseline/` with SHA-256 metadata. Every variant runs its own immutable build snapshot, with no compilation or dependency checks. Runs use fresh worlds, the same plugin/seed, requested window size and fixed-distance route. Do not run builds/tests alongside measurements.

| Step | Required implementation and evidence | Status |
| --- | --- | --- |
| 1 | Bounded mesh job/result queues independent of per-worker redraw acknowledgement; cheap empty-result handling; nearest-first batch admission. Stale/unload/palette parity, shutdown and queue bounds. Compare first clean residency, dirty-queue drain and frame tails. | Retain for loading; frame tail cost recorded below |
| 2 | Attribute blended preparation, sorting, buffer writes and presentation waits. Avoid unchanged-content invalidation; reduce measured sorting/allocation cost with exact alpha ordering. Compare stationary, movement and replacement phases. | Retain for sorting CPU and correct invalidation; FPS inconclusive |
| 3 | Bounded asynchronous concurrent region streaming with obsolete-view cancellation and revision/edit ordering. Verify actor/mailbox responsiveness and eventual visible data under slow regions. Compare baseline and step-one/two client with both engine variants. | Retain for responsiveness and initial residency |
| 4 | Reuse horizontal worldgen/feature calculations across vertical chunks; conservative empty summaries/transport where worthwhile. Preserve exact generation bytes, seams, carvers/features/islands and edited-mesh removal. Measure matched CPU and desktop workloads. | Retain for verified generation CPU reduction; no convincing residency/FPS gain |
| 5 | Attribute remaining GPU, draw/vertex, blended upload and inbound decode costs. Implement and compare justified frustum culling and bounded binary/background intake experiments; evaluate buffer reuse/GPU meshing according to the evidence rather than assume gains. | Retain bounded admission, culling and packed/background intake; defer opaque buffer pooling and GPU meshing |

Completion requires a disposition for every candidate, raw matched comparisons and behavior gates, `mise run check`/`mise run test`, and published reviewable changes with honest CI status. A single successful candidate does not complete this objective.

## Candidate 1: mesh queue

Six alternating immutable-snapshot captures (three per variant), perf client and the same verified debug NIF. Fixed 96-block flight above the actual spawn, 35-second initial load and 35-second drain. Travel was 96.00–96.72 blocks. Every capture ends with 2,592 loaded chunks, zero dirty/in-flight jobs and zero dropped samples.

| Metric | Original 9×9 baseline | Mesh queue |
| --- | ---: | ---: |
| First fully meshed residency, median seconds | 23.23 | 10.34 |
| Post-flight drain, median seconds | 16.52 | 4.12 |
| Flight frame p95, range ms | 17.52–17.60 | 18.29–19.13 |
| Flight frame p99, range ms | 18.06–18.89 | 18.97–23.05 |
| Maximum dirty chunks during flight | 1,538–1,585 | 642–698 |
| Maximum outstanding jobs | 2 | 32 |

Retention rationale: substantially faster complete residency and backlog recovery. This is not an FPS improvement: tails increased while more geometry became ready. The comparison includes scheduling-dependent remeshing and visibility, not identical per-frame draw workloads. The next candidate measures the transparency cost previously hidden inside redraw. Empty completion callbacks no longer count as geometry uploads, so `uploaded_meshes` counts are not comparable across the original baseline and this candidate.

Raw results: `.tools/candidates/mesh-queue-comparison/summary.json` and six run directories. Focused regression tests cover queued work completing without redraw acknowledgements, empty-result admission, old-mesh removal, stale/unloaded/revised snapshots and the 32-job bound. Native client tests and workspace Clippy passed before this checkpoint.

## Candidate 2: blended preparation

Opaque-only or absent-empty replacements no longer invalidate blended data. Identical blended replacements retain the prepared buffer; removal still invalidates it. Reuse aggregate scratch storage and cache each distance key once, retaining the exact stable descending `total_cmp` order. The 20,000-quad paired CPU fixture (eight rounds) measured reference sorting at 5.42–9.58 ms and cached sorting at 1.09–2.08 ms. This fixture establishes sorting cost and exact order parity, not a desktop FPS claim.

Frame telemetry now separates blended preparation and written bytes, swapchain acquisition, command encoding, submission/presentation CPU, and actual opaque draw/vertex counts. Surface-acquisition time includes presentation pacing; it is not GPU execution time. Desktop comparison uses the mesh-queue snapshot as its control to isolate the incremental change.

Six incremental desktop captures finished with complete residency and no dropped telemetry. Mesh-queue control first-clean median was 11.05 s and drain median 4.23 s; blended candidate medians were 11.33 s and 4.17 s. Flight frame p95 ranges were 18.07–18.25 ms control and 17.95–18.42 ms candidate; p99 ranges were 18.72–19.05 ms and 18.52–19.21 ms. No convincing full-game FPS or startup improvement. Retain the demonstrated cheaper sorting, correct invalidation and phase attribution; avoid claiming that the fixture speedup transfers directly to FPS. Raw evidence: `.tools/candidates/transparency-comparison/`.

The candidate's flight blended-preparation p95 was 2.84–4.30 ms. Startup chunk-upload p95 was 0.06 ms with maxima 0.14–0.16 ms, while count admission remained two geometry uploads per redraw. A later bounded admission experiment will test using more of the existing 1 ms / 2 MiB budget. Ordinary flight event-thread decode p95 was 0.08–0.17 ms: binary/background intake is principally a transport/boundedness experiment, not a demonstrated frame bottleneck on this optimized route.

## Candidate 3: region actor streaming

The client coordinator admits at most four snapshot tasks, at most one per existing region owner, with 16 chunks per request. Tasks perform the routing and synchronous owner calls outside the coordinator. Changed views kill outstanding request tasks and reject their late results; owner calls already queued or executing may still finish generation into the owner's cache. Cancellation bounds live request tasks, not previously delivered owner mailbox messages. Monotonic wanted-key revisions prevent a pending older snapshot from overwriting a published edit. Region/task failure terminates the coordinator rather than silently dropping required terrain. Shutdown cancels requests.

Seven focused ExUnit tests passed, including a live coordinator answering a snapshot call while its requested region was suspended. Credo and Dialyzer passed. Six matched captures compare the same client/NIF with serial versus asynchronous engine modules. All finish clean with full residency and no dropped samples. First-clean medians: 10.66 s serial versus 8.31 s asynchronous; drain: 4.17 versus 3.98 s. Serial first-clean samples were 9.97, 10.66 and 17.05 s, so variance is material. Flight p95: 17.99–18.19 ms serial and 18.06–19.00 ms asynchronous; no FPS improvement established.

The direct client-coordinator call p95 during initial loading fell from 31.1–87.1 ms to 0.204–0.307 ms; during flight, from 33.5–82.5 ms to 0.204–1.945 ms. Flight call p99 fell from 45.7–104.8 ms to 1.331–2.662 ms. These sample call completion, not end-to-end keypress-to-pixel latency. Probe calls add time to the driver's 100 ms input cycle in both matched variants; travel was 96.00–97.20 blocks. The route still verifies authoritative flight and available collision terrain. Port writes remain in the coordinator, so these measurements do not guarantee responsiveness under arbitrary pipe backpressure.

Raw results: `.tools/candidates/async-regions-comparison/`. Retain for faster initial residency and clearly lower coordinator delay, with the frame-tail and probe limitations explicit.

## Candidate 4: horizontal generation reuse

Native batches reuse columns and feature anchors when more than one vertical chunk shares a horizontal key. Cache lifetime is one call, without shared mutation or locks. Singleton columns keep the original generation path. A conservative empty proof accounts for terrain, sea level, islands and all intersecting features; carvers can only remove material. Packed data/revisions and full-height visual/collision residency remain intact.

The new byte-parity fixture covers complete vertical columns, negative coordinates, duplicate/reversed keys, invalid coordinates, caves, surface/island features, support depth and out-of-bounds air. The 32-layer decorated-column CPU fixture measured original generation at 8.26–8.78 ms versus 2.67–3.24 ms with reuse (eight alternating optimized rounds).

The actual game-plugin inventory, same 2,592 keys and original 32-key batch boundaries, measured debug-NIF generation at 7,220.7–7,994.8 ms versus 5,702.5–6,288.6 ms, three samples per variant. All six inventories contained 1,502 empty chunks and exactly matched keyed output SHA-256 `4CA6DDD7FE388EA9AC05BD91D4EDC1189CDFBA80114A65817A5BA100A586CDE2`. This workload's smaller gain than the fixture reflects mixed column/layer batches and real plugin features. Raw inventory artifacts: `.tools/candidates/worldgen-reuse-cpu/`. Desktop comparison is separate.

Six matched desktop captures: first-clean median 8.47 s without reuse versus 8.36 s with reuse, drain 4.12 versus 4.03 s. Flight frame p95 ranges 18.08–18.59 ms versus 18.32–18.98 ms; p99 19.01–19.37 versus 18.78–20.84 ms. All finish clean with 2,592 chunks and no dropped samples. Retain the measured CPU reduction and byte parity, with no convincing full-game FPS or residency improvement under the two-upload admission limit. Raw desktop results: `.tools/candidates/worldgen-reuse-comparison/`.

## Candidate 5: presentation, transport and upload admission

Conservative frustum/AABB rejection applies only to opaque draw submission, preserving full-height residency, meshing, collision and global alpha order. The tests cover near/far intersections, negative edges and projected inside points near large world coordinates. Blended counters now distinguish collection, sorting and staging/write CPU.

Native input uses a bounded 32-packet background queue. Framed JSON decoding, base64 expansion and versioned packed decoding happen on its reader thread; the event thread applies immutable chunk bytes and invalidation. Protocol `WYC1` admits at most 16 snapshots with signed 32-bit coordinates, unsigned 64-bit revisions, and exactly 8,192 bytes or explicit zero-length air. Air still replaces previous content. JSON remains supported for updates and older clients/engines. One bounded capability announcement selects packed batches. Truncation, oversized counts, bad lengths, trailing bytes and revision-width fixtures pass.

Geometry upload count is increased from two to at most eight per redraw while retaining the 1 ms admission and 2 MiB byte limits. One oversized indivisible upload may progress, as before; elapsed time bounds admission rather than the duration of a driver call. `WYRAM_MESH_UPLOAD_LIMIT=2` restores the control limit for measurements. `WYRAM_FRUSTUM_CULLING=0` and `WYRAM_CHUNK_PROTOCOL=0` restore the draw/transport controls. These are diagnostic controls, not gameplay authority.

GPU timestamp queries are requested only when capture is enabled and supported. One asynchronous readback is outstanding; redraw polls once without waiting and skips sampling until mapping completes. Samples cover the world render pass, exclude buffer-upload copies/presentation, and arrive in a later frame. Nulls mean no completed sample, never zero GPU cost. Capture sidecars record adapter, driver/backend, actual physical surface size and presentation mode. This machine uses RTX 4050 Laptop, Vulkan, NVIDIA driver 591.74, physical 2,240×1,260 for the 1,280×720 logical request, FIFO presentation.

The incremental comparison uses identical engine/client binaries with matching instrumentation. Its control keeps culling/packed protocol disabled and upload count two; its candidate enables culling/packed protocol and upload count eight. Background decoding is active in both, so this comparison does not isolate its incremental effect. Final comparisons against the original immutable baseline will assess the combined change in both debug and perf clients.

Six matched captures finished clean with zero dropped samples. First-clean median: 9.51 s control versus 3.63 s candidate (candidate range 3.49–3.89 s). Control drain median was 4.13 s; candidate residency was already clean at the recorded drain boundary (the report's first subsequent frame is 16–17 ms). Buffered markers make this a boundary observation rather than millisecond-accurate input-to-clean latency.

Flight opaque-draw medians: 572–578 control versus 35–36 candidate; submitted opaque-vertex medians: 206,370–210,414 versus 9,480–9,492. All-route inbound payloads: 50.44–50.63 MiB versus 18.15–18.32 MiB, including unchanged JSON character/control traffic. Travel was 96.24–96.96 blocks, so these are observed route totals, not exact compression ratios for identical per-frame traffic. World-pass GPU p95: 0.43–0.46 ms versus 0.35–0.36 ms; p99: 0.53–0.96 versus 0.45–0.53 ms. GPU render-pass execution is not the main loading limit here.

Flight frame p95 ranges: 17.91–21.72 ms control and 17.97–21.55 ms candidate; p99: 19.37–39.15 ms and 18.84–31.34 ms. One run in each variant had high tails. No convincing overall FPS improvement; retain the clear residency, draw-submission and transport improvements with this variance disclosed. Opaque buffer pooling is deferred: most measured upload CPU is well below the 1 ms admission budget, and raising bounded count already addresses the demonstrated loading limit. GPU meshing is deferred: the bounded CPU queue and admission changes deliver the loading gains without moving meshing authority or adding GPU pipeline/readback complexity. Neither deferred idea is claimed universally ineffective. Raw results: `.tools/candidates/graphics-transport-comparison/`.

## Final comparison against the original 9×9 baseline

Two alternating paired rounds per client profile compare the original `d0bcd3b` snapshot against all five retained candidates at `1d321dc`. Both use the same original game-plugin archive, seed, 96-block route, debug-NIF profile, full-height 9×9 residency and coordinator probes. Perf uses 35-second startup/drain periods; debug uses 60 seconds for both. Profiles are separate comparisons, not a debug-versus-perf experiment. Loaded NIF hashes and actual client profiles were verified, and all eight captures received 2,592 chunks with zero dropped samples.

| Metric | Original perf | Final perf | Original debug | Final debug |
| --- | ---: | ---: | ---: | ---: |
| First fully meshed residency, seconds per run | 24.76, 23.18 | 3.83, 3.55 | 25.80, 24.76 | 6.02, 8.03 |
| Post-flight drain, seconds per run | 17.26, 17.03 | Clean at recorded boundary | Not complete after 65.44, 65.47 observed | 2.75, 2.53 |
| Dirty chunks remaining at capture end | 0, 0 | 0, 0 | 590, 602 | 0, 0 |
| Flight frame p95, ms per run | 19.01, 33.15 | 18.27, 30.20 | 39.18, 35.56 | 34.53, 30.86 |
| Flight frame p99, ms per run | 33.63, 33.82 | 19.61, 33.62 | 42.64, 38.39 | 38.77, 35.16 |
| Flight coordinator-call p95, ms per run | 37.68, 45.16 | 0.307, 0.102 | 46.49, 39.01 | 0.204, 0.102 |

The debug baseline's drain is right-censored: the capture ends before complete meshing, so it establishes a lower bound rather than a completion time. Its two outstanding mesh jobs and remaining dirty counts are retained in the report. Initial residency did finish before flight in both baseline runs. The reporter rejects incomplete drains by default; `-AllowIncompleteDrain` explicitly preserves null completion times, an observed-duration bound and final backlog counts. It continues to reject missing chunks and dropped telemetry. A synthetic fixture verified strict rejection, null censoring and dropped-sample rejection.

Complete-residency medians fell from 23.97 to 3.69 seconds in perf (about 85% lower) and 25.28 to 7.02 seconds in debug (about 72% lower). Both final debug drains finish within 2.75 seconds. The debug baseline's median drain-phase frame was about 88 ms versus 16.68–16.71 ms after the changes: this is backlog recovery, not steady flight FPS. During final debug flight, blended preparation p95 still reaches 26.70–27.92 ms; measured world-pass GPU p95 is 0.37–0.39 ms. Blended CPU preparation remains a useful next target for the ordinary debug launcher.

Two samples per profile/variant are limited evidence. Perf frame tails vary substantially, including a final stationary-hover p95 of 33.10 ms in one run, so there is no broad steady-FPS guarantee. The clearer combined improvements are initial residency, recovery from the flight backlog and coordinator responsiveness. Buffered phase markers limit drain-boundary precision. Raw captures and reports: `.tools/candidates/final-perf-comparison/` and `.tools/candidates/final-debug-comparison/`.

`mise run check` and `mise run test` passed for the final production checkpoint, covering Elixir formatting/compilation, strict Credo, Dialyzer, Rust formatting/Clippy, plugin and gameplay smoke tests, 218 ExUnit tests and native workspace tests. Optimized client tests separately passed (73 tests, three manual benchmarks ignored). The benchmark Elixir files passed formatting and PowerShell scripts passed syntax parsing. Saves, raw telemetry, archives and build snapshots remain ignored.

## Reproduce comparisons

Before changing source, build both client profiles, compile the desired engine/NIF profile, and pack the game plugin. Snapshot each tested commit before proceeding to the next. `snapshot-candidate.ps1` copies dependencies, engine modules, the explicit NIF, native client and plugin into a fresh directory; inputs must already be built. The explicit NIF and its recorded hash avoid relying on Mix environment to identify the loaded native profile. Select `-Profile debug` for the ordinary launcher client, and preserve that original executable before rebuilding it.

```powershell
mise exec -- powershell -NoProfile -ExecutionPolicy Bypass -File scripts/snapshot-candidate.ps1 -Directory .tools/candidates/my-variant -Nif native/target/debug/wyram_nif.dll
mise exec -- powershell -NoProfile -ExecutionPolicy Bypass -File scripts/bench-candidate.ps1 -BaselineDirectory .tools/candidates/my-baseline -CandidateDirectory .tools/candidates/my-variant -OutputDirectory .tools/candidates/my-comparison -Rounds 3
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/candidate-perf-report.ps1 -Directory .tools/candidates/my-comparison
```

Use `-Workload worldgen` on the comparison runner for the direct, keyed-output inventory; it verifies parity across variants. Set `WYRAM_STREAM_RESPONSIVENESS=1` before both desktop variants to sample direct coordinator calls. `WYRAM_ROUTE_STARTUP_MS` and `WYRAM_ROUTE_DRAIN_MS` select matched phase durations (multiples of 100, from 1,000 to 120,000). Use `-AllowIncompleteDrain` on the reporter only when explicitly reporting a censored backlog result, as for the final debug baseline above. No builds, tests, other benchmarks or full-capture analysis should run alongside timed measurements. Snapshot and output directories must be new. Logs, binaries, plugin archives, saves and raw captures remain ignored; publish the source and summarized evidence only.
