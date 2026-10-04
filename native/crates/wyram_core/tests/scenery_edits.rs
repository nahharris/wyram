use wyram_core::scenery::{LodTile, TileKey};
use wyram_core::worldgen::{Generator, Settings};
use wyram_core::{BYTE_COUNT, read_block, write_block};

fn key(position: [i32; 3], level: u8) -> TileKey {
    TileKey::new(position, level).expect("key")
}

#[test]
fn sea_surface_edits_use_the_actual_sample_chunk_after_crossing_a_chunk_boundary() {
    let mut settings = Settings {
        relief: 0,
        islands: None,
        carvers: vec![],
        terrain: wyram_core::worldgen::Terrain {
            roughness: 0.0,
            ..Default::default()
        },
        ..Default::default()
    };
    settings.biomes[0].elevation_offset = -32;
    settings.biomes[0].water = 17;
    settings.biomes[0].features.clear();
    let generator = Generator::new(2026, settings).unwrap();
    let tile_key = key([0, 0, 0], 6);
    let chunks = generator.scenic_sample_chunks(tile_key).unwrap();
    assert!(
        chunks.contains(&[1, 0, 1]),
        "the sea sample at [16,0,16] belongs to the lower chunk"
    );
    assert!(
        !chunks.contains(&[1, 1, 1]),
        "the displaced center at y=16 is not sampled"
    );
    let chunk = generator.chunk([1, 0, 1]).unwrap();
    let cleared = write_block(&chunk, 0, 0, 0, 0).unwrap();
    let overrides = generator
        .extract_scenic_samples(tile_key, &[([1, 0, 1], &cleared)])
        .unwrap();
    assert_eq!(overrides, [0, 0, 0, 0]);
    let edited = generator
        .scenic_tile_with_samples(tile_key, &overrides)
        .unwrap();
    let cell = edited.cell([0, 0, 0]).unwrap();
    assert_eq!(cell.material(), 17);
    assert_eq!(cell.child_mask(), 0x32);
    assert_eq!(cell.occupied(), 3 * 32u32.pow(3));
}

#[test]
fn edited_level_one_matches_reduction_of_exact_edited_chunks() {
    let generator = Generator::new(41, Settings::default()).expect("generator");
    let tile_key = key([-1, -1, -1], 1);
    let chunk_keys = generator
        .scenic_sample_chunks(tile_key)
        .expect("sample chunks");
    assert_eq!(chunk_keys.len(), 8);
    let mut chunks: Vec<_> = chunk_keys
        .iter()
        .map(|&k| (k, generator.chunk(k).expect("chunk")))
        .collect();
    chunks[0].1 = write_block(&chunks[0].1, 0, 0, 0, 65535).expect("addition");
    chunks[0].1 = write_block(&chunks[0].1, 15, 15, 15, 0).expect("removal");
    let borrowed: Vec<_> = chunks
        .iter()
        .map(|(k, bytes)| (*k, bytes.as_slice()))
        .collect();
    let overrides = generator
        .extract_scenic_samples(tile_key, &borrowed[..1])
        .expect("extract");
    assert_eq!(overrides.len(), 4096 * 4);
    let edited = generator
        .scenic_tile_with_samples(tile_key, &overrides)
        .expect("scenery");
    let leaves: Vec<_> = chunks
        .iter()
        .map(|(k, bytes)| LodTile::from_chunk(key(*k, 0), bytes).expect("leaf"))
        .collect();
    let expected = LodTile::reduce(std::array::from_fn(|i| &leaves[i])).expect("parent");
    assert!(
        edited == expected,
        "edited coarse tile must match exact reduction"
    );
    assert!(
        edited != generator.scenic_tile(tile_key).expect("original"),
        "fixture must change the summary"
    );
}

#[test]
fn leaf_overrides_preserve_exact_chunk_addressing() {
    let generator = Generator::new(0, Settings::default()).expect("generator");
    let tile_key = key([-1, 0, 2], 0);
    let mut chunk = generator.chunk(tile_key.position()).expect("chunk");
    chunk = write_block(&chunk, 15, 3, 2, 99).expect("edit");
    let overrides = generator
        .extract_scenic_samples(tile_key, &[(tile_key.position(), &chunk)])
        .expect("extract");
    assert_eq!(overrides.len(), 4096 * 4);
    assert_eq!(
        generator
            .scenic_tile_with_samples(tile_key, &overrides)
            .expect("scenery"),
        LodTile::from_chunk(tile_key, &chunk).expect("import")
    );
}

#[test]
fn coarse_samples_have_unique_chunk_keys_and_extract_the_exact_world_space_sample() {
    let generator = Generator::new(7, Settings::default()).expect("generator");
    for level in [2, 4, 6] {
        let tile_key = key([-1, 0, -1], level);
        let chunks = generator.scenic_sample_chunks(tile_key).expect("keys");
        assert!(chunks.len() <= 32768);
        assert!(chunks.windows(2).all(|pair| pair[0] < pair[1]));
        let data: Vec<_> = (0..4096)
            .flat_map(|i| (i as u16 + 1).to_le_bytes())
            .collect();
        let chunk_key = chunks[chunks.len() / 2];
        let encoded = generator
            .extract_scenic_samples(tile_key, &[(chunk_key, &data)])
            .expect("samples");
        assert!(!encoded.is_empty());
        for pair in encoded.as_chunks::<4>().0 {
            let index = u16::from_le_bytes([pair[0], pair[1]]) as usize;
            let material = u16::from_le_bytes([pair[2], pair[3]]);
            let local = [index % 32, index / 1024, index / 32 % 32];
            let step = i64::from(tile_key.scale() / 2);
            let origin = tile_key.origin();
            let mut p: [i64; 3] =
                std::array::from_fn(|axis| origin[axis] + step / 2 + local[axis] as i64 * step);
            if origin[1] + local[1] as i64 * step <= 0 && p[1] > 0 {
                p[1] = 0;
            }
            assert_eq!(p.map(|v| v.div_euclid(16) as i32), chunk_key);
            let p = p.map(|v| v.rem_euclid(16) as usize);
            assert_eq!(
                material,
                read_block(&data, p[0], p[1], p[2]).expect("sample")
            );
        }
        let tile = generator
            .scenic_tile_with_samples(tile_key, &encoded)
            .expect("coarse edit");
        assert_eq!(LodTile::decode(&tile.encode()).expect("decode"), tile);
    }
}

#[test]
fn sea_stratum_addressing_handles_negative_levels_and_keeps_lower_midpoints() {
    let data: Vec<_> = (1..=4096u16).flat_map(u16::to_le_bytes).collect();
    for sea_level in [-17, -16, -1, 0, 15, 16] {
        let settings = Settings {
            sea_level,
            ..Default::default()
        };
        let generator = Generator::new(7, settings).unwrap();
        for level in [2, 4, 6] {
            let width = 16 * (1 << level);
            let tile_key = key([-1, sea_level.div_euclid(width), -1], level);
            let origin = tile_key.origin().map(|v| v as i32);
            let step = 1 << (level - 1);
            let row = (sea_level - origin[1]).div_euclid(step);
            let center = origin[1] + row * step + step / 2;
            let sample = [
                origin[0] + step / 2,
                center.min(sea_level),
                origin[2] + step / 2,
            ];
            let chunk = sample.map(|v| v.div_euclid(16));
            assert!(
                generator
                    .scenic_sample_chunks(tile_key)
                    .unwrap()
                    .contains(&chunk)
            );
            let encoded = generator
                .extract_scenic_samples(tile_key, &[(chunk, &data)])
                .unwrap();
            let index = (row * 1024) as u16;
            let record = encoded
                .as_chunks::<4>()
                .0
                .iter()
                .find(|record| u16::from_le_bytes([record[0], record[1]]) == index)
                .unwrap();
            let p = sample.map(|v| v.rem_euclid(16) as usize);
            assert_eq!(
                u16::from_le_bytes([record[2], record[3]]),
                read_block(&data, p[0], p[1], p[2]).unwrap(),
                "sea={sea_level} level={level}"
            );
        }
    }
}

#[test]
fn malformed_oversized_duplicate_and_unrelated_overrides_are_rejected() {
    let generator = Generator::new(0, Settings::default()).expect("generator");
    let tile_key = key([0; 3], 1);
    let air = vec![0; BYTE_COUNT];
    assert!(
        generator
            .extract_scenic_samples(tile_key, &[([0; 3], &[0])])
            .is_err()
    );
    assert!(
        generator
            .extract_scenic_samples(tile_key, &[([99; 3], &air)])
            .is_err()
    );
    assert!(
        generator
            .extract_scenic_samples(tile_key, &[([0; 3], &air), ([0; 3], &air)])
            .is_err()
    );
    assert!(
        generator
            .extract_scenic_samples(tile_key, &vec![([0; 3], air.as_slice()); 257])
            .is_err()
    );
    for bad in [
        vec![0],
        vec![0; 131076],
        vec![0, 128, 7, 0],
        vec![0, 0, 7, 0, 0, 0, 8, 0],
    ] {
        assert!(generator.scenic_tile_with_samples(tile_key, &bad).is_err());
    }
    assert!(
        generator
            .scenic_tile_with_samples(key([0; 3], 0), &[0, 16, 7, 0])
            .is_err()
    );
    assert_eq!(
        generator
            .extract_scenic_samples(tile_key, &[])
            .expect("empty"),
        Vec::<u8>::new()
    );
    assert_eq!(
        generator
            .scenic_tile_with_samples(tile_key, &[])
            .expect("unedited"),
        generator.scenic_tile(tile_key).expect("normal")
    );
}
