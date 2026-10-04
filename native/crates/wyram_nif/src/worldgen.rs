use super::binary_from_bytes;
use rustler::{Binary, Env, NifMap, ResourceArc};
use wyram_core::worldgen::{Biome, Carver, Feature, Field, Generator, Islands, Settings, Terrain};
type FieldWire = (f64, u32, u64);
type CarverWire = (u8, FieldWire, f64, i32, i32, i32);
type IslandsWire = (FieldWire, i32, i32, i32, f64);
type FeatureWire = (u8, u16, u16, i32, f64, (i32, i32, u64, i32, u8));
#[derive(NifMap)]
struct BiomeWire {
    climate: Vec<f64>,
    surface: u16,
    soil: u16,
    rock: u16,
    water: u16,
    elevation_offset: i32,
    features: Vec<FeatureWire>,
}
#[derive(NifMap)]
struct SettingsWire {
    min_y: i32,
    height: i32,
    sea_level: i32,
    relief: i32,
    blend: f64,
    terrain: (f64, f64, f64, i32, f64),
    fields: Vec<FieldWire>,
    carvers: Vec<CarverWire>,
    islands: Option<IslandsWire>,
    biomes: Vec<BiomeWire>,
}
fn field((scale, octaves, salt): FieldWire) -> Field {
    Field {
        scale,
        octaves,
        salt,
    }
}
pub struct Generation(Generator);
#[rustler::resource_impl]
impl rustler::Resource for Generation {}
#[rustler::nif(schedule = "DirtyCpu")]
fn compile_generator(
    seed: u64,
    wire: SettingsWire,
) -> Result<ResourceArc<Generation>, &'static str> {
    let fields: Vec<_> = wire.fields.into_iter().map(field).collect();
    let fields = fields
        .try_into()
        .map_err(|_| "expected six generation fields")?;
    if wire.biomes.len() > 32 || wire.carvers.len() > 4 {
        return Err("oversized generation configuration");
    }
    let biomes = wire
        .biomes
        .into_iter()
        .map(|b| {
            let climate = b
                .climate
                .try_into()
                .map_err(|_| "expected six biome climate axes")?;
            let features = b
                .features
                .into_iter()
                .map(
                    |(
                        kind,
                        block,
                        accent,
                        spacing,
                        density,
                        (radius, height, salt, support_depth, domain),
                    )| {
                        Feature {
                            kind,
                            block,
                            accent,
                            spacing,
                            density,
                            radius,
                            height,
                            salt,
                            domain,
                            support_depth,
                        }
                    },
                )
                .collect();
            Ok(Biome {
                climate,
                surface: b.surface,
                soil: b.soil,
                rock: b.rock,
                water: b.water,
                elevation_offset: b.elevation_offset,
                features,
            })
        })
        .collect::<Result<Vec<_>, &'static str>>()?;
    let carvers = wire
        .carvers
        .into_iter()
        .map(
            |(kind, f, threshold, min_y, max_y, surface_buffer)| Carver {
                kind,
                field: field(f),
                threshold,
                min_y,
                max_y,
                surface_buffer,
            },
        )
        .collect();
    let islands = wire
        .islands
        .map(|(f, base_y, thickness, relief, threshold)| Islands {
            field: field(f),
            base_y,
            thickness,
            relief,
            threshold,
        });
    let settings = Settings {
        min_y: wire.min_y,
        height: wire.height,
        sea_level: wire.sea_level,
        relief: wire.relief,
        blend: wire.blend,
        terrain: Terrain {
            roughness: wire.terrain.0,
            valley_depth: wire.terrain.1,
            plains_strength: wire.terrain.2,
            shelf_height: wire.terrain.3,
            shelf_strength: wire.terrain.4,
        },
        fields,
        carvers,
        islands,
        biomes,
    };
    Generator::new(seed, settings).map(|g| ResourceArc::new(Generation(g)))
}
type ChunkKey = (i32, i32, i32);
#[rustler::nif(schedule = "DirtyCpu")]
fn generate_world_chunks<'a>(
    env: Env<'a>,
    g: ResourceArc<Generation>,
    keys: Vec<ChunkKey>,
) -> Result<Vec<(ChunkKey, Binary<'a>)>, &'static str> {
    if keys.len() > 32 {
        return Err("oversized generation batch");
    }
    let coordinates: Vec<_> = keys.iter().map(|&(x, y, z)| [x, y, z]).collect();
    let chunks = g.0.chunks(&coordinates)?;
    Ok(keys
        .into_iter()
        .zip(chunks)
        .map(|(key, bytes)| (key, binary_from_bytes(env, &bytes)))
        .collect())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn generate_scenic_tiles<'a>(
    env: Env<'a>,
    g: ResourceArc<Generation>,
    keys: Vec<((i32, i32, i32), u8)>,
) -> Result<Vec<Binary<'a>>, &'static str> {
    if keys.len() > 2 {
        return Err("oversized scenic generation batch");
    }
    keys.into_iter()
        .map(|((x, y, z), level)| {
            let key = wyram_core::scenery::TileKey::new([x, y, z], level)
                .map_err(|_| "invalid scenic tile key")?;
            let tile = g.0.scenic_tile(key)?;
            Ok(binary_from_bytes(env, &tile.encode()))
        })
        .collect()
}
#[derive(NifMap)]
struct ColumnWire {
    height: i32,
    climate: Vec<f64>,
    weights: Vec<f64>,
    biome: usize,
    island: Option<(i32, i32)>,
}
#[rustler::nif(schedule = "DirtyCpu")]
fn sample_world(
    g: ResourceArc<Generation>,
    positions: Vec<(i32, i32)>,
) -> Result<Vec<ColumnWire>, &'static str> {
    if positions.len() > 4096
        || positions
            .iter()
            .any(|(x, z)| x.unsigned_abs() > 1_000_000 || z.unsigned_abs() > 1_000_000)
    {
        return Err("invalid field sample batch");
    }
    Ok(positions
        .into_iter()
        .map(|(x, z)| {
            let c = g.0.column(x, z);
            ColumnWire {
                height: c.height,
                climate: c.climate.to_vec(),
                weights: c.weights,
                biome: c.biome,
                island: c.island,
            }
        })
        .collect())
}
#[rustler::nif(schedule = "DirtyCpu")]
fn generator_spawn(g: ResourceArc<Generation>) -> (i32, i32, i32) {
    let [x, y, z] = g.0.spawn();
    (x, y, z)
}
#[rustler::nif(schedule = "DirtyCpu")]
fn surface_heights(
    g: ResourceArc<Generation>,
    positions: Vec<(i32, i32)>,
) -> Result<Vec<i32>, &'static str> {
    if positions.len() > 64
        || positions
            .iter()
            .any(|(x, z)| x.unsigned_abs() > 1_000_000 || z.unsigned_abs() > 1_000_000)
    {
        return Err("invalid spawn batch");
    }
    Ok(positions
        .into_iter()
        .map(|(x, z)| g.0.surface_spawn_height(x, z))
        .collect())
}
