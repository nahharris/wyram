use super::*;
use glam::Vec3;

#[test]
fn interleaved_near_and_far_quads_sort_by_actual_centers() {
    let near = [Vec3::new(10.0, 0.0, 0.0), Vec3::new(1.0, 0.0, 0.0)];
    let far0 = [Vec3::new(8.0, 0.0, 0.0), Vec3::new(3.0, 0.0, 0.0)];
    let far1 = [Vec3::new(6.0, 0.0, 0.0), Vec3::new(2.0, 0.0, 0.0)];

    let plan = build_order_plan(Vec3::ZERO, &near, &[&far0, &far1]);

    assert_eq!(
        plan.runs,
        [
            DrawRun::new(DrawSource::Near, 0..6),
            DrawRun::new(DrawSource::Far(0), 6..12),
            DrawRun::new(DrawSource::Far(1), 12..18),
            DrawRun::new(DrawSource::Far(0), 18..24),
            DrawRun::new(DrawSource::Far(1), 24..30),
            DrawRun::new(DrawSource::Near, 30..36),
        ]
    );
    assert_eq!(
        plan.indices,
        [
            0, 1, 2, 3, 4, 5, 0, 1, 2, 3, 4, 5, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 6, 7, 8, 9,
            10, 11, 6, 7, 8, 9, 10, 11
        ]
    );
}

#[test]
fn equal_distance_quads_keep_near_then_far_input_order() {
    let center = Vec3::new(3.0, 4.0, 5.0);
    let plan = build_order_plan(center, &[center], &[&[center][..], &[center][..]]);

    assert_eq!(
        plan.runs,
        [
            DrawRun::new(DrawSource::Near, 0..6),
            DrawRun::new(DrawSource::Far(0), 6..12),
            DrawRun::new(DrawSource::Far(1), 12..18),
        ]
    );
    assert_eq!(
        plan.indices,
        [0, 1, 2, 3, 4, 5, 0, 1, 2, 3, 4, 5, 0, 1, 2, 3, 4, 5]
    );
}

#[test]
fn empty_and_removed_sources_produce_no_stale_runs_or_indices() {
    let present = [Vec3::new(2.0, 0.0, 0.0)];
    let removed: [Vec3; 0] = [];
    let first = build_order_plan(Vec3::ZERO, &[], &[&present[..], &removed[..]]);
    assert_eq!(first.runs, [DrawRun::new(DrawSource::Far(0), 0..6)]);
    assert_eq!(first.indices, [0, 1, 2, 3, 4, 5]);

    let second = build_order_plan(Vec3::ZERO, &[], &[&removed[..]]);
    assert!(second.runs.is_empty());
    assert!(second.indices.is_empty());
}

#[test]
fn unchanged_quad_centers_reuse_cached_order_without_camera_resort() {
    let eye = Vec3::ZERO;
    let near = [Vec3::new(1.0, 0.0, 0.0)];
    let far0 = [Vec3::new(3.0, 0.0, 0.0)];
    let far1: [Vec3; 0] = [];
    let far = [&far0[..], &far1[..]];
    let mut snapshot = Vec::new();
    let mut lengths = Vec::new();
    capture_centers(&mut snapshot, &mut lengths, &near, far.iter().copied());

    assert!(sources_match(
        eye,
        Some(eye),
        &snapshot,
        &lengths,
        &near,
        far.iter().copied()
    ));
    assert!(!sources_match(
        Vec3::X,
        Some(eye),
        &snapshot,
        &lengths,
        &near,
        far.iter().copied()
    ));
    let moved_far = [Vec3::new(4.0, 0.0, 0.0)];
    assert!(!sources_match(
        eye,
        Some(eye),
        &snapshot,
        &lengths,
        &near,
        [&moved_far[..], &far1[..]].into_iter()
    ));
}
