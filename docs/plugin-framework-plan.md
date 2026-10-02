# Declarative plugin framework plan

Status: phases 1-3 implement the public contracts, declaration compiler and compiled-package replacement. Phases 4-8 remain planned.

## Goal and scope

Make Wyram plugins primarily declarations compiled into a game registry. Core and extension plugins provide generic capabilities; content plugins compose them through the public API. Blocks are the first declaration kind. Items, entities, particles, effects, events and GUI should later reuse the declaration compiler, references, dependency linking and diagnostics, while supplying their own domain contracts.

This is a pre-alpha replacement. Break existing callbacks, packages, protocol tables and saves wherever needed. Do not add compatibility adapters, migration infrastructure, schema version bumps or parallel legacy implementations. Rebuild plugins and reset development worlds when the representation changes. Package identity/release metadata and genuine BEAM toolchain compatibility checks are separate concerns.

## Current state

- The public API provides logical block references, typed declaration IR, source diagnostics and capability provider contracts. The first backend supports opaque RGB cubes with solid cube collision.
- The declaration compiler collects inline and split catalogs, validates dependency/template composition, and writes deterministic catalogs plus exported interfaces. Mix configuration names the entry; plugin identity and dependencies live in the DSL.
- The package/runtime replacement consumes compiled catalogs, verifies package ownership and dependency fingerprints, and assigns runtime block handles. Terrain and characters are compiled through an explicit public game builder; runtime startup does not invoke declaration or provider callbacks.
- Regions continue to own packed chunks. Native code still consumes batched cube data and palettes. Later phases must implement state, shape, material and lighting behavior before those capabilities become accepted content.

## Public authoring model

Use `Wyram.Plugin` as the framework entry point, replacing its current callback contract. Mix names the entry module and enables the Wyram compiler; identity and content dependencies are declared once in that entry module. Packaging derives them from its compiled interface.

Each `defblock` produces a named declaration module, giving authors an importable symbol similar to a registered Java block constant. Supported authoring syntax:

~~~elixir
defmodule WyramMods.Wyram do
  use Wyram.Plugin, id: "wyram"

  alias Wyram.Capability.{Geometry, Collision, Material}
  alias Wyram.Shape.Cube

  defblock SolidBlock, id: "solid_block" do
    capability %Geometry{shape: %Cube{}}
    capability %Collision{shape: %Cube{}}
    capability %Material{color: {160, 160, 160}, mode: :opaque}
  end

  defblock Ice, id: "ice" do
    template WyramMods.Wyram.Blocks.SolidBlock
    capability %Material{color: {180, 220, 255}, mode: :opaque}, override: true
  end
end
~~~

This generates `WyramMods.Wyram.Blocks.SolidBlock` and `WyramMods.Wyram.Blocks.Ice`. Authors may alias these modules and use the symbols directly in DSL expressions such as `template SolidBlock`. The explicit local ID separates the Elixir symbol from the persistent identity: `Ice` identifies the declaration module, while `"wyram:ice"` identifies the content externally. Renaming a module does not implicitly rename its content ID.

Generated modules expose compiler-owned declaration metadata and `ref/0`. Ordinary gameplay code uses `WyramMods.Wyram.Blocks.Ice.ref()` to obtain a `Wyram.Block.Ref`. These modules are declarations, not world instances, actors or registration side effects. They never allocate numeric registry handles during source compilation.

Within the DSL, reference-bearing fields consume module symbols and resolve them against collected declarations or dependency interfaces; they do not execute `ref/0` or arbitrary functions to discover their target. The compiler verifies that the symbol exists, is a Wyram declaration, has the required kind, is automatically public and belongs to this plugin or an explicit dependency. An Elixir alias by itself is not proof of any of these conditions.

Support local forward references independently of source order, including references across explicitly listed declaration modules. Collect and normalize symbols first, then resolve them. Do not call `Code.ensure_compiled!` on sibling declaration modules from inside macros or introduce circular BEAM compilation dependencies merely to reference declarations. Cross-plugin symbols resolve through dependency interfaces after required dependencies build.

For larger plugins, `use Wyram.Plugin.Declarations, plugin: WyramMods.Wyram` lets separate modules contribute catalogs explicitly listed by the entry. All declarations and capability providers are automatically public, including templates; there are no export lists or visibility modifiers. Ordinary implementation helper modules are not declarations. All contributions use the plugin's generated declaration namespace; splitting a source module does not change the symbol or content ID. Reject duplicate generated module names and collisions with handwritten modules as well as duplicate content IDs. Discover declarations through that explicit module list, rather than executing arbitrary catalog callbacks or depending on filesystem ordering.

Shared declarations may use approved templates and constants with deterministic expansion. Keep the accepted expression language small: literals, named structs, declaration-module symbols, state selectors and registered templates. Unsupported dynamic expressions fail with a source diagnostic instead of silently becoming runtime declarations.

### Template declarations

A registered block may supply reusable declaration data, as `SolidBlock` does above. A template-only declaration supplies reusable data without becoming a placeable block or receiving a registry handle. Both have named module symbols and compiler metadata, but their roles remain distinct.

Use `defblock Solid, template: true` for a template-only declaration. This is the same declaration macro as a registered block, with an explicit role; there is no separate template macro. A template does not require a persistent block ID. Validate `template` as a boolean option and retain the role in generated declaration metadata.

The `template` operation accepts an eligible block or block-template symbol; a placement field accepts a registered block only. Template-only symbols cannot masquerade as `Wyram.Block.Ref` values. Copy approved declaration data, never source identity, registry handles or mutable instance data. Define composition rules for each inherited field; do not make inheritance a generic map merge.

Check template cycles and expansion budgets independently of plugin dependency cycles, including cycles between declarations in one plugin. Report the expansion path and original source locations.

A plugin may also export providers and explicit behaviour handlers. The framework should make data declarations easy and imperative gameplay exceptional, without forbidding it.

The first replacement uses an explicit `game:` module implementing the public `Wyram.Game.Provider` contract. Its build-time `build/0` returns a validated `Wyram.Game.Config` with logical terrain block references, character profiles/models and the initial roster. The compiler validates and serializes this data; runtime never calls the builder. Select a game through the startup option or `WYRAM_GAME_PLUGIN`; automatic selection succeeds only when exactly one installed plugin supplies a game. These domains can gain named declaration macros when their broader entity/content consumers are ready.

## Identity and validation guarantees

| Concern | Representation and guarantee |
| --- | --- |
| Plugin/block identity | Validated namespace plus explicit local ID. Canonical strings such as `wyram:ice` at persistence/import boundaries; generated declaration modules in the DSL and `Wyram.Block.Ref` values in gameplay code. |
| Declaration symbols | Generated modules such as `WyramMods.Wyram.Blocks.Ice`. Metadata/linking verifies existence, kind, role and dependency ownership; a module alias alone is not validation. |
| Local state symbols | Finite source-authored atoms such as `:facing` and `:north`. An atom alone does not prove that a state field or value exists. |
| Capability identity | Imported provider/configuration modules, never free-form capability-name strings. The compiler verifies registration and provider contracts. |
| Configuration | Named structs with required fields, public typespecs and domain schemas. Struct field checks are supplemented by value/range/reference validation. |
| Native handles | Opaque registry-assigned integers. Plugins never hard-code IDs or rely on their width/order. |
| External input | Parse and resolve names against the registry. Never create atoms from arbitrary package, save or network strings. |

Elixir 1.20 adds gradual inference, but it does not give these declarations a complete static proof merely through typespecs. Wyram's domain compiler must enforce its own schema and linking guarantees. Keep typespecs for documentation and analysis; use compiler warnings and Dialyzer as complementary checks. See the [Elixir 1.20 release](https://elixir-lang.org/blog/2026/06/03/elixir-v1-20-0-released/).

Compilation should reject unknown configuration fields, invalid scalar values, duplicate declarations/module symbols, unintended capability replacement, missing override targets, template cycles, wrong reference kinds/roles, unresolved required references, invalid state defaults/transitions, unsupported provider combinations and exceeded expansion budgets. It cannot prove arbitrary handler behaviour, future installed packages, world conditions or incoming commands correct.

## Compiler and registry pipeline

1. **Collect:** macros retain source locations and collect declarations into a typed intermediate representation (IR), with one symbol table per plugin. Resolve local module-symbol forward references after collection; retain template and override provenance. Do not evaluate arbitrary declaration AST.
2. **Validate locally:** declaration kinds and providers check syntax, fields, value domains and finite state declarations. Retain unresolved declaration symbols for linking; defer composition checks that require dependency/template data. Provider validators/compilers are trusted build code; declarative restrictions are not an Elixir sandbox.
3. **Link and validate composition:** after Elixir modules compile, resolve declared dependencies, provider exports, declaration symbols, tags, assets and handlers through their exported interfaces. Check reference kinds/roles and cycles, expand local/dependency templates deterministically, apply explicit replacements and validate the final peer requirements and field ownership. Required dependencies must be available to build. Report cycle paths; do not recursively force compilation from inside macros.
4. **Lower:** compile declarations to immutable logical catalog data and supported backend descriptors. Preserve source information for diagnostics. Bounds and deterministic ordering apply to both compilation and emitted data.
5. **Package:** ship the validated catalog, dependency interface, assets, handler/provider BEAM modules and generated manifest. The packager consumes compiler output rather than independently interpreting declarations.
6. **Link installed set:** verify the actual installed dependency graph, module ownership, exports, backend support and cross-package consistency. Allocate packed state handles and publish one coherent registry. Reject failure before world startup.
7. **Run:** owners consume compiled tables and validate intents/commands against current world state. No DSL expansion or generic callback dispatch in voxel hot loops.

Implement `Mix.Tasks.Compile.Wyram` after the Elixir compiler. Plain `mix compile --warnings-as-errors` must fail on domain errors, not only packaging. Track source, provider, dependency interface and asset changes in its build manifest; implement clean support and remove deleted exports. See [Mix compiler tasks](https://mix.hexdocs.pm/1.20.4/Mix.Task.Compiler.html).

Distinguish build dependencies needed for provider code/interface availability from installed plugin dependencies needed in the game. Package modules owned by this plugin only; never copy a dependency's BEAM modules into multiple packages. Initially require explicit acyclic dependencies; optional dependencies and hot reload are deferred.

Diagnostic example: `blocks.ex:18: block Lamp (wyram:lamp) / Light.emission: expected integer 0..15, received 20`. Diagnostics retain the originating declaration even after template expansion and identify both sides of a conflict.

## Capability provider contract

A provider has a configuration struct/schema, supported declaration kinds, required peer capabilities, owned descriptor fields, compile validation/lowering and optional event subscriptions. Core providers and extension providers use the same public contract. The framework separates author configuration from provider output and validates both.

Composition is explicit: a descriptor field has one owner unless it defines a documented combining operator. For example, multiple contact effects may append in a stable order; two competing collision shapes are an error. Never choose a winner from map traversal order. Behaviour ordering follows declared phases/dependencies, with cycle checks and deterministic tie breaking.

### Explicit capability replacement

`capability %Surface{friction: 0.08}, override: true` intentionally replaces an already declared or inherited capability. Resolve capability identity to its registered provider module before checking duplicates, so aliases cannot evade validation.

- Without `override: true`, a second declaration of the same capability is a compile error, including duplicates introduced by template expansion.
- With `override: true`, a previous capability must exist in the composed declaration. A missing target is a compile error, catching stale or misspelled override intent.
- Replacement uses the complete new configuration; do not merge unspecified fields from the previous value.
- Replacement is limited to the same capability identity. It does not authorize conflicts with other providers, invalid configuration or missing required peers.
- Options are schema-checked too: unknown options and nonboolean override values fail compilation.

Expand templates in explicit source order and retain provenance for every contribution and replacement. Resolve each contribution using these rules, then validate the final composition's peer requirements and descriptor-field ownership. Two templates that introduce the same capability without explicit replacement fail; never silently select the last one. Diagnostics point to both definitions and their expansion sites.

Apply framework defaults only after authored/template composition. Implicit defaults do not count as an existing capability for `override: true`; authors can declare their first geometry or surface capability normally. Repeated providers such as multiple contact effects need a dedicated documented composition contract, rather than an accidental exception to duplicate rejection.


Extension providers lower into supported generic native primitives or register bounded Elixir behaviour. A new native rendering/collision primitive needs engine support; registering a provider does not make arbitrary Elixir executable inside meshing or collision loops.

| Block concern | Generic provider responsibility |
| --- | --- |
| Shape | Geometry templates for cube/slab/stairs and bounded custom model assets; separate visual mesh, collision proxy and selection volume. |
| Transparency | Material mode: opaque, cutout or blended. Light transmission/occlusion is explicit and separate from visual alpha. |
| Slippery/sticky/bouncy | Surface friction, movement resistance/grip and restitution with units and ranges. |
| Harmful | Contact effect declarations; bounded effects applied by the gameplay owner. |
| Interaction | Finite state schema, validated transitions and explicit handlers for behaviour that cannot be expressed as data. |
| Emits light | Light emission, optionally selected by finite state. |
| No collision | Explicit noncolliding policy, independent of visibility and selection. |
| Gravity | Support rules and scheduled fall behaviour; first implement discrete cell movement. |
| Rotatable | Finite orientation domain; transform visual, collision, selection and directional support/light data together. |
| Vegetation | Generic support predicates using block references/tags and required contact faces; vegetation is content, not an engine special case. |

Absence/default behaviour is defined by the declaration kind. Initially blocks default to opaque cube geometry/collision, no light, no surface effect, no interaction and no gravity. Explicitly declaring no collision overrides the default. Lower all defaults into complete descriptors so native consumers do not infer separate policies. Defaults are public framework policy, not special handling for official content.

Define author geometry in block/pixel units using `Wyram.Units` (8 pixels per block). Continuous physics remains continuous; author units do not quantize velocity or collision timing.

## Definitions, states and instance data

- **Definition:** shared identity, finite state schema and capability configuration.
- **State:** small finite values such as facing, slab half and lamp on/off. Compile allowed combinations into shared descriptors and store compact state handles in dense chunks. Reserve air explicitly.
- **Instance data:** sparse owner-managed storage for inventories, text and timers; never multiply these into state variants.

Bound the Cartesian product and allow explicit valid-combination constraints. Exhausted handle capacity or variant budgets are compile/link errors, not truncation. State changes validate before mutation. Persistence stores a registry mapping to logical definition/state identities; development saves may be reset during this redesign. The existing u16 representation is an implementation constraint to reassess in the state phase, not a plugin contract.

An ECS-inspired registry is appropriate for shared capability data and system queries. It does not imply a component map or process per voxel. Region actors retain dense chunks and sparse instance records; character/entity owners retain dense collections.

## Authority, events and performance

Compile subscriptions into owner-local dispatch tables. Handlers receive explicit bounded context and emit typed commands; they do not synchronously mutate other owners. Validate command shape, references, permissions, expected revision and world conditions before applying changes.

Use a deterministic tick/event phase order, bounded event cascades and defined failure handling. Region support/contact work is batched. Cross-region actions require coordinator-owned transactions or staged commands; never add synchronous cyclic GenServer calls. Discrete falling must move a block exactly once, including at region boundaries. A later falling-body implementation must transfer ownership without leaving both a cell and a body.

Native collision, selection, meshing and later lighting consume immutable descriptor tables in bulk. Registry changes invalidate affected cached results through epochs; chunk/state edits retain revision tracking. The renderer uses cached data and asynchronous messages. Registry startup publishes a complete set atomically; no partially linked world becomes visible.

## Execution plan: one focused PR per phase

The sequence creates the framework before expanding block mechanics. Every phase adds its own positive/negative tests, runs `mise run check` and `mise run test`, and passes Windows CI. No phase may ship an accepted capability that the runtime silently ignores.

| Phase | Deliverable and affected areas | Acceptance gate |
| --- | --- | --- |
| 1. Public contracts and IR | New reference, schema, declaration, diagnostic and provider contracts under `apps/wyram_plugin_api/lib/wyram/`. Finalize generated module namespaces/metadata and reference-kind contracts, `template: true`, automatic public exports, override rules, defaults, composition, units and dependency ownership. | Schema validation rejects wrong values/reference kinds; module symbols and reference identity are distinct from handles; block/template-only roles and deterministic normalization have focused tests. Existing game remains usable until the integration replacement. |
| 2. Declaration DSL and compiler | `use Wyram.Plugin`, split declaration modules, `defblock`, generated declaration modules/ref factories, template expansion, capability override checks and Mix compiler. Add isolated source fixture builds. | Plain compilation rejects misspellings, duplicate IDs/module symbols, module collisions, unknown providers, capability duplicates/missing override targets, wrong reference kinds/roles, template cycles, invalid defaults and variant budgets with file/line diagnostics. Local and dependency module references, forward refs, aliases and intentional replacements succeed. Incremental rebuild detects changed/deleted declarations and assets. |
| 3. Package/linker and complete replacement | Update manifest generator, packager/dev pipeline, `PluginManager`, Wyram/example/test plugins, terrain and character catalog registration. Replace legacy callbacks and API-version checks. The first end-to-end slice supports existing colored cubes. | Package/build/install errors cover missing dependencies, cycles, module collisions and duplicate IDs. The official plugin imports only public API. Development launch and fresh-world smoke tests pass. Remove superseded compatibility tests/code in this PR. |
| 4. State registry and native descriptors | Engine registry/regions/world/client-port plus core/NIF/client tables. Represent finite states independently from definition IDs; decide capacity from measured budgets. | Deterministic handle mapping, state validation, fresh-save round trip and authoritative edits work. Native consumers agree on the same registry; stale worker output cannot apply after descriptor changes. Cube behaviour remains correct. |
| 5. Geometry, material and orientation | Canonical slabs/stairs, rotated shapes, custom mesh assets with supported collision proxies; shared selection/collision/meshing semantics. | Slab/stair bounds, every supported rotation, noncollision selection, cutout/blended rendering and asset rejection are tested. Playtest walking in a 1.5-block tunnel with the 11-pixel player. Measure batch query/meshing cost against cubes. |
| 6. Surface effects and interactions | Character/contact integration, typed command application, finite transition declarations and opt-in handlers. Sparse instance ownership where first needed. | Demonstrate slippery, sticky, bouncy and harmful content; a stateful switch changes compiled descriptors. Invalid commands, stale revisions, contradictory transitions and event cascades are covered. |
| 7. Support and discrete gravity | Region-local support indexing/scheduling and cross-region move coordination; vegetation uses the same support provider. | Wrong substrate rejects placement; support removal updates affected content; falling across region boundaries neither duplicates nor loses a block. Work queues remain bounded. |
| 8. Emission and lighting | State-dependent light declarations plus complete batched propagation/render integration. | Light placement/removal/state changes and transparent boundaries agree across chunks. Bounded update queues recover under burst edits; native lighting remains batched. |

Phase 2 can introduce collection alongside the current behaviour briefly to develop the compiler, but phase 3 removes the old route rather than keeping an adapter. Until later phases enable a backend feature, declarations requesting that feature fail with an explicit unsupported-capability diagnostic.

Each phase is an issue-sized milestone; phases 5-8 may need smaller provider/backend PRs, each ending with a usable supported slice. Link their issues to this plan when implementation starts. A broader item/entity/GUI implementation is outside this first block series.

## Growth beyond blocks

Use one compiler for collection, namespaces, references, dependency linking, diagnostics and packaging. Each declaration kind supplies its own schema, required capability contracts and lowering rules. Provider applicability is checked by kind: an entity-only provider on a block is a compile error.

Add `defitem`, `defentity`, `defparticle`, `defeffect`, `defevent` and GUI declarations only when their first real runtime consumer is ready. Do not implement an untyped `defcontent(kind, map)` escape hatch or require all kinds to share a block layout. Cross-kind references carry the expected kind. The existing character model/profile contracts inform entity declarations without moving animation or physics authority into macros.

## File/dependency map

| Area | Planned change | Depends on |
| --- | --- | --- |
| `apps/wyram_plugin_api/lib/wyram/plugin.ex`, `plugin_api.ex`, new compiler/schema/provider/reference/generated-declaration modules | Replace behaviour with declarative framework; public contracts and build integration | Phases 1-2 |
| `plugins/*/mix.exs`, entry/content modules, `test/fixtures/plugins/*` | Configure compiler, declare content and exports, remove callback catalogs | Phases 2-3 |
| `scripts/generate-plugin-manifest.exs`, `pack-plugin.ps1`, `development-plugin.ps1` | Consume compiler artifacts and package owned modules/assets | Phase 2 |
| `apps/wyram_engine/lib/wyram/engine/plugin_manager.ex` and new registry/linker modules | Dependency graph, installed-set validation, immutable compiled registry | Phases 1-3 |
| Engine `region.ex`, `world.ex`, `characters.ex`, `client_port.ex` | State tables, sparse data, validated commands and batched publication | Phases 3-4 onward |
| `native/crates/wyram_core`, `wyram_nif`, client `world.rs` and protocol/render modules | Shared descriptor tables, shape queries, materials and later lighting | Phase 4 onward |
| Plugin upgrade/archive/dev/smoke scripts and API/engine/native tests | Replace obsolete compatibility expectations; retain archive safety and exercise new contracts | Each corresponding phase |
| `docs/plugins.md`, `architecture.md` and this plan | Document authoring, ownership, supported features and build guarantees | Each corresponding phase |

## Risks and rollback

The main risks are macro complexity, stale build artifacts, state explosion, conflicting provider composition, backend divergence and event/ownership loops. Mitigate them with a small expression grammar, one normalized IR, declaration-symbol provenance, build fingerprints, explicit budgets/field ownership, shared descriptor fixtures and bounded command scheduling.

Keep generated catalogs and build outputs out of Git. Benchmark compile/link duration, catalog memory/variant count and matched runtime batch costs before claiming improvements. Performance gates should target the changed path, not require unsupported FPS claims.

Rollback is a focused PR revert and plugin rebuild, with development world reset if necessary. If a dependent phase is already merged, revert its dependents first or fix forward as a new focused PR. Do not restore backward compatibility infrastructure merely to avoid a pre-alpha reset.
