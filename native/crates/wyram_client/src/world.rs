use std::collections::HashMap;

use base64::Engine;
use bytemuck::{Pod, Zeroable};
use glam::Vec3;
use wyram_core::{BLOCK_COUNT, BYTE_COUNT, CHUNK_SIDE};

#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
pub struct Vertex {
    position: [f32; 3],
    color: [f32; 3],
}

impl Vertex {
    pub fn layout() -> wgpu::VertexBufferLayout<'static> {
        wgpu::VertexBufferLayout {
            array_stride: size_of::<Self>() as u64,
            step_mode: wgpu::VertexStepMode::Vertex,
            attributes: &[
                wgpu::VertexAttribute {
                    offset: 0,
                    shader_location: 0,
                    format: wgpu::VertexFormat::Float32x3,
                },
                wgpu::VertexAttribute {
                    offset: 12,
                    shader_location: 1,
                    format: wgpu::VertexFormat::Float32x3,
                },
            ],
        }
    }
}

struct Chunk {
    revision: u64,
    data: Vec<u8>,
}

#[derive(Default)]
pub struct VoxelWorld {
    chunks: HashMap<[i32; 3], Chunk>,
    colors: HashMap<u16, [u8; 3]>,
}

impl VoxelWorld {
    pub fn set_palette(&mut self, colors: HashMap<String, [u8; 3]>) {
        self.colors = colors
            .into_iter()
            .filter_map(|(key, value)| key.parse::<u16>().ok().map(|id| (id, value)))
            .collect();
    }

    pub fn has_block_id(&self, id: u16) -> bool {
        self.colors.contains_key(&id)
    }

    pub fn receive_chunk(&mut self, key: [i32; 3], revision: u64, data: &str) -> bool {
        if self
            .chunks
            .get(&key)
            .is_some_and(|old| old.revision > revision)
        {
            return false;
        }
        let Ok(bytes) = base64::engine::general_purpose::STANDARD.decode(data) else {
            return false;
        };
        if bytes.len() != BYTE_COUNT {
            return false;
        }
        self.chunks.insert(
            key,
            Chunk {
                revision,
                data: bytes,
            },
        );
        true
    }

    pub fn forget(&mut self, key: [i32; 3]) {
        self.chunks.remove(&key);
    }

    pub fn block(&self, x: i32, y: i32, z: i32) -> u16 {
        let key = [
            x.div_euclid(CHUNK_SIDE as i32),
            y.div_euclid(CHUNK_SIDE as i32),
            z.div_euclid(CHUNK_SIDE as i32),
        ];
        let Some(chunk) = self.chunks.get(&key) else {
            return 0;
        };
        let lx = x.rem_euclid(CHUNK_SIDE as i32) as usize;
        let ly = y.rem_euclid(CHUNK_SIDE as i32) as usize;
        let lz = z.rem_euclid(CHUNK_SIDE as i32) as usize;
        let at = ((ly * CHUNK_SIDE + lz) * CHUNK_SIDE + lx) * 2;
        u16::from_le_bytes([chunk.data[at], chunk.data[at + 1]])
    }

    pub fn collides(&self, eye: Vec3) -> bool {
        for x in [eye.x - 0.28, eye.x + 0.28] {
            for z in [eye.z - 0.28, eye.z + 0.28] {
                for y in [eye.y - 1.62, eye.y - 0.08] {
                    if self.block(x.floor() as i32, y.floor() as i32, z.floor() as i32) != 0 {
                        return true;
                    }
                }
            }
        }
        false
    }

    pub fn mesh(&self) -> Vec<Vertex> {
        const FACES: [([i32; 3], [[f32; 3]; 4], f32); 6] = [
            (
                [1, 0, 0],
                [[1., 0., 0.], [1., 1., 0.], [1., 1., 1.], [1., 0., 1.]],
                0.78,
            ),
            (
                [-1, 0, 0],
                [[0., 0., 1.], [0., 1., 1.], [0., 1., 0.], [0., 0., 0.]],
                0.66,
            ),
            (
                [0, 1, 0],
                [[0., 1., 0.], [0., 1., 1.], [1., 1., 1.], [1., 1., 0.]],
                1.0,
            ),
            (
                [0, -1, 0],
                [[0., 0., 1.], [0., 0., 0.], [1., 0., 0.], [1., 0., 1.]],
                0.45,
            ),
            (
                [0, 0, 1],
                [[1., 0., 1.], [1., 1., 1.], [0., 1., 1.], [0., 0., 1.]],
                0.82,
            ),
            (
                [0, 0, -1],
                [[0., 0., 0.], [0., 1., 0.], [1., 1., 0.], [1., 0., 0.]],
                0.72,
            ),
        ];
        let mut result = Vec::new();
        for (key, chunk) in &self.chunks {
            for index in 0..BLOCK_COUNT {
                let at = index * 2;
                let id = u16::from_le_bytes([chunk.data[at], chunk.data[at + 1]]);
                if id == 0 {
                    continue;
                }
                let x = (index % CHUNK_SIDE) as i32 + key[0] * CHUNK_SIDE as i32;
                let y = (index / (CHUNK_SIDE * CHUNK_SIDE)) as i32 + key[1] * CHUNK_SIDE as i32;
                let z = ((index / CHUNK_SIDE) % CHUNK_SIDE) as i32 + key[2] * CHUNK_SIDE as i32;
                let base = self.colors.get(&id).copied().unwrap_or([255, 0, 255]);
                for (offset, corners, shade) in FACES {
                    if self.block(x + offset[0], y + offset[1], z + offset[2]) != 0 {
                        continue;
                    }
                    let color = [
                        base[0] as f32 / 255.0 * shade,
                        base[1] as f32 / 255.0 * shade,
                        base[2] as f32 / 255.0 * shade,
                    ];
                    for corner in [0, 1, 2, 0, 2, 3] {
                        result.push(Vertex {
                            position: [
                                x as f32 + corners[corner][0],
                                y as f32 + corners[corner][1],
                                z as f32 + corners[corner][2],
                            ],
                            color,
                        });
                    }
                }
            }
        }
        result
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn collision_uses_negative_chunk_coordinates() {
        let mut world = VoxelWorld::default();
        let data = wyram_core::generate_chunk(3, -1, 3, -1, [1, 2, 3]);
        world
            .chunks
            .insert([-1, 3, -1], Chunk { revision: 0, data });
        assert_eq!(world.block(-1, 48, -1), 3);
        assert!(world.collides(Vec3::new(-0.5, 49.0, -0.5)));
    }
}
