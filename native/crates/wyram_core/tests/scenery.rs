use wyram_core::scenery::{LodError, LodTile, MAX_LEVEL, TileKey};
use wyram_core::{BLOCK_COUNT, BYTE_COUNT, write_block};

fn key(position: [i32; 3], level: u8) -> TileKey {
    TileKey::new(position, level).expect("fixture key")
}

fn children(parent: [i32; 3], level: u8, material: u16) -> [LodTile; 8] {
    std::array::from_fn(|octant| {
        let position = std::array::from_fn(|axis| parent[axis] * 2 + ((octant >> axis) & 1) as i32);
        LodTile::uniform(key(position, level), material)
    })
}

#[test]
fn exact_chunk_import_preserves_material_and_occupancy() {
    let empty = vec![0; BYTE_COUNT];
    let packed = write_block(&empty, 3, 5, 7, 29).expect("fixture block");
    let tile = LodTile::from_chunk(key([-1, -2, 4], 0), &packed).expect("valid chunk");
    assert_eq!(tile.occupied(), 1);
    assert_eq!(tile.cell([3, 5, 7]).expect("inside tile").material(), 29);
    assert_eq!(tile.cell([3, 5, 7]).expect("inside tile").occupied(), 1);
    assert_eq!(tile.cell([4, 5, 7]).expect("inside tile").material(), 0);
    assert_eq!(tile.cell([16, 0, 0]), Err(LodError::OutOfBounds));
    assert_eq!(
        LodTile::from_chunk(key([0; 3], 0), &[0; 8]),
        Err(LodError::BadLength)
    );
    assert_eq!(
        LodTile::from_chunk(key([0; 3], 1), &empty),
        Err(LodError::NotLeaf)
    );
}

#[test]
fn empty_tiles_need_no_dense_cell_allocation() {
    let tile = LodTile::uniform(key([0; 3], 0), 0);
    assert_eq!(tile.occupied(), 0);
    assert_eq!(tile.resident_cell_bytes(), 0);
    let inputs = children([0; 3], 0, 0);
    let parent = LodTile::reduce(std::array::from_fn(|i| &inputs[i])).expect("siblings");
    assert_eq!(parent.key(), key([0; 3], 1));
    assert_eq!(parent.resident_cell_bytes(), 0);
    assert_eq!(parent.cell([15; 3]).expect("inside").occupied(), 0);
}

#[test]
fn solid_tiles_preserve_sample_count_through_the_largest_supported_level() {
    let inputs = children([0; 3], MAX_LEVEL - 1, 7);
    let parent = LodTile::reduce(std::array::from_fn(|i| &inputs[i])).expect("largest parent");
    let samples_per_cell = u32::from(parent.key().scale()).pow(3);
    assert_eq!(
        parent.cell([0; 3]).expect("inside").occupied(),
        samples_per_cell
    );
    assert_eq!(parent.cell([0; 3]).expect("inside").material(), 7);
    assert_eq!(parent.cell([0; 3]).expect("inside").child_mask(), 255);
    assert!(!parent.cell([0; 3]).expect("inside").mixed_materials());
    assert_eq!(
        parent.occupied(),
        u64::from(samples_per_cell) * BLOCK_COUNT as u64
    );
    let highest = children([0; 3], MAX_LEVEL, 7);
    assert_eq!(
        LodTile::reduce(std::array::from_fn(|i| &highest[i])),
        Err(LodError::MaxLevel)
    );
    assert_eq!(TileKey::new([0; 3], MAX_LEVEL + 1), Err(LodError::MaxLevel));
}

#[test]
fn a_single_voxel_survives_reduction_at_negative_coordinates() {
    let mut inputs = children([-1; 3], 0, 0);
    let packed = write_block(&vec![0; BYTE_COUNT], 15, 15, 15, 41).expect("thin feature");
    inputs[7] = LodTile::from_chunk(key([-1; 3], 0), &packed).expect("leaf");
    let parent = LodTile::reduce(std::array::from_fn(|i| &inputs[i])).expect("negative siblings");
    assert_eq!(parent.key(), key([-1; 3], 1));
    assert_eq!(parent.key().origin(), [-32; 3]);
    assert_eq!(parent.occupied(), 1);
    let cell = parent.cell([15; 3]).expect("last cell");
    assert_eq!(cell.material(), 41);
    assert_eq!(cell.occupied(), 1);
    assert_eq!(cell.child_mask(), 128);
}

#[test]
fn material_selection_is_weighted_and_ties_are_deterministic() {
    let mut packed = vec![0; BYTE_COUNT];
    for (position, material) in [([0, 0, 0], 9), ([1, 0, 0], 9), ([0, 1, 0], 4)] {
        packed =
            write_block(&packed, position[0], position[1], position[2], material).expect("fixture");
    }
    let mut inputs = children([0; 3], 0, 0);
    inputs[0] = LodTile::from_chunk(key([0; 3], 0), &packed).expect("leaf");
    let parent = LodTile::reduce(std::array::from_fn(|i| &inputs[i])).expect("siblings");
    let cell = parent.cell([0; 3]).expect("inside");
    assert_eq!(cell.material(), 9);
    assert_eq!(cell.occupied(), 3);
    assert!(cell.mixed_materials());
    packed = write_block(&packed, 1, 1, 0, 4).expect("tie");
    inputs[0] = LodTile::from_chunk(key([0; 3], 0), &packed).expect("leaf");
    let tied = LodTile::reduce(std::array::from_fn(|i| &inputs[i])).expect("siblings");
    assert_eq!(tied.cell([0; 3]).expect("inside").material(), 4);
}

#[test]
fn reduction_accepts_any_arrival_order_but_rejects_duplicate_or_unrelated_children() {
    let inputs = children([-2, 0, 3], 0, 5);
    let original = LodTile::reduce(std::array::from_fn(|i| &inputs[i])).expect("siblings");
    let permutation = [6, 0, 3, 7, 1, 5, 2, 4];
    let shuffled = LodTile::reduce(std::array::from_fn(|i| &inputs[permutation[i]]))
        .expect("shuffled siblings");
    assert_eq!(original, shuffled);
    let mut duplicate = std::array::from_fn(|i| &inputs[i]);
    duplicate[7] = &inputs[0];
    assert_eq!(LodTile::reduce(duplicate), Err(LodError::DuplicateChild));
    let unrelated = LodTile::uniform(key([20; 3], 0), 5);
    let mut wrong = std::array::from_fn(|i| &inputs[i]);
    wrong[7] = &unrelated;
    assert_eq!(LodTile::reduce(wrong), Err(LodError::IncompatibleChildren));
    let another_level = LodTile::uniform(key([-4, 0, 6], 1), 5);
    wrong[7] = &another_level;
    assert_eq!(LodTile::reduce(wrong), Err(LodError::IncompatibleChildren));
}

#[test]
fn origin_arithmetic_is_wide_enough_for_extreme_tile_coordinates() {
    let tile = key([i32::MAX, i32::MIN, 0], MAX_LEVEL);
    let width = i64::from(tile.scale()) * 16;
    assert_eq!(
        tile.origin(),
        [i64::from(i32::MAX) * width, i64::from(i32::MIN) * width, 0]
    );
}

#[test]
fn complete_parent_grid_matches_an_independent_world_space_reduction() {
    let parent_key = key([-2, -1, 3], 1);
    let origin = parent_key.origin();
    let sample = |position: [i64; 3]| {
        (position[0] * 3 + position[1] * 5 + position[2] * 7).rem_euclid(13) as u16
    };
    let inputs: [LodTile; 8] = std::array::from_fn(|octant| {
        let position =
            std::array::from_fn(|axis| [-2, -1, 3][axis] * 2 + ((octant >> axis) & 1) as i32);
        let child_key = key(position, 0);
        let mut packed = vec![0; BYTE_COUNT];
        let child_origin = child_key.origin();
        for y in 0..16 {
            for z in 0..16 {
                for x in 0..16 {
                    let point = [
                        child_origin[0] + x,
                        child_origin[1] + y,
                        child_origin[2] + z,
                    ];
                    let at = ((y * 16 + z) * 16 + x) as usize * 2;
                    packed[at..at + 2].copy_from_slice(&sample(point).to_le_bytes());
                }
            }
        }
        LodTile::from_chunk(child_key, &packed).expect("fixture leaf")
    });
    let parent =
        LodTile::reduce(std::array::from_fn(|i| &inputs[(i * 3) % 8])).expect("shuffled input");
    assert_eq!(
        parent.occupied(),
        inputs.iter().map(LodTile::occupied).sum()
    );
    for y in 0..16 {
        for z in 0..16 {
            for x in 0..16 {
                let mut counts = [0u32; 13];
                let mut mask = 0;
                for octant in 0..8 {
                    let cell = [x, y, z];
                    let point = std::array::from_fn(|axis| {
                        origin[axis] + cell[axis] as i64 * 2 + ((octant >> axis) & 1) as i64
                    });
                    let id = sample(point);
                    if id != 0 {
                        counts[id as usize] += 1;
                        mask |= 1 << octant;
                    }
                }
                let occupied = counts.iter().sum();
                let material = (1..13)
                    .max_by_key(|&id| (counts[id], std::cmp::Reverse(id)))
                    .expect("material range");
                let cell = parent.cell([x, y, z]).expect("inside parent");
                assert_eq!(cell.occupied(), occupied);
                assert_eq!(cell.child_mask(), mask);
                let mut top_counts = [0u32; 13];
                for dx in 0..2 {
                    for dz in 0..2 {
                        let mut id = sample([
                            origin[0] + x as i64 * 2 + dx,
                            origin[1] + y as i64 * 2 + 1,
                            origin[2] + z as i64 * 2 + dz,
                        ]);
                        if id == 0 {
                            id = sample([
                                origin[0] + x as i64 * 2 + dx,
                                origin[1] + y as i64 * 2,
                                origin[2] + z as i64 * 2 + dz,
                            ]);
                        }
                        if id != 0 {
                            top_counts[id as usize] += 1;
                        }
                    }
                }
                let top = (1..13)
                    .max_by_key(|&id| (top_counts[id], std::cmp::Reverse(id)))
                    .unwrap();
                assert_eq!(
                    parent.top_material([x, y, z]).unwrap(),
                    if occupied == 0 { 0 } else { top as u16 }
                );
                assert_eq!(
                    cell.material(),
                    if occupied == 0 { 0 } else { material as u16 }
                );
                assert_eq!(
                    cell.mixed_materials(),
                    counts.iter().filter(|&&count| count > 0).count() > 1
                );
            }
        }
    }
}

#[test]
fn sparse_occupancy_is_not_rounded_away_over_multiple_levels() {
    let packed = write_block(&vec![0; BYTE_COUNT], 0, 0, 0, 41).expect("thin feature");
    let mut tile = LodTile::from_chunk(key([0; 3], 0), &packed).expect("leaf");
    for level in 1..=MAX_LEVEL {
        let mut inputs = children([0; 3], level - 1, 0);
        inputs[0] = tile;
        tile = LodTile::reduce(std::array::from_fn(|i| &inputs[i])).expect("sparse siblings");
        assert_eq!(tile.occupied(), 1);
        assert_eq!(tile.cell([0; 3]).expect("inside").occupied(), 1);
        assert_eq!(tile.cell([0; 3]).expect("inside").material(), 41);
        assert_eq!(tile.cell([0; 3]).expect("inside").child_mask(), 1);
    }
}

#[test]
#[ignore = "manual visual voxel reduction CPU benchmark"]
fn benchmark_visual_voxel_reduction() {
    let dense: [LodTile; 8] = std::array::from_fn(|octant| {
        let packed = (0..BLOCK_COUNT)
            .flat_map(|at| ((at % 11) as u16).to_le_bytes())
            .collect::<Vec<_>>();
        let position = std::array::from_fn(|axis| ((octant >> axis) & 1) as i32);
        LodTile::from_chunk(key(position, 0), &packed).expect("fixture")
    });
    for (name, inputs) in [
        ("empty", children([0; 3], 0, 0)),
        ("solid", children([0; 3], 0, 7)),
        ("mixed", dense),
    ] {
        let start = std::time::Instant::now();
        let mut resident = 0;
        for _ in 0..1_000 {
            let parent = LodTile::reduce(std::array::from_fn(|i| &inputs[i])).expect("siblings");
            resident = parent.resident_cell_bytes();
            std::hint::black_box(parent);
        }
        println!(
            "reduce kind={name} per_tile_ms={:.5} resident_cell_bytes={resident}",
            start.elapsed().as_secs_f64() * 1_000.0 / 1_000.0
        );
    }
}
