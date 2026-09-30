use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use base64::Engine;
use bytemuck::{Pod, Zeroable};
use glam::Vec3;
#[cfg(test)]
use wyram_core::BLOCK_COUNT;
use wyram_core::{BYTE_COUNT, CHUNK_SIDE};

#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
pub struct Vertex {
    pub(crate) position: [f32; 3],
    pub(crate) color: [f32; 3],
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
    chunks: HashMap<[i32; 3], Arc<Chunk>>,
    colors: Arc<HashMap<u16, [u8; 3]>>,
    generations: HashMap<[i32; 3], u64>,
    dirty: HashSet<[i32; 3]>,
    epoch: u64,
}

pub struct MeshJob {
    pub key: [i32; 3],
    pub generation: u64,
    snapshot: VoxelWorld,
}

impl MeshJob {
    pub fn build(&self) -> Vec<Vertex> {
        let data = &self
            .snapshot
            .chunks
            .get(&self.key)
            .expect("mesh snapshot has its chunk")
            .data;
        crate::chunk_mesh::build(data, self.key, &self.snapshot.colors, |p| {
            self.snapshot.block(p[0], p[1], p[2])
        })
    }
}

const NEIGHBORS: [[i32; 3]; 6] = [
    [1, 0, 0],
    [-1, 0, 0],
    [0, 1, 0],
    [0, -1, 0],
    [0, 0, 1],
    [0, 0, -1],
];

impl VoxelWorld {
    pub fn set_palette(&mut self, colors: HashMap<String, [u8; 3]>) {
        self.colors = Arc::new(
            colors
                .into_iter()
                .filter_map(|(key, value)| key.parse::<u16>().ok().map(|id| (id, value)))
                .collect(),
        );
        let keys: Vec<_> = self.chunks.keys().copied().collect();
        for key in keys {
            self.invalidate(key);
        }
    }

    pub fn has_block_id(&self, id: u16) -> bool {
        self.colors.contains_key(&id)
    }

    pub fn receive_chunk(&mut self, key: [i32; 3], revision: u64, data: &str) -> bool {
        if self
            .chunks
            .get(&key)
            .is_some_and(|old| old.revision >= revision)
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
            Arc::new(Chunk {
                revision,
                data: bytes,
            }),
        );
        self.invalidate_neighborhood(key);
        true
    }

    pub fn forget(&mut self, key: [i32; 3]) {
        self.chunks.remove(&key);
        self.generations.remove(&key);
        self.dirty.remove(&key);
        self.invalidate_neighborhood(key);
    }

    fn invalidate(&mut self, key: [i32; 3]) {
        if self.chunks.contains_key(&key) {
            self.epoch = self
                .epoch
                .checked_add(1)
                .expect("mesh generation exhausted");
            self.generations.insert(key, self.epoch);
            self.dirty.insert(key);
        }
    }

    fn invalidate_neighborhood(&mut self, key: [i32; 3]) {
        self.invalidate(key);
        for offset in NEIGHBORS {
            self.invalidate(std::array::from_fn(|i| key[i] + offset[i]));
        }
    }

    pub fn mesh_is_current(&self, key: [i32; 3], generation: u64) -> bool {
        self.generations.get(&key) == Some(&generation)
    }

    pub fn mesh_job(&mut self, key: [i32; 3]) -> Option<MeshJob> {
        let generation = *self.generations.get(&key)?;
        let mut chunks = HashMap::new();
        chunks.insert(key, Arc::clone(self.chunks.get(&key)?));
        for offset in NEIGHBORS {
            let neighbor = std::array::from_fn(|i| key[i] + offset[i]);
            if let Some(chunk) = self.chunks.get(&neighbor) {
                chunks.insert(neighbor, Arc::clone(chunk));
            }
        }
        self.dirty.remove(&key);
        Some(MeshJob {
            key,
            generation,
            snapshot: Self {
                chunks,
                colors: Arc::clone(&self.colors),
                ..Self::default()
            },
        })
    }

    pub fn next_mesh_job(&mut self, center: [i32; 3], busy: &HashSet<[i32; 3]>) -> Option<MeshJob> {
        let key = self
            .dirty
            .iter()
            .filter(|key| !busy.contains(*key))
            .min_by_key(|key| {
                let distance: i64 = (0..3)
                    .map(|i| (i64::from(key[i]) - i64::from(center[i])).abs())
                    .sum();
                (distance, **key)
            })
            .copied()?;
        self.mesh_job(key)
    }

    pub fn chunk_count(&self) -> usize {
        self.chunks.len()
    }
    pub fn dirty_count(&self) -> usize {
        self.dirty.len()
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

    #[cfg(test)]
    fn mesh_chunk(&self, key: [i32; 3]) -> Vec<Vertex> {
        use crate::chunk_mesh::FACES;
        let mut result = Vec::new();
        if let Some(chunk) = self.chunks.get(&key) {
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
#[path = "mesh_tests.rs"]
mod mesh_tests;

#[cfg(test)]
mod tests {
    use super::*;

    fn encoded_block(x: usize) -> String {
        let mut data = vec![0; BYTE_COUNT];
        data[x * 2] = 1;
        base64::engine::general_purpose::STANDARD.encode(data)
    }

    #[test]
    fn chunk_mesh_culls_and_restores_neighbor_faces() {
        let mut world = VoxelWorld::default();
        world.receive_chunk([0, 0, 0], 0, &encoded_block(15));
        assert_eq!(world.mesh_job([0, 0, 0]).unwrap().build().len(), 36);
        world.receive_chunk([1, 0, 0], 0, &encoded_block(0));
        assert_eq!(world.mesh_job([0, 0, 0]).unwrap().build().len(), 30);
        world.forget([1, 0, 0]);
        assert_eq!(world.mesh_job([0, 0, 0]).unwrap().build().len(), 36);
    }

    #[test]
    fn every_chunk_face_uses_neighbor_data_at_negative_coordinates() {
        let key = [-2, -3, -4];
        for offset in NEIGHBORS {
            let local: [usize; 3] = std::array::from_fn(|i| if offset[i] > 0 { 15 } else { 0 });
            let neighbor_local: [usize; 3] =
                std::array::from_fn(|i| if offset[i] < 0 { 15 } else { 0 });
            let index = |p: [usize; 3]| (p[1] * CHUNK_SIDE + p[2]) * CHUNK_SIDE + p[0];
            let mut world = VoxelWorld::default();
            world.receive_chunk(key, 0, &encoded_block(index(local)));
            let neighbor = std::array::from_fn(|i| key[i] + offset[i]);
            world.receive_chunk(neighbor, 0, &encoded_block(index(neighbor_local)));
            assert_eq!(world.mesh_job(key).unwrap().build().len(), 30);
            assert_eq!(world.mesh_job(neighbor).unwrap().build().len(), 30);
            world.forget(neighbor);
            assert_eq!(world.mesh_job(key).unwrap().build().len(), 36);
        }
    }

    #[test]
    fn snapshots_are_immutable_and_neighbor_changes_invalidate_results() {
        let mut world = VoxelWorld::default();
        world.receive_chunk([0, 0, 0], 0, &encoded_block(15));
        let job = world.mesh_job([0, 0, 0]).unwrap();
        world.receive_chunk([1, 0, 0], 0, &encoded_block(0));
        assert!(!world.mesh_is_current(job.key, job.generation));
        assert_eq!(job.build().len(), 36);
        assert_eq!(world.mesh_job([0, 0, 0]).unwrap().build().len(), 30);
    }

    #[test]
    fn unload_reload_and_palette_changes_reject_old_results() {
        let mut world = VoxelWorld::default();
        world.receive_chunk([0, 0, 0], 7, &encoded_block(0));
        let job = world.mesh_job([0, 0, 0]).unwrap();
        world.forget([0, 0, 0]);
        assert!(!world.mesh_is_current(job.key, job.generation));
        world.receive_chunk([0, 0, 0], 7, &encoded_block(0));
        assert!(!world.mesh_is_current(job.key, job.generation));
        let job = world.mesh_job([0, 0, 0]).unwrap();
        world.set_palette(HashMap::from([("1".into(), [1, 2, 3])]));
        assert!(!world.mesh_is_current(job.key, job.generation));
        assert!(!world.receive_chunk([0, 0, 0], 6, &encoded_block(0)));
        assert!(!world.receive_chunk([0, 0, 0], 7, &encoded_block(0)));
    }

    #[test]
    fn collision_uses_negative_chunk_coordinates() {
        let mut world = VoxelWorld::default();
        let data = wyram_core::generate_chunk(3, -1, 3, -1, [1, 2, 3]);
        world
            .chunks
            .insert([-1, 3, -1], Arc::new(Chunk { revision: 0, data }));
        assert_eq!(world.block(-1, 48, -1), 3);
        assert!(world.collides(Vec3::new(-0.5, 49.0, -0.5)));
    }
}
