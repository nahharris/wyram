# Wyram

Wyram is an experimental local voxel game built around an Elixir actor simulation and a Rust graphics and computation layer. The default creative game is a compiled plugin using the same API available to other trusted plugins. All artwork and world generation in this repository are original placeholders.

The current slice supports procedural terrain, walking/running, sneaking, crawling, jumping, climbing, floor/wall sliding, rolling, original animated characters and external cameras, alongside block editing and save/load. It is Windows-first. The renderer uses shaded block colors; fluid gameplay, textures, lighting propagation and the full benchmark targets remain upcoming work.

## Windows development

Install [mise](https://mise.jdx.dev/installing-mise.html), Git, GitHub CLI, and Visual Studio 2022 Build Tools with the C++ workload and Windows SDK. Run these commands in PowerShell or Nushell:

```powershell
mise install
mise run setup
mise run dev
```

Run `setup` once to prepare dependencies and the native client. Both `dev` and `dev:agent` rebuild and temporarily stage the Wyram game plugin before launch. When the game exits, the temporary plugin is removed, or the previously installed package is restored. The mise tasks invoke Windows PowerShell themselves, so they work from either shell.

Click the window to capture the mouse. Use WASD to move, Space to jump, Ctrl to sprint, Left Shift to sneak (or slide while running), C to crawl, Q with WASD to roll (Q alone rolls forward), hold Space toward a nearby two/three-block ledge for jump-assisted climbing, the number keys to select a block, left click to remove a block, right click to place it, and Escape to release the mouse. F5 cycles first/third/front-facing views; the captured mouse wheel adjusts external camera distance. Game data and installed plugins live in `%LOCALAPPDATA%\Wyram`, or the directory specified by `WYRAM_DATA_DIR`.

Run `mise run check` and `mise run test` before publishing changes. The test layers are described in [docs/testing.md](docs/testing.md). `mise run package` builds a Windows engine release and native client in `dist/windows`. From that directory, run `powershell -ExecutionPolicy Bypass -File run.ps1` to start the packaged game. The launcher installs the bundled Wyram game plugin into the user data directory if it is absent.

Use `mise run dev:agent` and the [local automation interface](docs/automation.md) to inspect the player and world or send commands from scripts. Use `mise run bench` to record repeatable engine measurements; [benchmarking.md](docs/benchmarking.md) explains the results and comparison tool.

Use `mise run dev:perf` or `mise run dev:agent:perf` for an optimized native client with debug symbols. These use the same plugin staging and cleanup as ordinary development; normal `dev` remains unoptimized. `mise run bench:mesh` compares greedy meshing against the simple test oracle in the same optimized profile. The [performance issue plan](docs/performance-plan.md) lists the remaining approaches and verification gates.

The [gameplay roadmap](docs/gameplay-plan.md) tracks reusable character movement, models, animations and cameras. Walk/run policy and movement tuning live in the public Elixir character profile; a shared fixed-step Elixir owner now controls position and grounded jumping through batched swept collision, providing the foundation for additional traversal. The game includes two original reusable rigs, state-driven animations, and F5 first/third/front camera switching. External mouse-wheel zoom keeps the character head as the edit origin. Use isolated worktrees and PRs targeting the protected main branch for changes.

## Plugins

`plugins/wyram` is the default game. `plugins/example` is a separate package adding an amber block. To build the example, run `mise exec -- powershell -NoProfile -ExecutionPolicy Bypass -File scripts/pack-plugin.ps1 example`, then copy `dist/example.wyrplug` into the game-data `plugins` directory and restart.

Plugins implement `Wyram.Plugin` from the public `wyram_plugin_api` application. Plugin metadata is declared in `mix.exs`; packaging generates the manifest alongside compiled BEAM files. Packages target the declared API, OTP major version, and Elixir minor version. Loading third-party packages runs their BEAM code with the user's OS permissions. Install only plugins you trust.

The plugin API and engine architecture are described in [docs/architecture.md](docs/architecture.md). The public package format is described in [docs/plugins.md](docs/plugins.md). Elixir 1.20's stable gradual type inference runs during compilation; public boundaries also carry typespecs and Dialyzer is part of `mise run check`. Explicit signature syntax is not used because that part of the type system is still under development.

## License

The original Wyram code is MIT licensed. Minecraft and its assets are not included or required.

Character sizes use an eight-pixel design grid per block. The player is 1\3 (1.375 blocks) tall; see Wyram.Units and the gameplay plan for block/pixel notation.
