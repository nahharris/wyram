# Progressive terrain

Nearby terrain retains its normal block rendering inside the horizontal 11-chunk circle, across the complete world height. Distant tiles contain 32³ rendered cells plus a one-cell sampling halo. Fixed world coordinates align the grids, including negative positions.

| Cell size | Outer radius at the default near radius |
| --- | --- |
| 1³ | 11 chunks / 176 blocks |
| 2³ | 22 chunks / 352 blocks |
| 4³ | 44 chunks / 704 blocks |
| 8³ | 88 chunks / 1,408 blocks |
| 16³ | 176 chunks / 2,816 blocks |

The radii follow the nearby radius times 1, 2, 4, 8 and 16. There is no larger-cell fallback under resource pressure. Elixir plans and schedules visual tiles, tracks edits and revisions, and supplies the existing immutable generator to native workers. Distant tiles never create simulation regions or participate in collision.

## Startup settings

`WYRAM_LOD_MAX_CELL_SIZE` selects 2, 4, 8 or 16; the default is 16. Set it to 0 to run the accepted circle-only baseline. Visual acceptance proceeds through 2, then 4, 8 and 16, including fog at each stage.

Available parallelism is resolved once from the smaller of the native client's CPU report and BEAM's online dirty CPU scheduler count. Failed detection uses 4. The combined worker budget is `clamp(floor(P / 2) - 2, 2, 8)`; generation receives its rounded-up half and meshing its rounded-down half. For P=22, this is 4 generation and 4 meshing workers. Nearby workers are unchanged.

`WYRAM_LOD_GEN_WORKERS` and `WYRAM_LOD_MESH_WORKERS` independently override their automatic counts with integers from 1 through 8. Invalid overrides fail startup with a configuration error. Increasing workers does not enlarge admission, memory or transport limits; cancelled jobs still running consume worker slots.

## Admission and visibility

Encoded tile caches are capped at 256 MiB. Distant GPU geometry has a separate 256 MiB allowance, including 32 MiB reserved for transparent indices. Transport batches are at most 1 MiB, and meshes split into bounded parts. A tile becomes GPU-ready only after every part is resident, including a valid empty completion. Replacements keep the prior mesh until completion.

The renderer protects the nearby circle, uses a two-chunk transition buffer and a 200 ms complementary fade, and applies the same fog to opaque and liquid terrain. Fog reveals a conservative contiguous frontier of complete GPU-ready columns across the full height; its outermost 20% fades into the sky. Ordinary movement retains coverage and prefetches boundaries. Teleport epochs reset coverage.

## Verification and visual acceptance

Automated checks cover fixed bands, negative coordinates, deterministic generation, surface and liquid materials, edits, protocol bounds, bounded worker and cache behavior, empty completions, replacement admission, seams and coverage transitions. Owner playtests must still check nearby appearance, boundary reversals, flight, teleporting, shores, caves, islands, edits and resource pressure at each enabled cell size.

Use matched routes, world seed, plugin, build profile, window and machine when comparing with `WYRAM_LOD_MAX_CELL_SIZE=0`. Compare automatic workers with 2+2 and higher overrides. `WYRAM_CLIENT_METRICS` records frame timings, inbound queue latency, distant jobs, pending and resident tiles, encoded and GPU bytes, and the fog frontier. Engine control status includes generation counts and queue sizes. Capture process memory separately. Unit tests and subjective playtest feedback are not measured performance gains.
