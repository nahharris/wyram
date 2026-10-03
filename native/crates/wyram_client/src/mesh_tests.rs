use super::*;
use std::collections::BTreeSet;

fn job(data: Vec<u8>) -> MeshJob {
    let mut world = VoxelWorld::default();
    world.set_palette(HashMap::from([
        ("1".into(), [12, 80, 140]),
        ("2".into(), [160, 40, 8]),
        ("3".into(), [12, 80, 140]),
    ]));
    world.receive_chunk(
        [-2, 3, -4],
        0,
        &base64::engine::general_purpose::STANDARD.encode(data),
    );
    world.mesh_job([-2, 3, -4]).unwrap()
}

#[test]
fn liquid_mesh_keeps_solid_banks_visible_and_uses_flow_height_and_opacity() {
    let mut world = VoxelWorld::default();
    world.set_palette(HashMap::from([
        ("1".into(), [80, 80, 80]),
        ("10".into(), [40, 100, 220]),
    ]));
    world.set_descriptors(
        HashMap::from([(
            "10".into(),
            RenderDescriptor {
                opacity: 160,
                height: 0.5,
                liquid: 10,
                emissive: false,
            },
        )]),
        vec![10],
    );
    let data = bytes(|i| {
        if i == 0 {
            1
        } else if i == 1 {
            10
        } else {
            0
        }
    });
    world.receive_chunk(
        [0, 0, 0],
        0,
        &base64::engine::general_purpose::STANDARD.encode(data),
    );
    let vertices = world.mesh_job([0, 0, 0]).unwrap().build();
    assert_eq!(vertices.iter().filter(|v| v.opacity == 1.0).count(), 36);
    let water: Vec<_> = vertices.iter().filter(|v| v.opacity < 1.0).collect();
    assert!(!water.is_empty());
    assert!(water.iter().all(|v| v.position[1] <= 0.5));
    assert!(
        water
            .iter()
            .all(|v| (v.opacity - 160.0 / 255.0).abs() < 1e-6)
    );
    let before = world.camera_eye(Vec3::new(0.5, 0.3, 0.5), Vec3::X * 1.5);
    assert!(before.is_some());
}

#[test]
fn same_liquid_family_culls_shared_faces_and_emissive_faces_are_unshaded() {
    let mut world = VoxelWorld::default();
    world.set_palette(HashMap::from([
        ("10".into(), [240, 80, 10]),
        ("11".into(), [240, 80, 10]),
    ]));
    world.set_descriptors(
        HashMap::from([
            (
                "10".into(),
                RenderDescriptor {
                    opacity: 255,
                    height: 1.0,
                    liquid: 10,
                    emissive: true,
                },
            ),
            (
                "11".into(),
                RenderDescriptor {
                    opacity: 255,
                    height: 0.5,
                    liquid: 10,
                    emissive: true,
                },
            ),
        ]),
        vec![10, 11],
    );
    world.receive_chunk(
        [0, 0, 0],
        0,
        &base64::engine::general_purpose::STANDARD.encode(bytes(|i| {
            if i == 0 {
                10
            } else if i == 1 {
                11
            } else {
                0
            }
        })),
    );
    let vertices = world.mesh_job([0, 0, 0]).unwrap().build();
    assert!(
        vertices
            .iter()
            .all(|v| v.color == [240.0 / 255.0, 80.0 / 255.0, 10.0 / 255.0])
    );
    // The higher cell exposes only the strip above its lower neighbor.
    let interface: Vec<_> = vertices
        .as_chunks::<6>()
        .0
        .iter()
        .filter(|q| q.iter().all(|v| v.position[0] == 1.0))
        .collect();
    assert_eq!(interface.len(), 1);
    assert!(interface[0].iter().all(|v| v.position[1] >= 0.5));
}

#[test]
fn liquid_prediction_crosses_a_noncolliding_cell_and_descriptor_changes_invalidate_jobs() {
    let mut world = VoxelWorld::default();
    world.receive_chunk(
        [0, 0, 0],
        0,
        &base64::engine::general_purpose::STANDARD.encode(bytes(|i| if i == 1 { 10 } else { 0 })),
    );
    let old_job = world.mesh_job([0, 0, 0]).unwrap();
    assert_eq!(
        world
            .predict_body([1.5, 0.0, 0.5], Vec3::X, 0.1, 0.5, 0.3)
            .unwrap()
            .x,
        1.5
    );
    world.set_descriptors(
        HashMap::from([(
            "10".into(),
            RenderDescriptor {
                opacity: 160,
                height: 1.0,
                liquid: 10,
                emissive: false,
            },
        )]),
        vec![10],
    );
    assert!(!world.mesh_is_current(old_job.key, old_job.generation));
    assert_eq!(
        world
            .predict_body([1.5, 0.0, 0.5], Vec3::X, 0.1, 0.5, 0.3)
            .unwrap()
            .x,
        2.5
    );
    assert!(
        world
            .camera_eye(Vec3::new(1.5, 0.3, 0.5), Vec3::X)
            .unwrap()
            .x
            > 2.4
    );
}

#[test]
fn selection_rays_pass_through_the_empty_space_above_flowing_liquid() {
    let mut world = VoxelWorld::default();
    world.receive_chunk(
        [0, 0, 0],
        0,
        &base64::engine::general_purpose::STANDARD.encode(bytes(|i| if i == 1 { 10 } else { 0 })),
    );
    world.set_descriptors(
        HashMap::from([(
            "10".into(),
            RenderDescriptor {
                opacity: 160,
                height: 0.5,
                liquid: 10,
                emissive: false,
            },
        )]),
        vec![10],
    );
    let upper = world.aim_point(Vec3::new(0.5, 0.75, 0.5), Vec3::X);
    let lower = world.aim_point(Vec3::new(0.5, 0.25, 0.5), Vec3::X);
    assert!(upper.x > 6.0);
    assert!(lower.x >= 1.0 && lower.x <= 1.1);
}

fn bytes(mut material: impl FnMut(usize) -> u16) -> Vec<u8> {
    (0..BLOCK_COUNT)
        .flat_map(|i| material(i).to_le_bytes())
        .collect()
}

type UnitFace = ([i32; 3], [i32; 3], [u32; 3]);

fn coverage(vertices: &[Vertex]) -> BTreeSet<UnitFace> {
    assert_eq!(vertices.len() % 6, 0);
    let mut faces = BTreeSet::new();
    for quad in vertices.as_chunks::<6>().0 {
        assert_eq!(quad[0].position, quad[3].position);
        assert_eq!(quad[2].position, quad[4].position);
        let a = Vec3::from_array(quad[1].position) - Vec3::from_array(quad[0].position);
        let b = Vec3::from_array(quad[2].position) - Vec3::from_array(quad[0].position);
        let cross = a.cross(b).to_array();
        let axis = cross.iter().position(|v| *v != 0.0).unwrap();
        let normal = std::array::from_fn(|i| {
            if i == axis {
                cross[i].signum() as i32
            } else {
                0
            }
        });
        let u = (axis + 1) % 3;
        let v = (axis + 2) % 3;
        let low: [i32; 3] =
            std::array::from_fn(|i| quad.iter().map(|p| p.position[i] as i32).min().unwrap());
        let high: [i32; 3] =
            std::array::from_fn(|i| quad.iter().map(|p| p.position[i] as i32).max().unwrap());
        let color = quad[0].color.map(f32::to_bits);
        assert!(quad.iter().all(|p| p.color.map(f32::to_bits) == color));
        for x in low[u]..high[u] {
            for y in low[v]..high[v] {
                let mut position = low;
                position[u] = x;
                position[v] = y;
                assert!(
                    faces.insert((position, normal, color)),
                    "duplicate surface coverage"
                );
            }
        }
    }
    faces
}

#[test]
fn solid_chunk_merges_to_six_quads() {
    let job = job(bytes(|_| 1));
    assert_eq!(job.build().len(), 36);
}

#[test]
fn greedy_preserves_oriented_surface_and_color_coverage() {
    let mut random = 42u64;
    let mut cases = vec![
        bytes(|_| 0),
        bytes(|_| 1),
        bytes(|i| if i % 16 < 8 { 1 } else { 2 }),
        bytes(|i| {
            if (i % 16 + i / 16 % 16 + i / 256).is_multiple_of(2) {
                1
            } else {
                0
            }
        }),
        bytes(|i| if i == 1234 { 0 } else { 1 }),
    ];
    for seed in 0..8 {
        cases.push(wyram_core::generate_chunk(seed, -2, 3, -4, [1, 2, 3]));
        cases.push(bytes(|_| {
            random = random.wrapping_mul(6364136223846793005).wrapping_add(1);
            (random >> 32) as u16 % 4
        }));
    }
    for data in cases {
        let job = job(data);
        assert_eq!(
            coverage(&job.build()),
            coverage(&job.snapshot.mesh_chunk(job.key))
        );
    }
}

#[test]
fn equal_colors_do_not_merge_distinct_materials() {
    let job = job(bytes(|i| match i {
        0 => 1,
        1 => 3,
        _ => 0,
    }));
    assert_eq!(job.build().len(), 60);
}

#[test]
fn seam_and_edit_coverage_matches_the_simple_mesher() {
    let key = [-2, 3, -4];
    let mut world = VoxelWorld::default();
    for neighbor in NEIGHBORS
        .into_iter()
        .map(|offset| std::array::from_fn(|i| key[i] + offset[i]))
        .chain([key])
    {
        let data =
            wyram_core::generate_chunk(2026, neighbor[0], neighbor[1], neighbor[2], [1, 2, 3]);
        world.receive_chunk(
            neighbor,
            0,
            &base64::engine::general_purpose::STANDARD.encode(data),
        );
    }
    let before = world.mesh_job(key).unwrap();
    assert_eq!(
        coverage(&before.build()),
        coverage(&before.snapshot.mesh_chunk(key))
    );
    let edited = wyram_core::write_block(&world.chunks[&key].data, 0, 12, 0, 0).unwrap();
    world.receive_chunk(
        key,
        1,
        &base64::engine::general_purpose::STANDARD.encode(edited),
    );
    let after = world.mesh_job(key).unwrap();
    assert_eq!(
        coverage(&after.build()),
        coverage(&after.snapshot.mesh_chunk(key))
    );
    assert!(!world.mesh_is_current(before.key, before.generation));
}

#[test]
#[ignore = "manual matched meshing benchmark"]
fn matched_mesh_benchmark() {
    use std::time::Instant;
    let cases = [
        ("empty", job(bytes(|_| 0))),
        ("solid", job(bytes(|_| 1))),
        (
            "terrain",
            job(wyram_core::generate_chunk(2026, -2, 3, -4, [1, 2, 3])),
        ),
        (
            "checkerboard",
            job(bytes(|i| {
                if (i % 16 + i / 16 % 16 + i / 256).is_multiple_of(2) {
                    1
                } else {
                    0
                }
            })),
        ),
    ];
    let mut results = Vec::new();
    for (name, job) in cases {
        let candidate_vertices = job.build().len();
        let simple_vertices = job.snapshot.mesh_chunk(job.key).len();
        assert_eq!(
            coverage(&job.build()),
            coverage(&job.snapshot.mesh_chunk(job.key))
        );
        for _ in 0..10 {
            std::hint::black_box(job.build());
            std::hint::black_box(job.snapshot.mesh_chunk(job.key));
        }
        let mut simple = Vec::new();
        let mut greedy = Vec::new();
        for round in 0..30 {
            let mut measure = |candidate: bool| {
                let start = Instant::now();
                for _ in 0..10 {
                    let result = if candidate {
                        job.build()
                    } else {
                        job.snapshot.mesh_chunk(job.key)
                    };
                    std::hint::black_box(result);
                }
                let elapsed = start.elapsed().as_secs_f64() * 100.0;
                if candidate {
                    greedy.push(elapsed);
                } else {
                    simple.push(elapsed);
                }
            };
            measure(round % 2 == 0);
            measure(round % 2 != 0);
        }
        results.push(serde_json::json!({"workload":name,"simple_vertices":simple_vertices,"greedy_vertices":candidate_vertices,"simple_ms":simple,"greedy_ms":greedy}));
    }
    let path = std::env::var("WYRAM_MESH_BENCH_OUTPUT").expect("set WYRAM_MESH_BENCH_OUTPUT");
    let report = serde_json::json!({
        "schema": 1, "profile": env!("WYRAM_NATIVE_PROFILE"), "opt_level": env!("WYRAM_OPT_LEVEL"),
        "rounds": 30, "iterations_per_round": 10, "workloads": results,
    });
    std::fs::write(path, serde_json::to_vec_pretty(&report).unwrap()).unwrap();
}
