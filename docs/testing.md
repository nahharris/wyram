# Integration tests

Run `mise run setup` once, then `mise run test`. The Windows CI workflow runs the same test task.

The engine tests install two compiled packages from `test/fixtures/plugins` into a fresh data directory for each run. `test_terrain` supplies three deliberately non-game block names and the layered terrain palette; `test_addon` depends on it and adds a block. These packages are test fixtures and are never included in the game release.

The suite checks package loading, palette-driven native terrain, invalid block rejection, chunk edits and persistence, separate region owners and recovery after a region restart, missing-dependency and duplicate-ID rejection, and preservation of saved block IDs when an addon is installed later. The upgrade check starts the engine twice in separate processes so it exercises actual startup and save loading. A separate smoke run starts with only the Wyram game plugin and verifies its terrain contract.

Rust core tests pass arbitrary numeric palettes directly. They do not load a plugin or assume Wyram game block IDs; this keeps the packed voxel layer independent of game content.

The suite also exercises the opt-in loopback control protocol and runs a short benchmark smoke check. Performance results are recorded as JSON, but CI does not set a timing threshold.
