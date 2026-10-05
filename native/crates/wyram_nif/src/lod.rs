use super::{binary_from_bytes, worldgen::Generation};
use rustler::{Binary, Env, ResourceArc};
use wyram_core::lod::{ChunkOverride, Tile, TileKey};

type Key = (u8, i32, i32, i32);
type Edit<'a> = ((i32, i32, i32), Binary<'a>);

fn key((size, x, y, z): Key) -> Result<TileKey, &'static str> {
    TileKey::new(size, [x, y, z])
}

fn validate_liquids(ids: &[u16]) -> Result<(), &'static str> {
    if ids.len() > 256 || ids.contains(&0) {
        Err("invalid LOD liquid IDs")
    } else {
        Ok(())
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn generate_lod_tile<'a>(
    env: Env<'a>,
    generator: ResourceArc<Generation>,
    tile_key: Key,
    liquid_ids: Vec<u16>,
) -> Result<Binary<'a>, &'static str> {
    validate_liquids(&liquid_ids)?;
    let tile = generator.0.lod_tile(key(tile_key)?, &liquid_ids)?;
    Ok(binary_from_bytes(env, &tile.encode()?))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn apply_lod_edits<'a>(
    env: Env<'a>,
    tile_key: Key,
    data: Binary<'a>,
    edits: Vec<Edit<'a>>,
    liquid_ids: Vec<u16>,
) -> Result<Binary<'a>, &'static str> {
    validate_liquids(&liquid_ids)?;
    if edits.len() > 128 {
        return Err("LOD edit batch exceeds 128 chunks");
    }
    let mut tile = Tile::decode(key(tile_key)?, data.as_slice())?;
    let edits: Vec<_> = edits
        .iter()
        .map(|((x, y, z), data)| ChunkOverride {
            key: [*x, *y, *z],
            data: data.as_slice(),
        })
        .collect();
    tile.apply_overrides(&edits, &liquid_ids)?;
    Ok(binary_from_bytes(env, &tile.encode()?))
}
