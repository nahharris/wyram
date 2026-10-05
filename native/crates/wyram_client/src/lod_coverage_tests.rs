use super::*;

fn coverage(near_radius_chunks: u32, max_cell_size: u8) -> LodCoverage {
    LodCoverage::new(CoverageConfig {
        near_radius_chunks,
        max_cell_size,
        min_y_chunk: -12,
        max_y_chunk: 19,
        columns_per_side: 384,
        frontier_fade_fraction: 0.2,
        transition_seconds: 0.2,
        promotion_buffer_chunks: 2,
        demotion_buffer_chunks: 2,
    })
    .unwrap()
}

fn ready_near(c: &mut LodCoverage, x: i32, z: i32, now: f32) {
    for y in -12..=19 {
        c.mark_near_ready([x, y, z], now);
    }
}

#[test]
fn ready_fine_prefetch_is_retained_in_the_distant_band() {
    let mut c = coverage(4, 2);
    c.set_view([0, 0], 0.0, 1);
    ready_near(&mut c, 5, 0, 0.0);
    assert_eq!(c.represented_size([5, 0]), 1);
    let index = c.column_index([5, 0]).unwrap();
    assert_eq!(c.frame(0.0).columns[index][3].to_bits(), u32::MAX);
    c.set_view([1, 0], 0.1, 1);
    assert_eq!(c.represented_size([5, 0]), 1);
    c.set_view([0, 0], 0.2, 1);
    assert_eq!(c.represented_size([5, 0]), 1);
}

#[test]
fn walking_into_prefetched_columns_keeps_the_frontier_outside_near_terrain() {
    let mut c = coverage(4, 2);
    c.set_view([0, 0], 0.0, 1);
    for x in -6i32..=6 {
        for z in -6i32..=6 {
            if x * x + z * z <= 36 {
                ready_near(&mut c, x, z, 0.0);
            }
        }
    }
    for step in 0..200 {
        c.frame(step as f32 * 0.1);
    }
    for center in [[1, 0], [0, 0], [1, 0], [0, 0]] {
        c.set_view(center, 20.0, 1);
        assert!(
            c.frame(20.0).frontier_radius_blocks > 4.0 * 16.0,
            "walking within prefetch must not hide the near circle"
        );
    }
}

fn ready_tile_stack(c: &mut LodCoverage, size: u8, x: i32, z: i32, now: f32) {
    let span_chunks = i32::from(size) * 2;
    let tx = x.div_euclid(span_chunks);
    let tz = z.div_euclid(span_chunks);
    let span_blocks = i32::from(size) * 32;
    let min_tile_y = (-192i32).div_euclid(span_blocks);
    let max_tile_y = 319i32.div_euclid(span_blocks);
    for ty in min_tile_y..=max_tile_y {
        c.mark_tile_ready(TileKey::new(size, [tx, ty, tz]).unwrap(), now);
    }
}

#[test]
fn movement_keeps_resident_detail_until_the_finer_replacement_is_ready() {
    let mut c = coverage(4, 16);
    c.set_view([0, 0], 0.0, 1);
    ready_tile_stack(&mut c, 4, 9, 0, 0.0);
    ready_tile_stack(&mut c, 4, 16, 0, 0.0);
    assert_eq!(c.desired_size([9, 0]), 4);
    assert_eq!(c.represented_size([9, 0]), 4);
    assert_eq!(c.represented_size([16, 0]), 4);

    c.set_view([4, 0], 0.1, 1);
    assert_eq!(c.desired_size([9, 0]), 2);
    assert_eq!(c.represented_size([9, 0]), 4);
    assert_eq!(c.represented_size([16, 0]), 4);

    let index = c.column_index([9, 0]).unwrap();
    let held = c.frame(0.1).columns[index];
    assert_eq!(held[0], 4.0);

    ready_tile_stack(&mut c, 2, 9, 0, 0.2);
    let index = c.column_index([9, 0]).unwrap();
    let swapped = c.frame(0.2).columns[index];
    assert_eq!(swapped[0], 2.0);
    assert_eq!(swapped[1], 4.0);
    assert_eq!(swapped[2], 0.2);
    assert_eq!(c.represented_size([16, 0]), 4);
    let (old_weight, new_weight) = complementary_weights(4, 2, 0.3, swapped[2]);
    assert!((old_weight - 0.5).abs() < 1e-6);
    assert!((new_weight - 0.5).abs() < 1e-6);
    assert!((old_weight + new_weight - 1.0).abs() < 1e-6);
}

#[test]
fn entering_the_near_circle_keeps_ready_far_coverage_until_full_height_is_ready() {
    let mut c = coverage(4, 16);
    c.set_view([0, 0], 0.0, 1);
    ready_tile_stack(&mut c, 2, 5, 0, 0.0);
    assert_eq!(c.represented_size([5, 0]), 2);

    c.set_view([5, 0], 0.1, 1);
    assert_eq!(c.desired_size([5, 0]), 1);
    c.mark_near_ready([5, -12, 0], 0.2);
    let index = c.column_index([5, 0]).unwrap();
    assert_eq!(c.represented_size([5, 0]), 2);
    assert_eq!(c.frame(0.2).columns[index][3].to_bits(), 1);

    ready_near(&mut c, 5, 0, 0.3);
    let index = c.column_index([5, 0]).unwrap();
    let swapped = c.frame(0.3).columns[index];
    assert_eq!(swapped[0], 1.0);
    assert_eq!(swapped[1], 2.0);
    assert_eq!(swapped[2], 0.3);
}

#[test]
fn a_ready_finer_replacement_waits_for_the_active_transition_to_finish() {
    let mut c = coverage(4, 16);
    c.set_view([0, 0], 0.0, 1);
    ready_tile_stack(&mut c, 4, 9, 0, 0.0);
    c.set_view([4, 0], 0.1, 1);
    ready_tile_stack(&mut c, 2, 9, 0, 0.1);
    assert_eq!(c.represented_size([9, 0]), 2);

    c.set_view([9, 0], 0.15, 1);
    ready_near(&mut c, 9, 0, 0.15);
    let index = c.column_index([9, 0]).unwrap();
    let during = c.frame(0.15).columns[index];
    assert_eq!(during[0], 2.0);
    assert_eq!(during[1], 4.0);
    assert_eq!(during[2], 0.1);
    assert_eq!(during[3].to_bits(), u32::MAX);

    assert_eq!(c.frame(0.299).columns[index][0], 2.0);
    let completed = c.frame(0.3).columns[index];
    assert_eq!(completed[0], 1.0);
    assert_eq!(completed[1], 2.0);
    assert_eq!(completed[2], 0.3);
}

#[test]
fn reversing_a_deferred_promotion_keeps_the_active_pair_and_fades() {
    let mut c = coverage(4, 16);
    c.set_view([0, 0], 0.0, 1);
    ready_tile_stack(&mut c, 4, 9, 0, 0.0);
    c.set_view([4, 0], 0.1, 1);
    ready_tile_stack(&mut c, 2, 9, 0, 0.1);
    c.set_view([9, 0], 0.15, 1);
    ready_near(&mut c, 9, 0, 0.15);

    c.forget_near([9, -12, 0], 0.16);
    c.set_view([2, 0], 0.17, 1);
    let index = c.column_index([9, 0]).unwrap();
    let reversed = c.frame(0.4).columns[index];
    assert_eq!(reversed[0], 2.0);
    assert_eq!(reversed[1], 4.0);
    assert_eq!(reversed[2], 0.1);
    assert_eq!(reversed[3].to_bits(), u32::MAX - 1);
}

#[test]
fn near_mask_tracks_partial_vertical_readiness_without_claiming_full_coverage() {
    let mut c = coverage(4, 16);
    c.set_view([0, 0], 0.0, 1);
    c.mark_near_ready([0, -12, 0], 0.1);
    let index = c.column_index([0, 0]).unwrap();
    assert_eq!(c.frame(0.1).columns[index][3].to_bits(), 1);
    assert_eq!(c.represented_size([0, 0]), 0);

    c.mark_near_ready([0, -11, 0], 0.2);
    assert_eq!(c.frame(0.2).columns[index][3].to_bits(), 3);
    c.forget_near([0, -12, 0], 0.3);
    assert_eq!(c.frame(0.3).columns[index][3].to_bits(), 2);
    assert_eq!(c.represented_size([0, 0]), 0);
}

#[test]
fn near_mask_configuration_fits_in_one_word() {
    let invalid = LodCoverage::new(CoverageConfig {
        near_radius_chunks: 4,
        max_cell_size: 16,
        min_y_chunk: -12,
        max_y_chunk: 20,
        columns_per_side: 32,
        frontier_fade_fraction: 0.2,
        transition_seconds: 0.2,
        promotion_buffer_chunks: 2,
        demotion_buffer_chunks: 2,
    });
    assert!(invalid.is_err());
}

#[test]
fn near_columns_require_every_vertical_chunk_including_empty_chunks() {
    let mut c = coverage(4, 16);
    c.set_view([0, 0], 0.0, 1);
    ready_near(&mut c, 0, 0, 0.0);
    assert_eq!(c.represented_size([0, 0]), 1);
    c.forget_near([0, -12, 0], 0.1);
    assert_eq!(c.represented_size([0, 0]), 0);
    c.mark_near_ready([0, -12, 0], 0.2);
    assert_eq!(c.represented_size([0, 0]), 1);
}

#[test]
fn exact_bands_protect_near_and_choose_discrete_sizes() {
    let mut c = coverage(8, 16);
    c.set_view([0, 0], 0.0, 1);
    assert_eq!(c.desired_size([0, 0]), 1);
    assert_eq!(c.desired_size([8, 0]), 1);
    assert_eq!(c.desired_size([9, 0]), 2);
    assert_eq!(c.desired_size([16, 0]), 2);
    assert_eq!(c.desired_size([17, 0]), 4);
    assert_eq!(c.desired_size([33, 0]), 8);
    assert_eq!(c.desired_size([65, 0]), 16);
    assert_eq!(c.desired_size([-9, 0]), 2);
}

#[test]
fn bands_stop_at_the_maximum_requested_radius() {
    let mut c = coverage(11, 16);
    c.set_view([0, 0], 0.0, 1);
    assert_eq!(c.desired_size([12, 0]), 2);
    assert_eq!(c.desired_size([23, 0]), 4);
    assert_eq!(c.desired_size([45, 0]), 8);
    assert_eq!(c.desired_size([89, 0]), 16);
    assert_eq!(c.desired_size([177, 0]), 0);
}

#[test]
fn missing_far_tile_holds_frontier_and_empty_resident_tile_counts_ready() {
    let mut c = coverage(2, 2);
    c.set_view([0, 0], 0.0, 1);
    let initial = c.frame(0.0).frontier_radius_blocks;
    ready_tile_stack(&mut c, 2, 4, 0, 0.1);
    let partial = c.frame(0.1).frontier_radius_blocks;
    assert!(partial >= initial);
    assert_eq!(c.represented_size([4, 0]), 2);
    c.forget_tile(TileKey::new(2, [1, 0, 0]).unwrap(), 0.2);
    assert_eq!(c.represented_size([4, 0]), 0);
}

#[test]
fn frontier_stops_before_the_entire_nearest_missing_column() {
    let mut c = coverage(2, 2);
    c.set_view([0, 0], 0.0, 1);
    ready_near(&mut c, 0, 0, 0.1);
    let radius = c.frame(0.1).frontier_radius_blocks;
    assert!(radius > 0.0);
    assert!(radius < 16.0);
}

#[test]
fn movement_and_reversal_retain_hysteresis_without_reclassifying_every_frame() {
    let mut c = coverage(8, 16);
    c.set_view([0, 0], 0.0, 1);
    assert_eq!(c.desired_size([17, 0]), 4);
    c.set_view([20, 0], 0.1, 1);
    let promoted = c.desired_size([17, 0]);
    assert!(promoted <= 4);
    c.set_view([0, 0], 0.2, 1);
    assert!(c.desired_size([17, 0]) >= promoted);
    let frame = c.frame(0.21);
    assert_eq!(frame.side, 384);
    assert_eq!(frame.columns.len(), 384 * 384);
}

#[test]
fn transitions_are_complementary_and_teleport_resets_them() {
    assert_eq!(transition_weight(0.0, 0.0), 0.0);
    assert_eq!(transition_weight(0.1, 0.0), 0.5);
    assert_eq!(transition_weight(0.2, 0.0), 1.0);
    for old in [1, 2, 4, 8, 16] {
        for new in [1, 2, 4, 8, 16] {
            for p in [0.0, 0.1, 0.2] {
                let (old_weight, new_weight) = complementary_weights(old, new, p, 0.0);
                assert!((old_weight + new_weight - 1.0).abs() < 1e-6);
            }
        }
    }
    let mut c = coverage(4, 16);
    c.set_view([0, 0], 0.0, 1);
    ready_near(&mut c, 0, 0, 0.0);
    c.forget_near([0, -12, 0], 0.1);
    c.mark_near_ready([0, -12, 0], 0.1);
    let index = c.column_index([0, 0]).unwrap();
    assert_ne!(c.frame(0.1).columns[index][1], 0.0);
    c.set_view([100, -100], 0.2, 2);
    let index = c.column_index([0, 0]).unwrap();
    let values = c.frame(0.2).columns[index];
    assert_eq!(values[1], values[0]);
    assert_eq!(values[2], 0.2);
}

#[test]
fn requested_tiles_are_aligned_and_never_coarser_than_the_assigned_band() {
    let mut c = coverage(4, 16);
    c.set_view([-1, -1], 0.0, 1);
    for key in c.requested_tiles() {
        assert!(matches!(key.cell_size, 2 | 4 | 8 | 16));
        assert_eq!(key.position[0].rem_euclid(1), 0);
    }
    assert_eq!(c.desired_size([-1, -1]), 1);
}

#[test]
fn moving_the_grid_remaps_unchanged_world_column_state() {
    let mut c = coverage(4, 16);
    c.set_view([0, 0], 0.0, 1);
    ready_near(&mut c, 0, 0, 0.0);
    let old_index = c.column_index([0, 0]).unwrap();
    assert_eq!(c.frame(0.0).columns[old_index][0], 1.0);
    c.set_view([1, 0], 0.1, 1);
    let new_index = c.column_index([0, 0]).unwrap();
    assert_ne!(old_index, new_index);
    assert_eq!(c.frame(0.1).columns[new_index][0], 1.0);
    assert_eq!(c.represented_size([0, 0]), 1);
}

#[test]
fn teleport_discards_old_residency_and_transition_state() {
    let mut c = coverage(4, 16);
    c.set_view([0, 0], 0.0, 1);
    ready_near(&mut c, 0, 0, 0.0);
    assert_eq!(c.represented_size([0, 0]), 1);
    c.set_view([0, 0], 0.2, 2);
    assert_eq!(c.represented_size([0, 0]), 0);
    assert_eq!(c.frame(0.2).epoch, 2);
    let index = c.column_index([0, 0]).unwrap();
    let values = c.frame(0.2).columns[index];
    assert_eq!(values, [0.0, 0.0, 0.2, 0.0]);
}
