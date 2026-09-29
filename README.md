# Wyram

Wyram is an experimental local voxel game built around an Elixir actor simulation and a Rust graphics and computation layer. The default creative game is a compiled plugin using the same API available to other trusted plugins. All artwork and world generation in this repository are original placeholders.

The current slice supports procedural terrain, walking and jumping, block placement and removal, save/load, and a separately packaged example block. It is Windows-first. The renderer currently uses shaded block colors; textures, lighting propagation, more robust movement authority, and the full benchmark targets are upcoming work.

## Windows development

Install [mise](https://mise.jdx.dev/installing-mise.html), Git, GitHub CLI, and Visual Studio 2022 Build Tools with the C++ workload and Windows SDK. In PowerShell:

```powershell
mise install
mise run setup
mise run dev
```

Click the window to capture the mouse. Use WASD to move, Space to jump, Ctrl to sprint, the number keys to select a block, left click to remove a block, right click to place it, and Escape to release the mouse. Game data and installed plugins live in `%LOCALAPPDATA%\Wyram`, or the directory specified by `WYRAM_DATA_DIR`.

Run `mise run check` and `mise run test` before publishing changes. The test layers are described in [docs/testing.md](docs/testing.md). `mise run package` builds a Windows engine release and native client in `dist/windows`. From that directory, run `powershell -ExecutionPolicy Bypass -File run.ps1` to start the packaged game. The launcher installs the bundled Wyram game plugin into the user data directory if it is absent.

## Plugins

`plugins/wyram` is the default game. `plugins/example` is a separate package adding an amber block. To build the example, run `mise exec -- powershell -NoProfile -ExecutionPolicy Bypass -File scripts/pack-plugin.ps1 example`, then copy `dist/example.wyrplug` into the game-data `plugins` directory and restart.

Plugins implement `Wyram.Plugin` from the public `wyram_plugin_api` application. Plugin metadata is declared in `mix.exs`; packaging generates the manifest alongside compiled BEAM files. Packages target the declared API, OTP major version, and Elixir minor version. Loading third-party packages runs their BEAM code with the user's OS permissions. Install only plugins you trust.

The plugin API and engine architecture are described in [docs/architecture.md](docs/architecture.md). The public package format is described in [docs/plugins.md](docs/plugins.md). Elixir 1.20's stable gradual type inference runs during compilation; public boundaries also carry typespecs and Dialyzer is part of `mise run check`. Explicit signature syntax is not used because that part of the type system is still under development.

## License

The original Wyram code is MIT licensed. Minecraft and its assets are not included or required.
