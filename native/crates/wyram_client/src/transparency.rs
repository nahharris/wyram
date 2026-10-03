use crate::world::Vertex;
use glam::Vec3;
use std::collections::BTreeMap;

#[derive(Default)]
pub struct BlendedMeshes {
    chunks: BTreeMap<[i32; 3], Vec<[Vertex; 6]>>,
    buffer: Option<wgpu::Buffer>,
    capacity: usize,
    count: u32,
    dirty: bool,
    eye: Option<Vec3>,
    scratch: Vec<[Vertex; 6]>,
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

    pub fn prepare(&mut self, device: &wgpu::Device, queue: &wgpu::Queue, eye: Vec3) -> usize {
        if !self.dirty && self.eye == Some(eye) {
            return 0;
        }
        self.eye = Some(eye);
        self.dirty = false;
        self.scratch.clear();
        self.scratch
            .extend(self.chunks.values().flat_map(|q| q.iter().copied()));
        sort_quads(&mut self.scratch, eye);
        self.count = (self.scratch.len() * 6) as u32;
        if self.scratch.is_empty() {
            return 0;
        }
        let bytes = bytemuck::cast_slice(&self.scratch);
        if bytes.len() > self.capacity {
            self.capacity = bytes.len().next_power_of_two();
            self.buffer = Some(device.create_buffer(&wgpu::BufferDescriptor {
                label: Some("Sorted blended faces"),
                size: self.capacity as u64,
                usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::COPY_DST,
                mapped_at_creation: false,
            }));
        }
        queue.write_buffer(
            self.buffer.as_ref().expect("blended buffer allocated"),
            0,
            bytes,
        );
        bytes.len()
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
            pass.draw(0..self.count, 0..1);
        }
    }
}

fn sort_quads(quads: &mut [[Vertex; 6]], eye: Vec3) {
    let distance = |q: &[Vertex; 6]| {
        let center = (Vec3::from_array(q[0].position) + Vec3::from_array(q[2].position)) * 0.5;
        center.distance_squared(eye)
    };
    // IEEE total order, descending; cached keys avoid recomputing distances and
    // sorting moves small indices rather than the 168-byte quads. Stable ties
    // retain the original chunk/face ordering, as in sort_by(total_cmp).
    quads.sort_by_cached_key(|q| {
        let bits = distance(q).to_bits();
        std::cmp::Reverse(if bits & 0x8000_0000 == 0 {
            bits ^ 0x8000_0000
        } else {
            !bits
        })
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::world::Vertex;
    use glam::Vec3;

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

    fn reference_sort(quads: &mut [[Vertex; 6]], eye: Vec3) {
        let distance = |q: &[Vertex; 6]| {
            let center = (Vec3::from_array(q[0].position) + Vec3::from_array(q[2].position)) * 0.5;
            center.distance_squared(eye)
        };
        quads.sort_by(|a, b| distance(b).total_cmp(&distance(a)));
    }

    #[test]
    fn cached_sort_preserves_exact_order_and_stable_distance_ties() {
        for eye in [Vec3::ZERO, Vec3::new(-33.0, 12.0, 2048.0)] {
            let mut expected = fixture();
            let mut actual = expected.clone();
            reference_sort(&mut expected, eye);
            sort_quads(&mut actual, eye);
            assert!(actual == expected);
        }
    }

    #[test]
    #[ignore = "manual paired transparency CPU benchmark"]
    fn benchmark_blended_sort() {
        let input = fixture();
        for round in 0..8 {
            for cached in if round % 2 == 0 {
                [false, true]
            } else {
                [true, false]
            } {
                let mut quads = input.clone();
                let start = std::time::Instant::now();
                if cached {
                    sort_quads(&mut quads, Vec3::ZERO);
                } else {
                    reference_sort(&mut quads, Vec3::ZERO);
                }
                println!(
                    "sort round={round} cached={cached} ms={:.4}",
                    start.elapsed().as_secs_f64() * 1000.0
                );
                std::hint::black_box(quads);
            }
        }
    }

    #[test]
    fn opaque_and_empty_replacements_leave_blended_content_clean() {
        let mut scene = BlendedMeshes::default();
        let opaque = [Vertex {
            position: [0.0; 3],
            color: [1.0; 3],
            opacity: 1.0,
        }; 6];
        scene.replace([0, 0, 0], &opaque);
        assert!(
            !scene.dirty,
            "opaque-only chunks do not change blended content"
        );
        scene.replace([0, 0, 0], &[]);
        assert!(
            !scene.dirty,
            "absent empty chunks do not change blended content"
        );
    }

    #[test]
    fn identical_blended_replacement_is_clean_but_removal_invalidates() {
        let mut scene = BlendedMeshes::default();
        let blended = [Vertex {
            position: [1.0, 2.0, 3.0],
            color: [0.5; 3],
            opacity: 0.5,
        }; 6];
        scene.replace([0, 0, 0], &blended);
        assert!(scene.dirty);
        scene.dirty = false; // Represents the completed GPU preparation.
        scene.replace([0, 0, 0], &blended);
        assert!(
            !scene.dirty,
            "unchanged quads do not need another global sort/upload"
        );
        scene.replace([0, 0, 0], &[]);
        assert!(scene.dirty);
        assert!(scene.chunks.is_empty());
    }
}
