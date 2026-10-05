use std::collections::HashMap;

use bytemuck::{Pod, Zeroable};
use wyram_core::lod::{Cell, TILE_CELLS, Tile};

use crate::world::RenderDescriptor;

const TILE_STORAGE: usize = TILE_CELLS + 2;
const MAX_PART_CELLS: usize = 8 * 8 * 8;
const MAX_PART_BYTES: usize = 1024 * 1024;
const QUAD_INDICES: [usize; 6] = [0, 1, 2, 0, 2, 3];

#[derive(Clone, Copy)]
struct FacePatch {
    face_index: usize,
    origin: [i32; 3],
    low: [i32; 3],
    high: [i32; 3],
    plane: i32,
    width: usize,
    height: usize,
}

#[derive(Clone, Copy)]
struct FaceStyle {
    color: [f32; 3],
    opacity: f32,
    lod_size: f32,
}

#[cfg(test)]
#[path = "lod_mesh_tests.rs"]
mod tests;

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

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Pod, Zeroable)]
pub struct LodVertex {
    pub position: [f32; 3],
    pub color: [f32; 3],
    pub opacity: f32,
    pub lod_size: f32,
}

impl LodVertex {
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
                wgpu::VertexAttribute {
                    offset: 24,
                    shader_location: 2,
                    format: wgpu::VertexFormat::Float32,
                },
                wgpu::VertexAttribute {
                    offset: 28,
                    shader_location: 3,
                    format: wgpu::VertexFormat::Float32,
                },
            ],
        }
    }
}

#[derive(Clone, Debug)]
pub struct MeshPart {
    pub index: u16,
    pub vertices: Vec<LodVertex>,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct MeshCompletion {
    pub parts: u16,
    pub bytes: usize,
    pub cancelled: bool,
}

#[derive(Clone, Copy, Debug)]
pub struct BoundaryCell {
    pub origin: [i32; 3],
    pub size: u8,
    pub cell: Cell,
    /// Whether the sampled neighbor's geometry is current and eligible to draw.
    /// Tile data can be available before the coverage state exposes its mesh.
    pub geometry_ready: bool,
}

/// Build a tile in bounded, deterministic parts using actual neighboring boxes at seams.
pub fn build_parts(
    tile: &Tile,
    colors: &HashMap<u16, [u8; 3]>,
    descriptors: &HashMap<u16, RenderDescriptor>,
    sample: impl Fn([i32; 3]) -> Option<BoundaryCell>,
    mut emit: impl FnMut(MeshPart) -> bool,
) -> MeshCompletion {
    let Some(origin) = tile.key.origin().ok() else {
        return MeshCompletion {
            cancelled: true,
            ..MeshCompletion::default()
        };
    };
    if tile.cells.len() != TILE_STORAGE * TILE_STORAGE * TILE_STORAGE {
        return MeshCompletion {
            cancelled: true,
            ..MeshCompletion::default()
        };
    }

    let size = i32::from(tile.key.cell_size);
    let mut completion = MeshCompletion::default();
    let mut part_vertices = Vec::new();
    let mut part_cells = 0;

    for group_y in (0..TILE_CELLS).step_by(8) {
        for group_z in (0..TILE_CELLS).step_by(8) {
            for group_x in (0..TILE_CELLS).step_by(8) {
                let end_y = (group_y + 8).min(TILE_CELLS);
                let end_z = (group_z + 8).min(TILE_CELLS);
                let end_x = (group_x + 8).min(TILE_CELLS);
                for y in group_y..end_y {
                    for z in group_z..end_z {
                        for x in group_x..end_x {
                            let cell = tile.cells[storage_index(x + 1, y + 1, z + 1)];
                            let cell_origin = [
                                origin[0] + x as i32 * size,
                                origin[1] + y as i32 * size,
                                origin[2] + z as i32 * size,
                            ];
                            let cell_vertices =
                                build_cell(tile, cell_origin, cell, colors, descriptors, &sample);
                            let cell_bytes = cell_vertices.len() * size_of::<LodVertex>();

                            if !part_vertices.is_empty()
                                && (part_cells == MAX_PART_CELLS
                                    || part_vertices.len() * size_of::<LodVertex>() + cell_bytes
                                        > MAX_PART_BYTES)
                                && !flush_part(
                                    &mut part_vertices,
                                    &mut part_cells,
                                    &mut completion,
                                    &mut emit,
                                )
                            {
                                return completion;
                            }

                            if cell_bytes > MAX_PART_BYTES {
                                // A cell is bounded by six solid and six liquid sides. If a
                                // future field expands that geometry, split it into face batches.
                                for face_vertices in cell_vertices
                                    .chunks(MAX_PART_BYTES / size_of::<LodVertex>() / 6 * 6)
                                {
                                    if !part_vertices.is_empty()
                                        && part_vertices.len() * size_of::<LodVertex>()
                                            + size_of_val(face_vertices)
                                            > MAX_PART_BYTES
                                        && !flush_part(
                                            &mut part_vertices,
                                            &mut part_cells,
                                            &mut completion,
                                            &mut emit,
                                        )
                                    {
                                        return completion;
                                    }
                                    part_vertices.extend_from_slice(face_vertices);
                                    if !flush_part(
                                        &mut part_vertices,
                                        &mut part_cells,
                                        &mut completion,
                                        &mut emit,
                                    ) {
                                        return completion;
                                    }
                                }
                            } else {
                                part_vertices.extend_from_slice(&cell_vertices);
                                if !cell_vertices.is_empty() {
                                    part_cells += 1;
                                }
                            }
                        }
                    }
                }
                if !flush_part(
                    &mut part_vertices,
                    &mut part_cells,
                    &mut completion,
                    &mut emit,
                ) {
                    return completion;
                }
            }
        }
    }
    completion
}

fn flush_part(
    vertices: &mut Vec<LodVertex>,
    source_cells: &mut usize,
    completion: &mut MeshCompletion,
    emit: &mut impl FnMut(MeshPart) -> bool,
) -> bool {
    if vertices.is_empty() {
        *source_cells = 0;
        return true;
    }
    let part = MeshPart {
        index: completion.parts,
        vertices: std::mem::take(vertices),
    };
    let part_bytes = part.vertices.len() * size_of::<LodVertex>();
    if !emit(part) {
        completion.cancelled = true;
        return false;
    }
    completion.parts = completion
        .parts
        .checked_add(1)
        .expect("LOD tile part count fits u16");
    completion.bytes += part_bytes;
    *source_cells = 0;
    true
}

fn build_cell(
    tile: &Tile,
    origin: [i32; 3],
    cell: Cell,
    colors: &HashMap<u16, [u8; 3]>,
    descriptors: &HashMap<u16, RenderDescriptor>,
    sample: &impl Fn([i32; 3]) -> Option<BoundaryCell>,
) -> Vec<LodVertex> {
    let mut vertices = Vec::new();
    if cell.material != 0 && cell.solid_height != 0 {
        build_solid_faces(
            tile,
            origin,
            cell,
            colors,
            descriptors,
            sample,
            &mut vertices,
        );
    }
    if cell.liquid != 0 && cell.liquid_height != 0 {
        build_liquid_faces(
            tile,
            origin,
            cell,
            colors,
            descriptors,
            sample,
            &mut vertices,
        );
    }
    vertices
}

fn build_solid_faces(
    tile: &Tile,
    origin: [i32; 3],
    cell: Cell,
    colors: &HashMap<u16, [u8; 3]>,
    descriptors: &HashMap<u16, RenderDescriptor>,
    sample: &impl Fn([i32; 3]) -> Option<BoundaryCell>,
    vertices: &mut Vec<LodVertex>,
) {
    let size = i32::from(tile.key.cell_size);
    let low = origin;
    let mut high = std::array::from_fn(|axis| origin[axis] + size);
    high[1] = origin[1] + i32::from(cell.solid_height);
    for (face_index, (normal, _, _)) in FACES.iter().enumerate() {
        let axis = normal.iter().position(|component| *component != 0).unwrap();
        let positive = normal[axis] > 0;
        let material = if normal[1] > 0 && cell.top_material != 0 {
            cell.top_material
        } else {
            cell.material
        };
        let u = (axis + 1) % 3;
        let v = (axis + 2) % 3;
        let plane = if positive { high[axis] } else { low[axis] };
        let width = (high[u] - low[u]) as usize;
        let height = (high[v] - low[v]) as usize;
        let mut mask = vec![false; width * height];
        for j in 0..height {
            for i in 0..width {
                let mut neighbor_position = [0; 3];
                neighbor_position[u] = low[u] + i as i32;
                neighbor_position[v] = low[v] + j as i32;
                neighbor_position[axis] = if positive { plane } else { plane - 1 };
                mask[j * width + i] =
                    solid_face_visible(material, neighbor_position, tile, descriptors, sample);
            }
        }
        let descriptor = descriptors.get(&material).copied().unwrap_or_default();
        let base = colors.get(&material).copied().unwrap_or([255, 0, 255]);
        let shade = if descriptor.emissive {
            1.0
        } else {
            FACES[face_index].2
        };
        let color = base.map(|value| f32::from(value) / 255.0 * shade);
        emit_mask_quads(
            FacePatch {
                face_index,
                origin,
                low,
                high,
                plane,
                width,
                height,
            },
            &mut mask,
            FaceStyle {
                color,
                opacity: f32::from(descriptor.opacity) / 255.0,
                lod_size: f32::from(tile.key.cell_size),
            },
            vertices,
        );
    }
}

fn solid_face_visible(
    material: u16,
    position: [i32; 3],
    tile: &Tile,
    descriptors: &HashMap<u16, RenderDescriptor>,
    sample: &impl Fn([i32; 3]) -> Option<BoundaryCell>,
) -> bool {
    let Some(neighbor) = adjacent_cell(tile, position, sample) else {
        return true;
    };
    if !contains_solid(neighbor, position) {
        return true;
    }
    if neighbor.cell.material == material {
        return false;
    }
    descriptors
        .get(&neighbor.cell.material)
        .copied()
        .unwrap_or_default()
        .opacity
        < 255
}

fn emit_mask_quads(
    patch: FacePatch,
    mask: &mut [bool],
    style: FaceStyle,
    vertices: &mut Vec<LodVertex>,
) {
    let FacePatch {
        face_index,
        origin,
        low,
        high,
        plane,
        width,
        height,
    } = patch;
    let normal = FACES[face_index].0;
    let axis = normal.iter().position(|component| *component != 0).unwrap();
    let u = (axis + 1) % 3;
    let v = (axis + 2) % 3;
    let mut j = 0;
    while j < height {
        let mut i = 0;
        while i < width {
            let at = j * width + i;
            if !mask[at] {
                i += 1;
                continue;
            }
            let mut rect_width = 1;
            while i + rect_width < width && mask[j * width + i + rect_width] {
                rect_width += 1;
            }
            let mut rect_height = 1;
            while j + rect_height < height
                && (0..rect_width).all(|x| mask[(j + rect_height) * width + i + x])
            {
                rect_height += 1;
            }
            for row in j..j + rect_height {
                mask[row * width + i..row * width + i + rect_width].fill(false);
            }
            let mut rect_low = origin.map(|value| value as f32);
            let mut rect_high = rect_low;
            for dimension in 0..3 {
                rect_low[dimension] = low[dimension] as f32;
                rect_high[dimension] = high[dimension] as f32;
            }
            rect_low[axis] = plane as f32;
            rect_high[axis] = plane as f32;
            rect_low[u] = low[u] as f32 + i as f32;
            rect_high[u] = rect_low[u] + rect_width as f32;
            rect_low[v] = low[v] as f32 + j as f32;
            rect_high[v] = rect_low[v] + rect_height as f32;
            push_quad(
                face_index,
                rect_low,
                rect_high,
                style.color,
                style.opacity,
                style.lod_size,
                vertices,
            );
            i += rect_width;
        }
        j += 1;
    }
}

fn build_liquid_faces(
    tile: &Tile,
    origin: [i32; 3],
    cell: Cell,
    colors: &HashMap<u16, [u8; 3]>,
    descriptors: &HashMap<u16, RenderDescriptor>,
    sample: &impl Fn([i32; 3]) -> Option<BoundaryCell>,
    vertices: &mut Vec<LodVertex>,
) {
    let Some(descriptor) = descriptors.get(&cell.liquid).copied() else {
        return;
    };
    if descriptor.liquid == 0 {
        return;
    }
    let bottom = (origin[1] + i32::from(cell.solid_height)) as f32;
    let top = liquid_top(
        tile,
        BoundaryCell {
            origin,
            size: tile.key.cell_size,
            cell,
            geometry_ready: true,
        },
        descriptors,
        sample,
    );
    if top <= bottom {
        return;
    }
    let base = colors.get(&cell.liquid).copied().unwrap_or([255, 0, 255]);
    let opacity = f32::from(descriptor.opacity) / 255.0;
    let size = i32::from(tile.key.cell_size);
    let high = [origin[0] + size, origin[1] + size, origin[2] + size];

    if top < high[1] as f32 {
        let color = liquid_color(base, descriptor, FACES[2].2);
        push_quad(
            2,
            [origin[0] as f32, top, origin[2] as f32],
            [high[0] as f32, top, high[2] as f32],
            color,
            opacity,
            f32::from(tile.key.cell_size),
            vertices,
        );
    } else {
        let mut mask = vec![false; (size * size) as usize];
        let (u, v) = (2, 0);
        for j in 0..size {
            for i in 0..size {
                let mut point = [0; 3];
                point[u] = origin[u] + i;
                point[v] = origin[v] + j;
                point[1] = high[1];
                mask[(j * size + i) as usize] =
                    liquid_face_visible(tile, point, top, cell.liquid, true, descriptors, sample);
            }
        }
        let color = liquid_color(base, descriptor, FACES[2].2);
        emit_mask_quads(
            FacePatch {
                face_index: 2,
                origin,
                low: origin,
                high,
                plane: high[1],
                width: size as usize,
                height: size as usize,
            },
            &mut mask,
            FaceStyle {
                color,
                opacity,
                lod_size: f32::from(tile.key.cell_size),
            },
            vertices,
        );
    }
    if cell.solid_height == 0 {
        let mut mask = vec![false; (size * size) as usize];
        let (u, v) = (2, 0);
        for j in 0..size {
            for i in 0..size {
                let mut point = [0; 3];
                point[u] = origin[u] + i;
                point[v] = origin[v] + j;
                point[1] = origin[1] - 1;
                mask[(j * size + i) as usize] = liquid_face_visible(
                    tile,
                    point,
                    bottom,
                    cell.liquid,
                    false,
                    descriptors,
                    sample,
                );
            }
        }
        let color = liquid_color(base, descriptor, FACES[3].2);
        emit_mask_quads(
            FacePatch {
                face_index: 3,
                origin,
                low: origin,
                high,
                plane: origin[1],
                width: size as usize,
                height: size as usize,
            },
            &mut mask,
            FaceStyle {
                color,
                opacity,
                lod_size: f32::from(tile.key.cell_size),
            },
            vertices,
        );
    }

    for face_index in [0, 1, 4, 5] {
        let normal = FACES[face_index].0;
        let axis = normal.iter().position(|component| *component != 0).unwrap();
        let positive = normal[axis] > 0;
        let horizontal = if axis == 0 { 2 } else { 0 };
        let plane = if positive { high[axis] } else { origin[axis] };
        for tangent in 0..size {
            let mut low = [origin[0] as f32, bottom, origin[2] as f32];
            let mut upper = [high[0] as f32, top, high[2] as f32];
            low[axis] = plane as f32;
            upper[axis] = plane as f32;
            low[horizontal] += tangent as f32;
            upper[horizontal] = low[horizontal] + 1.0;
            let mut breaks = vec![bottom, top];
            for y in bottom.floor() as i32..top.ceil() as i32 {
                let mut point = [0; 3];
                point[axis] = if positive { plane } else { plane - 1 };
                point[horizontal] = origin[horizontal] + tangent;
                point[1] = y;
                if let Some(neighbor) = adjacent_cell(tile, point, sample) {
                    interval_breaks(
                        tile,
                        neighbor,
                        descriptors,
                        sample,
                        bottom,
                        top,
                        &mut breaks,
                    );
                }
            }
            breaks.sort_by(f32::total_cmp);
            breaks.dedup_by(|a, b| (*a - *b).abs() < f32::EPSILON);
            for interval in breaks.windows(2) {
                let lower = interval[0];
                let upper_y = interval[1];
                if upper_y <= lower {
                    continue;
                }
                let midpoint = (lower + upper_y) * 0.5;
                let mut point = [0; 3];
                point[axis] = if positive { plane } else { plane - 1 };
                point[horizontal] = origin[horizontal] + tangent;
                point[1] = midpoint.floor() as i32;
                if liquid_side_occluded(tile, point, midpoint, cell.liquid, descriptors, sample) {
                    continue;
                }
                low[1] = lower;
                upper[1] = upper_y;
                let color = liquid_color(base, descriptor, FACES[face_index].2);
                push_quad(
                    face_index,
                    low,
                    upper,
                    color,
                    opacity,
                    f32::from(tile.key.cell_size),
                    vertices,
                );
            }
        }
    }
}

fn interval_breaks(
    tile: &Tile,
    neighbor: BoundaryCell,
    descriptors: &HashMap<u16, RenderDescriptor>,
    sample: &impl Fn([i32; 3]) -> Option<BoundaryCell>,
    bottom: f32,
    top: f32,
    breaks: &mut Vec<f32>,
) {
    let y = neighbor.origin[1] as f32;
    let size = f32::from(neighbor.size);
    if neighbor.cell.material != 0 {
        breaks.push((y + f32::from(neighbor.cell.solid_height)).clamp(bottom, top));
    }
    if neighbor.cell.liquid != 0 && descriptors.contains_key(&neighbor.cell.liquid) {
        let liquid_bottom = y + f32::from(neighbor.cell.solid_height);
        let liquid_top = liquid_top(tile, neighbor, descriptors, sample);
        breaks.push(liquid_bottom.clamp(bottom, top));
        breaks.push(liquid_top.clamp(bottom, top));
    }
    breaks.push((y + size).clamp(bottom, top));
}

fn liquid_side_occluded(
    tile: &Tile,
    position: [i32; 3],
    y: f32,
    liquid: u16,
    descriptors: &HashMap<u16, RenderDescriptor>,
    sample: &impl Fn([i32; 3]) -> Option<BoundaryCell>,
) -> bool {
    let Some(neighbor) = adjacent_cell(tile, position, sample) else {
        return false;
    };
    if contains_solid(neighbor, position)
        && descriptors
            .get(&neighbor.cell.material)
            .copied()
            .unwrap_or_default()
            .opacity
            == 255
    {
        return true;
    }
    if neighbor.cell.liquid == 0 {
        return false;
    }
    let Some(neighbor_descriptor) = descriptors.get(&neighbor.cell.liquid) else {
        return false;
    };
    if neighbor_descriptor.liquid != descriptors.get(&liquid).map_or(0, |own| own.liquid) {
        return false;
    }
    let lower = (neighbor.origin[1] + i32::from(neighbor.cell.solid_height)) as f32;
    let upper = liquid_top(tile, neighbor, descriptors, sample);
    y >= lower && y < upper
}

fn liquid_face_visible(
    tile: &Tile,
    position: [i32; 3],
    plane: f32,
    liquid: u16,
    above: bool,
    descriptors: &HashMap<u16, RenderDescriptor>,
    sample: &impl Fn([i32; 3]) -> Option<BoundaryCell>,
) -> bool {
    let Some(neighbor) = adjacent_cell(tile, position, sample) else {
        return true;
    };
    if contains_solid(neighbor, position)
        && descriptors
            .get(&neighbor.cell.material)
            .copied()
            .unwrap_or_default()
            .opacity
            == 255
    {
        return false;
    }
    let Some(descriptor) = descriptors.get(&neighbor.cell.liquid) else {
        return true;
    };
    if descriptor.liquid == 0
        || descriptor.liquid != descriptors.get(&liquid).map_or(0, |own| own.liquid)
    {
        return true;
    }
    let neighbor_bottom = neighbor.origin[1] as f32 + f32::from(neighbor.cell.solid_height);
    let neighbor_top = liquid_top(tile, neighbor, descriptors, sample);
    if above {
        !(neighbor_bottom <= plane && neighbor_top > plane)
    } else {
        !(neighbor_bottom < plane && neighbor_top >= plane)
    }
}

/// Only the exposed surface uses the authored fractional liquid height. A full
/// cell with connected liquid above reaches its ceiling, avoiding internal gaps
/// and transparent sheets throughout an ocean column.
fn liquid_top(
    tile: &Tile,
    neighbor: BoundaryCell,
    descriptors: &HashMap<u16, RenderDescriptor>,
    sample: &impl Fn([i32; 3]) -> Option<BoundaryCell>,
) -> f32 {
    let descriptor = descriptors
        .get(&neighbor.cell.liquid)
        .copied()
        .unwrap_or_default();
    let ceiling = neighbor.origin[1] + i32::from(neighbor.size);
    if neighbor.cell.liquid_height == neighbor.size {
        let position = [
            neighbor.origin[0] + i32::from(neighbor.size) / 2,
            ceiling,
            neighbor.origin[2] + i32::from(neighbor.size) / 2,
        ];
        if let Some(above) = adjacent_cell(tile, position, sample)
            && above.cell.liquid_height > above.cell.solid_height
            && above.origin[1] + i32::from(above.cell.solid_height) <= ceiling
            && descriptor.liquid != 0
            && descriptors
                .get(&above.cell.liquid)
                .is_some_and(|other| other.liquid == descriptor.liquid)
        {
            return ceiling as f32;
        }
    }
    neighbor.origin[1] as f32 + f32::from(neighbor.cell.liquid_height) - 1.0 + descriptor.height
}

fn liquid_color(base: [u8; 3], descriptor: RenderDescriptor, shade: f32) -> [f32; 3] {
    let shade = if descriptor.emissive { 1.0 } else { shade };
    base.map(|value| f32::from(value) / 255.0 * shade)
}

fn adjacent_cell(
    tile: &Tile,
    position: [i32; 3],
    sample: &impl Fn([i32; 3]) -> Option<BoundaryCell>,
) -> Option<BoundaryCell> {
    let origin = tile.key.origin().ok()?;
    let span = tile.key.span();
    let inside_core =
        (0..3).all(|axis| position[axis] >= origin[axis] && position[axis] < origin[axis] + span);
    if let Some(boundary) = sample(position) {
        return boundary.geometry_ready.then_some(boundary);
    }
    if !inside_core {
        return None;
    }
    let cell = tile.sample(position)?;
    let size = i32::from(tile.key.cell_size);
    Some(BoundaryCell {
        origin: position.map(|coordinate| coordinate.div_euclid(size) * size),
        size: tile.key.cell_size,
        cell,
        geometry_ready: true,
    })
}

fn contains_solid(cell: BoundaryCell, position: [i32; 3]) -> bool {
    if cell.cell.material == 0 || cell.cell.solid_height == 0 {
        return false;
    }
    let size = i32::from(cell.size);
    position[0] >= cell.origin[0]
        && position[0] < cell.origin[0] + size
        && position[1] >= cell.origin[1]
        && position[1] < cell.origin[1] + i32::from(cell.cell.solid_height)
        && position[2] >= cell.origin[2]
        && position[2] < cell.origin[2] + size
}

fn storage_index(x: usize, y: usize, z: usize) -> usize {
    (y * TILE_STORAGE + z) * TILE_STORAGE + x
}

fn push_quad(
    face_index: usize,
    low: [f32; 3],
    high: [f32; 3],
    color: [f32; 3],
    opacity: f32,
    lod_size: f32,
    vertices: &mut Vec<LodVertex>,
) {
    let corners = FACES[face_index].1;
    for index in QUAD_INDICES {
        vertices.push(LodVertex {
            position: std::array::from_fn(|axis| {
                low[axis] + corners[index][axis] * (high[axis] - low[axis])
            }),
            color,
            opacity,
            lod_size,
        });
    }
}
