# Game foundations and frontier roadmap

Status: proposed delivery plan implementing the settled [world vision](world-vision.md) and [resource principles](resources-and-creation.md). This document records intended work, not a claim that future systems already exist. The baseline below was inspected at `bd82100` on 2026-10-03; refresh it when scoping implementation.

## Delivery policy

Settle a working game foundation, then build the world's soul through playable updates. Foundation work should establish dependable ownership, authoring and interactions for the next slice. Later content can require focused public extensions. Each extension must have a concrete content use and a bounded contract; implementing every planned framework capability is not a prerequisite for the first living region.

The order of first substantial frontier attention is **surface, underground, ocean, skies**. Surface remains the main environment. This orders emphasis; it does not require completing one frontier before introducing the next. Revisit earlier frontiers between and after introductions.

Simple landscapes for several frontiers can arrive early. Track that geographical presence separately from gameplay depth. Mountain peaks can connect surface and skies, while underground water bodies can lead to the ocean. Frontier releases may span these boundaries and should improve the connected world.

Keep performance work and content work in isolated worktrees and focused PRs targeting `main`. Refresh the current base and coordinate shared contracts before integration. Every published change runs `mise run check` and `mise run test`, with Windows CI green before merge. Use [benchmarking](../benchmarking.md) when a change affects scale or runtime costs; claims require measured evidence.

## Existing foundation and remaining boundaries

This is a source-inspected baseline. The readiness gate below still requires execution and playtest evidence on the selected implementation head.

| Area | Present at the inspected baseline | Boundary for world delivery |
| --- | --- | --- |
| Plugins and content | Compiled typed catalogs for blocks, biomes, shaping, profiles, models, characters and worldgen; public capability providers. | Items, recipes, resource properties, settlements, machines and spells need their own contracts as introduced. An existing declaration compiler does not supply their runtime behavior. |
| Terrain | Seeded 512-block world, sea level zero, terrain/climate fields, caves, floating islands, biome blending and bounded features. | One wilderness palette. Specialized environments and meaningful frontier ecology remain content work. Current feature kinds are trees, boulders and crystal spires; colossal anatomy needs a focused generation extension. |
| World edits and saves | Region-owned packed chunks, placement/removal, durable edits, restart recovery and generation fingerprints. | The creative editor supplies selected blocks. Resource collection, inventories, processing and crafting are not a demonstrated progression loop. Generation changes need an explicit existing-world policy. |
| Dwarf traversal | Elixir-authoritative movement/collision, postures, jumps, climbing, slides, rolling and opt-in double-tap flight. | Swimming/diving remain future work. The creative flight capability does not settle progression travel, its costs or aerial habitation. |
| Presentation | Original reusable dwarf rigs, state-driven animation, cube colors, transparent water, emissive lava and external cameras. | Textures, light propagation, world ambience and rich habitat presentation need scoped work. Existing emission does not establish dynamic lighting. |
| Liquids | Water/lava sources, bounded falling/flow/drainage and noncollision, with persistence checks. | Swimming, fluid contact damage and mixing reactions remain open implementation work. Water volume alone does not establish an ocean gameplay frontier. |
| Life and creation | A reusable character roster with an idle companion. | Resource gameplay, combat/health, spells, machines, settlement inhabitants and ecology are future slices. A second rendered character does not establish population simulation. |
| Performance | Bounded native batches, background outbound IPC and asynchronous mesh workers, with tests and capture tooling. | Streaming, transport, saves, GPU work and large scenery have separate measurements and ongoing work. See the performance plan; no full-game performance target is declared achieved here. |

Technical plans remain authoritative for their contracts: [architecture](../architecture.md), [plugin framework](../plugin-framework-plan.md), [character gameplay](../gameplay-plan.md), [world generation](../world-generation.md), [performance](../performance-plan.md) and [testing](../testing.md).

## F0: working foundation gate

Purpose: accept a dependable base for a small playable surface release. F0 is a planned gate, currently awaiting evidence; it does not declare the framework or performance work complete.

### F0.1: baseline stability

Scope the first surface scene and its expected residency, feature sizes and traversal before measuring it. Verify ordinary play, block edits, travel, save/restart and plugin build/install behavior on a clean test world. Establish the representative route and record generation, streaming, edit, simulation and frame costs relevant to that scene.

Acceptance evidence:

- Required checks and tests pass on the chosen head, including Windows CI.
- The player can launch, traverse, edit, save, exit and reload the selected scene without lost edits or authority disagreements.
- Representative route captures identify remaining bottlenecks and record agreed limits for that slice. Numerical budgets are chosen from evidence before accepting scale increases.
- The Wyram content plugin uses only public APIs. Native work and transport remain batched, with no renderer wait on a GenServer.
- Save compatibility or a deliberate development-world reset is documented. New generation settings do not silently alter an edited world's base terrain.

### F0.2: minimum resource and creation contracts

Design the smallest public contracts needed by S1 below. Cover logical material/item identity, acquisition, owner-held quantities, processing/creation requests and persistent results. Specify validation and interrupted/repeated-action behavior before introducing recipes or yields. Decide how progression play relates to the current unlimited creative block selector; keep creative testing useful without treating it as a validated acquisition economy.

Demonstrate collecting a resource, keeping it through save/reload, consuming it in a useful creation and using that creation in the world. Add the smallest reusable action, health or hazard contract needed for S1's chosen danger. Presentation communicates the resource, its uses, costs and outcome clearly.

Acceptance evidence:

- Collection and consumption cannot duplicate or lose resources through a rejected, repeated, interrupted or stale request; restart coverage exercises the selected ownership model.
- At least two material choices demonstrate distinct useful roles, and a creation still gives an earlier resource a meaningful contribution.
- A second small content fixture exercises the public contract independently of Wyram-specific identities.
- The example is usable through the player interface, with correctness tests at the authority boundary.

Do not add whole economy, combat, magic, automation or NPC frameworks in anticipation of later frontiers. Their initial runtime contracts arrive with the first slice that needs them. F0 is complete when F0.1 and F0.2 have recorded evidence and S1's dependencies are explicit.

## Frontier release pattern

Every update after F0 should add soul to at least one frontier, including a connection between frontiers where appropriate. A focused update can add one part of the pattern; the first substantial release of a frontier must combine the essentials into a playable experience.

Record these fields for each release:

| Field | Required decision |
| --- | --- |
| Place | Selected environments, local contrast, boundaries and recognizable landmarks. |
| Scale and ancient traces | How dwarf-scale life relates to older monumental forms; which colossus or lineage evidence appears. |
| Creation opportunity | A resource, property, process or interaction that enables a player project; its tier peers and continuing uses. |
| Life and danger | A scoped ecological, creature or social behavior and readable risks; identify presentation-only elements. |
| Habitation | What makes the place worth inhabiting, how a dwelling/workshop works, and which long-term needs remain deferred. |
| Connections | Routes to existing environments and any visible future routes; released travel must match available capabilities. |
| Public extensions | The precise missing contracts, their owners and tests. Keep existing supported content declarative where possible. |
| Evidence | Player route, creation/habitation demonstration, regression checks, performance observations and save policy. |

Build playable vertical slices in small PRs. A temporary landscape or incomplete behavior must be labeled clearly; a frontier introduction is accepted only when its promised loop works. Choose detailed species, recipes and assets at release scoping time, preserving the settled design principles.

## Proposed sequence of first releases

All entries below are planned. The identifiers give implementation work stable references; they are not dates or completion claims. The examples are candidate scopes, to be refined before implementation.

### S1: first living surface region

Create one coherent surface area with nearby environmental contrast, readable scale, useful local materials, a resource-bearing colossus trace and a place to build. Introduce a small amount of present life and a readable local danger. Use F0's creation loop to make exploration serve a player project.

Keep the first resource graph small but branching. Accessible bone shards can have an early use; the first demonstration of advanced bone potential needs a concrete later milestone. Settlements may initially appear as environmental evidence, with inhabitants explicitly deferred to S2. Select S1's exact environments and first lineage before work begins; the bone desert is a candidate, not a locked starting biome.

Acceptance: a new player can recognize a lead, acquire materials with different roles, make a useful creation, alter/build a home, venture into the second environment and return with a new possibility. Loose bone and monumental remains follow consistent resource rules. Confirm scale and buildability in the actual scene.

### S2: surface societies and a first bone specialization

Deepen the surface with a contrasted environment and a locally coherent dwarven community. The bone-desert forge city is the leading candidate. Its crafts and architecture should reveal why its inhabitants live there.

Introduce the first working local inhabitants and clearly communicated access behavior. Keep intercity simulation outside this scope. Add a bone-processing path demonstrating exceptional potential in one selected domain: combat, engineering or magic. Scope that domain's minimum reusable contract alongside the content. Other domains follow in separate releases, and earlier materials remain useful.

Acceptance: the player can understand the community's boundaries, use the new material path, produce an exceptional creation and find a reason to return. Demonstrate that the lineage's material has a useful peer role rather than replacing every resource. Show how local extraction and persistent edits interact with the settlement.

### U1: first inhabited underground frontier

Introduce connected cave/cavern environments with distinctive materials, exposed colossus anatomy or population traces, a scoped ecosystem or community and a local danger. Include a reason to establish a workshop or dwelling below ground. Select the lighting/visibility behavior that makes the released routes readable.

Acceptance: a player can reach the region from the surface, pursue a new creation opportunity, establish a usable home/workshop, save/reload it and travel back. Underground work has benefits beyond supplying a single surface recipe. A flooded route may foreshadow ocean access while underwater traversal remains deferred until supported.

### R1: revisit surface and underground, connect creation domains

Return to both introduced frontiers with new combinations, life or environments. Add a first demonstration in a creation domain not yet exercised, and connect it to existing materials and activities. This release makes the branching progression observable across environments instead of leaving each update as an isolated tier.

Acceptance: an existing creation gains a useful new combination, established materials retain roles, and a player has a reason to revisit an earlier region. Demonstrate a practical connection such as a mine, cavern settlement or underground water edge.

### O1: coast and a first living ocean region

Start with a manageable coastal/reef scope connected to the surface or underground. Add aquatic lineage remains, marine resources and scoped life/danger. Provide an initial habitation option and a project that benefits from the aquatic environment.

Prerequisites: validated swimming/diving, underwater controls and presentation, and the selected exposure/breathing or protective rules. Costs and hazards remain design decisions until scoped; underwater access must work before promising deep-ocean settlement gameplay.

Acceptance: the player can prepare, enter, navigate, gather, create, occupy the selected dwelling/workshop and return. Validate collision, visibility, edits and persistence across dry/flooded boundaries. Abyssal societies and more demanding depth environments are future ocean expansions.

### K1: high peaks and a first living sky region

Use mountains as a bridge into a limited sky environment. Add a distinct material or condition, aerial lineage evidence, scoped life/danger and a reason to build above ordinary ground.

Prerequisites: select and implement a dependable travel/return method and habitation requirements for this scope. Existing creative flight is useful for authoring but does not decide how progression players reach or inhabit it. Suspended remains and sky biomes require deliberate placement and visual identity within supported world bounds.

Acceptance: a player can establish and revisit an elevated home/workshop, use its local creation opportunity and travel between the mountain and sky environments. Measure the selected scenery and view costs; do not enlarge world height or view distance implicitly.

## Continuing expansions

Cycle among the frontiers after and between their introductions. Candidate directions include frozen surface remains, giant forests, deeper fossil ecosystems, underground seas, twilight/abyssal cultures, storm environments, and additional colossus lineages. Extend combat, engineering, magic and habitation together through material connections, with depth selected per release.

A frontier's progress should be reported across landscape, resources/creation, life, danger, habitation and connections. A generated biome can be present while its societies or habitation remain planned. Avoid one percentage or a blanket "complete" label for all those dimensions.

For each new environment, demonstrate both an exploration attraction and a sustainable reason to stay. Mature underground, ocean and sky play should support chosen homes and local projects while remaining connected to the surface. Support continued access to important resources through explicitly selected acquisition and supply rules.

## Ownership and extension rules

The game plugin owns Wyram's lineages, resources, tier relationships, cultures, environments and authored behavior through the public API. Elixir owns gameplay authority, validation, ownership and persistence. Native code owns packed bulk operations and presentation. Region actors own dense world data; bounded owners can hold entity state. Keep calls and messages batched and never introduce a process for every block or entity.

Every extension proposal should identify its immediate content use, reusable public contract, state owner, command validation, persistence behavior, native batching/presentation needs and acceptance evidence. Reuse the existing declaration compiler and runtime boundaries where applicable. Reject a descriptor the runtime cannot honor instead of silently accepting unsupported content.

Large colossi need deterministic placement across chunk/region boundaries, repeatable anatomy/resource rules, editable persistence and bounded generation/mesh work. Current tree/boulder dimensions and the 512-block world are working limits, not final lore constraints. A scale extension requires explicit scope, compatibility policy and measurements. A landmark's apparent size alone does not justify an engine rewrite.

## Decisions to settle at release scoping

- S1's environment pair, first colossus lineage and resource/property set.
- Creative versus progression play behavior, failure/recovery rules and the initial crafting interface.
- The first combat, engineering and magic demonstrations, including their order and cross-domain interactions.
- Bone yields, processing, useful quantities, depletion/replenishment and extraction near settlements.
- Encounter behavior, local friendliness, settlement boundaries and any early trade.
- Swimming, exposure, underwater building and sky travel/habitation rules when those scopes approach.
- Scene scale, presentation assets, tested performance budgets and save compatibility for each release.

The extinction's explanation, a complete species taxonomy and every future biome can remain unresolved while these playable decisions are made.
