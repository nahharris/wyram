use super::binary_from_bytes;
use super::worldgen::Generation;
use rustler::{Binary, Env, ResourceArc};
use wyram_core::scenery::TileKey;
type Key = ((i32, i32, i32), u8);
fn key(((x, y, z), level): Key) -> Result<TileKey, &'static str> {
    TileKey::new([x, y, z], level).map_err(|_| "invalid scenic tile key")
}

#[rustler::nif(schedule = "DirtyCpu")]
fn scenic_sample_chunks(
    generation: ResourceArc<Generation>,
    wire: Key,
) -> Result<Vec<(i32, i32, i32)>, &'static str> {
    generation
        .0
        .scenic_sample_chunks(key(wire)?)
        .map(|keys| keys.into_iter().map(|[x, y, z]| (x, y, z)).collect())
}
#[rustler::nif(schedule = "DirtyCpu")]
fn extract_scenic_samples<'a>(
    env: Env<'a>,
    generation: ResourceArc<Generation>,
    wire: Key,
    chunks: Vec<((i32, i32, i32), Binary<'a>)>,
) -> Result<Binary<'a>, &'static str> {
    if chunks.len() > 256 {
        return Err("oversized scenic edit batch");
    }
    let borrowed: Vec<_> = chunks
        .iter()
        .map(|((x, y, z), bytes)| ([*x, *y, *z], bytes.as_slice()))
        .collect();
    let samples = generation.0.extract_scenic_samples(key(wire)?, &borrowed)?;
    Ok(binary_from_bytes(env, &samples))
}
#[rustler::nif(schedule = "DirtyCpu")]
fn generate_edited_scenic_tiles<'a>(
    env: Env<'a>,
    generation: ResourceArc<Generation>,
    tiles: Vec<(Key, Binary<'a>)>,
) -> Result<Vec<Binary<'a>>, &'static str> {
    if tiles.len() > 2 {
        return Err("oversized scenic generation batch");
    }
    tiles
        .into_iter()
        .map(|(wire, samples)| {
            let tile = generation
                .0
                .scenic_tile_with_samples(key(wire)?, samples.as_slice())?;
            Ok(binary_from_bytes(env, &tile.encode()))
        })
        .collect()
}
