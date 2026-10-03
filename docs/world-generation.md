# World generation foundation

Wyram uses sea level **Y=0** in a **512-block** world: **-192 through 319**, inclusive. Chunk coordinates span **-12 through 19** vertically. The datum, bounds and sea level belong to the selected game plugin, rather than the renderer. The first palette is wilderness; desert, jungle, snow, fire and transition biomes will be authored separately.

## Pipeline and ownership

1. Resolve the saved seed and validate the plugin's `Wyram.WorldGen.Config`.
2. Sample continuous continentalness, erosion, tectonics, temperature, humidity and detail fields in world coordinates.
3. Combine continental elevation and ridged uplift with erosion-weighted plains, narrow valley cuts, buildable shelves and finer local relief into ground height; altitude cools temperature and the coast affects humidity.
4. Compute normalized biome weights in six dimensions: temperature, humidity, continentalness, erosion, elevation and tectonics. Blend elevation offsets continuously. Pick categorical materials deterministically from those weights.
5. Add disconnected floating island density with an independent field, altitude and shaped underside.
6. Apply bounded cave or rift carvers, preserving the bottom layer and each carver's surface buffer.
7. Apply biome surface/soil/rock layers and fill exposed ocean volume through sea level with that biome's liquid source block.
8. Place seeded features anchored on the ground or islands. Dense voxel loops and packed writes stay native.

Elixir owns the validated public contracts, block identity resolution, world seed, save compatibility and region ownership. A single immutable native resource is shared by region actors. No callback runs per block, and no process is created per feature or voxel. Region generation and renderer transport run in bounded batches.

The tectonics and erosion inputs currently shape noise-based geology. They are not a simulated plate history or a hydraulic erosion solver. Later regional solvers can supply fields to this same pipeline without putting world state in the renderer.

## Public authoring API

Select a `worldgen Module` in game composition, or pass `worldgen:` to `Wyram.Game.Config.new!/1` in a procedural builder. Biomes own the palettes; no game palette is needed. The simple layered generator uses an explicit `palette:` instead. The Wyram plugin provides a working example in `plugins/wyram/lib/world_gen.ex`.

```elixir
alias Wyram.WorldGen.{Biome, Config, Feature}

Config.new!(%{
  min_y: -192,
  height: 512,
  sea_level: 0,
  biomes: [
    Biome.new!(%{
      id: "my_game:wilderness",
      climate: %{temperature: 0.55, humidity: 0.7},
      surface: Blocks.Grass.ref(),
      soil: Blocks.Dirt.ref(),
      rock: Blocks.Stone.ref(),
      water: Blocks.Water.ref(),
      features: [
        Feature.new!(%{
          kind: :tree, block: Blocks.Wood.ref(), accent: Blocks.Leaves.ref(),
          spacing: 32, density: 0.4, radius: 4, height: 14, salt: 101
        })
      ]
    })
  ]
})
```

Use a typed biome catalog in an owned plugin module:

```elixir
defmodule MyGame.Biomes do
  use Wyram.Plugin.Catalog, kind: :biome
  alias MyGame.Blocks

  defbiome Wilderness, id: "wilderness" do
    %{surface: Blocks.Grass, soil: Blocks.Dirt, rock: Blocks.Stone,
      water: Blocks.Water, climate: %{humidity: 0.7}}
  end
end
```

The plugin entry links it with `catalog MyGame.Biomes`. A world-generation catalog declares `defworldgen Wilderness, id: "wilderness" do %{biomes: [MyGame.Biomes.Wilderness]} end`, and the game composition selects that preset with `worldgen MyGame.WorldGen.Wilderness`. Persistent biome IDs derive from the application's name and local ID. Module aliases are typed references resolved after compilation; arbitrary calls do not execute inside declarations. Biomes can be split across included family catalogs. The compiler validates every biome, feature, and world-generation preset, including unselected content. The public data constructors remain available to explicit procedural builders.

`Biome` is the common data model for these declarations. Game builders can assemble multiple biomes and transition biomes. Unspecified climate axes default to 0.5. A transition biome is a separately named biome with its own climate center, surface palette and feature rules; placing it between other centers gives it weight through that region. `blend` controls how broadly centers overlap. Material choices are seeded categorical choices, while elevation offsets use continuous weighted blending; contrasting palettes may need an explicitly authored transition palette.

`terrain: Wyram.WorldGen.Terrain.new!(%{...})` tunes the balance between buildable land and rugged detail. `roughness` (0..32, default 12) controls finer relief; `valley_depth` (0..64, default 20) cuts narrow erosion channels. `plains_strength` (0..1, default 0.8) suppresses channels and fine roughness in high-erosion regions. `shelf_height` (2..16, default 8) and `shelf_strength` (0..1, default 0.65) form broad, smoothly connected shelves. The detail field sets local scales, while erosion controls where rugged or gentler terrain occurs. Setting roughness, valley depth and shelf strength to zero restores the broad terrain profile. These are procedural shape controls, not physical erosion simulation.

Each field has scale in blocks, octave count and a salt. Six required field names are checked, so misspellings fail during plugin compilation. Carvers have their own fields, thresholds, vertical limits and surface buffers. Islands have a footprint field, base altitude, thickness, relief and threshold; `islands: nil` disables them. Empty `carvers` disables carving. Biomes can add an elevation offset between -64 and 64 blocks.

Feature kinds are trees, boulders and crystal spires. Their block and accent materials remain logical plugin references. Placement has spacing, density, size, salt and a ground/island domain. Radius is bounded to 16 blocks and height to 64. Each grid anchor evaluates in global coordinates; adjacent chunks recompute all anchors whose footprints touch them. This supports large trees crossing chunk and region boundaries without depending on generation order. Biomes sort by ID, features sort by salt, and overlaps use that stable priority. A salt must be unique within its biome. Features fill empty cells and do not overwrite terrain or ocean sources. `support_depth` defaults to **0**, which preserves gaps and overhangs (for fallen logs and other intentionally suspended features). A positive value up to 64 extends only the base footprint downward with the feature's block material: tree trunks, rock bases or crystal bases, never canopies. Supports stop at the local terrain or island surface, preserving caves below it. Unsupported footprint columns beyond the configured depth, or beyond an island edge, are trimmed rather than left floating. The expanded vertical footprint participates in chunk overlap, so support fill is independent of chunk generation order. Wyram opts its living trees and boulders into support fill.

The first Wyram palette exercises ordinary trees, 48-block trees, boulders and island rocks. Crystal placement is wired as a native primitive, with crystal materials and specific biome distribution left to future content. Jungle density, different deserts, snow, volcanic materials and their transitions are also content work ahead.

## Bounds, streaming and spawning

Generation produces air outside the configured range, and ordinary block edits outside it are rejected. Native chunk keys and field samples are bounded to the game's supported horizontal coordinate limit of roughly one million blocks. Generation validates dimensions before allocating packed chunks. The native batch cap is 32 chunks; client streaming progresses 16 chunks per turn and prioritizes proximity to the observer. The current two-chunk horizontal view radius contains 800 chunks across all 32 vertical layers, or 6.25 MiB of packed voxel data before metadata, meshing and transport. Height support does not by itself establish an FPS result; view distance and GPU costs need separate measurement.

Wyram opts into `spawn: :surface` on its public game config: characters are relocated to dry ground near the initial seed's origin, with surface/feature clearance and their relative X/Z offsets. The default `spawn: :configured` preserves authored character positions, including for other games with a custom generator. Spawning in a configured world with no dry ground falls back to the sea surface; fully oceanic games should supply an appropriate starting environment before relying on walking locomotion.

Generated ocean cells are stable source blocks. They do not enqueue entire oceans in the liquid simulation; nearby edits wake liquid neighborhoods. Existing liquid movement limitations still apply.

## Persistence and inspection

Saved edits use format 2, with the saved seed and a fingerprint of normalized generation settings and logical references. The fingerprint includes the native algorithm version and ignores the default seed, so an existing world's saved seed remains authoritative. A changed pipeline fails with `incompatible_save` instead of silently regenerating different terrain around edited chunks. Format 1 worlds remain readable with the legacy generator; old Wyram terrain saves are not automatically migrated to this new generator. Use a separate data directory for previewing it.

`mise exec -- mix run scripts/worldgen-atlas.exs` exports a 256 by 256 sample of actual generation fields over an 8192-block square, plus a measured generation time for the full-height residency window. Output defaults to `.tools/worldgen-atlas.json`; pass an output path as the script argument to change it. Select Wyram in a clean `WYRAM_DATA_DIR` containing its package, and use a missing `WYRAM_CLIENT` path for a headless run. Generated outputs stay out of source control.

Tests cover the coordinate datum, finite bounds, negative coordinates, independent seed streams, normalized biome weights, chunk-order/seam consistency, optional grounded feature support and overhangs across boundaries, sampled buildable patches and rugged relief, cave disabling, dry-land spawning, compiled block reference ownership, native batch validation, liquid behavior, and save identity/seed restoration.
