# Compiled plugin packages

The proposed replacement for this callback-based API is described in [plugin-framework-plan.md](plugin-framework-plan.md). This page documents the current implementation.

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

The engine validates positive numeric fields up to 100 and requires `run_speed >= walk_speed`. Invalid profiles stop plugin initialization. A plugin without this callback uses the default profile; API version 1 remains compatible. Only the active terrain provider supplies the player profile. A character with different tuning can call the same pure `Wyram.Character.Profile.motion/2` policy in Elixir. Profiles now include crouch/prone dimensions and enabled traversal capabilities with validated limits; see [gameplay-plan.md](gameplay-plan.md) for controls and interruption rules.
## Character catalogs and presentation

The active game provider may also implement optional `character_models/0` and `characters/0`. Return lists of public `Wyram.Character.Model` and `Wyram.Character.Definition` values. Every definition supplies a unique ID, model ID, profile, feet position and initial look; exactly one definition is named `player`. The model catalog validates ordered bone parents, semantic roles, local pivots, colored cuboids and named attachment references. `Wyram.Character.Model.compatible?/2` compares semantic roles, allowing different bone names and proportions to share presentation logic. Existing providers without these callbacks retain a default cuboid and player definition.

Use `plugins/wyram/lib/wyram_mods/characters.ex` as the original editable source example. Model and definition catalogs are each limited to 16 entries; models have at most 32 bones and 64 cuboids. Plugin packaging compiles their source with the existing BEAM package pipeline. The engine exports model values in the client initialization batch and snapshots per-character model IDs; no game plugin imports engine internals. Native animation maps approved states to humanoid semantic roles, with safe fallback for missing roles/capabilities. Character physics remains independent of presentation.