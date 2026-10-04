# Scenic voxel summaries

The native core now provides immutable, visual-only 16³ voxel tiles. Each level
doubles cell width. Level zero imports an exact packed chunk; eight complete
sibling tiles reduce to one parent. This data supplies neither collision nor
simulation authority.

Tile coordinates address the grid at their own level. Parent coordinates use
Euclidean division, including for negative positions. Origins use `i64`
arithmetic so extreme tile coordinates do not overflow. Supported levels are
zero through ten: the largest cell spans 1,024 units and its tile spans 16,384
units. This is a representation limit, not an implemented view distance.

Each cell records a representative material, an exact non-air sample count for
data derived from exact chunks, a mask of occupied child octants, and whether
material mixing occurred. A single occupied sample remains nonempty through
successive reductions; partial occupancy and mixed materials remain available
as refinement hints.

Representatives use occupancy-weighted child materials with the lower handle
breaking ties. At higher levels this is an approximation: child summaries do
not retain full material histograms. The mask describes immediate child
occupancy, not the entire shape inside them. These summaries alone do not
guarantee a preserved bridge silhouette, cave opening or liquid boundary.
Meshing and selection must use refinement hints and material contracts when
deciding whether a proxy is acceptable at its projected size.

## Storage and validation

Uniform tiles retain one inline cell. Empty tiles need no allocated cell grid.
Mixed tiles use a dense grid. `resident_cell_bytes` reports cell payload only:
zero for implicit empty data, eight bytes for a uniform nonempty cell, and
32,768 bytes for a dense grid. Fixed tile metadata and allocator overhead must
also be included in any future cache budget.

Reduction validates all eight keys before accepting data, including empty
children. Input order is irrelevant; duplicate, unrelated or mixed-level
children are rejected. Cell sample counts fit `u32` at the supported maximum,
while tile totals use `u64`.

Tests compare every cell of a parent against a separate world-space oracle and
cover all axes, negative coordinates, arbitrary arrival order, material ties,
bad input, maximum-level counts and recursive survival of a single voxel.

A manual optimized-build fixture, recorded on 2026-10-03, averaged 0.00005 ms
for empty siblings, 0.19740 ms for solid siblings, and 0.25102 ms for mixed
siblings over 1,000 reductions of each kind. This measures reduction of existing
data, not distant generation, cache I/O, meshing or rendering. Other development
processes were running; these samples are a cost baseline, not a comparative
speedup claim.

```powershell
mise exec -- cargo test --manifest-path native/Cargo.toml -p wyram_core --test scenery --locked
mise exec -- cargo test --manifest-path native/Cargo.toml -p wyram_core --test scenery benchmark_visual_voxel_reduction --profile perf --locked -- --ignored --nocapture
```

## Integration boundaries

This slice does not load or render distant tiles. The next integration must
define a public Elixir contract for visual generation and reduction policy,
versioned packed transport, owner-managed edit revisions, bounded scenery
workers/cache residency, and renderer selection with complete parent/child
handoff. Expensive bulk operations belong in native workers; distant visuals
must not activate gameplay regions or block rendering on a GenServer.

Generating every full-resolution chunk before reduction is useful for parity
checks but is not a suitable sole strategy for unseen horizons. Coarse
generation needs a separately validated path using the same world seed,
generator configuration and feature placement. Known edits must invalidate the
affected visual ancestors before stale cached scenery can be reused.
