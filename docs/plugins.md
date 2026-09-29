# Compiled plugin packages

A `.wyrplug` file is a ZIP archive with `manifest.json` and `ebin/Elixir.WyramMods.*.beam`. A package declares `id`, `version`, `api`, `otp`, `elixir`, `entry`, `modules`, and `dependencies`. The loader checks package size, paths, API/runtime compatibility, duplicate IDs and module names, then loads the listed modules. Package code is trusted and runs with the same OS permissions as the engine.

The entry module implements `Wyram.Plugin`: `blocks/0` defines names and RGB colors, `terrain/0` may provide a layered terrain palette, and `interact/2` defines interaction behavior. Block identifiers are `plugin_id:block_name`; numeric IDs are assigned by the engine at startup and retained in saves, so installing a new plugin does not reinterpret existing blocks. Saves record required plugin versions. Removing or changing a required plugin version still prevents that world from opening until the matching plugin is restored.

Use the official and example projects as build templates. Run `scripts/pack-plugin.ps1` through `mise exec` to compile and package them. Move the resulting `.wyrplug` into `%LOCALAPPDATA%\Wyram\plugins`, or into `WYRAM_DATA_DIR\plugins`, and restart the game.
