use super::*;

fn chunks() -> Vec<([i32; 3], Vec<u8>)> {
    let mut chunks = Vec::new();
    for x in -1..=0 {
        for y in -1..=0 {
            for z in -1..=0 {
                chunks.push(([x, y, z], vec![0; crate::BYTE_COUNT]));
            }
        }
    }
    chunks
}

#[test]
fn sweep_stops_at_wall_and_slides_along_it_without_tunneling() {
    let mut data = chunks();
    let chunk = data.iter_mut().find(|(key, _)| *key == [0, 0, 0]).unwrap();
    for y in 0..3 {
        chunk.1 = crate::write_block(&chunk.1, 2, y, 0, 1).unwrap();
    }
    let world = PackedWorld::new(data.iter().map(|(key, bytes)| (*key, bytes.as_slice()))).unwrap();
    let result = world
        .sweep([0.5, 0.0, 0.5], [5.0, 0.0, 0.2], 0.28, 1.8)
        .unwrap();
    assert!((result.position[0] - 1.72).abs() < 1e-8);
    assert!((result.position[2] - 0.7).abs() < 1e-8);
    assert!(result.blocked[0]);
}

#[test]
fn missing_chunks_are_unavailable_and_never_treated_as_air() {
    let world = PackedWorld::new(std::iter::empty()).unwrap();
    let result = world
        .sweep([0.5, 0.0, 0.5], [1.0, -1.0, 0.0], 0.28, 1.8)
        .unwrap();
    assert!(result.unavailable);
    assert_eq!(result.position, [0.5, 0.0, 0.5]);
}

#[test]
fn all_body_cells_and_negative_coordinates_are_checked() {
    let mut data = chunks();
    let chunk = data
        .iter_mut()
        .find(|(key, _)| *key == [-1, 0, -1])
        .unwrap();
    chunk.1 = crate::write_block(&chunk.1, 15, 1, 15, 1).unwrap();
    let world = PackedWorld::new(data.iter().map(|(key, bytes)| (*key, bytes.as_slice()))).unwrap();
    let result = world.sweep([-0.5, 0.0, -0.5], [0.0; 3], 0.28, 3.0).unwrap();
    assert!(result.blocked.iter().all(|value| *value));
    assert!(
        world
            .sweep([f64::NAN, 0.0, 0.0], [0.0; 3], 0.28, 1.8)
            .is_err()
    );
}

#[test]
fn floor_and_ceiling_contacts_clamp_exactly_to_voxel_faces() {
    let mut data = chunks();
    let below = data.iter_mut().find(|(key, _)| *key == [0, -1, 0]).unwrap();
    below.1 = crate::write_block(&below.1, 0, 15, 0, 1).unwrap();
    let above = data.iter_mut().find(|(key, _)| *key == [0, 0, 0]).unwrap();
    above.1 = crate::write_block(&above.1, 0, 3, 0, 1).unwrap();
    let world = PackedWorld::new(data.iter().map(|(key, bytes)| (*key, bytes.as_slice()))).unwrap();
    let floor = world
        .sweep([0.5, 0.1, 0.5], [0.0, -2.0, 0.0], 0.28, 1.8)
        .unwrap();
    assert!(floor.position[1].abs() < 1e-8);
    assert!(floor.blocked[1]);
    let ceiling = world
        .sweep([0.5, 0.0, 0.5], [0.0, 5.0, 0.0], 0.28, 1.8)
        .unwrap();
    assert!((ceiling.position[1] - 1.2).abs() < 1e-8);
}
