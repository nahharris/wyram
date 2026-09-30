# Compiled plugin packages

A `.wyrplug` file is a ZIP archive with a generated `manifest.json` and `ebin/Elixir.WyramMods.*.beam`. In the plugin's `mix.exs`, set the Mix project `version` and declare `wyram_plugin: [id: "my_plugin", entry: WyramMods.MyPlugin, dependencies: []]`. The packager derives the API, OTP, and Elixir versions from its active toolchain and lists the compiled plugin modules. Plugin authors do not maintain a source `manifest.json`. The loader checks package size, paths, API/runtime compatibility, duplicate IDs and module names, then loads the listed modules. Package code is trusted and runs with the same OS permissions as the engine.

The entry module implements `Wyram.Plugin`: `blocks/0` defines names and RGB colors, `terrain/0` may provide a layered terrain palette, and `interact/2` defines interaction behavior. Block identifiers are `plugin_id:block_name`; numeric IDs are assigned by the engine at startup and retained in saves, so installing a new plugin does not reinterpret existing blocks. Saves record required plugin versions. Removing or changing a required plugin version still prevents that world from opening until the matching plugin is restored.

Use the Wyram game and example projects as build templates. Run `scripts/pack-plugin.ps1` through `mise exec` to compile and package them. Move the resulting `.wyrplug` into `%LOCALAPPDATA%\Wyram\plugins`, or into `WYRAM_DATA_DIR\plugins`, and restart the game. The renamed game plugin has the ID `wyram`; worlds saved with the old `official` ID are incompatible.

## Character locomotion profiles

The terrain/game provider may implement the optional `player_profile/0` callback, returning a `Wyram.Character.Profile` from the public API:

```elixir
@impl true
def player_profile do
  %{Wyram.Character.Profile.default() | walk_speed: 4.0, run_speed: 8.0}
end
```

The engine validates positive numeric fields up to 100 and requires `run_speed >= walk_speed`. Invalid profiles stop plugin initialization. A plugin without this callback uses the default profile; API version 1 remains compatible. Only the active terrain provider supplies the player profile. A character with different tuning can call the same pure `Wyram.Character.Profile.motion/2` policy in Elixir. Additional postures, traversal capabilities and animation contracts will be introduced with their gameplay implementations, as described in [gameplay-plan.md](gameplay-plan.md).