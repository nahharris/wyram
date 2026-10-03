use wyram_core::{
    BYTE_COUNT, read_block,
    worldgen::{Generator, Settings},
};

#[test]
fn range_is_512_blocks_with_sea_level_zero_and_negative_caves() {
    let generator = Generator::new(2026, Settings::default()).unwrap();
    assert_eq!(generator.bounds(), (-192, 319));
    for cy in [-13, 20] {
        assert_eq!(generator.chunk([0, cy, 0]).unwrap(), vec![0; BYTE_COUNT]);
    }
    assert_eq!(
        read_block(&generator.chunk([0, -12, 0]).unwrap(), 0, 0, 0),
        Ok(3)
    );
}

#[test]
fn generation_is_order_independent_and_matches_world_space_sampling_at_seams() {
    let generator = Generator::new(41, Settings::default()).unwrap();
    for key in [[-1, -1, -1], [0, -1, -1], [-1, 0, 0], [0, 12, 0]] {
        let chunk = generator.chunk(key).unwrap();
        for z in [0, 15] {
            for x in [0, 15] {
                for y in [0, 15] {
                    assert_eq!(
                        read_block(&chunk, x, y, z).unwrap(),
                        generator.voxel([
                            key[0] * 16 + x as i32,
                            key[1] * 16 + y as i32,
                            key[2] * 16 + z as i32
                        ])
                    );
                }
            }
        }
        assert_eq!(chunk, generator.chunk(key).unwrap());
    }
    assert_ne!(
        generator.column(0, 0).height,
        Generator::new(99, Settings::default())
            .unwrap()
            .column(0, 0)
            .height
    );
}

#[test]
fn continuous_fields_produce_oceans_mountains_and_normalized_biome_weights() {
    let g = Generator::new(2026, Settings::default()).unwrap();
    let mut low = 1000;
    let mut high = -1000;
    let mut islands = 0;
    for z in (-4096..4096).step_by(128) {
        for x in (-4096..4096).step_by(128) {
            let c = g.column(x, z);
            low = low.min(c.height);
            high = high.max(c.height);
            islands += usize::from(c.island.is_some());
            assert!((c.weights.iter().sum::<f64>() - 1.0).abs() < 1e-10);
            assert!((g.column(x + 1, z).height - c.height).abs() <= 4);
            if c.height < -4 {
                assert_eq!(g.voxel([x, 0, z]), 4);
            }
        }
    }
    assert!(low < -30 && high > 80, "height range {low}..{high}");
    assert!(islands > 0);
}

#[test]
fn carvers_and_features_are_configurable_and_cross_chunk_boundaries() {
    let mut settings = Settings::default();
    settings.biomes[0]
        .features
        .push(wyram_core::worldgen::Feature {
            kind: 0,
            block: 5,
            accent: 6,
            spacing: 16,
            density: 1.0,
            radius: 8,
            height: 32,
            salt: 109,
            domain: 0,
        });
    let decorated = Generator::new(2, settings.clone()).unwrap();
    settings.biomes[0].features.clear();
    settings.carvers.clear();
    let plain = Generator::new(2, settings).unwrap();
    let mut caves = 0;
    let mut features = 0;
    let [sx, _, sz] = decorated.spawn();
    for z in (sz - 32..sz + 32).step_by(2) {
        for x in (sx - 32..sx + 32).step_by(2) {
            let h = decorated.column(x, z).height;
            for y in -120..(h + 40) {
                let a = decorated.voxel([x, y, z]);
                let b = plain.voxel([x, y, z]);
                caves += usize::from(a == 0 && b == 3);
                features += usize::from(a == 5 || a == 6);
            }
        }
    }
    assert!(caves > 0);
    assert!(features > 0);
    let cx = sx.div_euclid(16);
    let cz = sz.div_euclid(16);
    let cy = (decorated.column(sx, sz).height + 16).div_euclid(16);
    let mut seam_features = 0;
    for key in [[cx - 1, cy, cz], [cx, cy, cz], [cx, cy + 1, cz]] {
        let c = decorated.chunk(key).unwrap();
        for z in 0..16 {
            for x in 0..16 {
                let id = read_block(&c, x, 15, z).unwrap();
                seam_features += usize::from(id == 5 || id == 6);
                assert_eq!(
                    id,
                    decorated.voxel([
                        key[0] * 16 + x as i32,
                        key[1] * 16 + 15,
                        key[2] * 16 + z as i32
                    ])
                );
            }
        }
    }
    assert!(seam_features > 0);
}

#[test]
fn invalid_settings_and_unbounded_coordinates_are_rejected() {
    let settings = Settings {
        height: 513,
        ..Settings::default()
    };
    assert!(Generator::new(0, settings).is_err());
    let g = Generator::new(0, Settings::default()).unwrap();
    assert!(g.chunk([i32::MAX, 0, 0]).is_err());
}

#[test]
fn default_spawn_finds_dry_land_above_sea_level() {
    let g = Generator::new(2026, Settings::default()).unwrap();
    let [x, y, z] = g.spawn();
    assert!(
        g.column(x, z).height > 4,
        "spawn {x},{y},{z} is ocean or shore"
    );
}

#[test]
fn extreme_island_coordinates_are_rejected_without_arithmetic_overflow() {
    let mut s = Settings::default();
    s.islands.as_mut().unwrap().base_y = i32::MIN;
    assert!(Generator::new(0, s).is_err());
}

#[test]
fn transition_weights_and_elevation_offsets_blend_continuously() {
    let mut s = Settings::default();
    let mut b = s.biomes[0].clone();
    let center = Generator::new(7, s.clone()).unwrap().column(0, 48).climate;
    s.biomes[0].climate = center;
    s.biomes[0].climate[0] = (center[0] - 0.1).max(0.0);
    b.climate = center;
    b.climate[0] = (center[0] + 0.1).min(1.0);
    b.surface = 7;
    b.elevation_offset = 24;
    s.biomes.push(b);
    s.blend = 0.15;
    let g = Generator::new(7, s).unwrap();
    let mut mixed = 0;
    for x in -512..512 {
        let c = g.column(x, 48);
        assert_eq!(c.weights.len(), 2);
        assert!((c.weights.iter().sum::<f64>() - 1.0).abs() < 1e-10);
        assert!((c.height - g.column(x + 1, 48).height).abs() <= 3);
        mixed += usize::from(c.weights.iter().all(|w| *w > 0.1));
    }
    assert!(mixed > 0);
}
