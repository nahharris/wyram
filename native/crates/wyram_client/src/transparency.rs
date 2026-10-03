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
            self.chunks.remove(&key);
        } else {
            self.chunks.insert(key, quads);
        }
        self.dirty = true;
    }

    pub fn prepare(&mut self, device: &wgpu::Device, queue: &wgpu::Queue, eye: Vec3) {
        if !self.dirty && self.eye == Some(eye) {
            return;
        }
        self.eye = Some(eye);
        self.dirty = false;
        let mut quads: Vec<_> = self
            .chunks
            .values()
            .flat_map(|q| q.iter().copied())
            .collect();
        sort_quads(&mut quads, eye);
        self.count = (quads.len() * 6) as u32;
        if quads.is_empty() {
            return;
        }
        let bytes = bytemuck::cast_slice(&quads);
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
    quads.sort_by(|a, b| distance(b).total_cmp(&distance(a)));
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
}
