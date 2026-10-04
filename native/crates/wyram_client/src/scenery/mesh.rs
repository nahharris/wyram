use crate::world::{RenderDescriptor, Vertex};
use bytemuck::{Pod, Zeroable};
use std::collections::HashMap;
use std::sync::Arc;
use wyram_core::scenery::LodTile;

#[derive(Debug)]
pub struct Neighbor {
    pub tile: Arc<LodTile>,
    // A retained parent does not prove that its selected children cover a face.
    pub opaque_occlusion: bool,
}

impl From<Arc<LodTile>> for Neighbor {
    fn from(tile: Arc<LodTile>) -> Self {
        Self {
            tile,
            opaque_occlusion: true,
        }
    }
}

#[repr(C)]
#[derive(Clone, Copy, PartialEq, Pod, Zeroable)]
pub struct ProxyVertex {
    pub base: Vertex,
    pub normal: [i8; 4],
}

pub struct Mesh {
    pub vertices: Vec<ProxyVertex>,
    pub side: usize,
}

impl ProxyVertex {
    pub fn layout() -> wgpu::VertexBufferLayout<'static> {
        const ATTRIBUTES: [wgpu::VertexAttribute; 4] =
            wgpu::vertex_attr_array![0 => Float32x3, 1 => Float32x3, 2 => Float32, 3 => Snorm8x4];
        wgpu::VertexBufferLayout {
            array_stride: size_of::<Self>() as u64,
            step_mode: wgpu::VertexStepMode::Vertex,
            attributes: &ATTRIBUTES,
        }
    }
}

impl Mesh {
    /// Opaque buffers have exact sizes. Blended buffers can grow to twice their
    /// payload: position/color, normal flags and sorted indices all count here.
    pub fn bytes(&self) -> usize {
        self.vertices
            .iter()
            .map(|v| {
                if v.base.opacity < 1.0 {
                    2 * (size_of::<ProxyVertex>() + size_of::<u32>())
                } else {
                    size_of::<ProxyVertex>()
                }
            })
            .sum()
    }
}

#[cfg(test)]
fn build(
    tile: &LodTile,
    colors: &HashMap<u16, [u8; 3]>,
    descriptors: &HashMap<u16, RenderDescriptor>,
    water: &HashMap<u16, f32>,
    budget: usize,
) -> Result<Mesh, &'static str> {
    build_with_neighbors(tile, colors, descriptors, water, budget, &[])
}

pub fn build_with_neighbors(
    tile: &LodTile,
    colors: &HashMap<u16, [u8; 3]>,
    descriptors: &HashMap<u16, RenderDescriptor>,
    water: &HashMap<u16, f32>,
    budget: usize,
    neighbors: &[Neighbor],
) -> Result<Mesh, &'static str> {
    if tile.occupied() == 0 {
        return Ok(Mesh {
            vertices: Vec::new(),
            side: 32,
        });
    }
    for side in [32, 16, 8, 4, 2, 1] {
        if let Some(mesh) = build_grid(tile, colors, descriptors, water, side, budget, neighbors) {
            return Ok(mesh);
        }
    }
    Err("scenery mesh exceeds its byte budget")
}

fn grid(tile: &LodTile, side: usize) -> (Vec<u16>, Vec<u16>) {
    let mut cells = vec![0; side.pow(3)];
    let mut top = vec![0; side.pow(3)];
    for y in 0..side {
        for z in 0..side {
            for x in 0..side {
                let p = [x, y, z];
                let material = if side == 32 {
                    let cell = tile.cell(p.map(|v| v / 2)).unwrap();
                    let octant = (x % 2) | ((y % 2) << 1) | ((z % 2) << 2);
                    if cell.child_mask() & (1 << octant) != 0 {
                        cell.material()
                    } else {
                        0
                    }
                } else if side == 16 {
                    tile.cell(p).unwrap().material()
                } else {
                    let span = 16 / side;
                    let mut weights = HashMap::<u16, u64>::new();
                    for cy in y * span..(y + 1) * span {
                        for cz in z * span..(z + 1) * span {
                            for cx in x * span..(x + 1) * span {
                                let cell = tile.cell([cx, cy, cz]).unwrap();
                                if cell.occupied() > 0 {
                                    *weights.entry(cell.material()).or_default() +=
                                        u64::from(cell.occupied());
                                }
                            }
                        }
                    }
                    weights
                        .into_iter()
                        .max_by(|(a, wa), (b, wb)| wa.cmp(wb).then(b.cmp(a)))
                        .map_or(0, |(id, _)| id)
                };
                let at = (y * side + z) * side + x;
                cells[at] = material;
                top[at] = if material == 0 {
                    0
                } else if side == 32 {
                    tile.top_material(p.map(|v| v / 2)).unwrap()
                } else if side == 16 {
                    tile.top_material(p).unwrap()
                } else {
                    let span = 16 / side;
                    let mut weights = HashMap::<u16, usize>::new();
                    for cz in z * span..(z + 1) * span {
                        for cx in x * span..(x + 1) * span {
                            if let Some(cy) = (y * span..(y + 1) * span)
                                .rev()
                                .find(|&cy| tile.cell([cx, cy, cz]).unwrap().occupied() > 0)
                            {
                                *weights
                                    .entry(tile.top_material([cx, cy, cz]).unwrap())
                                    .or_default() += 1;
                            }
                        }
                    }
                    weights
                        .into_iter()
                        .max_by(|(a, wa), (b, wb)| wa.cmp(wb).then(b.cmp(a)))
                        .map_or(material, |(id, _)| id)
                };
            }
        }
    }
    (cells, top)
}

#[derive(Clone, Copy, PartialEq)]
struct Surface {
    material: u16,
    color_material: u16,
    lower: f32,
    top: f32,
}

struct Grid<'a> {
    cells: Vec<u16>,
    top: Vec<u16>,
    side: usize,
    step: f32,
    origin: [f32; 3],
    descriptors: &'a HashMap<u16, RenderDescriptor>,
    water: &'a HashMap<u16, f32>,
    neighbors: &'a [Neighbor],
}

impl Grid<'_> {
    fn neighbor(&self, p: [i32; 3]) -> Option<&Neighbor> {
        if p.iter().all(|&v| (0..self.side as i32).contains(&v)) {
            return None;
        }
        let world: [f32; 3] =
            std::array::from_fn(|i| self.origin[i] + (p[i] as f32 + 0.5) * self.step);
        self.neighbors
            .iter()
            .filter(|neighbor| {
                let tile = &neighbor.tile;
                let low = tile.key().origin().map(|v| v as f32);
                let width = f32::from(tile.key().scale()) * 16.0;
                (0..3).all(|i| world[i] >= low[i] && world[i] < low[i] + width)
            })
            .min_by_key(|neighbor| neighbor.tile.key().level())
    }
    fn get(&self, p: [i32; 3]) -> u16 {
        if p.iter().any(|&v| !(0..self.side as i32).contains(&v)) {
            let world: [f32; 3] =
                std::array::from_fn(|i| self.origin[i] + (p[i] as f32 + 0.5) * self.step);
            return self.neighbor(p).map_or(0, |neighbor| {
                let tile = &neighbor.tile;
                let low = tile.key().origin().map(|v| v as f32);
                let half = f32::from(tile.key().scale()) * 0.5;
                let p: [usize; 3] =
                    std::array::from_fn(|i| ((world[i] - low[i]) / half).floor() as usize);
                let cell = tile.cell(p.map(|v| v / 2)).unwrap();
                let octant = (p[0] % 2) | ((p[1] % 2) << 1) | ((p[2] % 2) << 2);
                if cell.child_mask() & (1 << octant) != 0 {
                    cell.material()
                } else {
                    0
                }
            });
        }
        self.cells[(p[1] as usize * self.side + p[2] as usize) * self.side + p[0] as usize]
    }
    fn descriptor(&self, id: u16) -> RenderDescriptor {
        self.descriptors.get(&id).copied().unwrap_or_default()
    }
    fn height(&self, p: [i32; 3], id: u16) -> f32 {
        let d = self.descriptor(id);
        if d.liquid == 0 {
            return 1.0;
        }
        let above = self.get([p[0], p[1] + 1, p[2]]);
        if above != 0 && self.descriptor(above).liquid == d.liquid {
            return 1.0;
        }
        let bottom = self.origin[1] + p[1] as f32 * self.step;
        if let Some(&plane) = self.water.get(&id)
            && plane >= bottom
            && (plane - bottom - self.step).abs() <= self.step * 0.5 + 1.0
        {
            return (plane - bottom) / self.step;
        }
        (self.step - (1.0 - d.height)) / self.step
    }
    fn surface(&self, p: [i32; 3], offset: [i32; 3]) -> Option<Surface> {
        let material = self.get(p);
        if material == 0 {
            return None;
        }
        let d = self.descriptor(material);
        let adjacent = std::array::from_fn(|i| p[i] + offset[i]);
        let other = self.get(adjacent);
        let od = self.descriptor(other);
        let opaque_occlusion = self.neighbor(adjacent).is_none_or(|n| n.opaque_occlusion);
        let top = self.height(p, material);
        let same = other != 0
            && (od.opacity != 255 || opaque_occlusion)
            && if d.liquid != 0 {
                od.liquid == d.liquid
            } else {
                other == material
            };
        let other_height = if other != 0 {
            self.height(adjacent, other)
        } else {
            0.0
        };
        let side = offset[1] == 0;
        let lower = if same && side {
            other_height.min(top)
        } else {
            0.0
        };
        if (same && side && lower >= top)
            || (same && offset[1] == 1 && top == 1.0)
            || (same && offset[1] == -1 && other_height == 1.0)
            || (!same && other != 0 && od.opacity == 255 && opaque_occlusion && other_height == 1.0)
        {
            return None;
        }
        let color_material = if offset[1] == 1 {
            let id =
                self.top[(p[1] as usize * self.side + p[2] as usize) * self.side + p[0] as usize];
            let top = self.descriptor(id);
            if id != 0
                && top.liquid == d.liquid
                && top.opacity == d.opacity
                && top.emissive == d.emissive
            {
                id
            } else {
                material
            }
        } else {
            material
        };
        Some(Surface {
            material,
            color_material,
            lower,
            top,
        })
    }
}

fn build_grid(
    tile: &LodTile,
    colors: &HashMap<u16, [u8; 3]>,
    descriptors: &HashMap<u16, RenderDescriptor>,
    water: &HashMap<u16, f32>,
    side: usize,
    budget: usize,
    neighbors: &[Neighbor],
) -> Option<Mesh> {
    let (cells, top) = grid(tile, side);
    let grid = Grid {
        cells,
        top,
        side,
        step: f32::from(tile.key().scale()) * 16.0 / side as f32,
        origin: tile.key().origin().map(|v| v as f32),
        descriptors,
        water,
        neighbors,
    };
    let mut mesh = Mesh {
        vertices: Vec::new(),
        side,
    };
    let mut bytes = 0;
    for (offset, corners, shade) in crate::chunk_mesh::FACES {
        let axis = offset.iter().position(|&v| v != 0).unwrap();
        let u = (axis + 1) % 3;
        let v = (axis + 2) % 3;
        for layer in 0..side {
            let mut mask = vec![None; side * side];
            for j in 0..side {
                for i in 0..side {
                    let mut p = [0; 3];
                    p[axis] = layer as i32;
                    p[u] = i as i32;
                    p[v] = j as i32;
                    mask[j * side + i] = grid.surface(p, offset);
                }
            }
            for j in 0..side {
                let mut i = 0;
                while i < side {
                    let Some(face) = mask[j * side + i] else {
                        i += 1;
                        continue;
                    };
                    let full = face.lower == 0.0 && face.top == 1.0;
                    let mut width = 1;
                    while i + width < side
                        && (u != 1 || full)
                        && mask[j * side + i + width] == Some(face)
                    {
                        width += 1;
                    }
                    let mut height = 1;
                    while j + height < side
                        && (v != 1 || full)
                        && (0..width).all(|x| mask[(j + height) * side + i + x] == Some(face))
                    {
                        height += 1;
                    }
                    let d = grid.descriptor(face.material);
                    bytes += 6 * if d.opacity < 255 {
                        2 * (size_of::<ProxyVertex>() + size_of::<u32>())
                    } else {
                        size_of::<ProxyVertex>()
                    };
                    if bytes > budget {
                        return None;
                    }
                    let mut base = grid.origin;
                    base[axis] += layer as f32 * grid.step;
                    base[u] += i as f32 * grid.step;
                    base[v] += j as f32 * grid.step;
                    let mut extent = [grid.step; 3];
                    extent[u] *= width as f32;
                    extent[v] *= height as f32;
                    let color = colors
                        .get(&face.color_material)
                        .copied()
                        .unwrap_or([255, 0, 255])
                        .map(|c| f32::from(c) / 255.0 * if d.emissive { 1.0 } else { shade });
                    for corner in [0, 1, 2, 0, 2, 3] {
                        let c = corners[corner];
                        let position = [
                            base[0] + c[0] * extent[0],
                            base[1]
                                + face.lower * grid.step
                                + c[1]
                                    * (extent[1] - grid.step + (face.top - face.lower) * grid.step),
                            base[2] + c[2] * extent[2],
                        ];
                        mesh.vertices.push(ProxyVertex {
                            base: Vertex {
                                position,
                                color,
                                opacity: f32::from(d.opacity) / 255.0,
                            },
                            normal: [
                                (offset[0] * 127) as i8,
                                (offset[1] * 127) as i8,
                                (offset[2] * 127) as i8,
                                127,
                            ],
                        });
                    }
                    for y in j..j + height {
                        mask[y * side + i..y * side + i + width].fill(None);
                    }
                    i += width;
                }
            }
        }
    }
    debug_assert_eq!(bytes, mesh.bytes());
    Some(mesh)
}

#[cfg(test)]
mod tests {
    use super::*;
    use wyram_core::scenery::TileKey;
    fn colors() -> HashMap<u16, [u8; 3]> {
        HashMap::from([(42, [40, 180, 30]), (17, [20, 80, 180])])
    }

    #[test]
    fn exposed_top_faces_keep_surface_color_when_the_cell_contains_rock() {
        let mut chunk = vec![0; wyram_core::BYTE_COUNT];
        for y in 0..8 {
            for z in 0..16 {
                for x in 0..16 {
                    let material: u16 = if y == 7 { 42 } else { 41 };
                    let at = ((y * 16 + z) * 16 + x) * 2;
                    chunk[at..at + 2].copy_from_slice(&material.to_le_bytes());
                }
            }
        }
        let air = vec![0; wyram_core::BYTE_COUNT];
        let leaves: Vec<_> = (0..8)
            .map(|i| {
                LodTile::from_chunk(
                    TileKey::new([i & 1, (i >> 1) & 1, i >> 2], 0).unwrap(),
                    if i & 2 == 0 { &chunk } else { &air },
                )
                .unwrap()
            })
            .collect();
        let tile = LodTile::reduce(std::array::from_fn(|i| &leaves[i])).unwrap();
        let colors = HashMap::from([(41, [100, 100, 100]), (42, [40, 180, 30])]);
        let mesh = build(&tile, &colors, &HashMap::new(), &HashMap::new(), 2 << 20).unwrap();
        let top: Vec<_> = mesh
            .vertices
            .iter()
            .filter(|v| v.normal[1] == 127)
            .collect();
        assert!(!top.is_empty());
        assert!(top.iter().all(|v| v.base.position[1] == 8.0));
        assert!(
            top.iter()
                .all(|v| v.base.color == [40.0 / 255.0, 180.0 / 255.0, 30.0 / 255.0]),
            "the exposed surface must keep its color independently of volume material"
        );
    }

    #[test]
    fn surface_colors_cannot_change_liquid_height_opacity_or_family() {
        let mut bytes = b"WSL2".to_vec();
        bytes.extend_from_slice(&[1, 1, 0, 0]);
        for position in [-1i32; 3] {
            bytes.extend_from_slice(&position.to_le_bytes());
        }
        bytes.extend_from_slice(&[17, 0, 8, 0, 0, 0, 255, 1, 42, 0]);
        let tile = LodTile::decode(&bytes).unwrap();
        let descriptors = HashMap::from([(
            17,
            RenderDescriptor {
                opacity: 160,
                emissive: false,
                height: 0.75,
                liquid: 1,
            },
        )]);
        let mesh = build(
            &tile,
            &colors(),
            &descriptors,
            &HashMap::from([(17, 0.75)]),
            2 << 20,
        )
        .unwrap();
        let top: Vec<_> = mesh
            .vertices
            .iter()
            .filter(|v| v.normal[1] == 127)
            .collect();
        assert!(!top.is_empty());
        assert!(top.iter().all(|v| v.base.position[1] == 0.75
            && v.base.opacity == 160.0 / 255.0
            && v.base.color == [20.0 / 255.0, 80.0 / 255.0, 180.0 / 255.0]));
    }

    #[test]
    fn refining_liquid_neighbors_only_retain_walls_when_the_summary_is_opaque() {
        let left = LodTile::uniform(TileKey::new([-1, -1, -1], 2).unwrap(), 17);
        let right = Arc::new(LodTile::uniform(TileKey::new([0, -1, -1], 2).unwrap(), 17));
        for opacity in [160, 255] {
            let descriptors = HashMap::from([(
                17,
                RenderDescriptor {
                    opacity,
                    emissive: false,
                    height: 1.0,
                    liquid: 1,
                },
            )]);
            let mesh = build_with_neighbors(
                &left,
                &colors(),
                &descriptors,
                &HashMap::from([(17, 0.75)]),
                2 << 20,
                &[Neighbor {
                    tile: Arc::clone(&right),
                    opaque_occlusion: false,
                }],
            )
            .unwrap();
            assert_eq!(
                mesh.vertices.iter().any(|v| v.normal[0] == 127),
                opacity == 255,
                "opaque liquid summaries cannot prove child coverage; translucent water keeps shared-wall culling"
            );
        }
    }

    #[test]
    fn adjacent_liquid_tiles_hide_their_shared_wall_but_keep_the_outer_surface() {
        let left = Arc::new(LodTile::uniform(TileKey::new([-1, -1, -1], 1).unwrap(), 17));
        let right = Arc::new(LodTile::uniform(TileKey::new([0, -1, -1], 1).unwrap(), 17));
        let desc = HashMap::from([(
            17,
            RenderDescriptor {
                opacity: 160,
                emissive: false,
                height: 1.0,
                liquid: 1,
            },
        )]);
        let planes = HashMap::from([(17, 0.75)]);
        let a = build_with_neighbors(
            &left,
            &colors(),
            &desc,
            &planes,
            1 << 20,
            &[Arc::clone(&right).into()],
        )
        .unwrap();
        let b = build_with_neighbors(
            &right,
            &colors(),
            &desc,
            &planes,
            1 << 20,
            &[Arc::clone(&left).into()],
        )
        .unwrap();
        assert!(
            a.vertices.iter().all(|v| v.normal[0] != 127),
            "the shared liquid wall must disappear"
        );
        assert!(b.vertices.iter().all(|v| v.normal[0] != -127));
        assert!(
            a.vertices.iter().any(|v| v.normal[0] == -127),
            "the outer surface remains"
        );
        assert!(
            a.vertices
                .iter()
                .filter(|v| v.normal[1] == 127)
                .all(|v| v.base.position[1] == 0.75)
        );
    }

    #[test]
    fn caves_and_detached_islands_preserve_the_oriented_unit_surface() {
        use std::collections::HashSet;
        let occupied: HashSet<[i32; 3]> = (0..8)
            .flat_map(|y| {
                (0..8).flat_map(move |z| {
                    (0..8).filter_map(move |x| {
                        (x == 0 || x == 7 || z == 0 || z == 7 || y == 0).then_some([x, y, z])
                    })
                })
            })
            .chain([[12, 12, 12], [13, 12, 12]])
            .collect();
        let mut data = vec![0; wyram_core::BYTE_COUNT];
        for &[x, y, z] in &occupied {
            data = wyram_core::write_block(&data, x as usize, y as usize, z as usize, 42).unwrap();
        }
        let air = vec![0; wyram_core::BYTE_COUNT];
        let leaves: Vec<_> = (0..8)
            .map(|i| {
                LodTile::from_chunk(
                    TileKey::new([i & 1, (i >> 1) & 1, i >> 2], 0).unwrap(),
                    if i == 0 { &data } else { &air },
                )
                .unwrap()
            })
            .collect();
        let tile = LodTile::reduce(std::array::from_fn(|i| &leaves[i])).unwrap();
        let mesh = build(
            &tile,
            &colors(),
            &HashMap::new(),
            &HashMap::new(),
            2 * 1024 * 1024,
        )
        .unwrap();
        assert_eq!(mesh.side, 32);
        let mut expected = HashSet::new();
        for &p in &occupied {
            for normal in [
                [1, 0, 0],
                [-1, 0, 0],
                [0, 1, 0],
                [0, -1, 0],
                [0, 0, 1],
                [0, 0, -1],
            ] {
                let next = std::array::from_fn(|i| p[i] + normal[i]);
                if !occupied.contains(&next) {
                    expected.insert((p, normal));
                }
            }
        }
        let mut actual = HashSet::new();
        for quad in mesh.vertices.as_chunks::<6>().0 {
            let normal = quad[0].normal[..3]
                .iter()
                .map(|&v| i32::from(v) / 127)
                .collect::<Vec<_>>();
            let normal: [i32; 3] = normal.try_into().unwrap();
            let axis = normal.iter().position(|&v| v != 0).unwrap();
            let u = (axis + 1) % 3;
            let v = (axis + 2) % 3;
            let low: [i32; 3] = std::array::from_fn(|i| {
                quad.iter()
                    .map(|q| q.base.position[i] as i32)
                    .min()
                    .unwrap()
            });
            let high: [i32; 3] = std::array::from_fn(|i| {
                quad.iter()
                    .map(|q| q.base.position[i] as i32)
                    .max()
                    .unwrap()
            });
            for j in low[v]..high[v] {
                for i in low[u]..high[u] {
                    let mut p = low;
                    p[axis] -= i32::from(normal[axis] > 0);
                    p[u] = i;
                    p[v] = j;
                    assert!(actual.insert((p, normal)), "duplicate surface coverage");
                }
            }
        }
        assert_eq!(actual, expected);
    }

    #[test]
    fn solid_negative_tiles_have_six_oriented_quads_at_their_world_extent() {
        let tile = LodTile::uniform(TileKey::new([-1, 0, -1], 6).unwrap(), 42);
        let mesh = build(
            &tile,
            &colors(),
            &HashMap::new(),
            &HashMap::new(),
            2 * 1024 * 1024,
        )
        .unwrap();
        assert_eq!(mesh.vertices.len(), 36);
        for triangle in mesh.vertices.as_chunks::<3>().0 {
            let p = triangle.map(|v| glam::Vec3::from_array(v.base.position));
            let normal: [i8; 3] = triangle[0].normal[..3].try_into().unwrap();
            let normal = glam::Vec3::from_array(normal.map(f32::from));
            assert!((p[1] - p[0]).cross(p[2] - p[0]).dot(normal) > 0.0);
        }
        for v in &mesh.vertices {
            assert!((-1024.0..=0.0).contains(&v.base.position[0]));
            assert!((0.0..=1024.0).contains(&v.base.position[1]));
            assert!((-1024.0..=0.0).contains(&v.base.position[2]));
        }
        assert_eq!(size_of::<ProxyVertex>(), 32);
    }

    #[test]
    fn a_sparse_occupancy_hint_stays_small_and_disconnected_from_empty_space() {
        let mut data = vec![0; wyram_core::BYTE_COUNT];
        data = wyram_core::write_block(&data, 3, 5, 7, 42).unwrap();
        let air = vec![0; wyram_core::BYTE_COUNT];
        let leaves: Vec<_> = (0..8)
            .map(|octant| {
                let key = TileKey::new([octant & 1, (octant >> 1) & 1, octant >> 2], 0).unwrap();
                LodTile::from_chunk(key, if octant == 0 { &data } else { &air }).unwrap()
            })
            .collect();
        let tile = LodTile::reduce(std::array::from_fn(|i| &leaves[i])).unwrap();
        let mesh = build(
            &tile,
            &colors(),
            &HashMap::new(),
            &HashMap::new(),
            2 * 1024 * 1024,
        )
        .unwrap();
        assert_eq!(mesh.side, 32);
        assert_eq!(mesh.vertices.len(), 36);
        for v in mesh.vertices {
            assert!((3.0..=4.0).contains(&v.base.position[0]));
            assert!((5.0..=6.0).contains(&v.base.position[1]));
            assert!((7.0..=8.0).contains(&v.base.position[2]));
        }
    }

    #[test]
    fn liquid_caps_share_the_configured_world_plane_without_scaling_flow_height() {
        let tile = LodTile::uniform(TileKey::new([-1, -1, -1], 4).unwrap(), 17);
        let desc = HashMap::from([(
            17,
            RenderDescriptor {
                opacity: 160,
                emissive: false,
                height: 0.75,
                liquid: 1,
            },
        )]);
        let mesh = build(
            &tile,
            &colors(),
            &desc,
            &HashMap::from([(17, 0.75)]),
            2 * 1024 * 1024,
        )
        .unwrap();
        let top: Vec<_> = mesh
            .vertices
            .iter()
            .filter(|v| v.normal[1] == 127)
            .collect();
        assert_eq!(top.len(), 6);
        assert!(top.iter().all(|v| v.base.position[1] == 0.75));
        assert!(
            mesh.vertices
                .iter()
                .all(|v| v.base.opacity == 160.0 / 255.0)
        );
    }

    #[test]
    fn geometry_degrades_once_to_fit_a_bound_and_empty_tiles_need_no_vertices() {
        let mut data = vec![0; wyram_core::BYTE_COUNT];
        for y in 0..16 {
            for z in 0..16 {
                for x in 0..16 {
                    if (x + y + z) % 2 == 0 {
                        let at = ((y * 16 + z) * 16 + x) * 2;
                        data[at..at + 2].copy_from_slice(&42u16.to_le_bytes());
                    }
                }
            }
        }
        let leaves: Vec<_> = (0..8)
            .map(|i| {
                LodTile::from_chunk(
                    TileKey::new([i & 1, (i >> 1) & 1, i >> 2], 0).unwrap(),
                    &data,
                )
                .unwrap()
            })
            .collect();
        let tile = LodTile::reduce(std::array::from_fn(|i| &leaves[i])).unwrap();
        let mesh = build(&tile, &colors(), &HashMap::new(), &HashMap::new(), 4096).unwrap();
        assert!(mesh.side < 32);
        assert!(mesh.vertices.len() * size_of::<ProxyVertex>() <= 4096);
        assert!(build(&tile, &colors(), &HashMap::new(), &HashMap::new(), 32).is_err());
        let empty = LodTile::uniform(tile.key(), 0);
        assert!(
            build(&empty, &colors(), &HashMap::new(), &HashMap::new(), 0)
                .unwrap()
                .vertices
                .is_empty()
        );
    }
}
