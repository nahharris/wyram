use std::collections::HashSet;
use std::sync::mpsc::{self, Receiver, SyncSender};
use std::time::{Duration, Instant};

use crate::world::{MeshJob, Vertex, VoxelWorld};

const WORKERS: usize = 2;
const MAX_UPLOADS: usize = 2;
const MAX_UPLOAD_BYTES: usize = 2 * 1024 * 1024;
const UPLOAD_TIME: Duration = Duration::from_millis(1);

struct Worker {
    sender: SyncSender<MeshJob>,
    key: Option<[i32; 3]>,
}

struct MeshResult {
    worker: usize,
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
}

impl UploadBudget {
    fn new() -> Self {
        Self {
            start: Instant::now(),
            count: 0,
            bytes: 0,
        }
    }

    fn allows(&self, bytes: usize) -> bool {
        // One indivisible oversized mesh must be allowed to progress. The time
        // limit controls admission, not the duration of a driver call.
        self.count == 0
            || (self.count < MAX_UPLOADS
                && self.bytes + bytes <= MAX_UPLOAD_BYTES
                && self.start.elapsed() < UPLOAD_TIME)
    }

    fn record(&mut self, bytes: usize) {
        self.count += 1;
        self.bytes += bytes;
    }
}

pub struct MeshPipeline {
    workers: Vec<Worker>,
    receiver: Receiver<MeshResult>,
    deferred: Option<MeshResult>,
}

impl MeshPipeline {
    pub fn new() -> Self {
        let (results, receiver) = mpsc::sync_channel(WORKERS);
        let workers = (0..WORKERS)
            .map(|worker| {
                let (sender, jobs) = mpsc::sync_channel::<MeshJob>(1);
                let results = results.clone();
                std::thread::spawn(move || {
                    while let Ok(job) = jobs.recv() {
                        let start = Instant::now();
                        let vertices = job.build();
                        let result = MeshResult {
                            worker,
                            key: job.key,
                            generation: job.generation,
                            vertices,
                            mesh_ms: start.elapsed().as_secs_f64() * 1000.0,
                        };
                        if results.send(result).is_err() {
                            break;
                        }
                    }
                });
                Worker { sender, key: None }
            })
            .collect();
        Self {
            workers,
            receiver,
            deferred: None,
        }
    }

    pub fn in_flight(&self) -> usize {
        self.workers.iter().filter(|w| w.key.is_some()).count()
    }

    pub fn update(
        &mut self,
        world: &mut VoxelWorld,
        center: [i32; 3],
        mut upload: impl FnMut([i32; 3], &[Vertex]),
    ) -> MeshStats {
        let mut stats = MeshStats::default();
        let mut budget = UploadBudget::new();
        while let Some(result) = self
            .deferred
            .take()
            .or_else(|| self.receiver.try_recv().ok())
        {
            if !world.mesh_is_current(result.key, result.generation) {
                self.workers[result.worker].key = None;
                stats.stale += 1;
                stats.mesh_ms += result.mesh_ms;
                continue;
            }
            let bytes = result.vertices.len() * size_of::<Vertex>();
            if !budget.allows(bytes) {
                self.deferred = Some(result);
                break;
            }
            self.workers[result.worker].key = None;
            let start = Instant::now();
            upload(result.key, &result.vertices);
            stats.upload_ms += start.elapsed().as_secs_f64() * 1000.0;
            stats.mesh_ms += result.mesh_ms;
            stats.uploads += 1;
            stats.upload_bytes += bytes;
            budget.record(bytes);
        }
        let mut busy: HashSet<_> = self.workers.iter().filter_map(|w| w.key).collect();
        for worker in &mut self.workers {
            if worker.key.is_none()
                && let Some(job) = world.next_mesh_job(center, &busy)
            {
                worker.key = Some(job.key);
                busy.insert(job.key);
                if worker.sender.try_send(job).is_err() {
                    panic!("mesh worker unavailable");
                }
            }
        }
        stats
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
        assert_eq!(pipeline.in_flight(), 2);
        assert_eq!(world.dirty_count(), 1);
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
            assert!(pipeline.in_flight() <= WORKERS);
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
}
