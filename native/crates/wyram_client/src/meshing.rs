use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::mpsc::{self, Receiver, SyncSender};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use crate::world::{MeshJob, Vertex, VoxelWorld};

const WORKERS: usize = 2;
// Includes queued jobs, active jobs and completed results awaiting admission.
// A bounded window lets workers refill without waiting for a redraw.
const MAX_JOBS: usize = 32;
const MAX_UPLOADS: usize = 8;
const MAX_UPLOAD_BYTES: usize = 2 * 1024 * 1024;
const UPLOAD_TIME: Duration = Duration::from_millis(1);

pub fn upload_limit() -> usize {
    std::env::var("WYRAM_MESH_UPLOAD_LIMIT")
        .ok()
        .and_then(|v| v.parse().ok())
        .filter(|limit| (1..=MAX_UPLOADS).contains(limit))
        .unwrap_or(MAX_UPLOADS)
}

struct MeshResult {
    key: [i32; 3],
    generation: u64,
    vertices: Vec<Vertex>,
    mesh_ms: f64,
}

#[derive(Default)]
pub struct MeshStats {
    pub uploads: usize,
    pub upload_bytes: usize,
    pub upload_ms: f64,
    pub mesh_ms: f64,
    pub stale: usize,
}

struct UploadBudget {
    start: Instant,
    count: usize,
    bytes: usize,
    limit: usize,
}

impl UploadBudget {
    fn new() -> Self {
        Self {
            start: Instant::now(),
            count: 0,
            bytes: 0,
            limit: MAX_UPLOADS,
        }
    }

    fn allows(&self, bytes: usize) -> bool {
        // One indivisible oversized mesh must be allowed to progress. The time
        // limit controls admission, not the duration of a driver call.
        self.count == 0
            || (self.count < self.limit
                && self.bytes + bytes <= MAX_UPLOAD_BYTES
                && self.start.elapsed() < UPLOAD_TIME)
    }

    fn record(&mut self, bytes: usize) {
        self.count += 1;
        self.bytes += bytes;
    }
}

pub struct MeshPipeline {
    sender: Option<SyncSender<MeshJob>>,
    workers: Vec<JoinHandle<()>>,
    receiver: Receiver<MeshResult>,
    in_flight: HashMap<[i32; 3], u64>,
    deferred: VecDeque<MeshResult>,
    upload_limit: usize,
}

impl MeshPipeline {
    pub fn new() -> Self {
        let (sender, jobs) = mpsc::sync_channel::<MeshJob>(MAX_JOBS);
        let jobs = Arc::new(Mutex::new(jobs));
        let (results, receiver) = mpsc::sync_channel(MAX_JOBS);
        let workers = (0..WORKERS)
            .map(|_| {
                let jobs = Arc::clone(&jobs);
                let results = results.clone();
                std::thread::spawn(move || {
                    loop {
                        // The receive lock is released before meshing. Render-thread
                        // admission never locks this mutex or waits for workers.
                        let job = jobs.lock().expect("mesh queue poisoned").recv();
                        if let Ok(job) = job {
                            let start = Instant::now();
                            let vertices = job.build();
                            let result = MeshResult {
                                key: job.key,
                                generation: job.generation,
                                vertices,
                                mesh_ms: start.elapsed().as_secs_f64() * 1000.0,
                            };
                            if results.send(result).is_err() {
                                break;
                            }
                        } else {
                            break;
                        }
                    }
                })
            })
            .collect();
        Self {
            sender: Some(sender),
            workers,
            receiver,
            in_flight: HashMap::new(),
            deferred: VecDeque::new(),
            upload_limit: upload_limit(),
        }
    }

    pub fn in_flight(&self) -> usize {
        self.in_flight.len()
    }

    pub fn update(
        &mut self,
        world: &mut VoxelWorld,
        center: [i32; 3],
        mut upload: impl FnMut([i32; 3], &[Vertex]),
    ) -> MeshStats {
        let mut stats = MeshStats::default();
        let mut budget = UploadBudget::new();
        budget.limit = self.upload_limit;
        while self.deferred.len() < MAX_JOBS {
            match self.receiver.try_recv() {
                Ok(result) => self.deferred.push_back(result),
                Err(_) => break,
            }
        }
        // Scan each ready result once. A deferred geometry upload must not
        // prevent cheap empty completions or stale-result rejection behind it.
        let ready = self.deferred.len();
        for _ in 0..ready {
            let result = self.deferred.pop_front().expect("ready result exists");
            if !world.mesh_is_current(result.key, result.generation) {
                self.in_flight.remove(&result.key);
                stats.stale += 1;
                stats.mesh_ms += result.mesh_ms;
                continue;
            }
            let bytes = result.vertices.len() * size_of::<Vertex>();
            if bytes > 0 && !budget.allows(bytes) {
                self.deferred.push_back(result);
                continue;
            }
            self.in_flight.remove(&result.key);
            let start = Instant::now();
            upload(result.key, &result.vertices);
            stats.upload_ms += start.elapsed().as_secs_f64() * 1000.0;
            stats.mesh_ms += result.mesh_ms;
            stats.upload_bytes += bytes;
            if bytes > 0 {
                stats.uploads += 1;
                budget.record(bytes);
            }
        }
        let busy: HashSet<_> = self.in_flight.keys().copied().collect();
        let available = MAX_JOBS - self.in_flight.len();
        for job in world.next_mesh_jobs(center, &busy, available) {
            self.in_flight.insert(job.key, job.generation);
            if self
                .sender
                .as_ref()
                .expect("mesh queue open")
                .try_send(job)
                .is_err()
            {
                panic!("mesh worker unavailable or admission bound violated");
            }
        }
        stats
    }
}

impl Drop for MeshPipeline {
    fn drop(&mut self) {
        self.sender.take();
        // Wake workers blocked on a full result queue before joining them.
        let (_, closed) = mpsc::channel();
        drop(std::mem::replace(&mut self.receiver, closed));
        for worker in self.workers.drain(..) {
            let _ = worker.join();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::Engine;
    use std::collections::HashMap;
    use wyram_core::BYTE_COUNT;

    fn block() -> String {
        let mut bytes = vec![0; BYTE_COUNT];
        bytes[0] = 1;
        base64::engine::general_purpose::STANDARD.encode(bytes)
    }

    #[test]
    fn work_is_bounded_and_stale_results_never_upload() {
        let mut world = VoxelWorld::default();
        for x in [0, 4, 8] {
            world.receive_chunk([x, 0, 0], 0, &block());
        }
        let mut pipeline = MeshPipeline::new();
        let stats = pipeline.update(&mut world, [0, 0, 0], |_, _| {
            panic!("first update only dispatches")
        });
        assert_eq!(stats.uploads, 0);
        assert_eq!(pipeline.in_flight(), 3);
        assert_eq!(world.dirty_count(), 0);
        world.forget([0, 0, 0]);
        world.receive_chunk(
            [4, 0, 0],
            1,
            &base64::engine::general_purpose::STANDARD.encode(vec![0; BYTE_COUNT]),
        );
        let mut uploaded = HashMap::new();
        let deadline = Instant::now() + Duration::from_secs(10);
        while pipeline.in_flight() != 0 || world.dirty_count() != 0 {
            assert!(Instant::now() < deadline, "workers did not finish");
            let stats = pipeline.update(&mut world, [0, 0, 0], |key, vertices| {
                uploaded.insert(key, vertices.len());
            });
            assert!(stats.uploads <= MAX_UPLOADS);
            assert!(pipeline.in_flight() <= MAX_JOBS);
            std::thread::sleep(Duration::from_millis(1));
        }
        assert!(!uploaded.contains_key(&[0, 0, 0]));
        assert_eq!(uploaded[&[4, 0, 0]], 0);
        assert_eq!(uploaded[&[8, 0, 0]], 36);
    }

    #[test]
    fn oversized_upload_can_progress_but_budget_stops_following_uploads() {
        let mut budget = UploadBudget::new();
        assert!(budget.allows(MAX_UPLOAD_BYTES + 1));
        budget.record(MAX_UPLOAD_BYTES + 1);
        assert!(!budget.allows(1));
        let mut budget = UploadBudget::new();
        budget.record(MAX_UPLOAD_BYTES / 2);
        assert!(!budget.allows(MAX_UPLOAD_BYTES));
    }

    #[test]
    fn cheap_uploads_use_the_available_time_budget_with_a_finite_count_bound() {
        let mut budget = UploadBudget::new();
        // A future start fixes elapsed() at zero, independent of CI scheduling.
        budget.start = Instant::now() + Duration::from_secs(60);
        for _ in 0..8 {
            assert!(budget.allows(1024));
            budget.record(1024);
        }
        assert!(!budget.allows(1024));
        budget.start = Instant::now() - Duration::from_secs(1);
        assert!(!budget.allows(1));
    }

    #[test]
    fn one_admission_keeps_workers_busy_between_redraws() {
        let mut world = VoxelWorld::default();
        for x in 0..8 {
            world.receive_chunk([x * 4, 0, 0], 0, &block());
        }
        let mut pipeline = MeshPipeline::new();
        pipeline.update(&mut world, [0, 0, 0], |_, _| panic!("admission only"));
        let deadline = Instant::now() + Duration::from_secs(10);
        let mut completed = 0;
        while completed < 8 {
            assert!(
                Instant::now() < deadline,
                "workers need another redraw to receive work"
            );
            if pipeline.receiver.try_recv().is_ok() {
                completed += 1;
            } else {
                std::thread::yield_now();
            }
        }
    }

    #[test]
    fn empty_results_do_not_consume_geometry_upload_slots() {
        let mut world = VoxelWorld::default();
        let air = base64::engine::general_purpose::STANDARD.encode(vec![0; BYTE_COUNT]);
        for x in 0..8 {
            world.receive_chunk([x * 4, 0, 0], 0, &air);
        }
        let mut pipeline = MeshPipeline::new();
        pipeline.update(&mut world, [0, 0, 0], |_, _| {});
        // Receive the first pair and put them back as deferred test results;
        // this gates completion without relying on a performance threshold.
        let first = pipeline
            .receiver
            .recv_timeout(Duration::from_secs(10))
            .unwrap();
        let second = pipeline
            .receiver
            .recv_timeout(Duration::from_secs(10))
            .unwrap();
        let (sender, receiver) = mpsc::sync_channel(8);
        sender.send(first).unwrap();
        sender.send(second).unwrap();
        pipeline.receiver = receiver;
        let stats = pipeline.update(&mut world, [0, 0, 0], |_, vertices| {
            assert!(vertices.is_empty())
        });
        assert_eq!(
            stats.uploads, 0,
            "empty completions cannot consume vertex upload admission"
        );
    }

    #[test]
    fn admission_is_bounded_and_an_empty_revision_removes_the_old_mesh() {
        let mut world = VoxelWorld::default();
        for x in 0..100 {
            world.receive_chunk([x * 4, 0, 0], 0, &block());
        }
        let mut pipeline = MeshPipeline::new();
        pipeline.update(&mut world, [0, 0, 0], |_, _| {});
        assert_eq!(pipeline.in_flight(), MAX_JOBS);
        assert_eq!(world.dirty_count(), 100 - MAX_JOBS);
        let mut meshes = HashMap::new();
        let deadline = Instant::now() + Duration::from_secs(10);
        while pipeline.in_flight() > 0 || world.dirty_count() > 0 {
            assert!(Instant::now() < deadline, "bounded queue did not drain");
            let stats = pipeline.update(&mut world, [0, 0, 0], |key, vertices| {
                meshes.insert(key, vertices.len());
            });
            assert!(stats.uploads <= MAX_UPLOADS);
            assert!(pipeline.in_flight() <= MAX_JOBS);
            std::thread::yield_now();
        }
        assert_eq!(meshes.len(), 100);
        assert_eq!(meshes[&[0, 0, 0]], 36);
        let air = base64::engine::general_purpose::STANDARD.encode(vec![0; BYTE_COUNT]);
        world.receive_chunk([0, 0, 0], 1, &air);
        while pipeline.in_flight() > 0 || world.dirty_count() > 0 {
            assert!(Instant::now() < deadline, "empty revision did not drain");
            let stats = pipeline.update(&mut world, [0, 0, 0], |key, vertices| {
                meshes.insert(key, vertices.len());
            });
            assert_eq!(stats.uploads, 0);
            std::thread::yield_now();
        }
        assert_eq!(meshes[&[0, 0, 0]], 0);
    }
}
