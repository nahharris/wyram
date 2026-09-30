use super::*;

fn snapshot(sequence: u64, epoch: u64) -> Snapshot {
    serde_json::from_value(serde_json::json!({"id":"player","x":0.5,"y":1.62,"z":0.5,"feet":[0.5,0.0,0.5],"velocity":[1.0,0.0,0.0],"radius":0.28,"height":1.8,"eye_height":1.62,"yaw":0.0,"pitch":0.0,"sequence":sequence,"epoch":epoch,"unavailable":false})).unwrap()
}

#[test]
fn reconciliation_rejects_old_snapshots_and_teleport_epochs() {
    let mut replica = Replica::default();
    assert!(replica.accept(snapshot(1, 0)));
    assert!(!replica.accept(snapshot(1, 0)));
    assert!(replica.accept(snapshot(2, 1)));
    assert!(!replica.accept(snapshot(100, 0)));
    assert!(!replica.accept(snapshot(1, 1)));
    assert!(replica.accept(snapshot(0, 2)));
}

#[test]
fn missing_visual_terrain_freezes_prediction_at_authoritative_position() {
    let mut replica = Replica::default();
    replica.accept(snapshot(1, 0));
    let predicted = replica.sample(&crate::world::VoxelWorld::default());
    assert_eq!(predicted, Vec3::new(0.5, 1.62, 0.5));
}

#[test]
fn traversal_prediction_stays_within_the_approved_target() {
    let state: Snapshot = serde_json::from_value(serde_json::json!({"id":"player","x":0.5,"y":4.58,"z":0.5,"feet":[0.5,2.96,0.5],"velocity":[0.0,4.0,0.0],"radius":0.28,"height":1.8,"eye_height":1.62,"yaw":0.0,"pitch":0.0,"sequence":1,"epoch":0,"unavailable":false,"action":{"kind":"climb","phase":"rise","target":[1.5,3.0,0.5]}})).unwrap();
    assert!((state.approved_delta(0.04).y - 0.04).abs() < 1e-6);
    assert_eq!(state.approved_delta(0.04).x, 0.0);
    assert_eq!(
        snapshot(1, 0).approved_delta(0.04),
        Vec3::new(0.04, 0.0, 0.0)
    );
}
