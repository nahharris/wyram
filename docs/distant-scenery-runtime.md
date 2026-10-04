# Distant scenery integration

This branch is an integration in progress. The published data and rendering
foundations are combined with the optimized 9×9 near-chunk streaming pipeline.
Distant drawing is not enabled yet.

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
actual memory use. The mesh field is reserved for the renderer's admission
budget; no mesh residency manager is connected yet.

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
service is inactive for games without a scenery policy. Client view requests
and packed native delivery are not connected yet.

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

The service owns one plan and retains at most the configured number of cached
tiles. It runs at most two generation jobs, each containing at most two tiles,
and keeps only one unacknowledged two-tile delivery to the current client.
Camera changes retain running jobs against the worker limit. Content changes
invalidate the encoded cache and outstanding delivery. Viewer termination
releases wanted tiles. Individual generation failures do not retry indefinitely.

## Remaining runtime gates

Distant queries must not activate gameplay regions or obtain authority over
collision, liquids, or characters. The read model and native sample path now
cover durable known edits, including restored saves. Persistent cache identity,
storage budgets, and incremental tile invalidation remain to be implemented.

Live view requests, packed IPC, bounded native decode/meshing, renderer residency,
parent replacement, near-geometry clipping, and depth handling still need
implementation. A parent must stay visible until all replacement children are
ready. Empty children count as ready. Memory pressure must retain usable coarse
coverage rather than cause repeated child eviction and regeneration.

Visual and performance validation must exercise cold loading, warm reuse,
camera movement, edited terrain, rapid view changes, negative coordinates,
islands, cave openings, translucent boundaries and configured resource limits.
CPU fixture improvements are not evidence of game FPS or final scenery quality.
