use super::{
    mesh::{self, Mesh},
    view::View,
    wire::{Node, Plan},
};
use crate::world::{Presentation, RenderDescriptor, VoxelWorld};
use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::{Arc, Mutex, mpsc};
use std::thread::JoinHandle;
use std::time::Instant;
use wyram_core::scenery::{LodTile, TileKey};

const WORKERS: usize = 2;
const MAX_JOB_BYTES: usize = 2 * 1024 * 1024;
// Six faces, six vertices per face, with worst-case blended allocation slack.
const MIN_TILE_BYTES: usize = 6 * 6 * 72;

#[derive(Default)]
struct Forest {
    roots: Vec<usize>,
    nodes: Vec<Node>,
    wanted: HashSet<TileKey>,
    budget: usize,
}

impl Forest {
    fn new(plan: &Plan) -> Self {
        let limit = plan.mesh_bytes / MIN_TILE_BYTES;
        if plan.roots.len() > limit {
            return Self::default();
        }
        let mut chosen: HashSet<usize> = plan.roots.iter().copied().collect();
        let mut queue: VecDeque<_> = plan.roots.iter().copied().collect();
        while let Some(i) = queue.pop_front() {
            let children = &plan.nodes[i].children;
            if children.len() == 8 && chosen.len() + 8 <= limit {
                chosen.extend(children.iter().copied());
                queue.extend(children.iter().copied());
            }
        }
        let nodes = plan
            .nodes
            .iter()
            .enumerate()
            .map(|(i, n)| Node {
                key: n.key,
                children: if chosen.contains(&i) && n.children.iter().all(|c| chosen.contains(c)) {
                    n.children.clone()
                } else {
                    Vec::new()
                },
            })
            .collect();
        Self {
            roots: plan.roots.clone(),
            nodes,
            wanted: chosen.iter().map(|&i| plan.nodes[i].key).collect(),
            budget: (plan.mesh_bytes / chosen.len().max(1)).min(MAX_JOB_BYTES),
        }
    }
    fn selected(&self, ready: &HashMap<TileKey, usize>) -> Vec<TileKey> {
        fn visit(f: &Forest, i: usize, ready: &HashMap<TileKey, usize>, out: &mut Vec<TileKey>) {
            let node = &f.nodes[i];
            if !node.children.is_empty()
                && node
                    .children
                    .iter()
                    .all(|&c| ready.contains_key(&f.nodes[c].key))
            {
                for &child in &node.children {
                    visit(f, child, ready, out);
                }
            } else if ready.contains_key(&node.key) {
                out.push(node.key);
            }
        }
        let mut selected = Vec::new();
        for &root in &self.roots {
            visit(self, root, ready, &mut selected);
        }
        selected
    }
}

#[derive(Debug)]
struct Job {
    tile: Arc<LodTile>,
    generation: u64,
    colors: Arc<HashMap<u16, [u8; 3]>>,
    descriptors: Arc<HashMap<u16, RenderDescriptor>>,
    water: Arc<HashMap<u16, f32>>,
    budget: usize,
}
struct ResultMesh {
    key: TileKey,
    generation: u64,
    mesh: Result<Mesh, &'static str>,
    mesh_ms: f64,
}

#[derive(Default)]
pub struct Stats {
    pub update_ms: f64,
    pub worker_ms: f64,
    pub upload_ms: f64,
    pub uploads: usize,
    pub upload_bytes: usize,
    pub stale: usize,
    pub degraded: usize,
    pub selected: usize,
}

pub struct Pipeline {
    pub stats: Stats,
    sender: Option<mpsc::SyncSender<Job>>,
    receiver: mpsc::Receiver<ResultMesh>,
    workers: Vec<JoinHandle<()>>,
    in_flight: HashMap<TileKey, u64>,
    deferred: VecDeque<ResultMesh>,
    ready: HashMap<TileKey, usize>,
    failed: HashSet<TileKey>,
    forest: Forest,
    epoch: u64,
    content: Option<(u64, u64)>,
    generation: u64,
    colors: Arc<HashMap<u16, [u8; 3]>>,
    descriptors: Arc<HashMap<u16, RenderDescriptor>>,
    water: Arc<HashMap<u16, f32>>,
}

impl Pipeline {
    pub fn new() -> Self {
        let (sender, jobs) = mpsc::sync_channel::<Job>(WORKERS);
        let jobs = Arc::new(Mutex::new(jobs));
        let (results, receiver) = mpsc::sync_channel(WORKERS);
        let workers = (0..WORKERS)
            .map(|_| {
                let jobs = Arc::clone(&jobs);
                let results = results.clone();
                std::thread::spawn(move || {
                    loop {
                        let job = jobs.lock().expect("scenery work queue poisoned").recv();
                        let Ok(job) = job else {
                            break;
                        };
                        let key = job.tile.key();
                        let start = Instant::now();
                        let mesh = mesh::build(
                            &job.tile,
                            &job.colors,
                            &job.descriptors,
                            &job.water,
                            job.budget,
                        );
                        if results
                            .send(ResultMesh {
                                key,
                                generation: job.generation,
                                mesh,
                                mesh_ms: start.elapsed().as_secs_f64() * 1000.0,
                            })
                            .is_err()
                        {
                            break;
                        }
                    }
                })
            })
            .collect();
        Self {
            stats: Stats::default(),
            sender: Some(sender),
            receiver,
            workers,
            in_flight: HashMap::new(),
            deferred: VecDeque::new(),
            ready: HashMap::new(),
            failed: HashSet::new(),
            forest: Forest::default(),
            epoch: 0,
            content: None,
            generation: 0,
            colors: Arc::default(),
            descriptors: Arc::default(),
            water: Arc::default(),
        }
    }
    pub fn ready(&self) -> &HashMap<TileKey, usize> {
        &self.ready
    }
    pub fn in_flight(&self) -> usize {
        self.in_flight.len()
    }
    pub fn failed(&self) -> usize {
        self.failed.len()
    }
    pub fn set_water(&mut self, planes: HashMap<String, f32>, world: &VoxelWorld) {
        let descriptors = world.presentation().descriptors;
        let planes = planes
            .into_iter()
            .filter_map(|(key, plane)| {
                let id = key.parse::<u16>().ok()?;
                (plane.is_finite()
                    && plane.abs() <= 1_000_000.0
                    && descriptors.get(&id).is_some_and(|d| d.liquid != 0))
                .then_some((id, plane))
            })
            .collect::<HashMap<_, _>>();
        if self.water.as_ref() != &planes {
            self.water = Arc::new(planes);
            self.generation += 1;
            self.ready.clear();
            self.failed.clear();
        }
    }
    pub fn update(
        &mut self,
        view: &View,
        world: &VoxelWorld,
        mut upload: impl FnMut(TileKey, Mesh),
    ) -> Vec<TileKey> {
        self.stats = Stats::default();
        let start = Instant::now();
        let Some(plan) = &view.plan else {
            return Vec::new();
        };
        let Presentation {
            colors,
            descriptors,
        } = world.presentation();
        let palette_changed =
            !Arc::ptr_eq(&colors, &self.colors) || !Arc::ptr_eq(&descriptors, &self.descriptors);
        let content = Some((plan.content, plan.stamp));
        if self.epoch != plan.epoch || palette_changed {
            let forest = Forest::new(plan);
            if self.content != content || palette_changed {
                self.generation += 1;
                self.ready.clear();
                self.failed.clear();
            }
            if self.forest.budget != forest.budget {
                self.failed.clear();
            }
            self.ready
                .retain(|key, bytes| forest.wanted.contains(key) && *bytes <= forest.budget);
            self.failed.retain(|key| forest.wanted.contains(key));
            self.forest = forest;
            self.epoch = plan.epoch;
            self.content = content;
            self.colors = colors;
            self.descriptors = descriptors;
        }
        // Results and retired work retain their slots until drained. Camera or
        // palette changes cannot start additional workers or accumulate jobs.
        while self.deferred.len() < WORKERS {
            if let Ok(result) = self.receiver.try_recv() {
                self.deferred.push_back(result);
            } else {
                break;
            }
        }
        let mut uploaded = false;
        for _ in 0..self.deferred.len() {
            let result = self.deferred.pop_front().unwrap();
            if result.generation != self.generation || !self.forest.wanted.contains(&result.key) {
                self.in_flight.remove(&result.key);
                self.stats.stale += 1;
                self.stats.worker_ms += result.mesh_ms;
                continue;
            }
            match result.mesh {
                Ok(mesh) if mesh.bytes() <= self.forest.budget => {
                    if uploaded && !mesh.vertices.is_empty() {
                        self.deferred.push_back(ResultMesh {
                            mesh: Ok(mesh),
                            ..result
                        });
                        continue;
                    }
                    uploaded |= !mesh.vertices.is_empty();
                    self.in_flight.remove(&result.key);
                    self.ready.insert(result.key, mesh.bytes());
                    self.stats.worker_ms += result.mesh_ms;
                    self.stats.degraded += usize::from(mesh.side < 32);
                    self.stats.uploads += usize::from(!mesh.vertices.is_empty());
                    self.stats.upload_bytes += mesh.vertices.len() * size_of::<mesh::ProxyVertex>();
                    let upload_start = Instant::now();
                    upload(result.key, mesh);
                    self.stats.upload_ms += upload_start.elapsed().as_secs_f64() * 1000.0;
                }
                Ok(_) => {
                    self.in_flight.remove(&result.key);
                }
                Err(_) => {
                    self.in_flight.remove(&result.key);
                    self.failed.insert(result.key);
                }
            }
        }
        for node in &plan.nodes {
            if self.in_flight.len() >= WORKERS {
                break;
            }
            let key = node.key;
            if !self.forest.wanted.contains(&key)
                || self.ready.contains_key(&key)
                || self.failed.contains(&key)
                || self.in_flight.contains_key(&key)
            {
                continue;
            }
            let Some(tile) = view.tiles.get(&key) else {
                continue;
            };
            let job = Job {
                tile: Arc::clone(tile),
                generation: self.generation,
                colors: Arc::clone(&self.colors),
                descriptors: Arc::clone(&self.descriptors),
                water: Arc::clone(&self.water),
                budget: self.forest.budget,
            };
            self.sender
                .as_ref()
                .unwrap()
                .try_send(job)
                .expect("scenery work admission bound");
            self.in_flight.insert(key, self.generation);
        }
        debug_assert!(self.ready.values().sum::<usize>() <= plan.mesh_bytes);
        let selected = self.forest.selected(&self.ready);
        self.stats.selected = selected.len();
        self.stats.update_ms = start.elapsed().as_secs_f64() * 1000.0;
        selected
    }
}

impl Drop for Pipeline {
    fn drop(&mut self) {
        self.sender.take();
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
    fn plan(budget: usize) -> Plan {
        let parent = TileKey::new([-1, 0, -1], 2).unwrap();
        Plan {
            epoch: 1,
            content: 7,
            stamp: 0,
            distance: 128,
            cache_bytes: 1 << 20,
            mesh_bytes: budget,
            roots: vec![0],
            nodes: std::iter::once(Node {
                key: parent,
                children: (1..9).collect(),
            })
            .chain((0..8).map(|i| Node {
                key: TileKey::new([-2 + (i & 1), (i >> 1) & 1, -2 + (i >> 2)], 1).unwrap(),
                children: vec![],
            }))
            .collect(),
        }
    }
    #[test]
    fn incomplete_siblings_keep_the_parent_and_empty_completions_count_as_ready() {
        let p = plan(1 << 20);
        let f = Forest::new(&p);
        let root = p.nodes[0].key;
        let mut ready = HashMap::from([(root, 0)]);
        for child in &p.nodes[1..8] {
            ready.insert(child.key, 0);
        }
        assert_eq!(f.selected(&ready), vec![root]);
        ready.insert(p.nodes[8].key, 0);
        let selected = f.selected(&ready);
        assert_eq!(
            selected,
            p.nodes[1..].iter().map(|n| n.key).collect::<Vec<_>>()
        );
        assert!(!selected.contains(&root));
    }
    #[test]
    fn low_budgets_prune_whole_child_groups_and_reserve_every_retained_tile() {
        let p = plan(MIN_TILE_BYTES * 8);
        let f = Forest::new(&p);
        assert_eq!(f.wanted.len(), 1);
        assert!(f.nodes[0].children.is_empty());
        assert!(f.budget * f.wanted.len() <= p.mesh_bytes);
        let p = plan(MIN_TILE_BYTES * 9);
        let f = Forest::new(&p);
        assert_eq!(f.wanted.len(), 9);
        assert!(f.budget * f.wanted.len() <= p.mesh_bytes);
    }
    #[test]
    fn work_and_uploads_are_bounded_and_content_changes_discard_completed_old_jobs() {
        let mut view = View::default();
        view.replace(plan(1 << 20));
        for node in &view.plan.as_ref().unwrap().nodes {
            view.tiles
                .insert(node.key, Arc::new(LodTile::uniform(node.key, 42)));
        }
        let world = VoxelWorld::default();
        let mut pipeline = Pipeline::new();
        pipeline.update(&view, &world, |_, _| panic!("initial update dispatches"));
        assert_eq!(pipeline.in_flight.len(), 2);
        let mut next = plan(1 << 20);
        next.epoch = 2;
        next.content = 8;
        view.replace(next);
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        while !pipeline.in_flight.is_empty() {
            assert!(std::time::Instant::now() < deadline);
            pipeline.update(&view, &world, |_, _| panic!("old content must not upload"));
            std::thread::sleep(std::time::Duration::from_millis(1));
        }
        assert!(pipeline.ready.is_empty());
        for node in &view.plan.as_ref().unwrap().nodes {
            view.tiles
                .insert(node.key, Arc::new(LodTile::uniform(node.key, 42)));
        }
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        while pipeline.ready.len() < 9 {
            assert!(std::time::Instant::now() < deadline);
            let mut uploads = 0;
            pipeline.update(&view, &world, |_, mesh| {
                assert!(mesh.bytes() <= MAX_JOB_BYTES);
                uploads += 1;
            });
            assert!(uploads <= 1, "one geometry upload per redraw");
            assert!(pipeline.in_flight.len() <= WORKERS);
            assert!(pipeline.ready.values().sum::<usize>() <= 1 << 20);
            std::thread::sleep(std::time::Duration::from_millis(1));
        }
        assert_eq!(pipeline.stats.selected, 8);
    }
}
