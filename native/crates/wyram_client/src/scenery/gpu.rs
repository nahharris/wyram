use super::mesh::{Mesh, ProxyVertex};
use crate::{frustum::Frustum, transparency::BlendedMeshes};
use bytemuck::{Pod, Zeroable};
use glam::Vec3;
use std::collections::{HashMap, HashSet};
use wgpu::util::DeviceExt;
use wyram_core::scenery::TileKey;

const DIM: [u32; 3] = [33, 64, 33];
const WORDS: usize = (33usize * 64 * 33).div_ceil(32);
#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
struct Frame {
    origin: [i32; 4],
    size: [u32; 4],
    eye: [f32; 4],
    fog: [f32; 4],
    near_bounds: [i32; 4],
}

struct Resident {
    buffer: Option<wgpu::Buffer>,
    count: u32,
    low: [f32; 3],
    high: [f32; 3],
    alpha: Vec<[ProxyVertex; 6]>,
}
pub struct Scene {
    pub layout: wgpu::BindGroupLayout,
    pub group: wgpu::BindGroup,
    uniform: wgpu::Buffer,
    mask: wgpu::Buffer,
    near: HashSet<[i32; 3]>,
    mask_dirty: bool,
    near_bounds: [i32; 4],
    center: Option<[i32; 3]>,
    resident: HashMap<TileKey, Resident>,
    active: HashSet<TileKey>,
    dirty: HashSet<TileKey>,
}

fn coverage(near: &HashSet<[i32; 3]>, center: [i32; 3]) -> ([i32; 4], Vec<u32>) {
    let min_y = near.iter().map(|key| key[1]).min().unwrap_or(0);
    let origin = [center[0] - 16, min_y, center[2] - 16, 0];
    let mut words = vec![0u32; WORDS];
    for key in near {
        let p: [i32; 3] = std::array::from_fn(|i| key[i] - origin[i]);
        if p.iter()
            .enumerate()
            .any(|(i, &v)| v < 0 || v >= DIM[i] as i32)
        {
            continue;
        }
        let bit =
            ((p[1] as usize * DIM[2] as usize + p[2] as usize) * DIM[0] as usize) + p[0] as usize;
        words[bit / 32] |= 1 << (bit % 32);
    }
    (origin, words)
}

impl Scene {
    pub fn pipelines(
        &self,
        device: &wgpu::Device,
        camera: &wgpu::BindGroupLayout,
        format: wgpu::TextureFormat,
        depth: bool,
    ) -> (wgpu::RenderPipeline, wgpu::RenderPipeline) {
        let layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("Scenery pipeline layout"),
            bind_group_layouts: &[Some(camera), Some(&self.layout)],
            immediate_size: 0,
        });
        let shader = device.create_shader_module(wgpu::include_wgsl!("shader.wgsl"));
        let make = |blended| {
            let buffers = if blended {
                vec![
                    Some(crate::world::Vertex::layout()),
                    Some(BlendedMeshes::normal_layout()),
                ]
            } else {
                vec![Some(ProxyVertex::layout())]
            };
            device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
                label: Some("Scenery voxel pipeline"),
                layout: Some(&layout),
                vertex: wgpu::VertexState {
                    module: &shader,
                    entry_point: Some("vs_main"),
                    compilation_options: Default::default(),
                    buffers: &buffers,
                },
                fragment: Some(wgpu::FragmentState {
                    module: &shader,
                    entry_point: Some("fs_main"),
                    compilation_options: Default::default(),
                    targets: &[Some(wgpu::ColorTargetState {
                        format,
                        blend: blended.then_some(wgpu::BlendState::ALPHA_BLENDING),
                        write_mask: wgpu::ColorWrites::ALL,
                    })],
                }),
                primitive: wgpu::PrimitiveState {
                    cull_mode: None,
                    ..Default::default()
                },
                depth_stencil: depth.then_some(wgpu::DepthStencilState {
                    format: wgpu::TextureFormat::Depth32Float,
                    depth_write_enabled: Some(!blended),
                    depth_compare: Some(wgpu::CompareFunction::Greater),
                    stencil: Default::default(),
                    bias: Default::default(),
                }),
                multisample: Default::default(),
                multiview_mask: None,
                cache: None,
            })
        };
        (make(false), make(true))
    }
    pub fn new(device: &wgpu::Device) -> Self {
        let uniform = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("Scenery frame"),
            contents: bytemuck::bytes_of(&Frame::zeroed()),
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
        });
        let mask = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("Near mesh coverage"),
            contents: bytemuck::cast_slice(&vec![0u32; WORDS]),
            usage: wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_DST,
        });
        let entry = |binding, ty, min| wgpu::BindGroupLayoutEntry {
            binding,
            visibility: wgpu::ShaderStages::FRAGMENT,
            ty: wgpu::BindingType::Buffer {
                ty,
                has_dynamic_offset: false,
                min_binding_size: wgpu::BufferSize::new(min),
            },
            count: None,
        };
        let layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("Scenery frame layout"),
            entries: &[
                entry(0, wgpu::BufferBindingType::Uniform, 80),
                entry(
                    1,
                    wgpu::BufferBindingType::Storage { read_only: true },
                    WORDS as u64 * 4,
                ),
            ],
        });
        let group = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("Scenery frame group"),
            layout: &layout,
            entries: &[
                wgpu::BindGroupEntry {
                    binding: 0,
                    resource: uniform.as_entire_binding(),
                },
                wgpu::BindGroupEntry {
                    binding: 1,
                    resource: mask.as_entire_binding(),
                },
            ],
        });
        Self {
            layout,
            group,
            uniform,
            mask,
            near: HashSet::new(),
            mask_dirty: true,
            near_bounds: [0; 4],
            center: None,
            resident: HashMap::new(),
            active: HashSet::new(),
            dirty: HashSet::new(),
        }
    }
    pub fn near_view(&mut self, center: [i32; 3], radius: u8) {
        let radius = i32::from(radius);
        self.near_bounds = [
            (center[0] - radius) * 16,
            (center[2] - radius) * 16,
            (center[0] + radius + 1) * 16,
            (center[2] + radius + 1) * 16,
        ];
    }
    pub fn near_ready(&mut self, key: [i32; 3]) {
        self.mask_dirty |= self.near.insert(key);
    }
    pub fn forget_near(&mut self, key: [i32; 3]) {
        self.mask_dirty |= self.near.remove(&key);
    }
    pub fn frame(&mut self, queue: &wgpu::Queue, eye: Vec3, distance: f32) {
        let center = eye.to_array().map(|v| (v.floor() as i32).div_euclid(16));
        if self.center != Some(center) {
            self.mask_dirty = true;
        }
        let origin = [
            center[0] - 16,
            self.near.iter().map(|key| key[1]).min().unwrap_or(0),
            center[2] - 16,
            0,
        ];
        if self.mask_dirty {
            let (_, words) = coverage(&self.near, center);
            queue.write_buffer(&self.mask, 0, bytemuck::cast_slice(&words));
            self.mask_dirty = false;
            self.center = Some(center);
        }
        let frame = Frame {
            origin,
            size: [DIM[0], DIM[1], DIM[2], 0],
            eye: [eye.x, eye.y, eye.z, distance],
            fog: [0.43, 0.65, 0.86, distance * 0.75],
            near_bounds: self.near_bounds,
        };
        queue.write_buffer(&self.uniform, 0, bytemuck::bytes_of(&frame));
    }
    pub fn upload(&mut self, device: &wgpu::Device, key: TileKey, mesh: Mesh) {
        let opaque: Vec<_> = mesh
            .vertices
            .iter()
            .filter(|v| v.base.opacity == 1.0)
            .copied()
            .collect();
        let alpha = mesh
            .vertices
            .as_chunks::<6>()
            .0
            .iter()
            .filter(|q| q[0].base.opacity < 1.0)
            .copied()
            .collect();
        let mut low = [f32::INFINITY; 3];
        let mut high = [f32::NEG_INFINITY; 3];
        for vertex in &mesh.vertices {
            for i in 0..3 {
                low[i] = low[i].min(vertex.base.position[i]);
                high[i] = high[i].max(vertex.base.position[i]);
            }
        }
        let buffer = (!opaque.is_empty()).then(|| {
            device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
                label: Some("Scenery opaque mesh"),
                contents: bytemuck::cast_slice(&opaque),
                usage: wgpu::BufferUsages::VERTEX,
            })
        });
        self.resident.insert(
            key,
            Resident {
                buffer,
                count: opaque.len() as u32,
                low,
                high,
                alpha,
            },
        );
        self.dirty.insert(key);
    }
    pub fn select(
        &mut self,
        ready: &HashMap<TileKey, usize>,
        selected: Vec<TileKey>,
        blended: &mut BlendedMeshes,
    ) {
        self.resident.retain(|key, _| ready.contains_key(key));
        let next: HashSet<_> = selected.into_iter().collect();
        for &key in self.active.difference(&next) {
            blended.replace_far(key, &[]);
        }
        // Missing previously active residents also remove their shared alpha data.
        for &key in &self.active {
            if !self.resident.contains_key(&key) {
                blended.replace_far(key, &[]);
            }
        }
        for &key in &next {
            if (!self.active.contains(&key) || self.dirty.contains(&key))
                && let Some(mesh) = self.resident.get(&key)
            {
                blended.replace_far(key, &mesh.alpha);
            }
        }
        self.active = next;
        self.dirty.clear();
    }
    pub fn draw(
        &self,
        pass: &mut wgpu::RenderPass<'_>,
        frustum: &Frustum,
        culling: bool,
    ) -> (usize, usize) {
        let mut draws = 0;
        let mut vertices = 0;
        for key in &self.active {
            let Some(mesh) = self.resident.get(key) else {
                continue;
            };
            if mesh.count == 0 || (culling && !frustum.intersects_bounds(mesh.low, mesh.high)) {
                continue;
            }
            pass.set_vertex_buffer(0, mesh.buffer.as_ref().unwrap().slice(..));
            pass.draw(0..mesh.count, 0..1);
            draws += 1;
            vertices += mesh.count as usize;
        }
        (draws, vertices)
    }
}

#[cfg(test)]
#[path = "gpu_tests.rs"]
mod gpu_tests;

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn coverage_preserves_every_column_of_a_21_by_21_near_view() {
        let near = (-10..=10)
            .flat_map(|x| (-10..=10).map(move |z| [x, 0, z]))
            .collect();
        let (_, words) = coverage(&near, [0, 0, 0]);
        assert_eq!(words.iter().map(|word| word.count_ones()).sum::<u32>(), 441);
    }
    #[test]
    fn coverage_includes_empty_completions_and_excludes_forgotten_or_unready_chunks() {
        let mut near = HashSet::from([[-1, -4, -1], [0, -3, 0], [-10000, 99, 10000]]);
        let (origin, mask) = coverage(&near, [-1, 0, -1]);
        let contains = |key: [i32; 3], mask: &[u32]| {
            let p: [i32; 3] = std::array::from_fn(|i| key[i] - origin[i]);
            if p.iter()
                .enumerate()
                .any(|(i, &v)| v < 0 || v >= DIM[i] as i32)
            {
                return false;
            }
            let bit = ((p[1] as usize * DIM[2] as usize + p[2] as usize) * DIM[0] as usize)
                + p[0] as usize;
            mask[bit / 32] & (1 << (bit % 32)) != 0
        };
        assert!(contains([-1, -4, -1], &mask));
        assert!(contains([0, -3, 0], &mask));
        assert!(!contains([-2, -4, -1], &mask));
        assert!(!contains([-10000, 99, 10000], &mask));
        near.remove(&[0, -3, 0]);
        let (_, mask) = coverage(&near, [-1, 0, -1]);
        assert!(!contains([0, -3, 0], &mask));
        assert_eq!(mask.len(), WORDS);
    }
}
