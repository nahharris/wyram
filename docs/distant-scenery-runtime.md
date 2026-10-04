# Distant scenery integration

This branch is an integration in progress. The published data and rendering
foundations are combined with the optimized 9×9 near-chunk streaming pipeline.
Distant drawing is enabled by the official game composition. The current
implementation is experimental; actual game captures and resource measurements
are part of its acceptance work.

## Public policy

Plugins can declare `scenery` in a public `Wyram.Game` composition. Compilation
stores a validated `Wyram.Scenery.Config` in the immutable game catalog. The
policy requires a shared world generator; games without scenery retain `nil`.

The policy currently defaults to a 1,024-unit horizontal view distance,
maximum level five, detail distance 64, at most 1,024 planned tiles, two worker
tasks, and 64 MiB each for encoded cache payload and renderer mesh payload.
Every tile contains 16³ cells and cell width is `2^level` world units.

`detail_distance` controls refinement: a tile can refine when observer distance
to its bounding box is below `detail_distance * 2^level`. Refinement stops at
level one or the tile count limit. A larger value requests finer detail farther
away. The count includes roots, parents, empty tiles and all replacement
children; it is not just the number of eventual draw calls.

The cache policy must accommodate the maximum encoded tile size for every
planned node. Fixed map metadata and transient work buffers also contribute to
actual memory use. The mesh field bounds admitted renderer geometry, including
blended vertex/index allocation slack. It does not describe total process memory
or temporary allocations retained by the GPU driver.

## Planning and work

The planner checks world-coordinate and height bounds, estimates root count
before allocating nodes, then builds deterministic complete sibling groups.
When the node budget is exhausted, it retains the coarse parent. Only complete
tiles inside native generation limits are requested near coordinate limits.
That can leave a narrow strip at the absolute world boundary without a coarse
proxy; authoritative near chunks remain separate.

The loader uses supervised tasks and batches at most two tiles per native call.
Camera changes keep existing tasks counted against the concurrency limit until
they finish. They do not repeatedly kill and replace dirty-CPU work. Results
outside the current plan are discarded. A changed content revision clears
cached results and rejects in-flight results from the previous revision.
Still-valid cache entries are reused across view changes, and completing jobs
are removed from the pending list before further dispatch.

Native output headers and storage lengths must match the requested keys before
the batch enters the cache. Cell validation belongs to the native generator and
decoder. Failures do not trigger an unbounded retry loop. These helpers are
tested independently and connected to the supervised visual service. The
service is inactive for games without a scenery policy. Client capability
negotiation now connects view requests and packed native delivery.

## Persistent visual storage

A separate store actor persists generated tile bytes under the world's
`scenery-cache` directory. Only bounded scenery workers wait on its file I/O;
the renderer and gameplay coordinator never call it synchronously. A slow store
retains its caller's worker slot. An unavailable store falls back to generation.

The stable identity includes the generator identity and seed, world bounds,
numeric block mapping, and an explicit native visual algorithm version. Changes
to generation, sampling, reduction or encoding must bump `CACHE_VERSION` in the
native core. Development build profiles do not change this content identity.
Each tile additionally includes its position, level and actual saved-edit sample
bytes. Unrelated edits therefore reuse persisted tiles; changed represented
samples regenerate their affected tiles. Snapshot checks still reject results
when an edit occurs during the read, generation or cache wait.

Storage uses a fixed slot pool with at most four times the configured tile count
and the configured cache byte budget, independently of the in-memory loader.
The disk budget includes the eight-byte slot metadata and every tile's 72-byte
header. Eviction makes room before writing; startup applies smaller policies.
Reads validate the content digest, payload length, checksum, tile key and native
cell encoding. Damaged, partial or unsupported files become misses. The store
touches only its numbered tile files and slot metadata; generated cache files
do not belong in Git.

## Edits and delivery

World owns a protected read model containing only known saved chunk edits.
Workers read at most 256 chunks per snapshot without activating region actors.
The world publishes each edit and a monotonic content stamp atomically after
the durable save succeeds. A failed save leaves both unchanged. A world restart
creates a new session and invalidates the previous read model.

The generator lists only chunks that contain a tile's sample positions. Edited
chunks are reduced to compact sample-index/material records before generation.
Each extraction call receives at most 2 MiB of chunk bytes; compact records are
bounded to 128 KiB per coarse tile. Level one incorporates every edited voxel;
higher levels incorporate edits at their stratified sample positions and may
miss unsampled thin additions or removals. Reads check the content stamp before
and after collection and generation, discarding obsolete results.

The sea-containing sample stratum moves a midpoint above sea level down to the
sea-level voxel. Lower midpoints stay unchanged. This retains thin sea layers
without increasing the sample count. Edit collection follows the shifted
positions, including chunk-boundary crossings at higher levels.

The service owns one plan and retains at most the configured number of cached
tiles. It runs at most two generation jobs, each containing at most two tiles,
and keeps only one unacknowledged two-tile delivery to the current client.
Camera changes retain running jobs against the worker limit. Content changes
invalidate the encoded cache and outstanding delivery. Viewer termination
releases wanted tiles. Individual generation failures do not retry indefinitely.

The client advertises scenery capability two. `WSP1` carries the epoch, content
identity, edit stamp, view distance, payload budgets and a parent-first indexed
forest. `WST1` carries at most two length-prefixed `WSL1` or `WSL2` tiles and a numeric
delivery credit. The coordinator maps that credit to the service's private task
token. Older epochs cannot release current work. Client close releases its view.

The native reader validates complete sibling groups, unique keys, root coverage
of every declared node, supported coordinate extents, byte limits and tile cells
before sending packets to the UI thread. The view cache accepts only current,
wanted tiles and preserves immutable data across camera-only changes. A new
content identity clears it, including after a service or world restart. Credits
coalesce in one outbound slot without displacing gameplay edits or input.

The repository test script exercises real Windows pipe framing and a matched
Elixir-to-native fixture containing known edits at negative coordinates,
complete refinement, camera reuse and content invalidation. It verifies data
transport and cache behavior. Separate native GPU tests exercise the drawing path.

## Drawing and replacement

Two native workers build volumetric proxy meshes from occupancy masks. Greedy
faces preserve disconnected geometry and cave openings at the available sample
resolution. A mesh that exceeds its per-node allowance is rebuilt at a coarser
resolution. The planner reserves enough space for a minimal proxy for each node;
parents remain resident so memory pressure can preserve coarse coverage.
Decoded empty tiles release their unused mesh allowance. Unknown tiles still
reserve space; occupied tiles share the remaining allowance, capped at 2 MiB
each. Degraded meshes can rebuild when their allowance doubles. Budget decreases
remove oversized geometry and schedule a fitting replacement.

Queued, active and completed jobs share a two-job limit. The renderer admits at
most one nonempty upload per redraw, with a maximum 2 MiB payload. Content changes
reject obsolete results without freeing their work slots prematurely. A parent
stays selected until all eight replacement children are ready, including empty
children, and neighboring meshes no longer use that retained parent to hide
opaque boundaries. Camera changes reuse wanted immutable tile data and resident meshes.

Decoded empty tiles complete directly without occupying a mesh-worker slot or
waiting for neighboring data. Their empty replacement clears prior GPU geometry
and counts toward sibling readiness. Missing tile data still retains the parent.
Retired occupied jobs keep their slots until their results are drained; empty
completion does not increase the two-job or one-nonempty-upload limits.

Meshing reads adjacent planned tiles, or their planned ancestors, to suppress
shared walls. It waits for these immutable summaries in the work scheduler;
rendering and gameplay never wait for a synchronous actor request. A changed
neighbor plan schedules a replacement while keeping the previous mesh available.
External samples read just across the shared boundary. A reduced mesh's cell
center can skip a neighbor's thin water stratum and incorrectly emit a second
sea cap. A generated-coast regression checks the actual overlap area between
a budget fallback mesh and its full-resolution vertical neighbor.
A parent that can refine does not prove its children's opaque face coverage,
so its summary cannot suppress those external walls. Refinement eligibility is
part of mesh dependencies, including camera changes that keep the same tile keys.
This conservatively retains opaque walls while translucent liquid summaries
continue to suppress shared water walls. Tests exercise a negative-coordinate
coarse wall reopened by a finer child's air gap and reversed worker completion.
Different sample resolutions can still approximate the two sides of a boundary
differently; the neighbor data is not a guarantee of exact surface agreement.

Completed near meshes, including empty meshes, populate a bounded GPU coverage
mask. Distant fragments covered by those chunks are discarded. Missing near
meshes retain their distant fallback. Near and distant translucent faces share
one camera-sorted index stream. Ocean cap heights come from generator metadata
and public material descriptors. A sampled water cap containing that plane uses
its configured height even when the plane is near the bottom of the coarse
cell; water away from it uses the local material height. Reverse infinite depth handles distant bounds;
horizontal fog and a hard cutoff limit the configured view range.

Cells can carry a separate top-surface color material. Reduction votes over the
highest occupied child of each horizontal column; direct generation preserves
the thin geological surface above the final occupied sample. The renderer uses
this metadata only for positive-Y faces whose material has the same liquid,
opacity and emission properties as the volume material. Geometry, liquid height,
and other face colors continue to use the volume descriptor. Fallback meshes
reduce surface votes separately, within the same mesh allowance.

## Reproducible game diagnostics

`mise run bench:scenery` runs isolated optimized games with and without distant
drawing, reversing the order on the second round. It uses fresh ignored saves,
ordinary inputs approved by Elixir, frame/GPU metrics, and one asynchronous GPU
capture per game. Each game exits automatically. Output goes under
`.tools/scenery-flight`; no generated captures or saves belong in Git.

For stationary captures, run:

```powershell
mise exec -- powershell -NoProfile -ExecutionPolicy Bypass -File scripts/bench-scenery.ps1 -Rounds 1 -Stationary
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/scenery-perf-report.ps1 -Directory <run-directory>
```

Stationary cases last 35 seconds by default. Pass `-StationarySeconds 75` to
inspect slower cold loads after they settle; the supported range is 35 through
120 seconds. The GPU capture delay is the requested duration minus five seconds.
Keep cold completion time separate from steady rendering cost, and check tile
readiness before treating the image or timing interval as settled.

Frame diagnostics record the current scenery epoch, planned tile count and
received tile count separately from mesh-ready tiles. The report includes each
epoch's first all-received and all-ready frame, at frame resolution. Old captures
remain readable without these fields. A mesh policy that prunes planned groups
can leave the all-ready timestamp unset; compare the counts before interpreting
it as incomplete work. These counters distinguish data arrival from mesh and
upload completion, without renderer calls to service actors.

The default benchmark uses optimized builds of both the client and generation
library. Pass `-NativeProfile dev` to keep the optimized client while measuring
debug generation as a control. Each case records the actual loaded generation
profile, optimization level and library hash in `frames.native.json`; the report
includes this metadata alongside the adapter and frame measurements. Older
captures without native metadata remain readable, but do not assume their
generation profile from the client profile.

The stationary mode positions the player through the authenticated local control
API, then fixes the presentation viewpoint at the requested coordinates. Flight
approval and near streaming still follow the authoritative player state; the
fixed presentation avoids transient falling before flight approval changing the
camera comparison. The flight route uses wall-clock inputs, so different authoritative tick
rates can produce different paths. Check the recorded positions before treating
those runs as matched camera comparisons. `redraw_cpu_ms` includes surface
acquisition waits; it is not a measure of pure renderer computation. FIFO
presentation can hold both cases near 60 Hz despite different GPU costs.

## Remaining runtime gates

Distant queries must not activate gameplay regions or obtain authority over
collision, liquids, or characters. The read model and native sample path now
cover durable known edits, including restored saves. Persistent storage reuses
unchanged sampled content across restarts and edits. Incremental server and
renderer invalidation remains to be implemented: a content change still clears
their in-memory tiles and meshes, even when the disk store can supply the same bytes.

Bounded native meshing, renderer residency, parent replacement, near clipping,
and depth handling are connected. Tests cover synthetic caves, detached islands,
negative positions, budget fallback, complete replacement, and GPU near coverage
and global translucent ordering. Actual generated terrain still requires visual
acceptance, particularly mixed-resolution shorelines and representative materials.

Visual and performance validation must exercise cold loading, warm reuse,
camera movement, edited terrain, rapid view changes, negative coordinates,
islands, cave openings, translucent boundaries and configured resource limits.
CPU fixture improvements are not evidence of game FPS or final scenery quality.
