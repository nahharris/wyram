use super::*;
use crate::world::RenderDescriptor;
use std::collections::{BTreeMap, HashMap};
use wyram_core::lod::{Cell, Tile, TileKey};

type FaceRectangleKey = (usize, u32, [u32; 3], u32, u32);
type FaceRectangles = BTreeMap<FaceRectangleKey, Vec<[f32; 4]>>;

#[test]
fn lod_vertex_layout_keeps_near_vertex_format_separate() {
    let layout = LodVertex::layout();
    assert_eq!(layout.array_stride, 32);
    assert_eq!(layout.attributes.len(), 4);
    assert_eq!(layout.attributes[3].shader_location, 3);
    assert_eq!(layout.attributes[3].offset, 28);
}

fn new_tile(cell_size: u8, position: [i32; 3]) -> Tile {
    Tile::empty(TileKey::new(cell_size, position).unwrap()).unwrap()
}

#[test]
fn stacked_source_water_has_one_exposed_top_and_no_submerged_sheets() {
    let mut tile = new_tile(2, [0; 3]);
    let water = Cell {
        liquid: 4,
        liquid_height: 2,
        ..Cell::default()
    };
    set_cell(&mut tile, [0, 0, 0], water);
    set_cell(&mut tile, [0, 1, 0], water);
    let descriptors = HashMap::from([(
        4,
        RenderDescriptor {
            liquid: 4,
            height: 0.9,
            opacity: 128,
            ..Default::default()
        },
    )]);
    let (parts, _) = meshes(&tile, &descriptors, |_| None);
    let vertices: Vec<_> = parts.into_iter().flat_map(|p| p.vertices).collect();
    assert_eq!(
        quad_area(&vertices, 1, 1.9),
        0.0,
        "submerged cell must not emit a lowered surface"
    );
    assert_eq!(
        quad_area(&vertices, 1, 2.0),
        0.0,
        "shared interface must be culled"
    );
    assert_eq!(
        quad_area(&vertices, 1, 3.9),
        4.0,
        "exposed liquid height must stay authored"
    );
}

fn core_index(x: usize, y: usize, z: usize) -> usize {
    ((y + 1) * 34 + (z + 1)) * 34 + (x + 1)
}

fn set_cell(tile: &mut Tile, local: [usize; 3], cell: Cell) {
    tile.cells[core_index(local[0], local[1], local[2])] = cell;
}

fn solid(_cell_size: u8, material: u16, solid_height: u8) -> Cell {
    Cell {
        material,
        coverage: 255,
        solid_height,
        ..Cell::default()
    }
}

fn meshes(
    tile: &Tile,
    descriptors: &HashMap<u16, RenderDescriptor>,
    sample: impl Fn([i32; 3]) -> Option<BoundaryCell>,
) -> (Vec<MeshPart>, MeshCompletion) {
    let mut parts = Vec::new();
    let completion = build_parts(tile, &HashMap::new(), descriptors, sample, |part| {
        parts.push(part);
        true
    });
    (parts, completion)
}

fn quad_area(vertices: &[LodVertex], axis: usize, plane: f32) -> f32 {
    vertices
        .as_chunks::<6>()
        .0
        .iter()
        .filter(|quad| quad.iter().all(|vertex| vertex.position[axis] == plane))
        .map(|quad| {
            let mut low = [f32::INFINITY; 3];
            let mut high = [f32::NEG_INFINITY; 3];
            for vertex in quad {
                for i in 0..3 {
                    low[i] = low[i].min(vertex.position[i]);
                    high[i] = high[i].max(vertex.position[i]);
                }
            }
            let tangents: Vec<_> = (0..3).filter(|&i| i != axis).collect();
            (high[tangents[0]] - low[tangents[0]]) * (high[tangents[1]] - low[tangents[1]])
        })
        .sum()
}

fn raw_vertices(
    tile: &Tile,
    colors: &HashMap<u16, [u8; 3]>,
    descriptors: &HashMap<u16, RenderDescriptor>,
    sample: &impl Fn([i32; 3]) -> Option<BoundaryCell>,
) -> Vec<LodVertex> {
    let origin = tile.key.origin().unwrap();
    let size = i32::from(tile.key.cell_size);
    let mut vertices = Vec::new();
    for y in 0..32 {
        for z in 0..32 {
            for x in 0..32 {
                let cell = tile.cells[core_index(x, y, z)];
                let cell_origin = [
                    origin[0] + x as i32 * size,
                    origin[1] + y as i32 * size,
                    origin[2] + z as i32 * size,
                ];
                vertices.extend(build_cell(
                    tile,
                    cell_origin,
                    cell,
                    colors,
                    descriptors,
                    sample,
                ));
            }
        }
    }
    vertices
}

fn built_vertices(
    tile: &Tile,
    colors: &HashMap<u16, [u8; 3]>,
    descriptors: &HashMap<u16, RenderDescriptor>,
    sample: impl Fn([i32; 3]) -> Option<BoundaryCell>,
) -> Vec<LodVertex> {
    let mut parts = Vec::new();
    build_parts(tile, colors, descriptors, sample, |part| {
        parts.push(part);
        true
    });
    parts.into_iter().flat_map(|part| part.vertices).collect()
}

fn oriented_face_rectangles(vertices: &[LodVertex]) -> FaceRectangles {
    let mut rectangles = BTreeMap::new();
    let (quads, remainder) = vertices.as_chunks::<6>();
    assert!(remainder.is_empty());
    for quad in quads {
        let axis = (0..3)
            .find(|&axis| {
                quad.iter()
                    .all(|vertex| vertex.position[axis] == quad[0].position[axis])
            })
            .unwrap();
        let edge_a = std::array::from_fn::<_, 3, _>(|i| quad[1].position[i] - quad[0].position[i]);
        let edge_b = std::array::from_fn::<_, 3, _>(|i| quad[2].position[i] - quad[0].position[i]);
        let normal = edge_a[(axis + 1) % 3] * edge_b[(axis + 2) % 3]
            - edge_a[(axis + 2) % 3] * edge_b[(axis + 1) % 3];
        let face = axis * 2 + usize::from(normal < 0.0);
        let u = (axis + 1) % 3;
        let v = (axis + 2) % 3;
        let low_u = quad
            .iter()
            .map(|vertex| vertex.position[u])
            .fold(f32::INFINITY, f32::min);
        let high_u = quad
            .iter()
            .map(|vertex| vertex.position[u])
            .fold(f32::NEG_INFINITY, f32::max);
        let low_v = quad
            .iter()
            .map(|vertex| vertex.position[v])
            .fold(f32::INFINITY, f32::min);
        let high_v = quad
            .iter()
            .map(|vertex| vertex.position[v])
            .fold(f32::NEG_INFINITY, f32::max);
        let style = (
            face,
            quad[0].position[axis].to_bits(),
            quad[0].color.map(f32::to_bits),
            quad[0].opacity.to_bits(),
            quad[0].lod_size.to_bits(),
        );
        rectangles
            .entry(style)
            .or_insert_with(Vec::new)
            .push([low_u, high_u, low_v, high_v]);
    }
    rectangles
}

fn assert_same_oriented_face_coverage(actual: &[LodVertex], expected: &[LodVertex]) {
    let actual = oriented_face_rectangles(actual);
    let expected = oriented_face_rectangles(expected);
    assert_eq!(
        actual.keys().collect::<Vec<_>>(),
        expected.keys().collect::<Vec<_>>()
    );
    for key in actual.keys() {
        let actual_rects = &actual[key];
        let expected_rects = &expected[key];
        let mut u_edges: Vec<_> = actual_rects
            .iter()
            .chain(expected_rects)
            .flat_map(|rect| [rect[0], rect[1]])
            .collect();
        let mut v_edges: Vec<_> = actual_rects
            .iter()
            .chain(expected_rects)
            .flat_map(|rect| [rect[2], rect[3]])
            .collect();
        u_edges.sort_by(f32::total_cmp);
        v_edges.sort_by(f32::total_cmp);
        u_edges.dedup_by(|a, b| a.to_bits() == b.to_bits());
        v_edges.dedup_by(|a, b| a.to_bits() == b.to_bits());
        for u in u_edges.windows(2) {
            for v in v_edges.windows(2) {
                let u_mid = (u[0] + u[1]) * 0.5;
                let v_mid = (v[0] + v[1]) * 0.5;
                let count = |rects: &[[f32; 4]]| {
                    rects
                        .iter()
                        .filter(|rect| {
                            u_mid >= rect[0]
                                && u_mid < rect[1]
                                && v_mid >= rect[2]
                                && v_mid < rect[3]
                        })
                        .count()
                };
                assert_eq!(
                    count(actual_rects),
                    count(expected_rects),
                    "face coverage differs for {key:?} in patch {:?} x {:?}",
                    u,
                    v
                );
            }
        }
    }
}

fn assert_compaction_parity(
    tile: &Tile,
    colors: &HashMap<u16, [u8; 3]>,
    descriptors: &HashMap<u16, RenderDescriptor>,
    sample: impl Fn([i32; 3]) -> Option<BoundaryCell>,
) {
    let reference = raw_vertices(tile, colors, descriptors, &sample);
    let compacted = built_vertices(tile, colors, descriptors, sample);
    assert_eq!(compacted.len() % 6, 0, "compaction emitted a partial face");
    assert_same_oriented_face_coverage(&compacted, &reference);
    assert!(
        compacted
            .iter()
            .all(|vertex| vertex.color.iter().all(|value| value.is_finite())
                && vertex.opacity.is_finite()
                && vertex.lod_size.is_finite()),
        "compaction emitted non-finite vertex attributes"
    );
}

#[test]
fn one_partial_cell_emits_only_its_exposed_box_and_empty_tile_completes() {
    let mut tile = new_tile(2, [-1, 0, 0]);
    set_cell(&mut tile, [0, 0, 0], solid(2, 7, 1));
    let descriptors = HashMap::from([(7, RenderDescriptor::default())]);
    let (parts, completion) = meshes(&tile, &descriptors, |_| None);

    assert_eq!(parts.len(), 1);
    assert_eq!(parts[0].index, 0);
    assert_eq!(parts[0].vertices.len(), 36);
    assert!(
        parts[0]
            .vertices
            .iter()
            .all(|vertex| vertex.lod_size == 2.0)
    );
    assert!(
        parts[0]
            .vertices
            .iter()
            .all(|vertex| (0.0..=1.0).contains(&vertex.position[1]))
    );
    assert_eq!(completion.parts, 1);
    assert_eq!(completion.bytes, 36 * size_of::<LodVertex>());
    assert!(!completion.cancelled);

    let empty = new_tile(2, [0, 0, 0]);
    let (parts, completion) = meshes(&empty, &descriptors, |_| None);
    assert!(parts.is_empty());
    assert_eq!(completion.parts, 0);
    assert_eq!(completion.bytes, 0);
    assert!(!completion.cancelled);
}

#[test]
fn top_material_only_changes_the_positive_y_surface() {
    let mut tile = new_tile(2, [0, 0, 0]);
    set_cell(
        &mut tile,
        [0, 0, 0],
        Cell {
            material: 1,
            top_material: 2,
            solid_height: 2,
            coverage: 255,
            ..Cell::default()
        },
    );
    let colors = HashMap::from([(1, [255, 0, 0]), (2, [0, 255, 0])]);
    let descriptors = HashMap::from([
        (1, RenderDescriptor::default()),
        (
            2,
            RenderDescriptor {
                opacity: 128,
                ..RenderDescriptor::default()
            },
        ),
    ]);
    let mut parts = Vec::new();
    build_parts(
        &tile,
        &colors,
        &descriptors,
        |_| None,
        |part| {
            parts.push(part);
            true
        },
    );
    let vertices = &parts[0].vertices;
    let top = vertices
        .as_chunks::<6>()
        .0
        .iter()
        .find(|quad| quad.iter().all(|vertex| vertex.position[1] == 2.0))
        .unwrap();
    assert!(top.iter().all(|vertex| vertex.color == [0.0, 1.0, 0.0]));
    assert!(
        top.iter()
            .all(|vertex| (vertex.opacity - 128.0 / 255.0).abs() < 1e-6)
    );
    let side = vertices
        .as_chunks::<6>()
        .0
        .iter()
        .find(|quad| quad.iter().all(|vertex| vertex.position[0] == 2.0))
        .unwrap();
    assert!(side.iter().all(|vertex| vertex.color[0] > 0.0));
}

#[test]
fn coarse_to_fine_seam_subtracts_checkerboard_partial_neighbor_volume() {
    let mut coarse = new_tile(4, [0, 0, 0]);
    set_cell(&mut coarse, [31, 0, 0], solid(4, 1, 4));
    let descriptors = HashMap::from([(1, RenderDescriptor::default())]);
    let sampler = |world: [i32; 3]| {
        if world[0] >= 128 && world[0] < 130 && (0..4).contains(&world[1]) {
            let cell_y = world[1].div_euclid(2) * 2;
            let cell_z = world[2].div_euclid(2) * 2;
            let cell = if (cell_y + cell_z).div_euclid(2).rem_euclid(2) == 0 {
                solid(2, 1, 1)
            } else {
                Cell::default()
            };
            Some(BoundaryCell {
                origin: [128, cell_y, cell_z],
                size: 2,
                cell,
                geometry_ready: true,
            })
        } else {
            None
        }
    };
    let (parts, _) = meshes(&coarse, &descriptors, sampler);
    let mut vertices: Vec<_> = parts.into_iter().flat_map(|part| part.vertices).collect();

    let mut fine = new_tile(2, [64, 0, 0]);
    for y in 0..2 {
        for z in 0..2 {
            if (y + z) % 2 == 0 {
                set_cell(&mut fine, [0, y, z], solid(2, 1, 1));
            }
        }
    }
    let coarse_neighbor = solid(4, 1, 4);
    let fine_sampler = |world: [i32; 3]| {
        Some(BoundaryCell {
            origin: [124, world[1].div_euclid(4) * 4, world[2].div_euclid(4) * 4],
            size: 4,
            cell: coarse_neighbor,
            geometry_ready: true,
        })
    };
    let (fine_parts, _) = meshes(&fine, &descriptors, fine_sampler);
    vertices.extend(fine_parts.into_iter().flat_map(|part| part.vertices));

    // Two diagonal fine cells cover one vertical base block each, removing
    // four coarse-wall patches; the reverse fine faces are culled by the same
    // union rule, leaving no overlapping oriented seam surface.
    assert_eq!(quad_area(&vertices, 0, 128.0), 12.0);
    assert!(
        vertices
            .as_chunks::<6>()
            .0
            .iter()
            .filter(|quad| { quad.iter().all(|vertex| vertex.position[0] == 128.0) })
            .all(|quad| quad.iter().all(|vertex| vertex.position[1] >= 0.0))
    );
}

#[test]
fn full_full_2_to_1_seams_cull_once_on_all_axes_and_both_resolution_sides() {
    for axis in 0..3 {
        for positive in [false, true] {
            for source_is_coarse in [false, true] {
                let source_size = if source_is_coarse { 4 } else { 2 };
                let neighbor_size = if source_is_coarse { 2 } else { 4 };
                let position = [-1; 3];
                let mut source = new_tile(source_size, position);
                let mut local = [10usize; 3];
                local[axis] = if positive { 31 } else { 0 };
                set_cell(&mut source, local, solid(source_size, 1, source_size));
                let origin = source.key.origin().unwrap();
                let boundary = (if positive {
                    origin[axis] + 32 * source_size as i32
                } else {
                    origin[axis]
                }) as f32;
                let neighbor_cell = solid(neighbor_size, 1, neighbor_size);
                let descriptors = HashMap::from([(1, RenderDescriptor::default())]);
                let sampler = move |world: [i32; 3]| {
                    let cell_origin = world.map(|coordinate| {
                        coordinate.div_euclid(neighbor_size as i32) * neighbor_size as i32
                    });
                    Some(BoundaryCell {
                        origin: cell_origin,
                        size: neighbor_size,
                        cell: neighbor_cell,
                        geometry_ready: true,
                    })
                };
                let (parts, _) = meshes(&source, &descriptors, sampler);
                let vertices: Vec<_> = parts.into_iter().flat_map(|part| part.vertices).collect();

                let interface_quads = vertices
                    .as_chunks::<6>()
                    .0
                    .iter()
                    .filter(|quad| quad.iter().all(|vertex| vertex.position[axis] == boundary));
                assert_eq!(
                    interface_quads.count(),
                    0,
                    "interface remained visible axis={axis} positive={positive} source_coarse={source_is_coarse}"
                );
            }
        }
    }
}

#[test]
fn unrendered_coarse_neighbor_does_not_cull_fine_boundary_face() {
    let mut fine = new_tile(2, [0, 0, 0]);
    set_cell(&mut fine, [31, 0, 0], solid(2, 1, 2));
    let descriptors = HashMap::from([(1, RenderDescriptor::default())]);
    let coarse = solid(4, 1, 4);
    let sampler = |geometry_ready| {
        move |world: [i32; 3]| {
            Some(BoundaryCell {
                origin: [64, world[1].div_euclid(4) * 4, world[2].div_euclid(4) * 4],
                size: 4,
                cell: coarse,
                geometry_ready,
            })
        }
    };

    let (unready_parts, _) = meshes(&fine, &descriptors, sampler(false));
    let unready_vertices: Vec<_> = unready_parts
        .into_iter()
        .flat_map(|part| part.vertices)
        .collect();
    let (ready_parts, _) = meshes(&fine, &descriptors, sampler(true));
    let ready_vertices: Vec<_> = ready_parts
        .into_iter()
        .flat_map(|part| part.vertices)
        .collect();

    assert_eq!(
        quad_area(&unready_vertices, 0, 64.0),
        4.0,
        "sampled coarse data without rendered geometry must leave the fine face visible"
    );
    assert_eq!(
        quad_area(&ready_vertices, 0, 64.0),
        0.0,
        "current coarse geometry must still cull the shared fine face"
    );
}

#[test]
fn selected_unready_finer_cell_overrides_coarse_cell_inside_tile_core() {
    let mut tile = new_tile(4, [0, 0, 0]);
    set_cell(&mut tile, [0, 0, 0], solid(4, 1, 4));
    set_cell(&mut tile, [1, 0, 0], solid(4, 1, 4));
    let descriptors = HashMap::from([(1, RenderDescriptor::default())]);
    let sampler = |world: [i32; 3]| {
        (world[0] == 4).then_some(BoundaryCell {
            origin: [4, 0, 0],
            size: 2,
            cell: Cell::default(),
            geometry_ready: false,
        })
    };

    let (parts, _) = meshes(&tile, &descriptors, sampler);
    let vertices: Vec<_> = parts.into_iter().flat_map(|part| part.vertices).collect();

    assert_eq!(
        quad_area(&vertices, 0, 4.0),
        16.0,
        "the selected finer cell must override opaque coarse source data while its mesh is unready"
    );
}

#[test]
fn same_family_liquids_do_not_emit_a_shared_face() {
    let mut tile = new_tile(2, [0, 0, 0]);
    let liquid = Cell {
        liquid: 10,
        liquid_height: 2,
        ..Cell::default()
    };
    set_cell(&mut tile, [0, 0, 0], liquid);
    set_cell(&mut tile, [1, 0, 0], liquid);
    let descriptor = RenderDescriptor {
        opacity: 160,
        emissive: false,
        height: 0.5,
        liquid: 10,
    };
    let descriptors = HashMap::from([(10, descriptor)]);
    let (parts, _) = meshes(&tile, &descriptors, |_| None);
    let vertices: Vec<_> = parts.into_iter().flat_map(|part| part.vertices).collect();

    assert_eq!(quad_area(&vertices, 0, 2.0), 0.0);
    assert!(vertices.iter().all(|vertex| vertex.position[1] <= 1.5));
    assert!(vertices.iter().any(|vertex| vertex.position[1] == 1.5));
}

#[test]
fn equal_liquid_planes_do_not_duplicate_side_water_across_2_to_1_seams() {
    for source_size in [2, 4] {
        let neighbor_size = if source_size == 2 { 4 } else { 2 };
        let mut source = new_tile(source_size, [-1, -1, -1]);
        let mut local = [0; 3];
        local[0] = 31;
        set_cell(
            &mut source,
            local,
            Cell {
                liquid: 10,
                liquid_height: 2,
                ..Cell::default()
            },
        );
        let descriptor = RenderDescriptor {
            opacity: 160,
            emissive: false,
            height: 1.0,
            liquid: 10,
        };
        let descriptors = HashMap::from([(10, descriptor)]);
        let neighbor = Cell {
            liquid: 10,
            liquid_height: 2,
            ..Cell::default()
        };
        let sampler = move |world: [i32; 3]| {
            let origin = world.map(|coordinate| {
                coordinate.div_euclid(i32::from(neighbor_size)) * i32::from(neighbor_size)
            });
            Some(BoundaryCell {
                origin,
                size: neighbor_size,
                cell: neighbor,
                geometry_ready: true,
            })
        };
        let (parts, _) = meshes(&source, &descriptors, sampler);
        let vertices: Vec<_> = parts.into_iter().flat_map(|part| part.vertices).collect();

        assert_eq!(quad_area(&vertices, 0, 0.0), 0.0);
    }
}

#[test]
fn all_supported_lods_use_world_cell_size_and_emit_the_same_box_contract() {
    for size in [2, 4, 8, 16] {
        let mut tile = new_tile(size, [-1, 0, 0]);
        set_cell(&mut tile, [0, 0, 0], solid(size, 1, size));
        let descriptors = HashMap::from([(1, RenderDescriptor::default())]);
        let (parts, _) = meshes(&tile, &descriptors, |_| None);
        let vertices: Vec<_> = parts.into_iter().flat_map(|part| part.vertices).collect();
        assert_eq!(vertices.len(), 36);
        assert!(
            vertices
                .iter()
                .all(|vertex| vertex.lod_size == f32::from(size))
        );
        assert!(vertices.iter().all(|vertex| {
            vertex.position[0] >= -32.0 * f32::from(size)
                && vertex.position[0] <= -31.0 * f32::from(size)
        }));
    }
}

fn checkerboard_tile() -> Tile {
    let mut tile = new_tile(16, [0, 0, 0]);
    for y in 0..32 {
        for z in 0..32 {
            for x in 0..32 {
                if (x + y + z) % 2 == 0 {
                    set_cell(&mut tile, [x, y, z], solid(16, 1, 16));
                }
            }
        }
    }
    tile
}

#[test]
fn pathological_checkerboard_streams_only_bounded_parts() {
    let tile = checkerboard_tile();
    let descriptors = HashMap::from([(1, RenderDescriptor::default())]);
    let mut parts = Vec::new();
    let completion = build_parts(
        &tile,
        &HashMap::new(),
        &descriptors,
        |_| None,
        |part| {
            assert!(part.vertices.len() * size_of::<LodVertex>() <= 1024 * 1024);
            assert_eq!(part.vertices.len() % 6, 0);
            for axis in 0..3 {
                let minimum = part
                    .vertices
                    .iter()
                    .map(|vertex| vertex.position[axis])
                    .fold(f32::INFINITY, f32::min);
                let maximum = part
                    .vertices
                    .iter()
                    .map(|vertex| vertex.position[axis])
                    .fold(f32::NEG_INFINITY, f32::max);
                assert!(maximum - minimum <= 8.0 * 16.0);
            }
            parts.push(part);
            true
        },
    );
    assert!(parts.len() > 1);
    assert_eq!(completion.parts as usize, parts.len());
    assert_eq!(
        completion.bytes,
        parts
            .iter()
            .map(|part| part.vertices.len() * 32)
            .sum::<usize>()
    );
    assert!(
        parts
            .iter()
            .enumerate()
            .all(|(index, part)| part.index as usize == index)
    );
    assert!(!completion.cancelled);
}

#[test]
fn full_solid_tile_compacts_closing_walls_by_at_least_sixteen_times() {
    let mut tile = new_tile(2, [0, 0, 0]);
    for y in 0..32 {
        for z in 0..32 {
            for x in 0..32 {
                set_cell(&mut tile, [x, y, z], solid(2, 1, 2));
            }
        }
    }
    let colors = HashMap::from([(1, [120, 80, 40])]);
    let descriptors = HashMap::from([(1, RenderDescriptor::default())]);
    let reference = raw_vertices(&tile, &colors, &descriptors, &|_| None);
    let mut parts = Vec::new();
    let completion = build_parts(
        &tile,
        &colors,
        &descriptors,
        |_| None,
        |part| {
            assert!(part.vertices.len() * size_of::<LodVertex>() <= MAX_PART_BYTES);
            parts.push(part);
            true
        },
    );
    let compacted: Vec<_> = parts
        .iter()
        .flat_map(|part| part.vertices.iter().copied())
        .collect();

    assert_eq!(reference.len(), 6 * 32 * 32 * 6);
    assert!(compacted.len() * 16 <= reference.len());
    assert_same_oriented_face_coverage(&compacted, &reference);
    assert_eq!(completion.parts as usize, parts.len());
    assert_eq!(
        parts
            .iter()
            .map(|part| part.index as usize)
            .collect::<Vec<_>>(),
        (0..parts.len()).collect::<Vec<_>>()
    );
    assert_eq!(completion.bytes, compacted.len() * size_of::<LodVertex>());
}

#[test]
fn compaction_preserves_water_negative_checkerboard_seam_and_mixed_faces() {
    let colors = HashMap::from([(1, [20, 90, 150]), (2, [20, 90, 150])]);
    let solid_descriptors = HashMap::from([
        (1, RenderDescriptor::default()),
        (2, RenderDescriptor::default()),
    ]);

    let mut negative_solid = new_tile(2, [-1, -1, -1]);
    for y in 0..3 {
        for z in 0..3 {
            for x in 0..3 {
                set_cell(&mut negative_solid, [x, y, z], solid(2, 1, 2));
            }
        }
    }
    assert_compaction_parity(&negative_solid, &colors, &solid_descriptors, |_| None);

    let mut water = new_tile(2, [-1, 0, -1]);
    let liquid = Cell {
        liquid: 1,
        liquid_height: 2,
        ..Cell::default()
    };
    for z in 0..4 {
        for x in 0..4 {
            set_cell(&mut water, [x, 0, z], liquid);
        }
    }
    let liquid_descriptors = HashMap::from([(
        1,
        RenderDescriptor {
            liquid: 1,
            height: 0.5,
            opacity: 128,
            ..Default::default()
        },
    )]);
    assert_compaction_parity(&water, &colors, &liquid_descriptors, |_| None);
    assert_eq!(
        built_vertices(&water, &colors, &liquid_descriptors, |_| None),
        raw_vertices(&water, &colors, &liquid_descriptors, &|_| None),
        "transparent quads retain their individual positions for depth sorting"
    );

    let mut checkerboard = new_tile(2, [-1, 0, -1]);
    for y in 0..8 {
        for z in 0..8 {
            for x in 0..8 {
                if (x + y + z) % 2 == 0 {
                    set_cell(&mut checkerboard, [x, y, z], solid(2, 1, 2));
                }
            }
        }
    }
    assert_compaction_parity(&checkerboard, &colors, &solid_descriptors, |_| None);

    let mut seam = new_tile(4, [0, 0, 0]);
    set_cell(&mut seam, [31, 0, 0], solid(4, 1, 4));
    let seam_sample = |world: [i32; 3]| {
        (world[0] >= 128).then_some(BoundaryCell {
            origin: [128, world[1].div_euclid(2) * 2, world[2].div_euclid(2) * 2],
            size: 2,
            cell: solid(2, 1, 2),
            geometry_ready: true,
        })
    };
    assert_compaction_parity(&seam, &colors, &solid_descriptors, seam_sample);

    let mut mixed = new_tile(2, [0, 0, 0]);
    set_cell(&mut mixed, [0, 0, 0], solid(2, 1, 2));
    set_cell(&mut mixed, [1, 0, 0], solid(2, 2, 2));
    let mixed_reference = raw_vertices(&mixed, &colors, &solid_descriptors, &|_| None);
    let mixed_actual = built_vertices(&mixed, &colors, &solid_descriptors, |_| None);
    assert_eq!(
        mixed_actual, mixed_reference,
        "mixed material parts are left unmerged"
    );
}

#[test]
fn malformed_rectangle_keeps_the_original_triangles() {
    let mut vertices = Vec::new();
    push_quad(2, [0.0; 3], [2.0; 3], [0.5; 3], 1.0, 2.0, &mut vertices);
    push_quad(
        2,
        [2.0, 0.0, 0.0],
        [4.0, 2.0, 2.0],
        [0.5; 3],
        1.0,
        2.0,
        &mut vertices,
    );
    vertices[4] = vertices[3];
    vertices[5] = vertices[3];
    let original = vertices.clone();
    compact_quads(&mut vertices);
    assert_eq!(vertices, original);
}

#[test]
fn callback_cancellation_stops_streaming() {
    let tile = checkerboard_tile();
    let descriptors = HashMap::from([(1, RenderDescriptor::default())]);
    let mut emitted = 0;
    let completion = build_parts(
        &tile,
        &HashMap::new(),
        &descriptors,
        |_| None,
        |_| {
            emitted += 1;
            false
        },
    );
    assert_eq!(emitted, 1);
    assert!(completion.cancelled);
    assert_eq!(completion.parts, 0);
    assert_eq!(completion.bytes, 0);
}
