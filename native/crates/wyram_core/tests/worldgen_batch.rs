use wyram_core::worldgen::{Feature, Generator, Settings};

fn decorated() -> Generator {
    let mut settings = Settings::default();
    settings.islands.as_mut().unwrap().threshold = 0.5;
    for domain in [0, 1] {
        settings.biomes[0].features.push(Feature {
            kind: 1,
            block: 5,
            accent: 6,
            spacing: 16,
            density: 1.0,
            radius: 8,
            height: 32,
            salt: 109 + domain as u64,
            domain,
            support_depth: 24,
        });
    }
    Generator::new(2026, settings).unwrap()
}

#[test]
fn batching_preserves_every_byte_across_columns_layers_features_and_order() {
    let generator = decorated();
    let [sx, _, sz] = generator.spawn();
    let cx = sx.div_euclid(16);
    let cz = sz.div_euclid(16);
    let mut keys: Vec<_> = [-1, 0, 1]
        .into_iter()
        .flat_map(|dx| (-13..=20).map(move |y| [cx + dx, y, cz - 1]))
        .collect();
    keys.extend([[-1, -12, -1], [-1, 19, -1], [cx, 1, cz - 1]]);
    let island = (-4096..4096)
        .step_by(128)
        .flat_map(|z| (-4096..4096).step_by(128).map(move |x| (x, z)))
        .find(|(x, z)| generator.column(*x, *z).island.is_some())
        .unwrap();
    keys.extend((-12..20).map(|y| [island.0.div_euclid(16), y, island.1.div_euclid(16)]));
    keys.reverse();
    let expected: Vec<_> = keys
        .iter()
        .map(|key| generator.chunk(*key).unwrap())
        .collect();
    assert_eq!(generator.chunks(&keys).unwrap(), expected);
    assert!(generator.chunks(&[]).unwrap().is_empty());
    assert!(generator.chunks(&[[0, 0, 0], [i32::MAX, 0, 0]]).is_err());
}

#[test]
#[ignore = "manual paired worldgen batch CPU benchmark"]
fn benchmark_vertical_reuse() {
    let generator = decorated();
    let [x, _, z] = generator.spawn();
    let keys: Vec<_> = (-12..20)
        .map(|y| [x.div_euclid(16), y, z.div_euclid(16)])
        .collect();
    for round in 0..8 {
        for batch in if round % 2 == 0 {
            [false, true]
        } else {
            [true, false]
        } {
            let start = std::time::Instant::now();
            let bytes = if batch {
                generator.chunks(&keys).unwrap()
            } else {
                keys.iter()
                    .map(|key| generator.chunk(*key).unwrap())
                    .collect()
            };
            println!(
                "worldgen round={round} batch={batch} ms={:.4}",
                start.elapsed().as_secs_f64() * 1000.0
            );
            std::hint::black_box(bytes);
        }
    }
}
