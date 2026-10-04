use crate::world::Vertex;
use glam::Vec3;
use std::collections::BTreeMap;

#[derive(Default)]
pub struct BlendedMeshes {
    chunks: BTreeMap<[i32; 3], Vec<[Vertex; 6]>>,
    buffer: Option<wgpu::Buffer>,
    capacity: usize,
    index_buffer: Option<wgpu::Buffer>,
    index_capacity: usize,
    count: u32,
    dirty: bool,
    eye: Option<Vec3>,
    vertices: Vec<[Vertex; 6]>,
    centers: Vec<Vec3>,
    order: Vec<u64>,
    indices: Vec<u32>,
}

#[derive(Default)]
struct UploadPlan {
    vertices: bool,
    indices: bool,
}

impl BlendedMeshes {
    pub fn replace(&mut self, key: [i32; 3], vertices: &[Vertex]) {
        let quads: Vec<_> = vertices
            .as_chunks::<6>()
            .0
            .iter()
            .filter(|q| q[0].opacity < 1.0)
            .copied()
            .collect();
        if quads.is_empty() {
            self.dirty |= self.chunks.remove(&key).is_some();
        } else if self.chunks.get(&key) != Some(&quads) {
            self.chunks.insert(key, quads);
            self.dirty = true;
        }
    }

    fn prepare_cpu(&mut self, eye: Vec3) -> UploadPlan {
        if !self.dirty && self.eye == Some(eye) {
            return UploadPlan::default();
        }
        let geometry_changed = self.dirty;
        self.eye = Some(eye);
        self.dirty = false;
        if geometry_changed {
            self.vertices.clear();
            self.vertices
                .extend(self.chunks.values().flat_map(|quads| quads.iter().copied()));
            self.centers.clear();
            self.centers.extend(self.vertices.iter().map(|quad| {
                (Vec3::from_array(quad[0].position) + Vec3::from_array(quad[2].position)) * 0.5
            }));
        }
        self.count = u32::try_from(self.vertices.len() * 6)
            .expect("resident blended vertex count fits GPU indices");
        self.order.clear();
        self.order
            .extend(self.centers.iter().enumerate().map(|(index, center)| {
                let bits = center.distance_squared(eye).to_bits();
                let ordered = if bits & 0x8000_0000 == 0 {
                    bits ^ 0x8000_0000
                } else {
                    !bits
                };
                ((u64::from(!ordered)) << 32) | index as u64
            }));
        // The original face index is the explicit tie-breaker, so every camera
        // update retains canonical chunk/face order even after previous sorts.
        self.order.sort_unstable();
        self.indices.resize(self.count as usize, 0);
        for (triangle_pair, &rank) in self
            .indices
            .as_chunks_mut::<6>()
            .0
            .iter_mut()
            .zip(&self.order)
        {
            let first = rank as u32 * 6;
            *triangle_pair = [first, first + 1, first + 2, first + 3, first + 4, first + 5];
        }
        UploadPlan {
            vertices: geometry_changed,
            indices: true,
        }
    }

    pub fn prepare(&mut self, device: &wgpu::Device, queue: &wgpu::Queue, eye: Vec3) {
        let plan = self.prepare_cpu(eye);
        if self.count == 0 {
            return;
        }
        if plan.vertices {
            upload(
                device,
                queue,
                &mut self.buffer,
                &mut self.capacity,
                bytemuck::cast_slice(&self.vertices),
                wgpu::BufferUsages::VERTEX,
                "Resident blended faces",
            );
        }
        if plan.indices {
            upload(
                device,
                queue,
                &mut self.index_buffer,
                &mut self.index_capacity,
                bytemuck::cast_slice(&self.indices),
                wgpu::BufferUsages::INDEX,
                "Ordered blended indices",
            );
        }
    }

    pub fn draw(&self, pass: &mut wgpu::RenderPass<'_>) {
        if self.count > 0 {
            pass.set_vertex_buffer(
                0,
                self.buffer
                    .as_ref()
                    .expect("blended buffer allocated")
                    .slice(..),
            );
            pass.set_index_buffer(
                self.index_buffer
                    .as_ref()
                    .expect("blended index buffer allocated")
                    .slice(..),
                wgpu::IndexFormat::Uint32,
            );
            pass.draw_indexed(0..self.count, 0, 0..1);
        }
    }
}

fn upload(
    device: &wgpu::Device,
    queue: &wgpu::Queue,
    buffer: &mut Option<wgpu::Buffer>,
    capacity: &mut usize,
    bytes: &[u8],
    usage: wgpu::BufferUsages,
    label: &str,
) {
    if bytes.len() > *capacity {
        *capacity = bytes.len().next_power_of_two();
        *buffer = Some(device.create_buffer(&wgpu::BufferDescriptor {
            label: Some(label),
            size: *capacity as u64,
            usage: usage | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        }));
    }
    queue.write_buffer(buffer.as_ref().expect("blended buffer allocated"), 0, bytes);
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::world::Vertex;
    use glam::Vec3;

    fn sort_quads(quads: &mut [[Vertex; 6]], eye: Vec3) {
        let distance = |quad: &[Vertex; 6]| {
            let center =
                (Vec3::from_array(quad[0].position) + Vec3::from_array(quad[2].position)) * 0.5;
            center.distance_squared(eye)
        };
        quads.sort_by(|a, b| distance(b).total_cmp(&distance(a)));
    }

    #[test]
    fn transparent_quads_sort_back_to_front_after_camera_changes() {
        let quad = |x| {
            [Vertex {
                position: [x, 0.0, 0.0],
                color: [1.0; 3],
                opacity: 0.5,
            }; 6]
        };
        let mut quads = vec![quad(1.0), quad(3.0)];
        sort_quads(&mut quads, Vec3::ZERO);
        assert_eq!(quads[0][0].position[0], 3.0);
        sort_quads(&mut quads, Vec3::new(4.0, 0.0, 0.0));
        assert_eq!(quads[0][0].position[0], 1.0);
    }

    #[test]
    fn unchanged_content_does_not_invalidate_resident_geometry() {
        let mut scene = BlendedMeshes::default();
        let blended = [Vertex {
            position: [1.0, 2.0, 3.0],
            color: [0.5; 3],
            opacity: 0.5,
        }; 6];
        scene.replace([0, 0, 0], &blended);
        scene.dirty = false;
        scene.replace([0, 0, 0], &blended);
        assert!(!scene.dirty, "identical geometry must stay resident");
        scene.replace([1, 0, 0], &[]);
        assert!(!scene.dirty, "an absent empty chunk changes no geometry");
        let mut opaque = blended;
        opaque.iter_mut().for_each(|vertex| vertex.opacity = 1.0);
        scene.replace([1, 0, 0], &opaque);
        assert!(!scene.dirty, "opaque content changes no blended geometry");
        scene.replace([0, 0, 0], &[]);
        assert!(
            scene.dirty,
            "removing existing blended content invalidates it"
        );
    }

    #[test]
    fn camera_motion_changes_only_indices_and_preserves_global_triangle_order() {
        let mut scene = BlendedMeshes::default();
        let quad = |x, tag| {
            [Vertex {
                position: [x, 0.0, 0.0],
                color: [tag, 0.0, 0.0],
                opacity: 0.5,
            }; 6]
        };
        // Chunk order deliberately differs from arrival order. Equal-distance
        // faces must retain canonical chunk/face order across camera changes.
        scene.replace([1, 0, 0], &quad(3.0, 3.0));
        scene.replace([0, 0, 0], &[quad(1.0, 1.0), quad(-1.0, 2.0)].concat());
        let initial = scene.prepare_cpu(Vec3::ZERO);
        assert!(initial.vertices && initial.indices);
        let resident = scene.vertices.clone();
        let address = scene.vertices.as_ptr();
        for eye in [Vec3::ZERO, Vec3::new(4.0, 0.0, 0.0), Vec3::ZERO] {
            let plan = scene.prepare_cpu(eye);
            assert!(!plan.vertices, "moving the camera never rewrites geometry");
            assert!(scene.vertices == resident);
            assert_eq!(scene.vertices.as_ptr(), address);
            let mut expected = resident.clone();
            sort_quads(&mut expected, eye);
            let actual: Vec<_> = scene
                .indices
                .iter()
                .map(|&i| scene.vertices[i as usize / 6][i as usize % 6])
                .collect();
            assert!(
                actual == expected.concat(),
                "indexed triangles preserve exact global order"
            );
        }
        let unchanged = scene.prepare_cpu(Vec3::ZERO);
        assert!(!unchanged.vertices && !unchanged.indices);
    }

    #[test]
    fn removal_and_replacement_rebuild_indices_without_referencing_old_vertices() {
        let mut scene = BlendedMeshes::default();
        let quad = [Vertex {
            position: [10.0, 2.0, -8.0],
            color: [0.4; 3],
            opacity: 0.5,
        }; 6];
        scene.replace([0, 0, 0], &quad);
        scene.replace([1, 0, 0], &quad);
        scene.prepare_cpu(Vec3::ZERO);
        assert_eq!(scene.indices.len(), 12);
        scene.replace([0, 0, 0], &[]);
        let changed = scene.prepare_cpu(Vec3::ZERO);
        assert!(changed.vertices && changed.indices);
        assert_eq!(scene.vertices.len(), 1);
        assert_eq!(scene.indices, (0..6).collect::<Vec<_>>());
        scene.replace([1, 0, 0], &[]);
        scene.prepare_cpu(Vec3::ZERO);
        assert!(scene.vertices.is_empty() && scene.indices.is_empty());
    }

    fn fixture() -> Vec<[Vertex; 6]> {
        (0..20_000)
            .map(|i| {
                [Vertex {
                    position: [(i * 7919 % 997) as f32, (i % 17) as f32, (i % 31) as f32],
                    color: [i as f32, 0.0, 0.0],
                    opacity: 0.5,
                }; 6]
            })
            .collect()
    }

    #[test]
    fn indexed_order_matches_reference_for_large_scene_and_nonfinite_distances() {
        let mut input = fixture();
        for x in [f32::NAN, f32::INFINITY, f32::NEG_INFINITY] {
            input.push(
                [Vertex {
                    position: [x, 0.0, 0.0],
                    color: [0.0; 3],
                    opacity: 0.5,
                }; 6],
            );
        }
        let mut scene = BlendedMeshes::default();
        scene.replace([0, 0, 0], &input.concat());
        for eye in [Vec3::ZERO, Vec3::new(-33.0, 12.0, 2048.0), Vec3::ZERO] {
            scene.prepare_cpu(eye);
            let mut expected = input.clone();
            sort_quads(&mut expected, eye);
            let actual: Vec<_> = scene
                .indices
                .iter()
                .map(|&i| scene.vertices[i as usize / 6][i as usize % 6])
                .collect();
            assert_eq!(
                bytemuck::cast_slice::<_, u8>(&actual),
                bytemuck::cast_slice::<_, u8>(&expected.concat())
            );
        }
    }

    #[test]
    #[ignore = "manual paired blended preparation CPU benchmark"]
    fn benchmark_resident_blended_geometry() {
        let input = fixture();
        let mut scene = BlendedMeshes::default();
        scene.replace([0, 0, 0], &input.concat());
        scene.prepare_cpu(Vec3::ZERO);
        let mut scratch = Vec::with_capacity(input.len());
        for round in 0..8 {
            let eye = Vec3::new(round as f32 * 9.0 + 1.0, 16.0, -32.0);
            for resident in if round % 2 == 0 {
                [false, true]
            } else {
                [true, false]
            } {
                let start = std::time::Instant::now();
                let bytes = if resident {
                    let plan = scene.prepare_cpu(eye);
                    assert!(!plan.vertices && plan.indices);
                    std::hint::black_box(&scene.indices);
                    scene.indices.len() * size_of::<u32>()
                } else {
                    scratch.clear();
                    scratch.extend_from_slice(&input);
                    scratch.sort_by_cached_key(|quad| {
                        let center = (Vec3::from_array(quad[0].position)
                            + Vec3::from_array(quad[2].position))
                            * 0.5;
                        let bits = center.distance_squared(eye).to_bits();
                        std::cmp::Reverse(if bits & 0x8000_0000 == 0 {
                            bits ^ 0x8000_0000
                        } else {
                            !bits
                        })
                    });
                    std::hint::black_box(&scratch);
                    scratch.len() * size_of::<[Vertex; 6]>()
                };
                println!(
                    "blended round={round} resident={resident} cpu_ms={:.4} upload_bytes={bytes}",
                    start.elapsed().as_secs_f64() * 1000.0
                );
            }
        }
    }
}

#[cfg(test)]
#[path = "transparency_gpu_tests.rs"]
mod gpu_tests;
