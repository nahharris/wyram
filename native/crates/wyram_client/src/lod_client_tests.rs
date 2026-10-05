use super::*;
use crate::lod_wire::WireTile;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};
use wyram_core::lod::{Cell, Tile};

fn fixture(key: TileKey, revision: u64, tile: Tile, epoch: u64) -> WireBatch {
    WireBatch {
        epoch,
        tiles: vec![WireTile {
            key,
            revision,
            payload: tile.encode().unwrap(),
        }],
    }
}

fn colors() -> Arc<LodColors> {
    Arc::new(HashMap::from([(1, [80, 150, 60])]))
}

fn descriptors() -> Arc<LodDescriptors> {
    Arc::new(HashMap::new())
}

fn neighbors() -> Arc<EncodedNeighbors> {
    Arc::new(HashMap::new())
}

fn sampler() -> Arc<BoundarySampler> {
    Arc::new(|_| None)
}

fn factory() -> Arc<SamplerFactory> {
    Arc::new(|_, _, near| near)
}

fn wait_for_ready<G: Send + 'static>(client: &mut LodClient<G>, key: TileKey, rev: u64) {
    let deadline = Instant::now() + Duration::from_secs(4);
    loop {
        let events = client.drain_events(64);
        if events.iter().any(|event| matches!(event, LodEvent::Ready { revision, key: got, .. } if *got == key && *revision == rev)) {
            return;
        }
        assert!(
            Instant::now() < deadline,
            "worker did not reach ready state: {events:?}"
        );
        thread::sleep(Duration::from_millis(1));
    }
}

fn solid_tile(key: TileKey) -> Tile {
    let mut tile = Tile::empty(key).unwrap();
    tile.cells[(34 + 1) * 34 + 1] = Cell {
        material: 1,
        top_material: 1,
        coverage: 255,
        solid_height: 1,
        ..Cell::default()
    };
    tile
}

#[test]
fn empty_completion_is_ready_and_epoch_change_resets_resident_coverage() {
    assert!(matches!(
        LodClient::<usize>::new(0),
        Err(LodError::InvalidWorkerCount)
    ));
    let key = TileKey::new(2, [0, 0, 0]).unwrap();
    let mut client = LodClient::<usize>::new(1).unwrap();
    client.set_plan(5, &[key]);
    client
        .submit(
            fixture(key, 7, Tile::empty(key).unwrap(), 5),
            colors(),
            descriptors(),
            neighbors(),
            sampler(),
            factory(),
        )
        .unwrap();
    wait_for_ready(&mut client, key, 7);
    assert!(client.is_ready(5, key, 7));
    assert_eq!(client.resident(key).unwrap().parts.len(), 0);
    client.set_plan(6, &[key]);
    assert!(!client.is_ready(6, key, 7));
    assert_eq!(client.gpu_bytes(), 0);
    assert!(client.drain_events(8).iter().any(|event| matches!(
        event,
        LodEvent::Dropped { epoch: 5, key: got, revision: 7 } if *got == key
    )));
}

#[test]
fn replacement_keeps_old_handles_until_every_new_part_is_uploaded() {
    let key = TileKey::new(2, [0, 0, 0]).unwrap();
    let mut client = LodClient::<usize>::new(1).unwrap();
    client.set_plan(1, &[key]);
    client
        .submit(
            fixture(key, 1, solid_tile(key), 1),
            colors(),
            descriptors(),
            neighbors(),
            sampler(),
            factory(),
        )
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(4);
    while !client.is_ready(1, key, 1) {
        for part in client.poll_parts(2, MAX_PART_BYTES) {
            client.reserve_upload(part.ticket).unwrap();
            client
                .ack_part(part.ticket, part.part.index as usize + 1)
                .unwrap();
        }
        let _ = client.drain_events(64);
        assert!(
            Instant::now() < deadline,
            "initial tile did not become ready"
        );
        thread::sleep(Duration::from_millis(1));
    }
    let old_bytes = client.gpu_bytes();
    assert!(old_bytes > 0);

    client
        .submit(
            fixture(key, 2, solid_tile(key), 1),
            colors(),
            descriptors(),
            neighbors(),
            sampler(),
            factory(),
        )
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(4);
    let mut uploaded = 0;
    while !client.is_ready(1, key, 2) {
        let parts = client.poll_parts(2, MAX_PART_BYTES);
        for part in parts {
            client.reserve_upload(part.ticket).unwrap();
            let handle = part.part.index as usize + 100;
            let bytes = vertex_bytes(&part.part);
            client.ack_part(part.ticket, handle).unwrap();
            uploaded += bytes;
            if !client.is_ready(1, key, 2) {
                assert!(client.is_ready(1, key, 1));
                assert_eq!(client.gpu_bytes(), old_bytes);
                assert!(client.gpu_bytes() + client.reserved_gpu_bytes() <= MAX_GPU_BYTES);
            }
        }
        let _ = client.drain_events(64);
        assert!(
            Instant::now() < deadline,
            "replacement did not become ready"
        );
        thread::sleep(Duration::from_millis(1));
    }
    assert!(uploaded > 0);
    assert_eq!(client.gpu_bytes(), uploaded);
    assert_eq!(client.resident(key).unwrap().revision, 2);
    assert_eq!(client.evict(key), uploaded);
    assert_eq!(client.gpu_bytes(), 0);
    assert!(client.drain_events(8).iter().any(|event| matches!(
        event,
        LodEvent::Dropped { revision: 2, key: got, .. } if *got == key
    )));
}

#[test]
fn gpu_pressure_defer_and_reject_release_reservations_and_allow_retry() {
    let key = TileKey::new(2, [0, 0, 0]).unwrap();
    let mut client = LodClient::<usize>::new(1).unwrap();
    client.set_plan(21, &[key]);
    client
        .submit(
            fixture(key, 1, solid_tile(key), 21),
            colors(),
            descriptors(),
            neighbors(),
            sampler(),
            factory(),
        )
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(4);
    while !client.is_ready(21, key, 1) {
        for part in client.poll_parts(2, MAX_PART_BYTES) {
            client.reserve_upload(part.ticket).unwrap();
            client
                .ack_part(part.ticket, part.part.index as usize + 1)
                .unwrap();
        }
        let _ = client.drain_events(64);
        assert!(
            Instant::now() < deadline,
            "initial resident did not become ready"
        );
        thread::sleep(Duration::from_millis(1));
    }
    let old_bytes = client.gpu_bytes();
    let old_handles = client.resident(key).unwrap().parts.to_vec();

    let replacement = fixture(key, 2, solid_tile(key), 21);
    client
        .submit(
            replacement.clone(),
            colors(),
            descriptors(),
            neighbors(),
            sampler(),
            factory(),
        )
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(4);
    let first = loop {
        let parts = client.poll_parts(1, MAX_PART_BYTES);
        if let Some(part) = parts.into_iter().next() {
            break part;
        }
        assert!(Instant::now() < deadline, "replacement emitted no part");
        thread::sleep(Duration::from_millis(1));
    };
    let new_bytes = vertex_bytes(&first.part);
    assert!(new_bytes > 0);

    // Simulate an old resident that leaves less than one replacement part free.
    client.residents.get_mut(&key).unwrap().bytes = MAX_GPU_BYTES - new_bytes + 1;
    client.gpu_bytes = MAX_GPU_BYTES - new_bytes + 1;
    assert_eq!(
        client.reserve_upload(first.ticket),
        Err(LodError::GpuBudgetExceeded)
    );
    assert_eq!(client.reserved_gpu_bytes(), 0);
    assert_eq!(client.resident(key).unwrap().parts, old_handles);

    // Free the simulated pressure, defer and retry the same part, then reject it.
    client.residents.get_mut(&key).unwrap().bytes = old_bytes;
    client.gpu_bytes = old_bytes;
    client.defer_part(first.ticket).unwrap();
    assert_eq!(client.reserved_gpu_bytes(), 0);
    let deferred = client.poll_parts(1, MAX_PART_BYTES).pop().unwrap();
    assert_eq!(deferred.part.index, first.part.index);
    client.reserve_upload(deferred.ticket).unwrap();
    assert_eq!(client.reserved_gpu_bytes(), new_bytes);
    client
        .reject_part(deferred.ticket, LodError::GpuBudgetExceeded)
        .unwrap();
    assert_eq!(client.reserved_gpu_bytes(), 0);
    assert_eq!(client.gpu_bytes(), old_bytes);
    assert_eq!(client.resident(key).unwrap().parts, old_handles);

    // Re-submit the same revision after pressure clears; detail becomes resident atomically.
    client
        .submit(
            replacement,
            colors(),
            descriptors(),
            neighbors(),
            sampler(),
            factory(),
        )
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(4);
    while !client.is_ready(21, key, 2) {
        for part in client.poll_parts(2, MAX_PART_BYTES) {
            client.reserve_upload(part.ticket).unwrap();
            client
                .ack_part(part.ticket, part.part.index as usize + 101)
                .unwrap();
        }
        let _ = client.drain_events(64);
        assert!(Instant::now() < deadline, "retry did not become ready");
        thread::sleep(Duration::from_millis(1));
    }
    assert_eq!(client.gpu_bytes(), new_bytes);
    assert_eq!(client.resident(key).unwrap().revision, 2);
}

#[test]
fn obsolete_jobs_keep_the_slot_until_worker_finish_and_report_rejection() {
    let key = TileKey::new(2, [0, 0, 0]).unwrap();
    let entered = Arc::new((Mutex::new(false), std::sync::Condvar::new()));
    let release = Arc::new((Mutex::new(false), std::sync::Condvar::new()));
    let entered_factory = Arc::clone(&entered);
    let release_factory = Arc::clone(&release);
    let blocking_factory: Arc<SamplerFactory> = Arc::new(move |_, _, near| {
        *entered_factory.0.lock().unwrap() = true;
        entered_factory.1.notify_all();
        let mut released = release_factory.0.lock().unwrap();
        while !*released {
            released = release_factory.1.wait(released).unwrap();
        }
        near
    });
    let mut client = LodClient::<usize>::new(1).unwrap();
    client.set_plan(2, &[key]);
    client
        .submit(
            fixture(key, 3, Tile::empty(key).unwrap(), 2),
            colors(),
            descriptors(),
            neighbors(),
            sampler(),
            blocking_factory,
        )
        .unwrap();
    let mut entered_guard = entered.0.lock().unwrap();
    while !*entered_guard {
        entered_guard = entered.1.wait(entered_guard).unwrap();
    }
    drop(entered_guard);
    client.set_plan(3, &[key]);
    assert_eq!(client.running_jobs(), 1);
    let rejected = client.drain_events(64);
    assert!(rejected.iter().any(|event| {
        matches!(
            event,
            LodEvent::Rejected {
                revision: 3,
                reason: LodError::StaleBatch,
                ..
            }
        )
    }));
    *release.0.lock().unwrap() = true;
    release.1.notify_all();
    let deadline = Instant::now() + Duration::from_secs(4);
    while client.running_jobs() != 0 {
        let _ = client.drain_events(64);
        assert!(
            Instant::now() < deadline,
            "obsolete worker did not release its slot"
        );
        thread::sleep(Duration::from_millis(1));
    }
    assert_eq!(client.running_jobs(), 0);
}

#[test]
fn part_poll_is_bounded_and_cache_retrieval_is_shared() {
    let key = TileKey::new(2, [0, 0, 0]).unwrap();
    let payload = Arc::new(Tile::empty(key).unwrap().encode().unwrap());
    let mut client = LodClient::<usize>::new(1).unwrap();
    client.cache_tile(key, 4, Arc::clone(&payload)).unwrap();
    let (revision, cached) = client.cached_tile(key).unwrap();
    assert_eq!(revision, 4);
    assert!(Arc::ptr_eq(&cached, &payload));
    assert_eq!(client.cache_bytes(), payload.len());

    client.set_plan(9, &[key]);
    client
        .submit(
            fixture(key, 5, solid_tile(key), 9),
            colors(),
            descriptors(),
            neighbors(),
            sampler(),
            factory(),
        )
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(4);
    let parts = loop {
        let parts = client.poll_parts(2, MAX_PART_BYTES);
        if !parts.is_empty() {
            break parts;
        }
        assert!(Instant::now() < deadline, "mesher emitted no part");
        thread::sleep(Duration::from_millis(1));
    };
    assert!(parts.len() <= 2);
    assert!(
        parts
            .iter()
            .map(|part| vertex_bytes(&part.part))
            .sum::<usize>()
            <= MAX_PART_BYTES
    );
}

#[test]
fn concurrent_worker_count_and_invalid_neighbor_bound_are_enforced() {
    let keys: Vec<_> = (0..4)
        .map(|x| TileKey::new(2, [x, 0, 0]).unwrap())
        .collect();
    let active = Arc::new(AtomicUsize::new(0));
    let peak = Arc::new(AtomicUsize::new(0));
    let active_factory = Arc::clone(&active);
    let peak_factory = Arc::clone(&peak);
    let measured: Arc<SamplerFactory> = Arc::new(move |_, _, near| {
        let now = active_factory.fetch_add(1, Ordering::SeqCst) + 1;
        peak_factory.fetch_max(now, Ordering::SeqCst);
        thread::sleep(Duration::from_millis(40));
        active_factory.fetch_sub(1, Ordering::SeqCst);
        near
    });
    let mut client = LodClient::<usize>::new(2).unwrap();
    client.set_plan(11, &keys);
    for pair in keys.chunks(2) {
        let tiles = pair
            .iter()
            .map(|&key| WireTile {
                key,
                revision: 1,
                payload: Tile::empty(key).unwrap().encode().unwrap(),
            })
            .collect();
        client
            .submit(
                WireBatch { epoch: 11, tiles },
                colors(),
                descriptors(),
                neighbors(),
                sampler(),
                Arc::clone(&measured),
            )
            .unwrap();
    }
    assert_eq!(client.running_jobs(), 4);
    assert!(client.encoded_neighbors(&vec![keys[0]; 65]).is_err());
    let deadline = Instant::now() + Duration::from_secs(4);
    while client.running_jobs() != 0 {
        let _ = client.drain_events(64);
        assert!(Instant::now() < deadline, "workers did not finish");
        thread::sleep(Duration::from_millis(1));
    }
    assert_eq!(peak.load(Ordering::SeqCst), 2);
}

#[test]
fn malformed_cached_source_is_evicted_so_same_revision_can_retry() {
    let key = TileKey::new(2, [0, 0, 0]).unwrap();
    let mut client = LodClient::<usize>::new(1).unwrap();
    client.set_plan(12, &[key]);
    let malformed = WireBatch {
        epoch: 12,
        tiles: vec![WireTile {
            key,
            revision: 8,
            payload: b"LT01\0\0\0\0\0\0\0\0\0\0\0\0".to_vec(),
        }],
    };
    client
        .submit(
            malformed,
            colors(),
            descriptors(),
            neighbors(),
            sampler(),
            factory(),
        )
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(4);
    loop {
        let events = client.drain_events(16);
        if events.iter().any(|event| {
            matches!(
                event,
                LodEvent::Rejected {
                    revision: 8,
                    reason: LodError::WorkerFailed(_),
                    ..
                }
            )
        }) {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "malformed payload was not rejected"
        );
        thread::sleep(Duration::from_millis(1));
    }
    assert_eq!(client.cache_bytes(), 0);
    client
        .submit(
            fixture(key, 8, Tile::empty(key).unwrap(), 12),
            colors(),
            descriptors(),
            neighbors(),
            sampler(),
            factory(),
        )
        .unwrap();
    wait_for_ready(&mut client, key, 8);
}

#[test]
fn explicit_invalidation_removes_encoded_cache_without_removing_the_plan() {
    let key = TileKey::new(2, [0, 0, 0]).unwrap();
    let bytes = Arc::new(Tile::empty(key).unwrap().encode().unwrap());
    let mut client = LodClient::<usize>::new(1).unwrap();
    client.set_plan(15, &[key]);
    client.cache_tile(key, 1, bytes).unwrap();
    assert!(client.cache_bytes() > 0);
    client.invalidate(key);
    assert_eq!(client.cache_bytes(), 0);
    assert!(client.cached_tile(key).is_none());
    client
        .submit(
            fixture(key, 1, Tile::empty(key).unwrap(), 15),
            colors(),
            descriptors(),
            neighbors(),
            sampler(),
            factory(),
        )
        .unwrap();
    wait_for_ready(&mut client, key, 1);
}
