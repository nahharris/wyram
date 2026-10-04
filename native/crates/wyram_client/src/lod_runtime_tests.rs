use super::*;

fn config(radius: u32, max_cell_size: u8) -> LodConfig {
    LodConfig {
        protocol: 1,
        enabled: true,
        generation_workers: 4,
        meshing_workers: 4,
        parallelism: 22,
        worker_budget: 8,
        near_radius: radius,
        max_cell_size,
        min_y: -192,
        max_y: 319,
    }
}

#[test]
fn evicted_wanted_coverage_is_requeued_at_the_same_detail() {
    let key = TileKey::new(2, [3, 0, 4]).unwrap();
    let mut runtime = LodRuntime::new(config(11, 2), Instant::now()).unwrap();
    runtime.wanted.insert(key);
    runtime.geometry_current.insert(key);
    runtime.held_coverage.insert(key);
    runtime.coverage_dropped(key);
    assert!(!runtime.geometry_current.contains(&key));
    assert!(!runtime.held_coverage.contains(&key));
    assert_eq!(runtime.remesh.pop_front(), Some(key));
    runtime.wanted.remove(&key);
    runtime.remesh_set.clear();
    runtime.coverage_dropped(key);
    assert!(runtime.remesh.is_empty());
}

#[test]
fn only_exact_transported_tiles_receive_acknowledgements() {
    let key = TileKey::new(2, [3, -1, 4]).unwrap();
    let mut runtime = LodRuntime::new(config(11, 16), Instant::now()).unwrap();
    runtime.epoch = 7;
    runtime.wanted.insert(key);
    let rejected = runtime.receive(WireBatch {
        epoch: 7,
        tiles: vec![WireTile {
            key,
            revision: 12,
            payload: Vec::new(),
        }],
    });
    assert!(rejected.is_empty());

    let filtered = runtime.filter_transport_acks(vec![
        (7, key, 12, true), // The accepted transport result is ACKed once.
        (7, key, 13, true), // Internal remesh of another revision is not transported work.
        (7, TileKey::new(2, [9, 9, 9]).unwrap(), 12, false),
    ]);
    assert_eq!(filtered, vec![(7, key, 12, true)]);
    assert!(
        runtime
            .filter_transport_acks(vec![(7, key, 12, true)])
            .is_empty()
    );
}

#[test]
fn failed_need_admission_can_be_restored_only_for_the_current_plan() {
    let key = TileKey::new(4, [-3, 0, 2]).unwrap();
    let mut runtime = LodRuntime::new(config(11, 16), Instant::now()).unwrap();
    runtime.epoch = 8;
    runtime.wanted.insert(key);
    runtime.restore_needs(8, [key]);
    assert_eq!(runtime.drain_needs(), vec![key]);
    runtime.restore_needs(7, [key]);
    assert!(runtime.drain_needs().is_empty());
}

#[test]
fn requested_sizes_are_exact_at_every_inclusive_band_edge_for_negative_centers() {
    let center = [-31, 0, -17];
    let cfg = config(11, 16);

    for (offset, expected) in [
        (0, 1),
        (11, 1),
        (12, 2),
        (22, 2),
        (23, 4),
        (44, 4),
        (45, 8),
        (88, 8),
        (89, 16),
        (176, 16),
        (177, 0),
    ] {
        assert_eq!(
            requested_size([center[0] - offset, center[2]], center, &cfg),
            expected,
            "unexpected LOD at horizontal offset {offset}"
        );
    }
}

#[test]
fn required_neighbors_are_only_adjacent_two_to_one_bands_and_never_lod1() {
    let centers = [[0, 0, 0], [-37, 4, -29], [41, -3, -53]];

    for center in centers {
        for radius in [1, 11] {
            for size in [2, 4, 8, 16] {
                for distance in [
                    0,
                    radius as i32 * size as i32,
                    radius as i32 * size as i32 * 2,
                    radius as i32 * size as i32 * 4,
                    radius as i32 * size as i32 * 8,
                ] {
                    for (dx, dz) in [
                        (distance, 0),
                        (-distance, 0),
                        (0, distance),
                        (0, -distance),
                        (distance, distance),
                        (-distance, distance),
                    ] {
                        let tile_span_chunks = i32::from(size) * 2;
                        let tx = (center[0] + dx).div_euclid(tile_span_chunks);
                        let tz = (center[2] + dz).div_euclid(tile_span_chunks);
                        let key = TileKey::new(size, [tx, 0, tz]).unwrap();
                        let cfg = config(radius, 16);
                        let neighbors = required_neighbors(key, center, &cfg);
                        let expected = expected_adjacent_neighbors(key, center, &cfg);

                        assert!(
                            neighbors.len() <= 64,
                            "{key:?} had {} seam dependencies",
                            neighbors.len()
                        );
                        assert_eq!(
                            neighbors.iter().copied().collect::<HashSet<_>>(),
                            expected,
                            "wrong seam dependencies for {key:?}"
                        );
                        for neighbor in neighbors {
                            assert!(neighbor.cell_size >= 2);
                            assert_ne!(neighbor.cell_size, size);
                            assert!(
                                neighbor.cell_size == size * 2 || size == neighbor.cell_size * 2,
                                "non-2:1 boundary: {size} next to {}",
                                neighbor.cell_size
                            );
                            assert!(neighbor.origin().is_ok());
                        }
                    }
                }
            }
        }
    }
}

fn expected_adjacent_neighbors(
    key: TileKey,
    center: [i32; 3],
    cfg: &LodConfig,
) -> HashSet<TileKey> {
    let chunk_span = i32::from(key.cell_size) * 2;
    let low_x = key.position[0] * chunk_span;
    let low_z = key.position[2] * chunk_span;
    let high_x = low_x + chunk_span - 1;
    let high_z = low_z + chunk_span - 1;
    let origin = key.origin().unwrap();
    let min_y = (origin[1] - i32::from(key.cell_size)).max(cfg.min_y);
    let max_y = (origin[1] + key.span() + i32::from(key.cell_size) - 1).min(cfg.max_y);
    let mut expected = HashSet::new();

    for x in low_x..=high_x {
        for z in low_z..=high_z {
            if requested_size([x, z], center, cfg) != key.cell_size {
                continue;
            }

            for [nx, nz] in [[x - 1, z], [x + 1, z], [x, z - 1], [x, z + 1]] {
                let size = requested_size([nx, nz], center, cfg);
                if size < 2 || size == key.cell_size {
                    continue;
                }
                let blocks = i32::from(size) * 32;
                for y in min_y.div_euclid(blocks)..=max_y.div_euclid(blocks) {
                    if let Ok(neighbor) = TileKey::new(
                        size,
                        [
                            nx.div_euclid(i32::from(size) * 2),
                            y,
                            nz.div_euclid(i32::from(size) * 2),
                        ],
                    ) {
                        expected.insert(neighbor);
                    }
                }
            }
        }
    }
    expected
}

#[test]
fn near_circle_tiles_have_no_lod1_dependencies() {
    let center: [i32; 3] = [-19, 0, -33];
    let size = 2;
    let span = i32::from(size) * 2;
    let key = TileKey::new(
        size,
        [center[0].div_euclid(span), 0, center[2].div_euclid(span)],
    )
    .unwrap();
    let neighbors = required_neighbors(key, center, &config(11, 16));

    assert!(neighbors.iter().all(|neighbor| neighbor.cell_size >= 2));
    assert_eq!(
        requested_size([center[0], center[2]], center, &config(11, 16)),
        1
    );
}

#[test]
fn default_radius_eleven_neighborhood_stays_within_fixed_neighbor_bound() {
    let cfg = config(11, 16);
    let center = [-101, 0, -203];
    let mut maximum = 0;

    for size in [2, 4, 8, 16] {
        let span = i32::from(size) * 2;
        let ring = 11 * i32::from(size);
        for (dx, dz) in [
            (ring, 0),
            (-ring, 0),
            (0, ring),
            (0, -ring),
            (ring, ring),
            (-ring, ring),
            (ring * 2, 0),
            (0, ring * 2),
            (ring * 4, 0),
            (0, ring * 8),
        ] {
            let key = TileKey::new(
                size,
                [
                    (center[0] + dx).div_euclid(span),
                    0,
                    (center[2] + dz).div_euclid(span),
                ],
            )
            .unwrap();
            maximum = maximum.max(required_neighbors(key, center, &cfg).len());
        }
    }

    assert!(maximum <= 64, "observed {maximum} required seam tiles");
}

#[test]
fn coarse_coverage_waits_for_finer_seam_geometry_but_fine_coverage_does_not_wait_for_coarse() {
    let fine = TileKey::new(2, [0, 0, 0]).unwrap();
    let coarse = TileKey::new(4, [0, 0, 0]).unwrap();
    let dependencies = vec![(fine, Some(3)), (coarse, Some(5))];
    let sources = HashMap::from([(fine, 3), (coarse, 5)]);
    let mut current = HashSet::new();

    assert!(!coverage_dependencies_ready(
        4,
        &dependencies,
        &current,
        &sources
    ));
    assert!(coverage_dependencies_ready(
        2,
        &dependencies,
        &current,
        &sources
    ));

    current.insert(fine);
    assert!(coverage_dependencies_ready(
        4,
        &dependencies,
        &current,
        &sources
    ));

    let missing_fine_source = vec![(fine, None), (coarse, Some(5))];
    assert!(!coverage_dependencies_ready(
        4,
        &missing_fine_source,
        &current,
        &sources
    ));
}

#[test]
fn missing_or_changed_source_revision_cannot_mark_geometry_context_current() {
    let dep = TileKey::new(2, [-1, 0, 3]).unwrap();
    let dependencies = vec![(dep, Some(7))];
    let same_revision = HashMap::from([(dep, 7)]);
    let changed_revision = HashMap::from([(dep, 8)]);
    let missing_revision = HashMap::new();

    assert!(geometry_context_current(
        [4, 0, -9],
        [4, 12, -9],
        &dependencies,
        &same_revision
    ));
    assert!(!geometry_context_current(
        [4, 0, -9],
        [4, 12, -9],
        &dependencies,
        &changed_revision
    ));
    assert!(!geometry_context_current(
        [4, 0, -9],
        [4, 12, -9],
        &dependencies,
        &missing_revision
    ));
    assert!(!geometry_context_current(
        [4, 0, -9],
        [5, 12, -9],
        &dependencies,
        &same_revision
    ));
}
