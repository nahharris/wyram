# Coarse scenery generation

The shared immutable generator can produce visual tiles directly. Level zero
imports the exact generated chunk. Level one evaluates every voxel of its
32³ extent, and matches reduction of eight exact chunks, including feature
placement and support. Levels two through six use eight stratified samples
per cell and weight each by its represented subcell volume.

Samples normally use each subcell's midpoint. In the stratum containing the
configured sea level, a midpoint above the sea moves down to the sea-level
voxel. Midpoints below it stay put. This preserves a thin sea surface that
would otherwise disappear from the upper tile. Saved-edit collection uses
these same positions, including when the move crosses a chunk boundary.
Level zero and level one remain exact.

Every level evaluates at most 32³ samples and 32² terrain columns. Terrain
columns are reused across vertical samples. Decoration candidates are gathered
only for a sampled column, with the same anchor placement, biome selection,
shape and support rules as exact generation. This avoids enumerating every
feature anchor in a large tile's entire horizontal area. Vertically empty
tiles return immediately. Coarse tile extents must remain inside the supported
world coordinate range; origin arithmetic is checked before narrowing.

These are volumetric proxies: sampled caves, islands and overhangs can remain
separate from the main terrain. Higher levels estimate occupancy; they do not
claim the exact counts provided by reduction of complete leaf data. Unsampled
thin geometry and small openings can disappear, and material choice remains
approximate. Sampling alone is insufficient for a final visual quality target.
Selection, refinement, transitions and visual validation must account for this.

The engine's dirty-CPU generator operation accepts at most two tile keys per
call and returns encoded tiles in input order. It uses the existing native
resource without activating region actors. Runtime integration now incorporates
known saved edits, revision invalidation, bounded caches, streaming and drawing;
see [distant scenery integration](distant-scenery-runtime.md) for current limits
and remaining acceptance work.

An optimized fixture recorded on 2026-10-03 alternated twelve matched pairs.
Exact level-one generation plus reduction had a median of 3.50180 ms; direct
generation had a median of 1.69620 ms, with byte-equivalent tiles. Sampled mean
times over twelve calls were 1.60797 ms at level two, 1.01366 ms at level four,
and 0.85481 ms at level six. The fixture used default generation settings and
no decoration features. These are CPU costs, not game FPS measurements; other
development processes were running.

Tests verify exact leaf and level-one parity with decoration present, negative
coordinates, a separate world-space sample oracle, encoded roundtrips,
generation limits, and native batch/error behavior.

```powershell
mise exec -- cargo test --manifest-path native/Cargo.toml -p wyram_core --test scenery_generation --locked
mise exec -- cargo test --manifest-path native/Cargo.toml -p wyram_core --test scenery_generation benchmark_scenic_generation --profile perf --locked -- --ignored --nocapture
```
