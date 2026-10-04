use super::quality_tests::settle;
use super::*;
use crate::scenery::wire::Batch;

fn fixture() -> (View, Vec<TileKey>) {
    let keys: Vec<_> = [0, 1, 4]
        .into_iter()
        .map(|x| TileKey::new([x, 0, 0], 1).unwrap())
        .collect();
    let mut view = View::default();
    view.replace(Plan {
        epoch: 1,
        content: 7,
        stamp: 0,
        distance: 128,
        cache_bytes: 4 << 20,
        mesh_bytes: 4 << 20,
        roots: vec![0, 1, 2],
        nodes: keys
            .iter()
            .map(|&key| Node {
                key,
                children: vec![],
            })
            .collect(),
        revisions: Some(keys.iter().map(|&key| (key, 0)).collect()),
    });
    assert!(view.accept(Batch {
        epoch: 1,
        delivery: 1,
        tiles: keys.iter().map(|&key| LodTile::uniform(key, 42)).collect(),
    }));
    (view, keys)
}

fn edit(view: &mut View, key: TileKey, epoch: u64, stamp: u64) {
    let plan = view.plan.as_ref().unwrap();
    let mut replacement = Plan {
        epoch,
        content: plan.content,
        stamp,
        distance: plan.distance,
        cache_bytes: plan.cache_bytes,
        mesh_bytes: plan.mesh_bytes,
        roots: plan.roots.clone(),
        nodes: Vec::new(),
        revisions: plan.revisions.clone(),
    };
    replacement.nodes = plan
        .nodes
        .iter()
        .map(|n| Node {
            key: n.key,
            children: n.children.clone(),
        })
        .collect();
    replacement.revisions.as_mut().unwrap().insert(key, stamp);
    assert!(view.replace(replacement));
}

#[test]
fn edits_rebuild_the_changed_tile_and_its_neighbor_but_retain_unrelated_geometry() {
    let (mut view, keys) = fixture();
    let world = VoxelWorld::default();
    let mut pipeline = Pipeline::new();
    settle(&mut pipeline, &view, &world, |_, _| {});
    let far_bytes = pipeline.ready[&keys[2]];
    edit(&mut view, keys[0], 2, 1);
    pipeline.update(&view, &world, |_, _| {
        panic!("changed data is not available yet")
    });
    assert_eq!(
        pipeline.ready.get(&keys[2]),
        Some(&far_bytes),
        "unrelated mesh must survive"
    );
    assert!(
        !pipeline.ready.contains_key(&keys[1]),
        "changed neighbor invalidates occlusion"
    );
    assert!(view.accept(Batch {
        epoch: 2,
        delivery: 2,
        tiles: vec![LodTile::uniform(keys[0], 0)]
    }));
    let mut replacements = HashMap::new();
    settle(&mut pipeline, &view, &world, |key, mesh| {
        replacements.insert(key, mesh);
    });
    assert!(
        !replacements.contains_key(&keys[2]),
        "retained tile must not upload again"
    );
    assert!(replacements[&keys[0]].vertices.is_empty());
    let mut reference = Pipeline::new();
    let mut expected = None;
    settle(&mut reference, &view, &world, |key, mesh| {
        if key == keys[1] {
            expected = Some(mesh);
        }
    });
    assert_eq!(
        bytemuck::cast_slice::<_, u8>(&replacements[&keys[1]].vertices),
        bytemuck::cast_slice::<_, u8>(&expected.unwrap().vertices)
    );
    assert_eq!(pipeline.ready, reference.ready);
}

#[test]
fn retired_revision_jobs_cannot_restore_removed_geometry_or_escape_worker_bounds() {
    let (mut view, keys) = fixture();
    let world = VoxelWorld::default();
    let mut pipeline = Pipeline::new();
    pipeline.update(&view, &world, |_, _| panic!("only dispatch"));
    assert_eq!(pipeline.in_flight(), WORKERS);
    edit(&mut view, keys[0], 2, 1);
    assert!(view.accept(Batch {
        epoch: 2,
        delivery: 2,
        tiles: vec![LodTile::uniform(keys[0], 0)]
    }));
    let mut changed_uploads = 0;
    settle(&mut pipeline, &view, &world, |key, mesh| {
        if key == keys[0] {
            assert!(
                mesh.vertices.is_empty(),
                "old occupied result must be rejected"
            );
            changed_uploads += 1;
        }
    });
    assert_eq!(changed_uploads, 1);
    assert_eq!(pipeline.ready[&keys[0]], 0);
}

#[test]
fn multiple_edit_plans_before_a_redraw_preserve_all_dependency_invalidations() {
    let (mut view, keys) = fixture();
    let world = VoxelWorld::default();
    let mut pipeline = Pipeline::new();
    settle(&mut pipeline, &view, &world, |_, _| {});
    edit(&mut view, keys[0], 2, 1);
    assert!(view.accept(Batch {
        epoch: 2,
        delivery: 2,
        tiles: vec![LodTile::uniform(keys[0], 0)]
    }));
    edit(&mut view, keys[1], 3, 2);
    assert!(view.accept(Batch {
        epoch: 3,
        delivery: 3,
        tiles: vec![LodTile::uniform(keys[1], 0)]
    }));
    let mut replaced = HashSet::new();
    settle(&mut pipeline, &view, &world, |key, mesh| {
        assert!(mesh.vertices.is_empty());
        replaced.insert(key);
    });
    assert_eq!(replaced, HashSet::from([keys[0], keys[1]]));
    let mut reference = Pipeline::new();
    settle(&mut reference, &view, &world, |_, _| {});
    assert_eq!(pipeline.ready, reference.ready);
}
