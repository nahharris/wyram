# Declarative plugin packages

Wyram plugins declare content through the public `wyram_plugin_api`. The compiler validates declarations and dependencies, expands templates, validates capability configurations, and lowers supported content into compiled catalogs. The engine consumes those catalogs at startup. It does not execute block, terrain, or character catalog callbacks.

## Package identity and composition

`mix.exs` is the single source of package identity and dependencies:

```elixir
[
  app: :forest,
  version: "0.1.0",
  compilers: [:wyram_prepare] ++ Mix.compilers() ++ [:wyram],
  wyram_plugin: Forest,
  deps: [
    {:wyram_plugin_api, path: "../../apps/wyram_plugin_api"},
    {:wyram, path: "../wyram"}
  ]
]
```

The compiler derives ID `"forest"` from `:app` and the release version from `:version`. Renaming the application changes persistent content identity. Direct Mix dependencies with compiled Wyram catalogs become required plugin dependencies; ordinary libraries do not. A plugin dependency without its catalog fails compilation. References through a transitive dependency require adding that plugin as a direct Mix dependency. The official base game is application `:wyram`; the engine and public API are `:wyram_engine` and `:wyram_plugin_api`. The repository examples use local path dependencies; registry publication is a separate delivery step.

```elixir
defmodule Forest do
  use Wyram.Plugin

  catalog Forest.Blocks
  catalog Forest.Biomes
  catalog Forest.Shaping
  catalog Forest.Profiles
  catalog Forest.Models
  catalog Forest.Characters
  catalog Forest.WorldGen

  game Forest.Game
end

defmodule Forest.Blocks do
  use Wyram.Plugin.Catalog, kind: :block
  include Forest.Blocks.Ground
  include Forest.Blocks.Wooden
end

defmodule Forest.Blocks.Ground do
  use Wyram.Plugin.Catalog, kind: :block
  defblock Moss do
    capability %Wyram.Capability.Material{color: {75, 120, 60}}
  end
end
```

Each catalog is optional. `catalog Module` reads the kind from the compiled catalog; the kind is declared once with `use Wyram.Plugin.Catalog, kind: :block`. Mix supplies the plugin owner to catalogs and game composition, so these modules need no `plugin:` option. They may live under any namespace. Catalogs may contain declarations, includes, or both, and may nest includes. Duplicate inclusion, cycles, foreign ownership, missing modules, unsupported kinds, and incompatible included kinds are build errors. `provider Module` explicitly registers extension capability providers. Small plugins can also declare blocks directly in the entrypoint.

Developers choose their own module names. All owned modules must have valid Elixir names and must not collide with another package or an existing VM module, including an available but unloaded module. There is no `WyramMods` prefix requirement. Generated declarations stay under the plugin entry namespace, so `Moss` above becomes `Forest.Blocks.Moss` even when its family or source file changes. Helpers and catalog names must avoid generated declaration names.

Content can live directly under `lib/`, as it does in the official game:

```text
mix.exs
lib/
  forest.ex
  blocks.ex
  blocks/
    ground.ex
    wooden.ex
    machines/
      furnace.ex
  biomes.ex
  biomes/
    woodland.ex
  shaping.ex
  profiles.ex
  models.ex
  models/
    dwarf_builder.ex
  characters.ex
  world_gen.ex
  game.ex
priv/
  assets/
```

File paths are conventions, not registration rules. A `lib/forest/` namespace directory is equally valid. The compiler follows explicit module references and never discovers content by scanning a content folder. The official entrypoint is `Wyram`; its composition is `Wyram.GameSetup`, because `Wyram.Game` is the public DSL module.

The API exports formatter rules. A plugin's `.formatter.exs` can use them with:

```elixir
[
  import_deps: [:wyram_plugin_api],
  inputs: ["{mix,.formatter}.exs", "lib/**/*.{ex,exs}"]
]
```

## Shared content declarations

| Kind | Declaration | Public data contract |
| --- | --- | --- |
| `:block` | `defblock` | Capability descriptors and block references |
| `:biome` | `defbiome` | `Wyram.WorldGen.Biome` |
| `:shaping` | `defshaping` | `Wyram.WorldGen.Terrain` landscape tuning |
| `:profile` | `defprofile` | `Wyram.Character.Profile` |
| `:model` | `defmodel` | `Wyram.Character.Model` |
| `:character` | `defcharacter` | Profile/model binding |
| `:worldgen` | `defworldgen` | `Wyram.WorldGen.Config` |

Declarations take a symbol and optional options. The local ID defaults to its snake_case name: `defblock MossStone` has ID `"moss_stone"`. Set `id: "stable_name"` to choose a different identity or preserve it when renaming the symbol. Explicit IDs must be literal strings. Templates have no persistent ID. Non-block bodies are literal maps of domain fields; bodies may be omitted to use schema defaults. Unknown fields, invalid values, unsupported nested structs, and invalid references fail the build, including for unselected content. Refer to other declarations using module aliases inside the DSL; do not call `ref/0`. References are checked against their expected kind and direct dependency ownership. Declaration modules expose `ref/0` returning a kind-tagged `Wyram.Plugin.ContentRef`; blocks retain `Wyram.Block.Ref`. Numeric handles remain engine-owned.

```elixir
defmodule Forest.Profiles do
  use Wyram.Plugin.Catalog, kind: :profile
  defprofile Walker do
    %{fly_enabled: true, radius: Wyram.Units.pixels(3)}
  end
end

defmodule Forest.Characters do
  use Wyram.Plugin.Catalog, kind: :character
  defcharacter Hero do
    %{profile: Forest.Profiles.Walker, model: Forest.Models.Dwarf}
  end
end

defmodule Forest.WorldGen do
  use Wyram.Plugin.Catalog, kind: :worldgen
  defworldgen Wilderness do
    %{shaping: Forest.Shaping.Wilderness, biomes: [Forest.Biomes.Woodland]}
  end
end
```

Supported nested world-generation structs are `Feature`, `Field`, `Carver`, `Islands`, and `Terrain`. Literal `Wyram.Units.pixels/1` and `blocks/1,2` computations are allowed. Arbitrary calls, variables, and anonymous functions are rejected in data bodies.

`shaping:` selects landscape tuning; biomes select surface, soil, rock, and water blocks. Named shaping declarations are useful for reusable custom settings. Omit `shaping:` to use defaults. The compiler lowers this field to the existing generation contract's `terrain` field, preserving generation settings and save identity.

Procedural models use an explicit build-time extension:

```elixir
defmodel Dwarf, build: {Forest.Models.DwarfBuilder, :build}
```

The builder must belong to the same compiled application and export `build/1`. It receives the canonical ID, such as `"forest:dwarf"`, and returns a valid `Wyram.Character.Model` with that ID. Every model is checked, including nested bone/cuboid fields and budgets. The compiler executes this trusted Elixir code and validates its output; it does not prove arbitrary builder behavior or determinism. Runtime consumes the resulting model data without calling the builder. Helper BEAM hashes and compiled output participate in dependency fingerprints.

Characters declare only profile/model bindings. Positions, yaw, pitch, and instance IDs belong to game spawns:

```elixir
defmodule Forest.Game do
  use Wyram.Game
  worldgen Forest.WorldGen.Wilderness
  player Forest.Characters.Hero
  spawn Forest.Characters.Companion, id: "companion", position: {2.5, 71.38, -2.5}
  spawn_policy :surface
end
```

`game Forest.Game` selects this plugin's startup composition. Content-only plugins omit it. A composition selects its player and one generation source. `worldgen Module` uses its biome palettes. For the simple layered generator, use `palette surface: Blocks.Grass, soil: Blocks.Dirt, rock: Blocks.Stone`. Declaring both or neither is an error. Additional spawns are optional; repeated character spawns require distinct instance IDs. The player instance keeps ID `"player"`. The compiler gathers selected models automatically and produces `Wyram.Game.Config`. An owned `Wyram.Game.Provider.build/0` module remains an explicit procedural alternative; return either `worldgen:` data or a `palette:` map, along with any character settings. The output is validated and serialized at build time.

Installed catalogs are validated again as data, including unselected content, typed reference bindings, ownership, and domain budgets. Registration creates immutable lookup tables by content kind and persistent ID; declarations do not allocate processes. Items and broader entities remain unsupported until their runtime contracts exist.

## Authoring blocks

```elixir
defmodule MyPlugin do
  use Wyram.Plugin
  alias Wyram.Capability.Material

  defblock Solid, template: true do
    capability %Material{color: {160, 160, 160}}
  end

  defblock Amber do
    template MyPlugin.Blocks.Solid
    capability %Material{color: {232, 154, 44}}, override: true
  end
end
```

This creates `MyPlugin.Blocks.Amber`. Ordinary Elixir code calls `Amber.ref/0` to obtain a validated `Wyram.Block.Ref`; the persistent identity is `my_plugin:amber`. Numeric handles are assigned only by the engine. Templates have no persistent ID or placement reference. Registered blocks can also serve as templates.

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

Block bodies accept only `template` and `capability` entries. Configuration expressions are constrained literals and named structs, with the supported literal unit helpers. The linker resolves module symbols after all source modules compile, including local forward references. Separate block catalogs use `use Wyram.Plugin.Catalog, kind: :block` and are linked with `catalog Module` and explicit `include Module` declarations.

Extension providers implement `Wyram.Plugin.Provider` and register through explicit `provider Module` declarations. They declare their named configuration struct, supported kinds, configuration schema, and owned descriptor fields, then validate and lower configurations. All registered declarations, templates, and providers are public automatically; there is no export list or visibility option. A reference to another plugin requires its application as a direct Mix dependency.

## Building and packaging

Mix names the entry module with `wyram_plugin: MyPlugin`. The build compiler derives identity and direct plugin dependencies from the Mix project. See the game and example projects for local compiler and path-dependency configuration.

A `.wyrplug` is a ZIP containing generated `manifest.json`, `catalog.term`, and exactly the manifest-listed owned `ebin/Elixir.*.beam` files. The manifest records the plugin ID, release version, dependencies, entry, owned module names, catalog SHA256, OTP major, and Elixir minor. The catalog contains descriptors, declaration identity summaries, BEAM hashes, and required dependency fingerprints. Before hashing and packaging, the compiler normalizes only the serialization order of Elixir checker metadata; executable and literal chunks remain unchanged. Runtime verifies the exact packaged BEAM bytes. The full authoring IR is stored as an opaque compiler payload: dependency builds decode it after validating the interface, while runtime consumes only the summaries and lowered data. Fingerprints bind both the compiler payload and the compiled block/content/game output. Rebuilding a dependency's plugin-owned implementation invalidates downstream catalogs, including changes to provider lowering or helper code. Changes to the shared core compiler or built-in providers require rebuilding all packages; dependency fingerprints do not provide cross-version compatibility for those semantics.

The loader checks archive budgets and paths, runtime compatibility, ownership, BEAM identity/hashes, dependency order/fingerprints, descriptor support, and game configuration before registering content. Plugin BEAM code is trusted and runs with the engine's OS permissions. Install only plugins you trust.

Run `scripts/pack-plugin.ps1` through `mise exec` to compile and package the provided projects. Install the `.wyrplug` in `%LOCALAPPDATA%\Wyram\plugins` or `WYRAM_DATA_DIR\plugins`, then restart. Rebuild all pre-alpha packages after this API replacement. Use `wyram_plugin: Entry` in Mix, `catalog Module` in the entrypoint, and a single `kind:` option in each catalog. Remove repeated `plugin:` options. Procedural game configurations replace the old `terrain:` palette with `palette:` and supply either that palette or `worldgen:`. Previous authoring syntax and compiled packages are incompatible; there are no compatibility adapters or schema-version migrations.

## Compiled game setup and characters

A game plugin names an explicit `game Module` composition or procedural `Wyram.Game.Provider.build/0` module. The compiler validates the generation source and character data. All referenced blocks must be registered by the game or a direct dependency. Procedural builders run at build time; runtime reads the resulting data.

Select the active game with `WYRAM_GAME_PLUGIN` (or the engine's `game:` startup option). Without explicit selection, exactly one installed plugin must provide game configuration. Zero or multiple candidates fail instead of relying on package filename ordering.

Profiles validate movement tuning and body dimensions. Game configurations allow at most 16 models and 16 character instances; each model has at most 32 bones and 64 cuboids. Definitions bind unique character IDs to model IDs and profiles, with one `player`. Ordered bone parents, semantic roles, pivots, cuboids, and attachments remain reusable through the public character API. See `plugins/wyram/lib/models/dwarf_builder.ex` for the original editable dwarf rigs.

Flight is an opt-in public profile capability: `fly_enabled` defaults to `false`; `fly_speed` defaults to 12 blocks/s and `fly_acceleration` to 40 blocks/s^2. Wyram enables it for the player and leaves the companion grounded. Native input detects two separate Space presses within 300 ms and sends a monotonic `flight_request` counter, retained when controls are released so pose coalescing cannot lose the gesture. The shared Elixir owner consumes each request once within the current teleport epoch and approves flight only for enabled profiles. Space rises, Left Shift descends, and the combined direction is normalized to the configured speed. Flight uses the normal batched voxel collision sweeps; downward contact or a stationary foot support probe restores walking. Walls and ceilings keep the character flying. Teleports reset flight and the request counter.

The engine sends models in a client initialization batch and character snapshots carry model IDs and approved movement state. Native animation retargets semantic roles. Character physics remains independent of presentation, and no game plugin imports engine internals.

Valid saved logical IDs retain their numeric handles when new content is added. Invalid, duplicate, unknown, or exhausted mappings fail rather than reinterpreting saved cells. Saves also retain required plugin release versions. The remaining capability phases are tracked in [plugin-framework-plan.md](plugin-framework-plan.md).
