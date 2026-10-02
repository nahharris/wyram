# Declarative plugin packages

Wyram plugins declare content through the public `wyram_plugin_api`. The compiler validates declarations and dependencies, expands templates, validates capability configurations, and lowers supported content into compiled catalogs. The engine consumes those catalogs at startup. It does not execute block, terrain, or character catalog callbacks.

## Authoring blocks

```elixir
defmodule WyramMods.MyPlugin do
  use Wyram.Plugin, id: "my_plugin"
  alias Wyram.Capability.Material

  defblock Solid, template: true do
    capability %Material{color: {160, 160, 160}}
  end

  defblock Amber, id: "amber" do
    template WyramMods.MyPlugin.Blocks.Solid
    capability %Material{color: {232, 154, 44}}, override: true
  end
end
```

This creates `WyramMods.MyPlugin.Blocks.Amber`. Ordinary Elixir code calls `Amber.ref/0` to obtain a validated `Wyram.Block.Ref`; the persistent identity is `my_plugin:amber`. Numeric handles are assigned only by the engine. Templates have no persistent ID or placement reference. Registered blocks can also serve as templates.

Duplicate capabilities fail compilation. `override: true` requires an existing capability from the same provider and replaces its complete configuration. Defaults fill missing geometry, collision, and material after authored composition; defaults are not override targets. The initial backend supports solid cube geometry/collision and opaque RGB materials. Unsupported shapes, transparency, states, light, and movement effects fail explicitly until their backend phases are implemented.

Block bodies accept only `template` and `capability` entries. Configuration expressions are constrained literals and named structs, not function calls or variables. The linker resolves module symbols after all source modules compile, including local forward references. Separate catalogs use `use Wyram.Plugin.Declarations, plugin: WyramMods.MyPlugin` and are listed in the entry's `declarations:` option. The entry itself contributes automatically.

Extension providers implement `Wyram.Plugin.Provider` and register through the entry's `providers:` option. They declare their named configuration struct, supported kinds, configuration schema, and owned descriptor fields, then validate and lower configurations. All registered declarations, templates, and providers are public automatically; there is no export list or visibility option. A reference to another plugin still requires its ID in `dependencies:` and its project in Mix dependencies.

## Building and packaging

Mix names the entry module with `wyram_plugin: [entry: WyramMods.MyPlugin]` and enables the Wyram compiler around the ordinary Elixir compilers. Identity and content dependencies are declared once in the entry module. See the game and example projects for the complete compiler and path-dependency configuration.

A `.wyrplug` is a ZIP containing generated `manifest.json`, `catalog.term`, and exactly the owned `ebin/Elixir.WyramMods.*.beam` files. The manifest records the plugin ID, release version, dependencies, entry, owned module names, catalog SHA256, OTP major, and Elixir minor. The catalog contains descriptors, declaration identity summaries, BEAM hashes, and required dependency fingerprints. The full authoring IR is stored as an opaque compiler payload: dependency builds decode it after validating the interface, while runtime consumes only the summaries and lowered data. Fingerprints bind both the compiler payload and the compiled block/game output. Rebuilding a dependency's plugin-owned implementation invalidates downstream catalogs, including changes to provider lowering or helper code. Changes to the shared core compiler or built-in providers require rebuilding all packages; dependency fingerprints do not provide cross-version compatibility for those semantics.

The loader checks archive budgets and paths, runtime compatibility, ownership, BEAM identity/hashes, dependency order/fingerprints, descriptor support, and game configuration before registering content. Plugin BEAM code is trusted and runs with the engine's OS permissions. Install only plugins you trust.

Run `scripts/pack-plugin.ps1` through `mise exec` to compile and package the provided projects. Install the `.wyrplug` in `%LOCALAPPDATA%\Wyram\plugins` or `WYRAM_DATA_DIR\plugins`, then restart. Rebuild all pre-alpha packages after this API replacement; old callback packages are incompatible. There are no compatibility adapters or schema-version migrations.

## Compiled game setup and characters

A game plugin names an explicit `game:` module implementing `Wyram.Game.Provider.build/0`. This build-time hook can construct procedural rigs and returns validated `Wyram.Game.Config` data: logical terrain references, a character profile, models, and character definitions. Terrain references must resolve to registered blocks owned by the game or an explicit dependency. The compiler invokes the builder; the runtime reads the resulting data.

Select the active game with `WYRAM_GAME_PLUGIN` (or the engine's `game:` startup option). Without explicit selection, exactly one installed plugin must provide game configuration. Zero or multiple candidates fail instead of relying on package filename ordering.

Profiles validate movement tuning and body dimensions. Models and character definitions are each limited to 16 entries; models have at most 32 bones and 64 cuboids. Definitions bind unique character IDs to model IDs and profiles, with one `player`. Ordered bone parents, semantic roles, pivots, cuboids, and attachments remain reusable through the public character API. See `plugins/wyram/lib/wyram_mods/characters.ex` for the original editable dwarf rigs.

The engine sends models in a client initialization batch and character snapshots carry model IDs and approved movement state. Native animation retargets semantic roles. Character physics remains independent of presentation, and no game plugin imports engine internals.

Valid saved logical IDs retain their numeric handles when new content is added. Invalid, duplicate, unknown, or exhausted mappings fail rather than reinterpreting saved cells. Saves also retain required plugin release versions. The remaining capability phases are tracked in [plugin-framework-plan.md](plugin-framework-plan.md).
