# Integration tests

Run `mise run setup` once, then `mise run test`. The Windows CI workflow runs the same test task.

The engine tests install two compiled packages from `test/fixtures/plugins` into a fresh data directory for each run. `test_terrain` supplies three deliberately non-game block names and the layered terrain palette; `test_addon` depends on it and adds a block. These packages are test fixtures and are never included in the game release.

The suite checks package loading, palette-driven native terrain, invalid block rejection, chunk edits and persistence, separate region owners and recovery after a region restart, missing-dependency and duplicate-ID rejection, and preservation of saved block IDs when an addon is installed later. The upgrade check starts the engine twice in separate processes so it exercises actual startup and save loading. A separate smoke run starts with only the Wyram game plugin and verifies its terrain contract.

Rust core tests pass arbitrary numeric palettes directly. They do not load a plugin or assume Wyram game block IDs; this keeps the packed voxel layer independent of game content.

The suite also exercises the opt-in loopback control protocol and runs a short benchmark smoke check. Performance results are recorded as JSON, but CI does not set a timing threshold.

Development shutdown tests run the real launcher in a child process with a native fixture that drains the initial view and exits. They check normal exit, nonzero exit, missing executable, bounded termination and staged-plugin cleanup. Client lifecycle tests cover waiting before exit and subscribing afterward. Game launches use a finite session script instead of `mix run --no-halt`, with Erlang input and break-menu handling disabled; launcher tests check option restoration. Interactive Nushell Ctrl+C behavior requires a manual terminal retest.

Native mesh tests expand greedy rectangles into oriented unit faces and compare coverage, triangle winding and colors against the retained simple mesher. Fixtures include mixed materials (including equal colors with different IDs), cavities, checkerboards, randomized voxels, procedural terrain, seams at negative coordinates and edits. Existing worker-bound, stale-result, unload/reload and collision tests remain active. Windows CI also runs native tests under the optimized `perf` profile. Launcher tests exercise actual builds and plugin staging/restoration for both profiles, replacing only the indefinite final game run; desktop/GPU captures are a separate manual verification surface.

Outbound IPC tests gate a writer to prove queue admission completes while I/O is blocked, enforce the edit capacity plus reserved latest pose, decode framed packets to check edit order and pose coalescing, and reject submissions after a single failure notification. Windows-only tests exercise real delayed and closed anonymous pipes. The matched slow-receiver benchmark is opt-in via `mise run bench:outbound`; CI runs correctness tests without timing thresholds. See [the design](outbound-ipc.md) for disconnect and shutdown delivery limits.

## Liquid coverage

`mise run test` also runs `scripts/test-liquids.exs` inside the packaged Wyram smoke game. It checks source placement, falling, flow across the x=64 region boundary, noncollision, owner restart, persistence, and drainage after source removal in a sealed channel. Unit tests cover invalid declarations, registry growth and rejected state mappings, horizontal attenuation, material height/opacity, liquid seam culling, conditional native batch writes, and transparent face sorting.

## World generation coverage

`mise run test` also runs the packaged world generation smoke check: 512-block bounds with sea level zero, sampled ocean/mountain/island fields, safe surface spawning, rejected out-of-range edits and liquid writes, save fingerprints and restored seed authority. Native tests compare chunk data against independent world-space voxel sampling at seams, exercise carvers and cross-boundary features, and check biome blend normalization and invalid parameter rejection. Public API tests cover `defbiome`, bounded data validation and reference ownership at compilation and installation. Client tests decode batched chunk packets with negative and high vertical coordinates. The atlas exporter described in [world-generation.md](world-generation.md) provides field inspection without a GPU.
