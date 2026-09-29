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

rustler::init!("Elixir.Wyram.Engine.Native");
