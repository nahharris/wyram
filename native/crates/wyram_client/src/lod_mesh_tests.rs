use super::*;
use crate::world::RenderDescriptor;
use std::collections::HashMap;
use wyram_core::lod::{Cell, Tile, TileKey};

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
