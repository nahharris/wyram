# Resident blended geometry

Camera movement changes the ordering of transparent faces. It does not change
their positions, colors or opacity. The client now retains the vertex stream
and uploads a globally ordered `u32` index stream when the camera moves.

Chunk replacement or removal rebuilds the resident stream and its cached face
centers. Identical replacements, absent empty chunks and opaque-only chunks do
not invalidate blended content. A stationary camera with unchanged content
requires neither a sort nor an upload.

The ordering remains descending squared distance from the camera to each face
center. The original chunk/face position supplies an explicit tie-breaker,
including after repeated camera changes. Both triangles of each face retain
their original vertex order. This preserves the existing global alpha ordering.

## Measurements

An alternating, eight-pair CPU fixture contains 20,000 transparent faces. The
reference collects the vertex stream and uses cached distance-key sorting; the
new path sorts compact ranks and builds indices from resident geometry. Both
paths start each update from canonical chunk/face order. The new path's initial
geometry preparation is outside the camera-update measurement.

Recorded on 2026-10-03:

| Build | Reference median CPU | Resident median CPU | Reduction |
| --- | ---: | ---: | ---: |
| Debug | 10.8460 ms | 6.6290 ms | 38.9% |
| Perf | 1.2169 ms | 0.2503 ms | 79.4% |

The camera-update payload falls from 3,360,000 vertex bytes to 480,000 index
bytes, a reduction of 85.7%. These figures measure the CPU fixture and payload
size, not GPU execution, full game frame time or flight FPS. Other development
processes were running during measurement; alternating pairs limit ordering
bias but do not eliminate system noise.

Geometry changes upload both vertices and indices. The GPU stores the additional
24 index bytes per face beside the existing 168 vertex bytes. CPU residency also
includes cached centers and reusable ordering/index arrays. Buffer capacities
grow as needed and are retained for reuse; this slice does not add a world
residency budget or distant-terrain LOD.

## Validation

The normal test suite checks camera reversals, stable distance ties, identical
replacement, edits, unloads and exact ordering for a large fixture, including
nonfinite distance keys. A manual offscreen test compares rendered RGBA pixels
against the vertex-stream reference during camera changes, replacement and
removal. It passed on the RTX 4050 Laptop GPU with the Vulkan backend.

Run the focused checks with:

```powershell
mise exec -- cargo test --manifest-path native/Cargo.toml -p wyram_client transparency --locked
mise exec -- cargo test --manifest-path native/Cargo.toml -p wyram_client resident_blended_draw_matches_vertex_reference_pixels --locked -- --ignored --nocapture
mise exec -- cargo test --manifest-path native/Cargo.toml -p wyram_client benchmark_resident_blended_geometry --locked -- --ignored --nocapture --test-threads=1
mise exec -- cargo test --manifest-path native/Cargo.toml -p wyram_client benchmark_resident_blended_geometry --profile perf --locked -- --ignored --nocapture --test-threads=1
```
