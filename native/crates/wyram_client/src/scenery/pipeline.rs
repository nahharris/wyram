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

type Dependencies = Vec<(TileKey, (u64, u64))>;

fn dependencies(view: &View, key: TileKey, neighbors: &[(TileKey, bool)]) -> Option<Dependencies> {
    std::iter::once(key)
        .chain(neighbors.iter().map(|&(key, _)| key))
        .map(|key| view.revision(key).map(|revision| (key, revision)))
        .collect()
}

fn current_dependencies(view: &View, dependencies: &Dependencies) -> bool {
    dependencies
        .iter()
        .all(|&(key, revision)| view.revision(key) == Some(revision))
}

#[derive(Default)]
struct Forest {
    roots: Vec<usize>,
    nodes: Vec<Node>,
    wanted: HashSet<TileKey>,
    budget: usize,
}

fn neighbor_keys(
    key: TileKey,
    wanted: &HashSet<TileKey>,
    refined: &HashSet<TileKey>,
) -> Vec<(TileKey, bool)> {
    let mut neighbors = Vec::new();
    for (offset, _, _) in crate::chunk_mesh::FACES {
        let position = std::array::from_fn(|i| key.position()[i] + offset[i]);
        let mut adjacent = TileKey::new(position, key.level()).unwrap();
        loop {
            if wanted.contains(&adjacent) {
                neighbors.push((adjacent, !refined.contains(&adjacent)));
                break;
            }
            if adjacent.level() >= 6 {
                break;
            }
            adjacent = adjacent.parent().unwrap();
        }
    }
    neighbors.sort_by_key(|(key, _)| (key.level(), key.position()));
    neighbors.dedup();
    neighbors
}

impl Forest {
    fn allowance(&self, view: &View, total: usize, ready: &HashMap<TileKey, usize>) -> usize {
        let mut count = 0;
        let mut retained = Vec::new();
        for key in &self.wanted {
            if view.tiles.get(key).is_none_or(|tile| tile.occupied() != 0) {
                count += 1;
                if let Some(&bytes) = ready.get(key) {
                    retained.push(bytes);
                }
            }
        }
        if count == 0 {
            return 0;
        }
        // Preserve existing geometry when new unknown tiles reserve a share.
        // Larger resident meshes retain their actual bytes; distribute only
        // the remaining budget among other occupied or unknown tiles.
        retained.sort_unstable_by(|a, b| b.cmp(a));
        let mut available = total;
        for bytes in retained {
            if bytes <= available / count.max(1) {
                break;
            }
            available = available.saturating_sub(bytes);
            count -= 1;
        }
        (available / count.max(1)).min(MAX_JOB_BYTES)
    }
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
    fn selected(
        &self,
        ready: &HashMap<TileKey, usize>,
        blocked: &HashSet<TileKey>,
    ) -> Vec<TileKey> {
        fn visit(
            f: &Forest,
            i: usize,
            ready: &HashMap<TileKey, usize>,
            blocked: &HashSet<TileKey>,
            out: &mut Vec<TileKey>,
        ) {
            let node = &f.nodes[i];
            if !node.children.is_empty()
                && !blocked.contains(&node.key)
                && node
                    .children
                    .iter()
                    .all(|&c| ready.contains_key(&f.nodes[c].key))
            {
                for &child in &node.children {
                    visit(f, child, ready, blocked, out);
                }
            } else if ready.contains_key(&node.key) {
                out.push(node.key);
            }
        }
        let mut selected = Vec::new();
        for &root in &self.roots {
            visit(self, root, ready, blocked, &mut selected);
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
    neighbors: Vec<mesh::Neighbor>,
    dependencies: Dependencies,
}
struct ResultMesh {
    key: TileKey,
    generation: u64,
    mesh: Result<Mesh, &'static str>,
    mesh_ms: f64,
    neighbors: Vec<(TileKey, bool)>,
    budget: usize,
    dependencies: Dependencies,
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
    ready_neighbors: HashMap<TileKey, Vec<(TileKey, bool)>>,
    ready_dependencies: HashMap<TileKey, Dependencies>,
    degraded: HashMap<TileKey, usize>,
    dirty: HashSet<TileKey>,
    planned: HashSet<TileKey>,
    refined: HashSet<TileKey>,
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
                        let mesh = mesh::build_with_neighbors(
                            &job.tile,
                            &job.colors,
                            &job.descriptors,
                            &job.water,
                            job.budget,
                            &job.neighbors,
                        );
                        if results
                            .send(ResultMesh {
                                key,
                                generation: job.generation,
                                mesh,
                                mesh_ms: start.elapsed().as_secs_f64() * 1000.0,
                                neighbors: job
                                    .neighbors
                                    .iter()
                                    .map(|neighbor| {
                                        (neighbor.tile.key(), neighbor.opaque_occlusion)
                                    })
                                    .collect(),
                                budget: job.budget,
                                dependencies: job.dependencies,
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
            ready_neighbors: HashMap::new(),
            ready_dependencies: HashMap::new(),
            degraded: HashMap::new(),
            dirty: HashSet::new(),
            planned: HashSet::new(),
            refined: HashSet::new(),
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
    pub fn degraded_ready(&self) -> usize {
        self.degraded.len()
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
            self.ready_neighbors.clear();
            self.ready_dependencies.clear();
            self.degraded.clear();
            self.dirty.clear();
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
            let mut forest = Forest::new(plan);
            forest.budget = forest.allowance(view, plan.mesh_bytes, &self.ready);
            self.planned = plan.nodes.iter().map(|node| node.key).collect();
            self.refined = plan
                .nodes
                .iter()
                .filter(|node| !node.children.is_empty())
                .map(|node| node.key)
                .collect();
            if self.content != content || palette_changed {
                self.generation += 1;
                if plan.revisions.is_some()
                    && self
                        .content
                        .is_some_and(|(lineage, _)| lineage == plan.content)
                    && !palette_changed
                {
                    self.ready.retain(|key, _| {
                        self.ready_dependencies
                            .get(key)
                            .is_some_and(|dependencies| current_dependencies(view, dependencies))
                    });
                } else {
                    self.ready.clear();
                }
                self.ready_neighbors
                    .retain(|key, _| self.ready.contains_key(key));
                self.degraded.retain(|key, _| self.ready.contains_key(key));
                self.dirty.clear();
                self.failed.clear();
            }
            if self.forest.budget != forest.budget {
                self.failed.clear();
            }
            self.ready.retain(|key, _| forest.wanted.contains(key));
            if self.ready.values().sum::<usize>() > plan.mesh_bytes {
                self.ready.clear();
            }
            self.ready_neighbors
                .retain(|key, _| self.ready.contains_key(key));
            self.dirty.retain(|key| self.ready.contains_key(key));
            for (&key, neighbors) in &self.ready_neighbors {
                if *neighbors != neighbor_keys(key, &self.planned, &self.refined) {
                    self.dirty.insert(key);
                }
            }
            self.failed.retain(|key| forest.wanted.contains(key));
            self.forest = forest;
            self.epoch = plan.epoch;
            self.content = content;
            self.colors = colors;
            self.descriptors = descriptors;
        }
        let allowance = self.forest.allowance(view, plan.mesh_bytes, &self.ready);
        if self.forest.budget != allowance {
            self.failed.clear();
            self.forest.budget = allowance;

            if self.ready.values().sum::<usize>() > plan.mesh_bytes {
                self.ready.clear();
            }
            self.ready_neighbors
                .retain(|key, _| self.ready.contains_key(key));
            self.dirty.retain(|key| self.ready.contains_key(key));
        }
        self.degraded.retain(|key, _| self.ready.contains_key(key));
        self.ready_dependencies
            .retain(|key, _| self.ready.contains_key(key));
        let all_known = self
            .forest
            .wanted
            .iter()
            .all(|key| view.tiles.contains_key(key));
        for (&key, &previous_allowance) in &self.degraded {
            // Doubling bounds churn while summaries arrive. Once every wanted
            // tile is known, use the final allowance even below that threshold.
            // A still-degraded result records this allowance and cannot repeat.
            if allowance > previous_allowance
                && (all_known || allowance >= previous_allowance.saturating_mul(2))
            {
                self.dirty.insert(key);
            }
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
            if result.generation != self.generation
                || !self.forest.wanted.contains(&result.key)
                || result.neighbors != neighbor_keys(result.key, &self.planned, &self.refined)
                || !current_dependencies(view, &result.dependencies)
            {
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
                    if mesh.side < 32 {
                        self.degraded.insert(result.key, result.budget);
                    } else {
                        self.degraded.remove(&result.key);
                    }
                    self.ready_neighbors.insert(result.key, result.neighbors);
                    self.ready_dependencies
                        .insert(result.key, result.dependencies);
                    self.dirty.remove(&result.key);
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
            let key = node.key;
            if !self.forest.wanted.contains(&key)
                || (self.ready.contains_key(&key) && !self.dirty.contains(&key))
                || self.failed.contains(&key)
            {
                continue;
            }
            let Some(tile) = view.tiles.get(&key) else {
                continue;
            };
            let Some(revision) = view.revision(key) else {
                continue;
            };
            if tile.occupied() == 0 {
                // Empty immutable data needs no neighbor read or mesh job.
                // Clear old GPU geometry while retaining any retired job slot.
                self.ready.insert(key, 0);
                self.ready_dependencies.insert(key, vec![(key, revision)]);
                self.ready_neighbors
                    .insert(key, neighbor_keys(key, &self.planned, &self.refined));
                self.degraded.remove(&key);
                self.dirty.remove(&key);
                let upload_start = Instant::now();
                upload(
                    key,
                    Mesh {
                        vertices: Vec::new(),
                        side: 32,
                    },
                );
                self.stats.upload_ms += upload_start.elapsed().as_secs_f64() * 1000.0;
                continue;
            }
            if self.in_flight.len() >= WORKERS || self.in_flight.contains_key(&key) {
                continue;
            }
            let neighbor_keys = neighbor_keys(key, &self.planned, &self.refined);
            let Some(dependencies) = dependencies(view, key, &neighbor_keys) else {
                continue;
            };
            let neighbors = neighbor_keys
                .iter()
                .map(|(key, opaque_occlusion)| {
                    view.tiles.get(key).map(|tile| mesh::Neighbor {
                        tile: Arc::clone(tile),
                        opaque_occlusion: *opaque_occlusion,
                    })
                })
                .collect::<Option<Vec<_>>>();
            let Some(neighbors) = neighbors else {
                continue;
            };
            let job = Job {
                tile: Arc::clone(tile),
                generation: self.generation,
                colors: Arc::clone(&self.colors),
                descriptors: Arc::clone(&self.descriptors),
                water: Arc::clone(&self.water),
                budget: self.forest.budget,
                neighbors,
                dependencies,
            };
            self.sender
                .as_ref()
                .unwrap()
                .try_send(job)
                .expect("scenery work admission bound");
            self.in_flight.insert(key, self.generation);
        }
        debug_assert!(self.ready.values().sum::<usize>() <= plan.mesh_bytes);
        // Old neighboring meshes can still have walls removed by this parent.
        // Complete children may replace it only after those boundaries are safe.
        let blocked = self
            .dirty
            .iter()
            .filter_map(|key| self.ready_neighbors.get(key))
            .flat_map(|neighbors| neighbors.iter())
            .filter_map(|(key, opaque_occlusion)| {
                (*opaque_occlusion && self.refined.contains(key)).then_some(*key)
            })
            .collect();
        let selected = self.forest.selected(&self.ready, &blocked);
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
#[path = "pipeline_quality_tests.rs"]
mod quality_tests;

#[cfg(test)]
#[path = "pipeline_edit_tests.rs"]
mod edit_tests;

#[cfg(test)]
mod tests {
    use super::*;
    fn plan(budget: usize) -> Plan {
        let parent = TileKey::new([-1, 0, -1], 2).unwrap();
        Plan {
            revisions: None,
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
    fn decoded_empty_siblings_complete_without_jobs_but_missing_data_keeps_the_parent() {
        let mut view = View::default();
        view.replace(plan(1 << 20));
        let nodes = &view.plan.as_ref().unwrap().nodes;
        let parent = nodes[0].key;
        let missing = nodes[8].key;
        for node in &nodes[..8] {
            view.tiles
                .insert(node.key, Arc::new(LodTile::uniform(node.key, 0)));
        }
        let mut pipeline = Pipeline::new();
        let world = VoxelWorld::default();
        let mut cleared = Vec::new();
        let selected = pipeline.update(&view, &world, |key, mesh| {
            assert!(mesh.vertices.is_empty());
            cleared.push(key);
        });
        assert_eq!(selected, vec![parent]);
        assert_eq!(pipeline.ready.len(), 8);
        assert_eq!(cleared.len(), 8);
        assert_eq!(pipeline.in_flight(), 0);
        assert_eq!(pipeline.stats.uploads, 0);
        view.tiles
            .insert(missing, Arc::new(LodTile::uniform(missing, 0)));
        let selected = pipeline.update(&view, &world, |key, mesh| {
            assert_eq!(key, missing);
            assert!(mesh.vertices.is_empty());
        });
        assert_eq!(selected.len(), 8);
        assert!(!selected.contains(&parent));
        assert_eq!(pipeline.ready.len(), 9);
        assert_eq!(pipeline.in_flight(), 0);
    }

    #[test]
    fn empty_tiles_do_not_wait_for_neighbors_or_displace_occupied_jobs() {
        let keys = [0, 1, 4, 8].map(|x| TileKey::new([x, 0, 0], 2).unwrap());
        let mut p = plan(1 << 20);
        p.nodes = keys
            .iter()
            .map(|&key| Node {
                key,
                children: vec![],
            })
            .collect();
        p.roots = (0..keys.len()).collect();
        let mut view = View::default();
        view.replace(p);
        for (key, material) in [(keys[0], 0), (keys[2], 42), (keys[3], 42)] {
            view.tiles
                .insert(key, Arc::new(LodTile::uniform(key, material)));
        }
        let mut pipeline = Pipeline::new();
        let selected = pipeline.update(&view, &VoxelWorld::default(), |key, mesh| {
            assert_eq!(key, keys[0]);
            assert!(mesh.vertices.is_empty());
        });
        assert_eq!(selected, vec![keys[0]]);
        assert_eq!(pipeline.ready[&keys[0]], 0);
        assert_eq!(pipeline.in_flight(), 2);
        assert!(pipeline.in_flight.contains_key(&keys[2]));
        assert!(pipeline.in_flight.contains_key(&keys[3]));
    }

    #[test]
    fn empty_new_content_clears_geometry_while_old_jobs_keep_their_slots() {
        let key = TileKey::new([0, 0, 0], 2).unwrap();
        let mut p = plan(1 << 20);
        p.nodes = vec![Node {
            key,
            children: vec![],
        }];
        p.roots = vec![0];
        let mut view = View::default();
        view.replace(p);
        view.tiles.insert(key, Arc::new(LodTile::uniform(key, 42)));
        let mut pipeline = Pipeline::new();
        let world = VoxelWorld::default();
        pipeline.update(&view, &world, |_, _| panic!("first occupied dispatch"));
        assert_eq!(pipeline.in_flight(), 1);
        let mut next = plan(1 << 20);
        next.nodes = vec![Node {
            key,
            children: vec![],
        }];
        next.roots = vec![0];
        next.epoch = 2;
        next.content = 8;
        view.replace(next);
        view.tiles.insert(key, Arc::new(LodTile::uniform(key, 0)));
        let mut cleared = 0;
        let selected = pipeline.update(&view, &world, |uploaded_key, mesh| {
            assert_eq!(uploaded_key, key);
            assert!(mesh.vertices.is_empty(), "old content cannot reappear");
            cleared += 1;
        });
        assert_eq!(selected, vec![key]);
        assert_eq!(cleared, 1);
        assert_eq!(pipeline.ready[&key], 0);
        assert!(pipeline.in_flight() <= 1);
        assert_eq!(
            pipeline.in_flight() + pipeline.stats.stale,
            1,
            "a retired slot is released only after its result is drained"
        );
        let deadline = Instant::now() + std::time::Duration::from_secs(5);
        while pipeline.in_flight() != 0 {
            assert!(Instant::now() < deadline);
            pipeline.update(&view, &world, |_, _| {
                panic!("empty geometry already cleared")
            });
            std::thread::sleep(std::time::Duration::from_millis(1));
        }
        assert_eq!(pipeline.ready[&key], 0);
        assert_eq!(pipeline.stats.uploads, 0);
    }

    #[test]
    fn known_empty_tiles_release_their_equal_mesh_allowance() {
        let mut view = View::default();
        view.replace(plan(4 << 20));
        for (i, node) in view.plan.as_ref().unwrap().nodes.iter().enumerate() {
            view.tiles.insert(
                node.key,
                Arc::new(LodTile::uniform(node.key, if i == 0 { 42 } else { 0 })),
            );
        }
        let mut pipeline = Pipeline::new();
        pipeline.update(&view, &VoxelWorld::default(), |_, mesh| {
            assert!(
                mesh.vertices.is_empty(),
                "occupied tiles still dispatch jobs"
            );
        });
        assert_eq!(
            pipeline.forest.budget, MAX_JOB_BYTES,
            "known empty tiles must not force occupied geometry to degrade"
        );
    }

    #[test]
    fn reclaimed_allowance_preserves_sparse_geometry_without_exceeding_the_view_budget() {
        let mut chunk = vec![0; wyram_core::BYTE_COUNT];
        for y in 0..16 {
            for z in 0..16 {
                for x in 0..16 {
                    if (x + y + z) % 4 == 0 {
                        let index = ((y * 16 + z) * 16 + x) * 2;
                        chunk[index..index + 2].copy_from_slice(&42u16.to_le_bytes());
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
        let mut p = plan(4 << 20);
        p.nodes = std::iter::once(Node {
            key: root,
            children: vec![],
        })
        .chain((1..=100).map(|x| Node {
            key: TileKey::new([x * 2, 0, 0], 1).unwrap(),
            children: vec![],
        }))
        .collect();
        p.roots = (0..p.nodes.len()).collect();
        let mut view = View::default();
        view.replace(p);
        let mut pipeline = Pipeline::new();
        let world = VoxelWorld::default();
        assert_eq!(
            pipeline.forest.allowance(&view, 4 << 20, &pipeline.ready),
            0
        );
        pipeline.update(&view, &world, |_, _| panic!("no tiles delivered"));
        assert_eq!(
            pipeline.forest.budget,
            (4 << 20) / 101,
            "unknown tiles still reserve space"
        );
        for node in &view.plan.as_ref().unwrap().nodes {
            view.tiles.insert(
                node.key,
                Arc::new(if node.key == root {
                    tile.clone()
                } else {
                    LodTile::uniform(node.key, 0)
                }),
            );
        }
        let deadline = Instant::now() + std::time::Duration::from_secs(5);
        let mut full_resolution = false;
        while !pipeline.ready.contains_key(&root) {
            assert!(Instant::now() < deadline);
            pipeline.update(&view, &world, |key, mesh| {
                if key == root {
                    assert_eq!(mesh.side, 32);
                    assert!(mesh.bytes() > (4 << 20) / 101);
                    full_resolution = true;
                }
            });
            assert!(pipeline.ready.values().sum::<usize>() <= 4 << 20);
            assert!(pipeline.in_flight.len() <= WORKERS);
            std::thread::sleep(std::time::Duration::from_millis(1));
        }
        assert!(full_resolution);
        let mut smaller = Plan {
            revisions: None,
            epoch: 2,
            content: 7,
            stamp: 0,
            distance: 128,
            cache_bytes: 4 << 20,
            mesh_bytes: MIN_TILE_BYTES * 101,
            roots: vec![],
            nodes: vec![],
        };
        let previous = view.plan.as_ref().unwrap();
        smaller.roots = previous.roots.clone();
        smaller.nodes = previous
            .nodes
            .iter()
            .map(|node| Node {
                key: node.key,
                children: node.children.clone(),
            })
            .collect();
        view.replace(smaller);
        pipeline.update(&view, &world, |key, mesh| {
            assert_ne!(
                key, root,
                "the smaller root replacement is not dispatched yet"
            );
            assert!(
                mesh.vertices.is_empty(),
                "other completions are empty tiles"
            );
        });
        assert!(!pipeline.ready.contains_key(&root));
        let deadline = Instant::now() + std::time::Duration::from_secs(5);
        while !pipeline.ready.contains_key(&root) {
            assert!(Instant::now() < deadline);
            pipeline.update(&view, &world, |key, mesh| {
                if key == root {
                    assert!(mesh.side < 32);
                }
            });
            assert!(pipeline.ready.values().sum::<usize>() <= MIN_TILE_BYTES * 101);
            std::thread::sleep(std::time::Duration::from_millis(1));
        }
    }

    #[test]
    fn children_wait_for_a_neighbor_to_stop_using_the_retained_parent_as_an_occluder() {
        let mut p = plan(4 << 20);
        let refined = p.nodes[0].key;
        let coarse = TileKey::new([-2, 0, -1], 2).unwrap();
        p.roots.push(p.nodes.len());
        p.nodes.push(Node {
            key: coarse,
            children: vec![],
        });
        let mut view = View::default();
        view.replace(p);
        let p = view.plan.as_ref().unwrap();
        for node in &p.nodes {
            view.tiles
                .insert(node.key, Arc::new(LodTile::uniform(node.key, 42)));
        }
        let world = VoxelWorld::default();
        let mut pipeline = Pipeline::new();
        pipeline.epoch = p.epoch;
        pipeline.content = Some((p.content, p.stamp));
        pipeline.forest = Forest::new(p);
        pipeline.planned = p.nodes.iter().map(|node| node.key).collect();
        pipeline.refined = HashSet::from([refined]);
        let palette = world.presentation();
        pipeline.colors = palette.colors;
        pipeline.descriptors = palette.descriptors;
        pipeline.ready = p.nodes.iter().map(|node| (node.key, 0)).collect();
        // All children are resident, but the coarse neighbor's old mesh still
        // hid its boundary using the parent's occupancy. Its replacement is busy.
        pipeline
            .ready_neighbors
            .insert(coarse, vec![(refined, true)]);
        pipeline.dirty.insert(coarse);
        pipeline.in_flight.insert(coarse, pipeline.generation);
        let selected = pipeline.update(&view, &world, |_, _| {
            panic!("replacement has not completed")
        });
        assert!(
            selected.contains(&refined),
            "the parent remains until its neighbor is safe"
        );
        assert_eq!(selected.len(), 2);
        pipeline.in_flight.remove(&coarse);
        pipeline
            .ready_neighbors
            .insert(coarse, vec![(refined, false)]);
        pipeline.dirty.remove(&coarse);
        let selected = pipeline.update(&view, &world, |_, _| panic!("all meshes are resident"));
        assert!(!selected.contains(&refined));
        assert_eq!(selected.len(), 9);
    }

    #[test]
    fn refining_a_neighbor_preserves_the_coarse_boundary_at_its_child_opening() {
        let coarse = TileKey::new([-1, 0, 0], 2).unwrap();
        let adjacent = TileKey::new([0, 0, 0], 2).unwrap();
        let mut data = vec![0; wyram_core::BYTE_COUNT];
        data = wyram_core::write_block(&data, 1, 1, 1, 42).unwrap();
        let air = vec![0; wyram_core::BYTE_COUNT];
        let leaves: Vec<_> = (0..8)
            .map(|i| {
                LodTile::from_chunk(
                    TileKey::new([i & 1, (i >> 1) & 1, i >> 2], 0).unwrap(),
                    if i == 0 { &data } else { &air },
                )
                .unwrap()
            })
            .collect();
        let fine = LodTile::reduce(std::array::from_fn(|i| &leaves[i])).unwrap();
        let children: Vec<_> = (0..8)
            .map(|i| {
                let key = TileKey::new([i & 1, (i >> 1) & 1, i >> 2], 1).unwrap();
                if i == 0 {
                    fine.clone()
                } else {
                    LodTile::uniform(key, 0)
                }
            })
            .collect();
        let parent = LodTile::reduce(std::array::from_fn(|i| &children[i])).unwrap();
        let mut initial = plan(4 << 20);
        initial.nodes = vec![
            Node {
                key: coarse,
                children: vec![],
            },
            Node {
                key: adjacent,
                children: vec![],
            },
        ];
        initial.roots = vec![0, 1];
        let mut view = View::default();
        view.replace(initial);
        view.tiles
            .insert(coarse, Arc::new(LodTile::uniform(coarse, 42)));
        view.tiles.insert(adjacent, Arc::new(parent));
        let world = VoxelWorld::default();
        let mut pipeline = Pipeline::new();
        let mut meshes = HashMap::new();
        let deadline = Instant::now() + std::time::Duration::from_secs(5);
        while pipeline.ready.len() < 2 {
            assert!(Instant::now() < deadline);
            pipeline.update(&view, &world, |key, mesh| {
                meshes.insert(key, mesh);
            });
            std::thread::sleep(std::time::Duration::from_millis(1));
        }
        let mut next = plan(4 << 20);
        next.epoch = 2;
        next.nodes = vec![
            Node {
                key: coarse,
                children: vec![],
            },
            Node {
                key: adjacent,
                children: (2..10).collect(),
            },
        ];
        next.nodes.extend(children.iter().map(|tile| Node {
            key: tile.key(),
            children: vec![],
        }));
        next.roots = vec![0, 1];
        view.replace(next);
        for child in children {
            view.tiles.insert(child.key(), Arc::new(child));
        }
        let deadline = Instant::now() + std::time::Duration::from_secs(5);
        loop {
            assert!(Instant::now() < deadline);
            let selected = pipeline.update(&view, &world, |key, mesh| {
                meshes.insert(key, mesh);
            });
            assert!(
                pipeline.ready.contains_key(&coarse),
                "old coverage stays during replacement"
            );
            assert!(pipeline.in_flight.len() <= WORKERS);
            assert!(pipeline.stats.uploads <= 1);
            assert!(pipeline.ready.values().sum::<usize>() <= 4 << 20);
            if selected.len() == 9 && pipeline.in_flight.is_empty() && pipeline.dirty.is_empty() {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(1));
        }
        // The selected fine solid occupies x=[1,2]; x=[0,1] is air. Its
        // retained parent can no longer justify hiding any of the x=0 wall.
        let area: f32 = meshes[&coarse]
            .vertices
            .as_chunks::<6>()
            .0
            .iter()
            .filter(|quad| quad[0].normal[0] == 127)
            .map(|quad| {
                let low = [1, 2].map(|axis| {
                    quad.iter()
                        .map(|v| v.base.position[axis])
                        .fold(f32::INFINITY, f32::min)
                });
                let high = [1, 2].map(|axis| {
                    quad.iter()
                        .map(|v| v.base.position[axis])
                        .fold(f32::NEG_INFINITY, f32::max)
                });
                (high[0] - low[0]) * (high[1] - low[1])
            })
            .sum();
        assert_eq!(
            area,
            64.0 * 64.0,
            "the selected opening exposes the entire coarse wall"
        );
    }

    #[test]
    fn planned_neighbors_arrive_before_meshing_and_camera_changes_refresh_dependencies() {
        let root = TileKey::new([0, 0, 0], 2).unwrap();
        let adjacent = TileKey::new([1, 0, 0], 2).unwrap();
        let mut view = View::default();
        let mut p = plan(1 << 20);
        p.nodes = vec![
            Node {
                key: root,
                children: vec![],
            },
            Node {
                key: adjacent,
                children: vec![],
            },
        ];
        p.roots = vec![0, 1];
        view.replace(p);
        view.tiles
            .insert(root, Arc::new(LodTile::uniform(root, 17)));
        let world = VoxelWorld::default();
        let mut pipeline = Pipeline::new();
        pipeline.update(&view, &world, |_, _| panic!("initial dispatch only"));
        assert!(
            pipeline.in_flight.is_empty(),
            "planned neighbor has not arrived"
        );
        view.tiles
            .insert(adjacent, Arc::new(LodTile::uniform(adjacent, 17)));
        let deadline = Instant::now() + std::time::Duration::from_secs(5);
        while pipeline.ready.len() < 2 {
            assert!(Instant::now() < deadline);
            pipeline.update(&view, &world, |_, _| {});
            std::thread::sleep(std::time::Duration::from_millis(1));
        }
        assert_eq!(pipeline.ready_neighbors[&root], vec![(adjacent, true)]);
        let mut next = plan(1 << 20);
        next.epoch = 2;
        next.nodes = vec![Node {
            key: root,
            children: vec![],
        }];
        next.roots = vec![0];
        view.replace(next);
        pipeline.update(&view, &world, |_, _| {
            panic!("changed view dispatches a replacement")
        });
        assert!(
            pipeline.ready.contains_key(&root),
            "old coverage remains while its wall is rebuilt"
        );
        assert!(pipeline.dirty.contains(&root));
        let deadline = Instant::now() + std::time::Duration::from_secs(5);
        while pipeline.dirty.contains(&root) {
            assert!(Instant::now() < deadline);
            pipeline.update(&view, &world, |key, mesh| {
                assert_eq!(key, root);
                assert!(mesh.vertices.iter().any(|v| v.normal[0] == 127));
            });
            std::thread::sleep(std::time::Duration::from_millis(1));
        }
        assert!(pipeline.ready_neighbors[&root].is_empty());
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
        assert_eq!(f.selected(&ready, &HashSet::new()), vec![root]);
        ready.insert(p.nodes[8].key, 0);
        let selected = f.selected(&ready, &HashSet::new());
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
