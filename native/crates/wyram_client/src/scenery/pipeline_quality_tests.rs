use super::*;
use std::time::Duration;

fn fixture(occupied: usize) -> (View, TileKey, Vec<TileKey>) {
    let mut chunk = vec![0; wyram_core::BYTE_COUNT];
    for y in 0..16 {
        for z in 0..16 {
            for x in 0..16 {
                if (x + y + z) % 4 == 0 {
                    let at = ((y * 16 + z) * 16 + x) * 2;
                    chunk[at..at + 2].copy_from_slice(&42u16.to_le_bytes());
                }
            }
        }
    }
    let air = vec![0; wyram_core::BYTE_COUNT];
    let leaves: Vec<_> = (0..8)
        .map(|i| {
            LodTile::from_chunk(
                TileKey::new([i & 1, (i >> 1) & 1, i >> 2], 0).unwrap(),
                if i == 0 { &chunk } else { &air },
            )
            .unwrap()
        })
        .collect();
    let tile = LodTile::reduce(std::array::from_fn(|i| &leaves[i])).unwrap();
    let root = tile.key();
    let keys: Vec<_> = (0..occupied + 2)
        .map(|i| TileKey::new([i as i32 * 2, 0, 0], 1).unwrap())
        .collect();
    assert_eq!(root, keys[0]);
    let mut view = View::default();
    view.replace(Plan {
        revisions: None,
        epoch: 1,
        content: 7,
        stamp: 0,
        distance: 128,
        cache_bytes: 4 << 20,
        mesh_bytes: 4 << 20,
        roots: (0..keys.len()).collect(),
        nodes: keys
            .iter()
            .map(|&key| Node {
                key,
                children: vec![],
            })
            .collect(),
    });
    view.tiles.insert(root, Arc::new(tile));
    for &key in &keys[1..occupied] {
        view.tiles.insert(key, Arc::new(LodTile::uniform(key, 42)));
    }
    (view, root, keys[occupied..].to_vec())
}

pub(super) fn settle(
    pipeline: &mut Pipeline,
    view: &View,
    world: &VoxelWorld,
    mut upload: impl FnMut(TileKey, Mesh),
) {
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut idle = 0;
    loop {
        pipeline.update(view, world, &mut upload);
        assert!(pipeline.in_flight() <= WORKERS);
        assert!(pipeline.stats.uploads <= 1);
        assert!(pipeline.ready.values().sum::<usize>() <= view.plan.as_ref().unwrap().mesh_bytes);
        if pipeline.ready.len() == view.tiles.len()
            && pipeline.in_flight() == 0
            && pipeline.dirty.is_empty()
        {
            // A result consumed this frame can expose a final quality retry on
            // the next update. Require consecutive idle updates before settling.
            idle += 1;
            if idle == 2 {
                break;
            }
        } else {
            idle = 0;
        }
        assert!(Instant::now() < deadline, "quality work must settle");
        std::thread::sleep(Duration::from_millis(1));
    }
}

#[test]
fn final_known_allowance_matches_simultaneous_delivery_without_intermediate_rebuilds() {
    let (mut view, root, missing) = fixture(3);
    let world = VoxelWorld::default();
    let mut pipeline = Pipeline::new();
    let mut meshes = Vec::new();
    settle(&mut pipeline, &view, &world, |key, mesh| {
        if key == root {
            meshes.push(mesh);
        }
    });
    assert_eq!(meshes.len(), 1);
    assert!(meshes[0].side < 32);
    let first_allowance = pipeline.forest.budget;

    view.tiles
        .insert(missing[0], Arc::new(LodTile::uniform(missing[0], 0)));
    settle(&mut pipeline, &view, &world, |key, mesh| {
        if key == root {
            meshes.push(mesh);
        }
    });
    assert_eq!(
        meshes.len(),
        1,
        "unknown data still bounds intermediate rebuild churn"
    );

    view.tiles
        .insert(missing[1], Arc::new(LodTile::uniform(missing[1], 0)));
    settle(&mut pipeline, &view, &world, |key, mesh| {
        if key == root {
            meshes.push(mesh);
        }
    });
    assert!(
        pipeline.forest.budget < first_allowance * 2,
        "exercise a sub-doubling final allowance"
    );
    assert_eq!(
        meshes.last().unwrap().side,
        32,
        "complete data must release the remaining quality headroom"
    );
    assert_eq!(meshes.len(), 2, "only one final quality replacement");

    let mut simultaneous = Pipeline::new();
    let mut reference = None;
    settle(&mut simultaneous, &view, &world, |key, mesh| {
        if key == root {
            reference = Some(mesh);
        }
    });
    let reference = reference.unwrap();
    assert_eq!(
        bytemuck::cast_slice::<_, u8>(&meshes.last().unwrap().vertices),
        bytemuck::cast_slice::<_, u8>(&reference.vertices)
    );
    assert_eq!(
        pipeline.ready, simultaneous.ready,
        "resident geometry converges within the same budget"
    );
}

#[test]
fn a_late_partial_allowance_result_still_converges_after_all_data_arrives() {
    let (mut view, root, missing) = fixture(3);
    let world = VoxelWorld::default();
    let mut pipeline = Pipeline::new();
    pipeline.update(&view, &world, |_, _| panic!("only initial dispatch"));
    assert!(pipeline.in_flight.contains_key(&root));
    for &key in &missing {
        view.tiles.insert(key, Arc::new(LodTile::uniform(key, 0)));
    }
    let mut sides = Vec::new();
    settle(&mut pipeline, &view, &world, |key, mesh| {
        if key == root {
            sides.push(mesh.side);
        }
    });
    assert_eq!(
        sides,
        vec![16, 32],
        "a result from the partial-data budget gets one final replacement"
    );
    assert!(!pipeline.degraded.contains_key(&root));
}

#[test]
fn intrinsically_degraded_final_geometry_cannot_rebuild_forever() {
    let (mut view, root, missing) = fixture(8);
    let world = VoxelWorld::default();
    let mut pipeline = Pipeline::new();
    let mut uploads = 0;
    settle(&mut pipeline, &view, &world, |key, _| {
        uploads += usize::from(key == root)
    });
    for &key in &missing {
        view.tiles.insert(key, Arc::new(LodTile::uniform(key, 0)));
    }
    settle(&mut pipeline, &view, &world, |key, mesh| {
        if key == root {
            assert!(mesh.side < 32);
            uploads += 1;
        }
    });
    assert!(
        pipeline.degraded.contains_key(&root),
        "final budget still requires a proxy"
    );
    let completed = uploads;
    for _ in 0..64 {
        pipeline.update(&view, &world, |key, _| uploads += usize::from(key == root));
        assert_eq!(
            pipeline.in_flight(),
            0,
            "a fitting final proxy must stop resubmitting"
        );
    }
    assert_eq!(uploads, completed);
}

#[test]
fn a_camera_plan_keeps_resident_detail_while_new_summaries_are_unknown() {
    let (mut view, root, missing) = fixture(1);
    for key in missing {
        view.tiles.insert(key, Arc::new(LodTile::uniform(key, 0)));
    }
    let world = VoxelWorld::default();
    let mut pipeline = Pipeline::new();
    settle(&mut pipeline, &view, &world, |_, _| {});
    let bytes = pipeline.ready[&root];
    assert!(bytes > 8192);
    let old = view.plan.as_ref().unwrap();
    let mut plan = Plan {
        epoch: old.epoch,
        content: old.content,
        stamp: old.stamp,
        distance: old.distance,
        cache_bytes: old.cache_bytes,
        mesh_bytes: old.mesh_bytes,
        roots: old.roots.clone(),
        nodes: old
            .nodes
            .iter()
            .map(|n| Node {
                key: n.key,
                children: n.children.clone(),
            })
            .collect(),
        revisions: old.revisions.clone(),
    };
    plan.epoch += 1;
    plan.cache_bytes = 64 << 20;
    for x in 100..612 {
        plan.roots.push(plan.nodes.len());
        plan.nodes.push(Node {
            key: TileKey::new([x, 0, 0], 1).unwrap(),
            children: vec![],
        });
    }
    assert!(view.replace(plan));
    let selected = pipeline.update(&view, &world, |_, _| panic!("no new data to mesh"));
    assert_eq!(
        pipeline.ready.get(&root),
        Some(&bytes),
        "camera changes must not discard detailed resident geometry to reserve unknown tiles"
    );
    assert!(selected.contains(&root));
    assert!(pipeline.ready.values().sum::<usize>() <= view.plan.as_ref().unwrap().mesh_bytes);
}
