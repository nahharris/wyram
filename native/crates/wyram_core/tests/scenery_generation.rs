use wyram_core::scenery::{LodTile, TileKey};
use wyram_core::worldgen::{Feature, Generator, Settings};

fn key(position: [i32; 3], level: u8) -> TileKey {
    TileKey::new(position, level).expect("fixture key")
}

#[test]
fn finest_scenic_generation_matches_exact_chunks() {
    let generator = Generator::new(2026, Settings::default()).expect("fixture");
    for position in [[-1, 0, -1], [0, -12, 0], [0, 14, 0]] {
        let tile = generator.scenic_tile(key(position, 0)).expect("tile");
        let exact =
            LodTile::from_chunk(key(position, 0), &generator.chunk(position).expect("chunk"))
                .expect("import");
        assert_eq!(tile, exact);
    }
}

#[test]
fn level_one_matches_full_sibling_reduction_including_features() {
    let mut settings = Settings::default();
    settings.biomes[0].features.push(Feature {
        kind: 1,
        block: 5,
        accent: 6,
        spacing: 16,
        density: 1.0,
        radius: 8,
        height: 32,
        salt: 109,
        domain: 0,
        support_depth: 16,
    });
    let generator = Generator::new(2, settings).expect("fixture");
    let [x, y, z] = generator.spawn();
    let positions = [
        [-1, -1, -1],
        [x.div_euclid(32), y.div_euclid(32), z.div_euclid(32)],
        [0, 7, 0],
    ];
    let mut features = 0;
    for position in positions {
        let children: [LodTile; 8] = std::array::from_fn(|octant| {
            let position =
                std::array::from_fn(|axis| position[axis] * 2 + ((octant >> axis) & 1) as i32);
            LodTile::from_chunk(key(position, 0), &generator.chunk(position).expect("chunk"))
                .expect("leaf")
        });
        let expected = LodTile::reduce(std::array::from_fn(|i| &children[i])).expect("parent");
        let actual = generator
            .scenic_tile(key(position, 1))
            .expect("scenic parent");
        assert_eq!(actual, expected, "position {position:?}");
        for y in 0..16 {
            for z in 0..16 {
                for x in 0..16 {
                    features += usize::from(matches!(
                        actual.cell([x, y, z]).expect("cell").material(),
                        5 | 6
                    ));
                }
            }
        }
    }
    assert!(
        features > 0,
        "parity fixture must contain decoration geometry"
    );
}

#[test]
fn coarse_cells_match_a_separate_world_space_sample_oracle() {
    let generator = Generator::new(41, Settings::default()).expect("fixture");
    for tile_key in [key([-1, 0, -1], 3), key([0, 0, 0], 5)] {
        let tile = generator.scenic_tile(tile_key).expect("coarse tile");
        let origin = tile_key.origin();
        let scale = i64::from(tile_key.scale());
        for z in [0, 3, 15] {
            for y in [0, 7, 15] {
                for x in [0, 5, 15] {
                    let p = [x, y, z];
                    let mut weights = std::collections::BTreeMap::<u16, u32>::new();
                    let mut mask = 0u8;
                    for octant in 0..8 {
                        let sample = std::array::from_fn(|axis| {
                            (origin[axis]
                                + p[axis] as i64 * scale
                                + scale / 4
                                + ((octant >> axis) & 1) as i64 * (scale / 2))
                                as i32
                        });
                        let material = generator.voxel(sample);
                        if material != 0 {
                            mask |= 1 << octant;
                            *weights.entry(material).or_default() += (scale / 2).pow(3) as u32;
                        }
                    }
                    let expected_material = weights
                        .iter()
                        .max_by_key(|(id, weight)| (**weight, std::cmp::Reverse(**id)))
                        .map_or(0, |(&id, _)| id);
                    let cell = tile.cell(p).expect("cell");
                    assert_eq!(cell.material(), expected_material);
                    assert_eq!(cell.occupied(), weights.values().sum());
                    assert_eq!(cell.child_mask(), mask);
                    assert_eq!(cell.mixed_materials(), weights.len() > 1);
                }
            }
        }
        assert_eq!(LodTile::decode(&tile.encode()).expect("roundtrip"), tile);
    }
}

#[test]
fn invalid_coordinates_and_generation_levels_are_rejected_and_outside_height_is_empty() {
    let generator = Generator::new(0, Settings::default()).expect("fixture");
    for invalid in [
        key([i32::MAX, 0, 0], 1),
        key([0; 3], 7),
        key([-62501, 0, 0], 0),
        key([62500, 0, 0], 1),
    ] {
        assert!(generator.scenic_tile(invalid).is_err());
    }
    for position in [[0, -2, 0], [0, 1, 0]] {
        let tile = generator
            .scenic_tile(key(position, 6))
            .expect("outside tile");
        assert_eq!(tile.occupied(), 0);
        assert_eq!(tile.encode().len(), 20);
    }
}

#[test]
#[ignore = "manual matched scenic generation CPU benchmark"]
fn benchmark_scenic_generation() {
    use std::hint::black_box;
    use std::time::Instant;
    let generator = Generator::new(2026, Settings::default()).expect("fixture");
    let tile_key = key([-1, 0, -1], 1);
    let exact = || {
        let children: [LodTile; 8] = std::array::from_fn(|octant| {
            let position = std::array::from_fn(|axis| {
                tile_key.position()[axis] * 2 + ((octant >> axis) & 1) as i32
            });
            LodTile::from_chunk(key(position, 0), &generator.chunk(position).expect("chunk"))
                .expect("leaf")
        });
        LodTile::reduce(std::array::from_fn(|i| &children[i])).expect("parent")
    };
    assert_eq!(exact(), generator.scenic_tile(tile_key).expect("scenic"));
    let mut baseline = Vec::new();
    let mut scenic = Vec::new();
    for iteration in 0..12 {
        for first in [iteration % 2 == 0, iteration % 2 != 0] {
            let start = Instant::now();
            if first {
                black_box(exact());
            } else {
                black_box(generator.scenic_tile(tile_key).expect("tile"));
            }
            let elapsed = start.elapsed().as_secs_f64() * 1000.0;
            if first {
                baseline.push(elapsed);
            } else {
                scenic.push(elapsed);
            }
        }
    }
    baseline.sort_by(f64::total_cmp);
    scenic.sort_by(f64::total_cmp);
    println!(
        "exact level-one median: {:.5} ms; direct median: {:.5} ms",
        baseline[6], scenic[6]
    );
    for level in [2, 4, 6] {
        let tile_key = key([0, 0, 0], level);
        let start = Instant::now();
        for _ in 0..12 {
            black_box(generator.scenic_tile(tile_key).expect("tile"));
        }
        println!(
            "level {level} sampled mean: {:.5} ms",
            start.elapsed().as_secs_f64() * 1000.0 / 12.0
        );
    }
}
