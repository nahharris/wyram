use super::*;
use base64::Engine;
fn world(wall: Option<(usize, usize)>) -> VoxelWorld {
    let mut w = VoxelWorld::default();
    let mut bytes = vec![0; wyram_core::BYTE_COUNT];
    if let Some((axis, at)) = wall {
        for x in 0..16 {
            for y in 0..16 {
                for z in 0..16 {
                    if [x, y, z][axis] == at {
                        bytes[((y * 16 + z) * 16 + x) * 2] = 1;
                    }
                }
            }
        }
    }
    w.receive_chunk(
        [0, 0, 0],
        1,
        &base64::engine::general_purpose::STANDARD.encode(bytes),
    );
    w
}
#[test]
fn modes_cycle_zoom_is_bounded_and_views_face_the_character() {
    let mut c = Camera::default();
    let eye = Vec3::new(8., 3., 8.);
    let aim = Vec3::NEG_Z;
    let w = world(None);
    let first = c.view(eye, aim, &w, 0.28);
    assert_eq!(first.position, eye);
    assert!(!first.show_player);
    c.cycle();
    let third = c.view(eye, aim, &w, 0.28);
    assert!(third.position.z > eye.z);
    assert!(third.direction.dot(aim) > 0.99);
    assert!(third.show_player);
    c.cycle();
    let front = c.view(eye, aim, &w, 0.28);
    assert!(front.position.z < eye.z);
    assert!(front.direction.dot(aim) < -0.99);
    c.zoom(-100.);
    assert_eq!(c.distance, 6.);
    c.zoom(100.);
    assert_eq!(c.distance, 1.);
    c.cycle();
    assert_eq!(c.mode, Mode::First);
}
#[test]
fn walls_ceilings_and_unknown_terrain_cannot_leave_camera_embedded() {
    let eye = Vec3::new(8., 3., 8.);
    let mut c = Camera::default();
    c.cycle();
    let wall = c.view(eye, Vec3::NEG_Z, &world(Some((2, 10))), 0.28);
    assert!(wall.position.z < 9.9 && wall.position.z > 9.);
    let ceiling = c.view(
        eye,
        Vec3::new(0., -0.7, -0.7).normalize(),
        &world(Some((1, 4))),
        0.28,
    );
    assert!(ceiling.position.y < 3.9);
    let close = c.view(
        Vec3::new(8., 3., 8.7),
        Vec3::NEG_Z,
        &world(Some((2, 9))),
        0.28,
    );
    assert!(!close.show_player);
    let missing = c.view(eye, Vec3::NEG_Z, &VoxelWorld::default(), 0.28);
    assert_eq!(missing.position, eye);
    assert!(!missing.show_player);
    let partial = c.view(Vec3::new(8., 3., 15.), Vec3::NEG_Z, &world(None), 0.28);
    assert_eq!(partial.position, Vec3::new(8., 3., 15.));
}
#[test]
fn moving_and_posture_sized_targets_keep_camera_independent_of_aim() {
    let mut c = Camera::default();
    let w = world(None);
    c.cycle();
    for y in [0.45, 0.85, 1.26, 1.62] {
        let eye = Vec3::new(8., y, 8.);
        let view = c.view(eye, Vec3::NEG_Z, &w, 0.28);
        assert!((view.position.y - eye.y).abs() < 1e-5);
        assert!((view.position.distance(eye) - 3.).abs() < 1e-4);
    }
    let a = c.view(Vec3::new(8., 2., 8.), Vec3::NEG_Z, &w, 0.28);
    let b = c.view(Vec3::new(9., 2., 8.), Vec3::NEG_Z, &w, 0.28);
    assert!(b.position.abs_diff_eq(a.position + Vec3::X, 1e-5));
}

#[test]
fn steep_pitch_large_bodies_and_negative_chunk_edges_use_safe_fallbacks() {
    let mut c = Camera::default();
    c.cycle();
    let w = world(None);
    let eye = Vec3::new(8., 3., 8.);
    for pitch in [-1.55_f32, 1.55] {
        let aim = Vec3::new(0., pitch.sin(), -pitch.cos());
        let v = c.view(eye, aim, &w, 0.28);
        assert!(v.position.is_finite() && v.direction.is_finite());
    }
    c.zoom(100.);
    assert!(!c.view(eye, Vec3::NEG_Z, &w, 2.).show_player);
    let unknown = c.view(Vec3::new(-0.1, 3., -0.1), Vec3::NEG_Z, &w, 0.28);
    assert!(!unknown.show_player);
}
