use rustler::{Binary, Env};
use wyram_core::scenery::{LodTile, TileKey};

use super::binary_from_bytes;

#[rustler::nif(schedule = "DirtyCpu")]
fn import_visual_chunks<'a>(
    env: Env<'a>,
    chunks: Vec<((i32, i32, i32), Binary<'a>)>,
) -> Result<Vec<Binary<'a>>, &'static str> {
    if chunks.len() > 16 {
        return Err("oversized visual chunk batch");
    }
    chunks
        .into_iter()
        .map(|((x, y, z), bytes)| {
            let key = TileKey::new([x, y, z], 0).map_err(|_| "invalid visual chunk")?;
            let tile =
                LodTile::from_chunk(key, bytes.as_slice()).map_err(|_| "invalid visual chunk")?;
            Ok(binary_from_bytes(env, &tile.encode()))
        })
        .collect()
}

#[rustler::nif(schedule = "DirtyCpu")]
fn reduce_visual_tiles<'a>(
    env: Env<'a>,
    batches: Vec<Vec<Binary<'a>>>,
) -> Result<Vec<Binary<'a>>, &'static str> {
    if batches.len() > 8 {
        return Err("oversized visual reduction batch");
    }
    batches
        .into_iter()
        .map(|batch| {
            if batch.len() != 8 {
                return Err("incomplete visual sibling batch");
            }
            let tiles = batch
                .into_iter()
                .map(|bytes| {
                    LodTile::decode(bytes.as_slice()).map_err(|_| "invalid visual tile encoding")
                })
                .collect::<Result<Vec<_>, _>>()?;
            let children = std::array::from_fn(|index| &tiles[index]);
            let tile = LodTile::reduce(children).map_err(|_| "invalid visual sibling batch")?;
            Ok(binary_from_bytes(env, &tile.encode()))
        })
        .collect()
}
