mod process_watch;
mod worldgen;

use rustler::{Binary, Env, OwnedBinary};

fn binary_from_bytes<'a>(env: Env<'a>, bytes: &[u8]) -> Binary<'a> {
    let mut result = OwnedBinary::new(bytes.len()).expect("failed to allocate chunk binary");
    result.as_mut_slice().copy_from_slice(bytes);
    result.release(env)
}

#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)] // Rustler's public NIF arity includes the terrain palette.
fn generate_chunk<'a>(
    env: Env<'a>,
    seed: u64,
    cx: i32,
    cy: i32,
    cz: i32,
    surface: u16,
    soil: u16,
    rock: u16,
) -> Binary<'a> {
    binary_from_bytes(
        env,
        &wyram_core::generate_chunk(seed, cx, cy, cz, [surface, soil, rock]),
    )
}

#[rustler::nif]
fn read_block(data: Binary<'_>, x: usize, y: usize, z: usize) -> Result<u16, &'static str> {
    wyram_core::read_block(data.as_slice(), x, y, z).map_err(|_| "invalid chunk or block position")
}

#[rustler::nif]
fn write_block<'a>(
    env: Env<'a>,
    data: Binary<'a>,
    x: usize,
    y: usize,
    z: usize,
    id: u16,
) -> Result<Binary<'a>, &'static str> {
    wyram_core::write_block(data.as_slice(), x, y, z, id)
        .map(|bytes| binary_from_bytes(env, &bytes))
        .map_err(|_| "invalid chunk or block position")
}

type Position = (f64, f64, f64);
type Query = (Position, Position, f64, f64);
type QueryResult = (Position, (bool, bool, bool), bool);

#[rustler::nif(schedule = "DirtyCpu")]
fn read_blocks(
    data: Binary<'_>,
    positions: Vec<(usize, usize, usize)>,
) -> Result<Vec<u16>, &'static str> {
    if positions.len() > 4096 {
        return Err("oversized voxel batch");
    }
    positions
        .into_iter()
        .map(|(x, y, z)| {
            wyram_core::read_block(data.as_slice(), x, y, z).map_err(|_| "invalid voxel batch")
        })
        .collect()
}

#[rustler::nif(schedule = "DirtyCpu")]
fn compare_write_blocks<'a>(
    env: Env<'a>,
    data: Binary<'a>,
    edits: Vec<(usize, usize, usize, u16, u16)>,
) -> Result<Binary<'a>, &'static str> {
    wyram_core::batch::compare_write(data.as_slice(), &edits)
        .map(|bytes| binary_from_bytes(env, &bytes))
        .map_err(|_| "stale or invalid voxel batch")
}

#[rustler::nif(schedule = "DirtyCpu")]
fn liquid_positions(
    data: Binary<'_>,
    ids: Vec<u16>,
) -> Result<Vec<(usize, usize, usize)>, &'static str> {
    if data.len() != wyram_core::BYTE_COUNT {
        return Err("invalid chunk");
    }
    let ids: std::collections::HashSet<_> = ids.into_iter().collect();
    Ok(data
        .as_slice()
        .as_chunks::<2>()
        .0
        .iter()
        .enumerate()
        .filter_map(|(i, bytes)| {
            ids.contains(&u16::from_le_bytes([bytes[0], bytes[1]]))
                .then_some((i % 16, i / 256, (i / 16) % 16))
        })
        .collect())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn sweep_bodies(
    chunks: Vec<((i32, i32, i32), Binary<'_>)>,
    queries: Vec<Query>,
    noncolliding: Vec<u16>,
) -> Result<Vec<QueryResult>, &'static str> {
    if queries.len() > 256 {
        return Err("oversized character batch");
    }
    let world = wyram_core::PackedWorld::new(
        chunks
            .iter()
            .map(|(key, bytes)| ([key.0, key.1, key.2], bytes.as_slice())),
    )?
    .with_noncolliding(&noncolliding);
    queries
        .into_iter()
        .map(|(p, d, r, h)| {
            let result = world.sweep([p.0, p.1, p.2], [d.0, d.1, d.2], r, h)?;
            let [x, y, z] = result.position;
            let [a, b, c] = result.blocked;
            Ok(((x, y, z), (a, b, c), result.unavailable))
        })
        .collect()
}
rustler::init!("Elixir.Wyram.Engine.Native");
