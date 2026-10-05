use wyram_core::lod::{Cell, ChunkOverride, Tile, TileKey};
use wyram_core::worldgen::{Generator, Settings};
use wyram_core::{BYTE_COUNT, write_block};

#[test]
fn occupied_tree_interiors_fill_the_entire_coarse_cell_height() {
    let mut settings = Settings {
        relief: 0,
        ..Settings::default()
    };
    settings.biomes[0].elevation_offset = 64;
    settings.biomes[0]
        .features
        .push(wyram_core::worldgen::Feature {
            kind: 0,
            block: 9,
            accent: 10,
            spacing: 32,
            density: 1.0,
            radius: 5,
            height: 16,
            salt: 101,
            domain: 0,
            support_depth: 0,
        });
    let generator = Generator::new(2026, settings).unwrap();
    let mut checked = 0;
    for tile_y in 0..3 {
        let tile = generator.lod_tile(key(2, [0, tile_y, 0]), &[]).unwrap();
        for z in (0..64).step_by(2) {
            for x in (0..64).step_by(2) {
                for y in (tile_y * 64..tile_y * 64 + 64).step_by(2) {
                    let supported_columns = (0..2)
                        .flat_map(|dz| (0..2).map(move |dx| (dx, dz)))
                        .filter(|&(dx, dz)| {
                            (0..2).all(|dy| {
                                matches!(generator.voxel([x + dx, y + dy, z + dz]), 9 | 10)
                            })
                        })
                        .count();
                    if supported_columns >= 2 {
                        assert_eq!(
                            tile.sample([x, y, z]).unwrap().solid_height,
                            2,
                            "tree interior at {x},{y},{z} must not become a floating slab"
                        );
                        checked += 1;
                    }
                }
            }
        }
    }
    assert!(checked > 0, "fixture must contain occupied tree interiors");
}

fn key(size: u8, position: [i32; 3]) -> TileKey {
    TileKey::new(size, position).expect("valid LOD key")
}

fn empty_data() -> Vec<u8> {
    vec![0; BYTE_COUNT]
}

#[test]
fn keys_are_world_aligned_at_every_scale_and_negative_coordinate() {
    for size in [2, 4, 8, 16] {
        let span = i32::from(size) * 32;
        let tile = key(size, [-1, 2, -3]);
        assert_eq!(tile.origin().unwrap(), [-span, 2 * span, -3 * span]);
        let data = Tile::empty(tile).unwrap();
        assert_eq!(data.cells.len(), 34usize.pow(3));
        assert_eq!(
            data.sample([-span, 2 * span, -3 * span]),
            Some(Cell::default())
        );
        assert_eq!(
            data.sample([-span - i32::from(size) - 1, 2 * span, -3 * span]),
            None
        );
    }
    for invalid in [0, 1, 3, 32] {
        assert!(TileKey::new(invalid, [0; 3]).is_err());
    }
    let malformed = TileKey {
        cell_size: 0,
        position: [0; 3],
    };
    assert!(malformed.origin().is_err());
    assert!(Tile::empty(malformed).is_err());
    assert!(Tile::decode(malformed, b"LT01").is_err());
    assert!(
        Tile {
            key: malformed,
            cells: vec![Cell::default(); 34usize.pow(3)],
        }
        .sample([0; 3])
        .is_none()
    );
}

#[test]
fn tile_codec_roundtrips_deterministically_and_rejects_malformed_runs() {
    let tile_key = key(4, [-2, 1, -3]);
    let mut tile = Tile::empty(tile_key).unwrap();
    let index = (34 + 2) * 34 + 3;
    tile.cells[index] = Cell {
        material: 7,
        top_material: 8,
        liquid: 9,
        coverage: 128,
        solid_height: 3,
        liquid_height: 2,
        reserved: 0,
    };
    let encoded = tile.encode().unwrap();
    assert_eq!(tile.encode().unwrap(), encoded);
    assert_eq!(Tile::decode(tile_key, &encoded).unwrap(), tile);

    for length in 0..encoded.len() {
        assert!(Tile::decode(tile_key, &encoded[..length]).is_err());
    }
    let mut trailing = encoded.clone();
    trailing.push(0);
    assert!(Tile::decode(tile_key, &trailing).is_err());
    assert!(Tile::decode(key(2, [0; 3]), &encoded).is_err());

    let mut zero_run = encoded.clone();
    zero_run[4..6].copy_from_slice(&0u16.to_le_bytes());
    assert!(Tile::decode(tile_key, &zero_run).is_err());
    let mut oversized_run = encoded.clone();
    oversized_run[4..6].copy_from_slice(&((34usize.pow(3) + 1) as u16).to_le_bytes());
    assert!(Tile::decode(tile_key, &oversized_run).is_err());
    let mut wrong_magic = encoded.clone();
    wrong_magic[0] = b'X';
    assert!(Tile::decode(tile_key, &wrong_magic).is_err());
    assert!(Tile::decode(tile_key, &vec![0; 1024 * 1024 + 1]).is_err());
}

#[test]
fn invalid_cells_and_oversized_or_duplicate_overrides_are_rejected_atomically() {
    let tile_key = key(2, [0, 4, 0]);
    let mut tile = Tile::empty(tile_key).unwrap();
    let before = tile.clone();
    let mut data = empty_data();
    data[0..2].copy_from_slice(&9u16.to_le_bytes());
    let duplicate = [
        ChunkOverride {
            key: [0, 18, 0],
            data: &data,
        },
        ChunkOverride {
            key: [0, 18, 0],
            data: &data,
        },
    ];
    assert!(tile.apply_overrides(&duplicate, &[]).is_err());
    assert_eq!(tile, before);

    let oversized = vec![
        ChunkOverride {
            key: [0, 18, 0],
            data: &data
        };
        129
    ];
    assert!(tile.apply_overrides(&oversized, &[]).is_err());

    let mut malformed = tile.clone();
    malformed.cells[0].reserved = 1;
    assert!(malformed.encode().is_err());
    malformed.cells[0].reserved = 0;
    malformed.cells[0].solid_height = 1;
    assert!(malformed.encode().is_err());
    let too_large = TileKey {
        cell_size: 16,
        position: [i32::MAX, 0, 0],
    };
    assert!(too_large.origin().is_err());
}

#[test]
fn exact_fine_cells_and_edit_clear_restore_reduce_all_eight_source_voxels() {
    let generator = Generator::new(2026, Settings::default()).unwrap();
    let tile_key = key(2, [0, 4, 0]);
    let mut tile = generator.lod_tile(tile_key, &[]).unwrap();
    let sample_before = tile.sample([4, 300, 4]).unwrap();

    let mut data = empty_data();
    for y in 12..14 {
        for z in 4..6 {
            for x in 4..6 {
                data = write_block(&data, x, y, z, 9).unwrap();
            }
        }
    }
    let edit = [ChunkOverride {
        key: [0, 18, 0],
        data: &data,
    }];
    tile.apply_overrides(&edit, &[]).unwrap();
    let solid = tile.sample([4, 300, 4]).unwrap();
    assert_eq!(solid.material, 9);
    assert_eq!(solid.coverage, 255);
    assert_eq!(solid.solid_height, 2);

    let cleared = empty_data();
    tile.apply_overrides(
        &[ChunkOverride {
            key: [0, 18, 0],
            data: &cleared,
        }],
        &[],
    )
    .unwrap();
    assert_eq!(tile.sample([4, 300, 4]).unwrap(), sample_before);
    tile.apply_overrides(&edit, &[]).unwrap();
    assert_eq!(tile.sample([4, 300, 4]).unwrap(), solid);

    let water_data = write_block(&empty_data(), 4, 10, 4, 17).unwrap();
    let mut water_tile = generator.lod_tile(key(2, [0, 5, 0]), &[]).unwrap();
    water_tile
        .apply_overrides(
            &[ChunkOverride {
                key: [0, 20, 0],
                data: &water_data,
            }],
            &[17],
        )
        .unwrap();
    let fluid = water_tile.sample([4, 330, 4]).unwrap();
    assert_eq!(fluid.material, 0);
    assert_eq!(fluid.liquid, 17);
    assert_eq!(fluid.liquid_height, 1);

    let mut variants = empty_data();
    variants = write_block(&variants, 4, 10, 4, 17).unwrap();
    variants = write_block(&variants, 5, 10, 4, 17).unwrap();
    variants = write_block(&variants, 4, 11, 4, 18).unwrap();
    let mut variant_tile = generator.lod_tile(key(2, [0, 5, 0]), &[]).unwrap();
    variant_tile
        .apply_overrides(
            &[ChunkOverride {
                key: [0, 20, 0],
                data: &variants,
            }],
            &[17, 18],
        )
        .unwrap();
    let variant = variant_tile.sample([4, 330, 4]).unwrap();
    assert_eq!(
        variant.liquid, 18,
        "the top liquid variant owns the surface"
    );
    assert_eq!(variant.liquid_height, 2);
}

#[test]
fn a_single_stratified_hit_keeps_density_without_becoming_a_full_solid_cell() {
    let mut data = empty_data();
    data = write_block(&data, 4, 10, 4, 9).unwrap();
    let mut tile = Tile::empty(key(2, [0, 5, 0])).unwrap();
    tile.apply_overrides(
        &[ChunkOverride {
            key: [0, 20, 0],
            data: &data,
        }],
        &[],
    )
    .unwrap();
    let cell = tile.sample([4, 330, 4]).unwrap();
    assert_eq!(cell.coverage, 32);
    assert_eq!(cell.material, 0);
    assert_eq!(cell.solid_height, 0);
}

#[test]
fn generated_surface_and_liquid_summaries_keep_independent_material_and_height() {
    let generator = Generator::new(2026, Settings::default()).unwrap();
    let [x, _, z] = generator.spawn();
    let column = generator.column(x, z);
    let size = 2;
    let span = 32 * i32::from(size);
    let tile_key = key(
        size,
        [
            x.div_euclid(span),
            column.height.div_euclid(span),
            z.div_euclid(span),
        ],
    );
    let tile = generator.lod_tile(tile_key, &[4]).unwrap();
    let top = tile.sample([x, column.height, z]).unwrap();
    assert_eq!(top.top_material, generator.voxel([x, column.height, z]));
    assert!(top.solid_height > 0);

    let water_key = key(2, [0, -1, 0]);
    let water_tile = generator.lod_tile(water_key, &[4]).unwrap();
    let water = water_tile.sample([0, -1, 0]).unwrap();
    assert_eq!(water.liquid, 4);
    assert!(water.liquid_height > 0);
}

#[test]
fn generated_liquid_material_comes_from_the_highest_sampled_liquid_level() {
    let mut settings = Settings::default();
    settings.biomes[0].water = 17;
    let mut second = settings.biomes[0].clone();
    second.water = 18;
    settings.biomes.push(second);
    let generator = Generator::new(2026, settings).unwrap();
    let tile_key = key(4, [0, -1, 0]);
    let mut fixture = None;

    'search: for cell_low in (-128..=-4).step_by(4) {
        for cell_z in 0..32 {
            for cell_x in 0..32 {
                let xs = [cell_x * 4 + 1, cell_x * 4 + 3];
                let zs = [cell_z * 4 + 1, cell_z * 4 + 3];
                let samples: Vec<_> = zs
                    .into_iter()
                    .flat_map(|z| xs.into_iter().map(move |x| (x, z)))
                    .flat_map(|(x, z)| {
                        [1, 3].map(|offset| {
                            let y = cell_low + offset;
                            let material = generator.voxel([x, y, z]);
                            (y, material)
                        })
                    })
                    .filter(|(_, material)| matches!(material, 17 | 18))
                    .collect();
                let mut volume_counts = std::collections::BTreeMap::new();
                let highest_y = samples.iter().map(|(y, _)| *y).max();
                let mut top_counts = std::collections::BTreeMap::new();

                for (y, material) in &samples {
                    *volume_counts.entry(*material).or_insert(0usize) += 1;
                    if Some(*y) == highest_y {
                        *top_counts.entry(*material).or_insert(0usize) += 1;
                    }
                }

                let mode = |counts: &std::collections::BTreeMap<u16, usize>| {
                    counts
                        .iter()
                        .max_by(|(left_id, left_count), (right_id, right_count)| {
                            left_count
                                .cmp(right_count)
                                .then_with(|| right_id.cmp(left_id))
                        })
                        .map(|(&id, _)| id)
                };

                if mode(&volume_counts).is_some() && mode(&volume_counts) != mode(&top_counts) {
                    fixture = Some((cell_x, cell_z, cell_low, mode(&top_counts).unwrap()));
                    break 'search;
                }
            }
        }
    }

    let (cell_x, cell_z, cell_low, expected_liquid) =
        fixture.expect("mixed-biome fixture has different volume and top liquid votes");
    let tile = generator.lod_tile(tile_key, &[17, 18]).unwrap();
    let world_cell = [cell_x * 4, cell_low, cell_z * 4];
    let actual = tile.sample(world_cell).unwrap();
    assert_eq!(actual.liquid, expected_liquid);
}

#[test]
fn separated_island_and_ground_caps_preserve_both_surfaces_and_the_air_gap() {
    let mut settings = Settings {
        sea_level: 100,
        ..Settings::default()
    };
    let islands = settings.islands.as_mut().unwrap();
    islands.base_y = 280;
    islands.thickness = 32;
    islands.relief = 0;
    islands.threshold = 0.5;
    let generator = Generator::new(2026, settings).unwrap();
    let tile_key = key(16, [0, 0, 0]);
    let tile = generator.lod_tile(tile_key, &[4]).unwrap();
    let mut fixture = None;
    for cell_z in 0..32 {
        for cell_x in 0..32 {
            let xs = [cell_x * 16 + 4, cell_x * 16 + 12];
            let zs = [cell_z * 16 + 4, cell_z * 16 + 12];
            let columns: Vec<_> = zs
                .into_iter()
                .flat_map(|z| xs.into_iter().map(move |x| (x, z)))
                .map(|(x, z)| (x, z, generator.column(x, z)))
                .collect();
            let ground = columns
                .iter()
                .filter(|(_, _, c)| c.height > 8)
                .map(|(_, _, c)| c.height)
                .collect::<Vec<_>>();
            let Some(&ground_y) = ground.first() else {
                continue;
            };
            let ground_level = ground_y.div_euclid(16);
            let ground_support = columns
                .iter()
                .filter(|(_, _, c)| c.height.div_euclid(16) == ground_level)
                .count();
            let islands: Vec<_> = columns
                .iter()
                .filter_map(|(_, _, c)| c.island)
                .filter(|(_, top)| top.div_euclid(16) < 32)
                .collect();
            let Some(&(island_bottom, island_top)) = islands.first() else {
                continue;
            };
            let island_level = island_top.div_euclid(16);
            let island_support = columns
                .iter()
                .filter(|(_, _, c)| {
                    c.island
                        .is_some_and(|(_, top)| top.div_euclid(16) == island_level)
                })
                .count();
            if ground_support >= 2
                && island_support >= 2
                && island_bottom > ground_y + 32
                && ground_level >= 0
            {
                fixture = Some((columns, ground_level, island_level, ground_y, island_bottom));
                break;
            }
        }
        if fixture.is_some() {
            break;
        }
    }
    let (columns, ground_level, island_level, ground_y, island_bottom) =
        fixture.expect("default settings include separated supported island and ground caps");
    let (ground_x, ground_z, _) = columns
        .iter()
        .find(|(_, _, column)| column.height.div_euclid(16) == ground_level)
        .unwrap();
    let ground = tile.sample([*ground_x, ground_y, *ground_z]).unwrap();
    assert_eq!(
        ground.top_material,
        generator.voxel([*ground_x, ground_y, *ground_z])
    );

    let (island_x, island_z, island_column) = columns
        .iter()
        .find(|(_, _, column)| {
            column
                .island
                .is_some_and(|(_, top)| top.div_euclid(16) == island_level)
        })
        .unwrap();
    let island_y = island_column.island.unwrap().1;
    let island = tile.sample([*island_x, island_y, *island_z]).unwrap();
    assert_eq!(
        island.top_material,
        generator.voxel([*island_x, island_y, *island_z])
    );

    let gap_y = (ground_y + island_bottom) / 2;
    let gap = tile.sample([*ground_x, gap_y, *ground_z]).unwrap();
    assert_eq!(gap.material, 0);
    assert_eq!(gap.solid_height, 0);
    assert_eq!(gap.coverage, 0);
}

#[test]
fn carved_cave_samples_reduce_coverage_instead_of_filling_the_airspace() {
    let mut settings = Settings {
        islands: None,
        ..Settings::default()
    };
    settings.carvers[0].threshold = 0.5;
    let carved = Generator::new(2026, settings.clone()).unwrap();
    settings.carvers.clear();
    let solid = Generator::new(2026, settings).unwrap();
    let [spawn_x, _, spawn_z] = carved.spawn();
    let mut fixture = None;
    'search: for z in (spawn_z - 128..=spawn_z + 128).step_by(8) {
        for x in (spawn_x - 128..=spawn_x + 128).step_by(8) {
            let top = carved.column(x, z).height - 8;
            for y in (-160..top.min(0)).step_by(8) {
                let point = [x, y, z];
                if solid.voxel(point) == 0 || carved.voxel(point) != 0 {
                    continue;
                }
                let low = point.map(|v| v.div_euclid(2) * 2);
                let before = (0..2)
                    .flat_map(|dy| (0..2).flat_map(move |dz| (0..2).map(move |dx| [dx, dy, dz])))
                    .filter(|offset| solid.voxel(std::array::from_fn(|i| low[i] + offset[i])) != 0)
                    .count();
                let after = (0..2)
                    .flat_map(|dy| (0..2).flat_map(move |dz| (0..2).map(move |dx| [dx, dy, dz])))
                    .filter(|offset| carved.voxel(std::array::from_fn(|i| low[i] + offset[i])) != 0)
                    .count();
                if before >= 4 && after < before {
                    fixture = Some((low, after));
                    break 'search;
                }
            }
        }
    }
    let (low, expected_solid) = fixture.expect("deterministic seed contains a sampled cave cell");
    let tile_key = key(2, std::array::from_fn(|axis| low[axis].div_euclid(64)));
    let tile = carved.lod_tile(tile_key, &[]).unwrap();
    let cell = tile.sample(low).unwrap();
    assert_eq!(cell.coverage, ((expected_solid * 255 + 4) / 8) as u8);
    if expected_solid < 4 {
        assert_eq!(cell.material, 0);
        assert_eq!(cell.solid_height, 0);
    }
}

#[test]
fn tile_sampling_is_deterministic_for_all_scales_and_negative_boundaries() {
    let generator = Generator::new(73, Settings::default()).unwrap();
    for size in [2, 4, 8, 16] {
        let tile_key = key(size, [-1, -1, -1]);
        let one = generator.lod_tile(tile_key, &[4]).unwrap();
        let two = generator.lod_tile(tile_key, &[4]).unwrap();
        assert_eq!(one, two);
        let origin = tile_key.origin().unwrap();
        assert_eq!(one.sample(origin), two.sample(origin));
        assert_eq!(
            one.sample([origin[0] + i32::from(size) * 31, origin[1], origin[2]]),
            two.sample([origin[0] + i32::from(size) * 31, origin[1], origin[2]])
        );
    }
}
