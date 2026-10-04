pub mod batch;
pub mod collision;
pub mod scenery;
pub mod worldgen;
pub use collision::PackedWorld;

pub const CHUNK_SIDE: usize = 16;
pub const BLOCK_COUNT: usize = CHUNK_SIDE * CHUNK_SIDE * CHUNK_SIDE;
pub const BYTE_COUNT: usize = BLOCK_COUNT * 2;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ChunkError {
    BadLength,
    OutOfBounds,
    Precondition,
}

#[inline]
pub fn index(x: usize, y: usize, z: usize) -> Result<usize, ChunkError> {
    if x >= CHUNK_SIDE || y >= CHUNK_SIDE || z >= CHUNK_SIDE {
        return Err(ChunkError::OutOfBounds);
    }
    Ok((y * CHUNK_SIDE + z) * CHUNK_SIDE + x)
}

pub fn read_block(data: &[u8], x: usize, y: usize, z: usize) -> Result<u16, ChunkError> {
    if data.len() != BYTE_COUNT {
        return Err(ChunkError::BadLength);
    }
    let at = index(x, y, z)? * 2;
    Ok(u16::from_le_bytes([data[at], data[at + 1]]))
}

pub fn write_block(
    data: &[u8],
    x: usize,
    y: usize,
    z: usize,
    id: u16,
) -> Result<Vec<u8>, ChunkError> {
    if data.len() != BYTE_COUNT {
        return Err(ChunkError::BadLength);
    }
    let at = index(x, y, z)? * 2;
    let mut result = data.to_vec();
    result[at..at + 2].copy_from_slice(&id.to_le_bytes());
    Ok(result)
}

fn hash(seed: u64, x: i32, z: i32) -> u32 {
    let mut value = seed
        ^ (x as u32 as u64).wrapping_mul(0x9e37_79b9_7f4a_7c15)
        ^ (z as u32 as u64).wrapping_mul(0xbf58_476d_1ce4_e5b9);
    value ^= value >> 30;
    value = value.wrapping_mul(0xbf58_476d_1ce4_e5b9);
    value ^= value >> 27;
    value = value.wrapping_mul(0x94d0_49bb_1331_11eb);
    (value ^ (value >> 31)) as u32
}

pub fn terrain_height(seed: u64, x: i32, z: i32) -> i32 {
    let coarse = hash(seed, x.div_euclid(8), z.div_euclid(8)) % 7;
    let detail = hash(seed ^ 0x5941_472d, x, z) % 3;
    56 + coarse as i32 + detail as i32
}

pub fn generate_chunk(seed: u64, cx: i32, cy: i32, cz: i32, palette: [u16; 3]) -> Vec<u8> {
    let mut result = vec![0; BYTE_COUNT];
    for z in 0..CHUNK_SIDE {
        for x in 0..CHUNK_SIDE {
            let world_x = cx * CHUNK_SIDE as i32 + x as i32;
            let world_z = cz * CHUNK_SIDE as i32 + z as i32;
            let surface = terrain_height(seed, world_x, world_z);
            for y in 0..CHUNK_SIDE {
                let world_y = cy * CHUNK_SIDE as i32 + y as i32;
                let id = if world_y > surface {
                    0
                } else if world_y == surface {
                    palette[0]
                } else if world_y > surface - 4 {
                    palette[1]
                } else {
                    palette[2]
                };
                let at = index(x, y, z).expect("coordinates are in range") * 2;
                result[at..at + 2].copy_from_slice(&id.to_le_bytes());
            }
        }
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generated_chunks_are_stable_and_are_correctly_addressed() {
        let palette = [17, 29, 43];
        let one = generate_chunk(7, -1, 3, 0, palette);
        assert_eq!(one, generate_chunk(7, -1, 3, 0, palette));
        assert_ne!(one, generate_chunk(7, 0, 3, 0, palette));
        assert_eq!(one.len(), BYTE_COUNT);
        assert_eq!(read_block(&one, 0, 0, 0), Ok(palette[2]));
    }

    #[test]
    fn edit_changes_only_the_requested_block() {
        let original = generate_chunk(5, 0, 4, 0, [17, 29, 43]);
        let edited = write_block(&original, 2, 3, 4, 42).unwrap();
        assert_eq!(read_block(&edited, 2, 3, 4), Ok(42));
        assert_eq!(read_block(&original, 2, 3, 4), Ok(0));
        assert_eq!(read_block(&edited, 3, 3, 4), read_block(&original, 3, 3, 4));
        assert_eq!(
            write_block(&original, 16, 0, 0, 1),
            Err(ChunkError::OutOfBounds)
        );
    }
}

#[cfg(test)]
#[path = "collision_tests.rs"]
mod collision_tests;
