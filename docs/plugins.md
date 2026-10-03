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

Duplicate capabilities fail compilation. `override: true` requires an existing capability from the same provider and replaces its complete configuration. Defaults fill missing geometry, collision, and material after authored composition; defaults are not override targets. The backend supports cube geometry, cube or explicitly absent collision, opaque/blended/emissive RGB materials, and finite liquid states. Other shapes, general authored state schemas, propagated light, and movement effects remain unsupported.

## Liquids

```elixir
alias Wyram.Capability.{Collision, Liquid, Material}

defblock Water, id: "water" do
  capability %Collision{shape: :none}
  capability %Liquid{flow_ms: 200, max_level: 7}
  capability %Material{color: {40, 105, 220}, mode: :blended, opacity: 160}
end
```

`Liquid` requires explicitly noncolliding cube geometry. `flow_ms` is an integer in 100..5000; `max_level` is in 1..7. These settings are data consumed by the core flow system, so third-party liquids use the same machinery as the official plugin. Material opacity is 1..254 for `:blended`; `:opaque` and `:emissive` require the default 255. Emissive surfaces retain their color without directional shading; they do not illuminate neighboring cells.

Placement creates a persistent source. Supply falls downward at full height; supported cells spread horizontally with diminishing levels up to `max_level`. Horizontal level `n` has height `(max_level + 1 - n) / (max_level + 1)` blocks. Flowing cells drain without supply. Sources remain until edited; there is no automatic source creation. Solid blocks and other liquid sources cannot be replaced by flow. Different liquids do not react in this foundation.

The registry allocates one source handle plus `max_level` horizontal handles and one falling handle per liquid. Saves retain logical names such as `wyram:water`, `wyram:water#flow_1`, and `wyram:water#falling`; numeric handles remain engine-owned. Only declared sources appear in placement selection. Internal variants cannot be placed through ordinary world edits. Existing saved mappings retain their handles; removed variants or exhausted capacity fail startup.

Region actors own packed cells and deduplicated pending positions. A coordinator samples immutable neighborhoods and requests conditional chunk batches, processing at most eight regions and 64 cells per region per 100 ms tick. Regions validate expected cell handles, persist each changed chunk, and publish one revisioned chunk message. Pending work resumes by scanning liquid cells after an owner or coordinator restart. Cross-region flow uses snapshots and conditional writes without cyclic owner calls; conflicting player edits win and cause reevaluation. Busy worlds may advance flow more slowly than the configured minimum interval.

Water uses seven levels and a 200 ms interval with transparent blue surfaces. Lava uses three levels and an 800 ms interval with emissive orange surfaces. Both remain selectable and noncolliding. Swimming, buoyancy, damage, mixing reactions, and propagated lighting are later systems. World generation can place sources using their public block references once its terrain API supports authored generators.

Block bodies accept only `template` and `capability` entries. Configuration expressions are constrained literals and named structs, not function calls or variables. The linker resolves module symbols after all source modules compile, including local forward references. Separate catalogs use `use Wyram.Plugin.Declarations, plugin: WyramMods.MyPlugin` and are listed in the entry's `declarations:` option. The entry itself contributes automatically.

Extension providers implement `Wyram.Plugin.Provider` and register through the entry's `providers:` option. They declare their named configuration struct, supported kinds, configuration schema, and owned descriptor fields, then validate and lower configurations. All registered declarations, templates, and providers are public automatically; there is no export list or visibility option. A reference to another plugin still requires its ID in `dependencies:` and its project in Mix dependencies.

## Building and packaging

Mix names the entry module with `wyram_plugin: [entry: WyramMods.MyPlugin]` and enables the Wyram compiler around the ordinary Elixir compilers. Identity and content dependencies are declared once in the entry module. See the game and example projects for the complete compiler and path-dependency configuration.

A `.wyrplug` is a ZIP containing generated `manifest.json`, `catalog.term`, and exactly the owned `ebin/Elixir.WyramMods.*.beam` files. The manifest records the plugin ID, release version, dependencies, entry, owned module names, catalog SHA256, OTP major, and Elixir minor. The catalog contains descriptors, declaration identity summaries, BEAM hashes, and required dependency fingerprints. Before hashing and packaging, the compiler normalizes only the serialization order of Elixir checker metadata; executable and literal chunks remain unchanged. Runtime verifies the exact packaged BEAM bytes. The full authoring IR is stored as an opaque compiler payload: dependency builds decode it after validating the interface, while runtime consumes only the summaries and lowered data. Fingerprints bind both the compiler payload and the compiled block/game output. Rebuilding a dependency's plugin-owned implementation invalidates downstream catalogs, including changes to provider lowering or helper code. Changes to the shared core compiler or built-in providers require rebuilding all packages; dependency fingerprints do not provide cross-version compatibility for those semantics.

The loader checks archive budgets and paths, runtime compatibility, ownership, BEAM identity/hashes, dependency order/fingerprints, descriptor support, and game configuration before registering content. Plugin BEAM code is trusted and runs with the engine's OS permissions. Install only plugins you trust.

Run `scripts/pack-plugin.ps1` through `mise exec` to compile and package the provided projects. Install the `.wyrplug` in `%LOCALAPPDATA%\Wyram\plugins` or `WYRAM_DATA_DIR\plugins`, then restart. Rebuild all pre-alpha packages after this API replacement; old callback packages are incompatible. There are no compatibility adapters or schema-version migrations.

## Compiled game setup and characters

A game plugin names an explicit `game:` module implementing `Wyram.Game.Provider.build/0`. This build-time hook can construct procedural rigs and returns validated `Wyram.Game.Config` data: logical terrain references, a character profile, models, and character definitions. Terrain references must resolve to registered blocks owned by the game or an explicit dependency. The compiler invokes the builder; the runtime reads the resulting data.

Select the active game with `WYRAM_GAME_PLUGIN` (or the engine's `game:` startup option). Without explicit selection, exactly one installed plugin must provide game configuration. Zero or multiple candidates fail instead of relying on package filename ordering.

Profiles validate movement tuning and body dimensions. Models and character definitions are each limited to 16 entries; models have at most 32 bones and 64 cuboids. Definitions bind unique character IDs to model IDs and profiles, with one `player`. Ordered bone parents, semantic roles, pivots, cuboids, and attachments remain reusable through the public character API. See `plugins/wyram/lib/wyram_mods/characters.ex` for the original editable dwarf rigs.

Flight is an opt-in public profile capability: `fly_enabled` defaults to `false`; `fly_speed` defaults to 12 blocks/s and `fly_acceleration` to 40 blocks/s². Wyram enables it for the player and leaves the companion grounded. Native input detects two separate Space presses within 300 ms and sends a monotonic `flight_request` counter, retained when controls are released so pose coalescing cannot lose the gesture. The shared Elixir owner consumes each request once within the current teleport epoch and approves flight only for enabled profiles. Space rises, Left Shift descends, and the combined direction is normalized to the configured speed. Flight uses the normal batched voxel collision sweeps; downward contact or a stationary foot support probe restores walking. Walls and ceilings keep the character flying. Teleports reset flight and the request counter.

The engine sends models in a client initialization batch and character snapshots carry model IDs and approved movement state. Native animation retargets semantic roles. Character physics remains independent of presentation, and no game plugin imports engine internals.

Valid saved logical IDs retain their numeric handles when new content is added. Invalid, duplicate, unknown, or exhausted mappings fail rather than reinterpreting saved cells. Saves also retain required plugin release versions. The remaining capability phases are tracked in [plugin-framework-plan.md](plugin-framework-plan.md).
