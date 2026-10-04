use std::time::Instant;

use crate::lod_runtime::GpuPart;
use crate::transparency::{BlendedMeshes, PrepareStats};
use glam::Vec3;

const MAX_FAR_INDEX_BYTES: usize = 32 * 1024 * 1024;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum DrawSource {
    Near,
    Far(usize),
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct DrawRun {
    source: DrawSource,
    indices: std::ops::Range<u32>,
}

impl DrawRun {
    fn new(source: DrawSource, indices: std::ops::Range<u32>) -> Self {
        Self { source, indices }
    }
}

#[cfg(test)]
#[derive(Default)]
struct OrderPlan {
    indices: Vec<u32>,
    runs: Vec<DrawRun>,
}

#[derive(Default)]
pub struct CombinedTransparency {
    order: Vec<u64>,
    source_refs: Vec<u64>,
    indices: Vec<u32>,
    runs: Vec<DrawRun>,
    index_buffer: Option<wgpu::Buffer>,
    index_capacity: usize,
    eye: Option<Vec3>,
    source_centers: Vec<Vec3>,
    source_lengths: Vec<usize>,
}

impl CombinedTransparency {
    pub fn prepare(
        &mut self,
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        eye: Vec3,
        near: &BlendedMeshes,
        far: &[&GpuPart],
    ) -> PrepareStats {
        let mut far_index_bytes = 0usize;
        for part in far {
            let quads = match &part.blended {
                Some((_, vertex_count)) => {
                    assert_eq!(vertex_count % 6, 0, "far blended vertices are quads");
                    let quads = (*vertex_count / 6) as usize;
                    assert_eq!(part.blended_centers.len(), quads);
                    far_index_bytes = far_index_bytes
                        .checked_add(quads * 6 * size_of::<u32>())
                        .expect("far LOD index size fits usize");
                    quads
                }
                None => {
                    assert!(part.blended_centers.is_empty());
                    0
                }
            };
            debug_assert_eq!(quads, part.blended_centers.len());
        }
        assert!(
            far_index_bytes <= MAX_FAR_INDEX_BYTES,
            "far transparency index budget exceeded"
        );

        let near_centers = near.quad_centers();
        if self.can_reuse(eye, near_centers, far) {
            return PrepareStats {
                quads: self.order.len(),
                ..PrepareStats::default()
            };
        }

        let sort_start = Instant::now();
        build_order_into(
            eye,
            near_centers,
            far,
            &mut self.order,
            &mut self.source_refs,
            &mut self.indices,
            &mut self.runs,
        );
        let sort_ms = sort_start.elapsed().as_secs_f64() * 1000.0;

        self.eye = Some(eye);
        self.remember_centers(near_centers, far);

        if self.indices.is_empty() {
            self.index_buffer = None;
            self.index_capacity = 0;
            return PrepareStats {
                sort_ms,
                ..PrepareStats::default()
            };
        }

        let write_start = Instant::now();
        let bytes = std::mem::size_of_val(self.indices.as_slice());
        let near_bytes = near_centers.len() * 6 * size_of::<u32>();
        let near_capacity = if near_bytes == 0 {
            0
        } else {
            near_bytes
                .checked_next_power_of_two()
                .expect("near transparency index capacity fits usize")
        };
        let max_capacity = near_capacity
            .checked_add(MAX_FAR_INDEX_BYTES)
            .expect("combined transparency index capacity fits usize");
        let desired_capacity = bytes
            .checked_next_power_of_two()
            .unwrap_or(bytes)
            .min(max_capacity);
        if self.index_capacity < bytes || self.index_capacity > max_capacity {
            self.index_capacity = desired_capacity;
            self.index_buffer = Some(device.create_buffer(&wgpu::BufferDescriptor {
                label: Some("Combined transparent draw indices"),
                size: self.index_capacity as u64,
                usage: wgpu::BufferUsages::INDEX | wgpu::BufferUsages::COPY_DST,
                mapped_at_creation: false,
            }));
        }
        queue.write_buffer(
            self.index_buffer
                .as_ref()
                .expect("combined index buffer allocated"),
            0,
            bytemuck::cast_slice(&self.indices),
        );
        PrepareStats {
            sort_ms,
            write_ms: write_start.elapsed().as_secs_f64() * 1000.0,
            bytes,
            quads: self.order.len(),
            ..PrepareStats::default()
        }
    }

    fn can_reuse(&self, eye: Vec3, near: &[Vec3], far: &[&GpuPart]) -> bool {
        sources_match(
            eye,
            self.eye,
            &self.source_centers,
            &self.source_lengths,
            near,
            far.iter().map(|part| part.blended_centers.as_slice()),
        )
    }

    fn remember_centers(&mut self, near: &[Vec3], far: &[&GpuPart]) {
        capture_centers(
            &mut self.source_centers,
            &mut self.source_lengths,
            near,
            far.iter().map(|part| part.blended_centers.as_slice()),
        );
    }

    pub fn draw(
        &self,
        pass: &mut wgpu::RenderPass<'_>,
        near: &BlendedMeshes,
        far: &[&GpuPart],
        near_pipeline: &wgpu::RenderPipeline,
        lod_pipeline: &wgpu::RenderPipeline,
    ) {
        if self.runs.is_empty() {
            return;
        }
        pass.set_index_buffer(
            self.index_buffer
                .as_ref()
                .expect("combined index buffer allocated")
                .slice(..),
            wgpu::IndexFormat::Uint32,
        );
        for run in &self.runs {
            let pipeline = match run.source {
                DrawSource::Near => {
                    pass.set_vertex_buffer(
                        0,
                        near.vertex_buffer()
                            .expect("near blended vertices available")
                            .slice(..),
                    );
                    near_pipeline
                }
                DrawSource::Far(index) => {
                    let (buffer, _) = far[index]
                        .blended
                        .as_ref()
                        .expect("far blended vertices available");
                    pass.set_vertex_buffer(0, buffer.slice(..));
                    lod_pipeline
                }
            };
            pass.set_pipeline(pipeline);
            pass.draw_indexed(run.indices.clone(), 0, 0..1);
        }
    }
}

#[cfg(test)]
fn build_order_plan(eye: Vec3, near: &[Vec3], far: &[&[Vec3]]) -> OrderPlan {
    let mut plan = OrderPlan::default();
    let mut order = Vec::new();
    let mut source_refs = Vec::new();
    build_order_from_centers(
        eye,
        near,
        far.iter().copied(),
        &mut order,
        &mut source_refs,
        &mut plan.indices,
        &mut plan.runs,
    );
    plan
}

fn build_order_into(
    eye: Vec3,
    near: &[Vec3],
    far: &[&GpuPart],
    order: &mut Vec<u64>,
    source_refs: &mut Vec<u64>,
    indices: &mut Vec<u32>,
    runs: &mut Vec<DrawRun>,
) {
    build_order_from_centers(
        eye,
        near,
        far.iter().map(|part| part.blended_centers.as_slice()),
        order,
        source_refs,
        indices,
        runs,
    );
}

fn build_order_from_centers<'a>(
    eye: Vec3,
    near: &[Vec3],
    far: impl Iterator<Item = &'a [Vec3]>,
    order: &mut Vec<u64>,
    source_refs: &mut Vec<u64>,
    indices: &mut Vec<u32>,
    runs: &mut Vec<DrawRun>,
) {
    order.clear();
    source_refs.clear();
    indices.clear();
    runs.clear();
    append_centers(0, near, eye, order, source_refs);
    for (index, centers) in far.enumerate() {
        let source = u32::try_from(index + 1).expect("far transparent source count fits u32");
        append_centers(source, centers, eye, order, source_refs);
    }
    order.sort_unstable();
    let index_count = order
        .len()
        .checked_mul(6)
        .and_then(|count| u32::try_from(count).ok())
        .expect("combined transparent index count fits u32");
    indices.reserve(index_count as usize);
    runs.reserve(order.len());
    for &key in order.iter() {
        let ordinal = key as u32 as usize;
        let source_ref = source_refs[ordinal];
        let source_id = (source_ref >> 32) as u32;
        let quad = source_ref as u32;
        let source = if source_id == 0 {
            DrawSource::Near
        } else {
            DrawSource::Far((source_id - 1) as usize)
        };
        let start = u32::try_from(indices.len()).expect("draw index start fits u32");
        let first = quad.checked_mul(6).expect("source quad index fits u32");
        indices.extend(first..first + 6);
        let end = start + 6;
        if let Some(last) = runs.last_mut().filter(|last| last.source == source) {
            last.indices.end = end;
        } else {
            runs.push(DrawRun::new(source, start..end));
        }
    }
}

fn append_centers(
    source: u32,
    centers: &[Vec3],
    eye: Vec3,
    order: &mut Vec<u64>,
    source_refs: &mut Vec<u64>,
) {
    for (quad, center) in centers.iter().enumerate() {
        let ordinal = u32::try_from(order.len()).expect("transparent quad count fits u32");
        let quad = u32::try_from(quad).expect("source transparent quad count fits u32");
        let bits = center.distance_squared(eye).to_bits();
        let ordered = if bits & 0x8000_0000 == 0 {
            bits ^ 0x8000_0000
        } else {
            !bits
        };
        order.push((u64::from(!ordered) << 32) | u64::from(ordinal));
        source_refs.push((u64::from(source) << 32) | u64::from(quad));
    }
}

fn sources_match<'a>(
    eye: Vec3,
    cached_eye: Option<Vec3>,
    snapshot: &[Vec3],
    lengths: &[usize],
    near: &[Vec3],
    far: impl Iterator<Item = &'a [Vec3]>,
) -> bool {
    if cached_eye != Some(eye) || lengths.first() != Some(&near.len()) {
        return false;
    }
    let mut offset = near.len();
    let mut source_index = 1;
    if snapshot.get(..offset) != Some(near) {
        return false;
    }
    for centers in far {
        if lengths.get(source_index) != Some(&centers.len())
            || snapshot.get(offset..offset + centers.len()) != Some(centers)
        {
            return false;
        }
        offset += centers.len();
        source_index += 1;
    }
    source_index == lengths.len() && offset == snapshot.len()
}

fn capture_centers<'a>(
    snapshot: &mut Vec<Vec3>,
    lengths: &mut Vec<usize>,
    near: &[Vec3],
    far: impl Iterator<Item = &'a [Vec3]>,
) {
    snapshot.clear();
    lengths.clear();
    lengths.push(near.len());
    snapshot.extend_from_slice(near);
    for centers in far {
        lengths.push(centers.len());
        snapshot.extend_from_slice(centers);
    }
}

#[cfg(test)]
#[path = "lod_transparency_tests.rs"]
mod tests;
