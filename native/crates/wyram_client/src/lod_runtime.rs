use crate::lod_client::{BoundarySampler, LodClient, LodEvent, SamplerFactory};
use crate::lod_coverage::{CoverageConfig, CoverageFrame, LodCoverage};
use crate::lod_mesh::{BoundaryCell, LodVertex};
use crate::lod_wire::{WireBatch, WireTile};
use crate::world::VoxelWorld;
use bytemuck::{Pod, Zeroable};
use serde::Deserialize;
use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::Arc;
use std::sync::mpsc::{self, Receiver, SyncSender};
use std::time::{Duration, Instant};
use wgpu::util::DeviceExt;
use wyram_core::lod::TileKey;

#[derive(Clone, Debug, Deserialize)]
pub struct LodConfig {
    pub protocol: u8,
    pub enabled: bool,
    pub generation_workers: usize,
    pub meshing_workers: usize,
    pub parallelism: usize,
    pub worker_budget: usize,
    pub near_radius: u32,
    pub max_cell_size: u8,
    pub min_y: i32,
    pub max_y: i32,
}

impl LodConfig {
    pub fn validate(&self) -> bool {
        self.protocol == 1
            && (1..=8).contains(&self.generation_workers)
            && (1..=8).contains(&self.meshing_workers)
            && self.parallelism > 0
            && (2..=8).contains(&self.worker_budget)
            && (1..=11).contains(&self.near_radius)
            && ((!self.enabled && self.max_cell_size == 0)
                || matches!(self.max_cell_size, 2 | 4 | 8 | 16))
            && self.min_y <= self.max_y
            && i64::from(self.max_y) - i64::from(self.min_y) < 512
            && self.min_y >= -1_000_000
            && self.max_y <= 1_000_000
    }
}

#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
pub struct CameraUniform {
    pub matrix: [f32; 16],
    pub eye: [f32; 4],
    pub fog: [f32; 4],
    pub grid: [i32; 4],
    pub anchor: [i32; 4],
}

impl CameraUniform {
    pub fn disabled(matrix: glam::Mat4) -> Self {
        Self {
            matrix: matrix.to_cols_array(),
            ..Self::zeroed()
        }
    }
}

pub const MASK_SIDE: usize = 384;
pub const MASK_BYTES: u64 = (MASK_SIDE * MASK_SIDE * 16) as u64;
// Reserve 32 MiB of the fixed distant GPU allowance for transparent indices.
pub const GPU_VERTEX_BYTES: usize = 224 * 1024 * 1024;

pub enum CoverageChange {
    View { center: [i32; 2], epoch: u64 },
    NearReady([i32; 3]),
    NearForgotten([i32; 3]),
    TileReady(TileKey),
    TileForgotten(TileKey),
}

/// Coverage bookkeeping runs away from the render thread. Both queues are fixed.
pub struct CoverageWorker {
    commands: SyncSender<Vec<CoverageChange>>,
    frames: Receiver<CoverageFrame>,
}

impl CoverageWorker {
    pub fn new(config: &LodConfig, start: Instant) -> Result<Self, &'static str> {
        let mut coverage = LodCoverage::new(CoverageConfig {
            near_radius_chunks: config.near_radius,
            max_cell_size: config.max_cell_size,
            min_y_chunk: config.min_y.div_euclid(16),
            max_y_chunk: config.max_y.div_euclid(16),
            columns_per_side: MASK_SIDE,
            frontier_fade_fraction: 0.2,
            transition_seconds: 0.2,
            promotion_buffer_chunks: 2,
            demotion_buffer_chunks: 2,
        })?;
        let (commands, receiver) = mpsc::sync_channel::<Vec<CoverageChange>>(64);
        let (sender, frames) = mpsc::sync_channel(1);
        std::thread::spawn(move || {
            let mut changed = false;
            let mut last_frontier = -1.0f32;
            loop {
                match receiver.recv_timeout(Duration::from_millis(16)) {
                    Ok(batch) => {
                        let now = start.elapsed().as_secs_f32();
                        for change in batch {
                            match change {
                                CoverageChange::View { center, epoch } => {
                                    coverage.set_view(center, now, epoch)
                                }
                                CoverageChange::NearReady(key) => {
                                    coverage.mark_near_ready(key, now)
                                }
                                CoverageChange::NearForgotten(key) => {
                                    coverage.forget_near(key, now)
                                }
                                CoverageChange::TileReady(key) => {
                                    coverage.mark_tile_ready(key, now)
                                }
                                CoverageChange::TileForgotten(key) => {
                                    coverage.forget_tile(key, now)
                                }
                            }
                        }
                        changed = true;
                    }
                    Err(mpsc::RecvTimeoutError::Timeout) => {}
                    Err(mpsc::RecvTimeoutError::Disconnected) => break,
                }
                let frame = coverage.frame(start.elapsed().as_secs_f32());
                if changed || (frame.frontier_radius_blocks - last_frontier).abs() > 0.05 {
                    let frontier = frame.frontier_radius_blocks;
                    if sender.try_send(frame.clone()).is_ok() {
                        changed = false;
                        last_frontier = frontier;
                    }
                }
            }
        });
        Ok(Self { commands, frames })
    }

    pub fn send(&self, changes: Vec<CoverageChange>) -> Result<(), Vec<CoverageChange>> {
        if changes.is_empty() {
            return Ok(());
        }
        match self.commands.try_send(changes) {
            Ok(()) => Ok(()),
            Err(mpsc::TrySendError::Full(changes) | mpsc::TrySendError::Disconnected(changes)) => {
                Err(changes)
            }
        }
    }

    pub fn frame(&self) -> Option<CoverageFrame> {
        self.frames.try_recv().ok()
    }
}

pub struct GpuPart {
    pub opaque: Option<(wgpu::Buffer, u32)>,
    pub blended: Option<(wgpu::Buffer, u32)>,
    pub blended_centers: Vec<glam::Vec3>,
}

impl GpuPart {
    fn upload(device: &wgpu::Device, vertices: &[LodVertex]) -> Self {
        let make = |blended| {
            let vertices: Vec<_> = vertices
                .iter()
                .filter(|v| (v.opacity < 1.0) == blended)
                .copied()
                .collect();
            (!vertices.is_empty()).then(|| {
                let buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
                    label: Some("LOD bounded mesh part"),
                    contents: bytemuck::cast_slice(&vertices),
                    usage: wgpu::BufferUsages::VERTEX,
                });
                (buffer, vertices.len() as u32)
            })
        };
        let blended_centers = vertices
            .as_chunks::<6>()
            .0
            .iter()
            .filter(|quad| quad[0].opacity < 1.0)
            .map(|quad| {
                (glam::Vec3::from_array(quad[0].position)
                    + glam::Vec3::from_array(quad[2].position))
                    * 0.5
            })
            .collect();
        Self {
            opaque: make(false),
            blended: make(true),
            blended_centers,
        }
    }
}

pub struct LodRuntime {
    pub config: LodConfig,
    pub client: LodClient<GpuPart>,
    pub coverage_frame: Option<CoverageFrame>,
    pub center: [i32; 3],
    pub epoch: u64,
    pub start: Instant,
    serial: u64,
    plan: Vec<TileKey>,
    wanted: HashSet<TileKey>,
    coverage: CoverageWorker,
    changes: Vec<CoverageChange>,
    pending: VecDeque<(u64, WireTile)>,
    remesh: VecDeque<TileKey>,
    remesh_set: HashSet<TileKey>,
    sources: HashMap<TileKey, u64>,
    contexts: HashMap<TileKey, MeshContext>,
    geometry_current: HashSet<TileKey>,
    held_coverage: HashSet<TileKey>,
    meshing: HashMap<TileKey, usize>,
    needs: HashSet<TileKey>,
    stale_acks: Vec<(u64, TileKey, u64, bool)>,
    pressure_retry: Instant,
    transported: HashSet<(u64, TileKey, u64)>,
}

type MeshContext = ([i32; 3], Vec<(TileKey, Option<u64>)>);

impl LodRuntime {
    pub fn new(config: LodConfig, start: Instant) -> Result<Self, String> {
        let coverage = CoverageWorker::new(&config, start).map_err(str::to_string)?;
        let client = LodClient::new(config.meshing_workers).map_err(|e| format!("{e:?}"))?;
        Ok(Self {
            config,
            client,
            coverage_frame: None,
            center: [0; 3],
            epoch: 0,
            start,
            serial: 0,
            plan: Vec::new(),
            wanted: HashSet::new(),
            coverage,
            changes: Vec::new(),
            pending: VecDeque::new(),
            remesh: VecDeque::new(),
            remesh_set: HashSet::new(),
            sources: HashMap::new(),
            contexts: HashMap::new(),
            geometry_current: HashSet::new(),
            held_coverage: HashSet::new(),
            meshing: HashMap::new(),
            needs: HashSet::new(),
            stale_acks: Vec::new(),
            pressure_retry: start,
            transported: HashSet::new(),
        })
    }

    pub fn set_plan(
        &mut self,
        epoch: u64,
        serial: u64,
        center: [i32; 3],
        keys: Vec<TileKey>,
        world: &mut VoxelWorld,
    ) {
        if epoch < self.epoch || (epoch == self.epoch && serial <= self.serial) {
            return;
        }
        let old_center = self.center;
        let teleport = epoch != self.epoch;
        if teleport {
            self.coverage_frame = None;
            self.remesh.clear();
            self.remesh_set.clear();
            self.sources.clear();
            self.contexts.clear();
            self.geometry_current.clear();
            self.held_coverage.clear();
            self.needs.clear();
            for (old_epoch, tile) in self.pending.drain(..) {
                self.stale_acks
                    .push((old_epoch, tile.key, tile.revision, false));
            }
        }
        self.epoch = epoch;
        self.serial = serial;
        self.center = center;
        self.plan = keys;
        self.wanted = self.plan.iter().copied().collect();
        self.client.set_plan(epoch, &self.plan);
        world.set_render_circle([center[0], center[2]], self.config.near_radius as i32);
        self.changes.push(CoverageChange::View {
            center: [center[0], center[2]],
            epoch,
        });
        if !teleport && [center[0], center[2]] != [old_center[0], old_center[2]] {
            let keys: Vec<_> = self
                .client
                .residents()
                .map(|r| r.key)
                .filter(|key| {
                    self.wanted.contains(key)
                        && (boundary_tile(*key, old_center, &self.config)
                            || boundary_tile(*key, center, &self.config))
                })
                .collect();
            for key in keys {
                self.queue_remesh(key);
            }
        }
        // Retain one extra tile beyond the prefetched ring; fixed GPU/cache budgets still apply.
        let evicted: Vec<_> = self
            .client
            .residents()
            .map(|r| r.key)
            .filter(|key| !self.wanted.contains(key) && !retained_tile(*key, center, &self.config))
            .collect();
        for key in evicted {
            self.client.evict(key);
            self.sources.remove(&key);
            self.contexts.remove(&key);
            self.geometry_current.remove(&key);
            self.held_coverage.remove(&key);
            self.changes.push(CoverageChange::TileForgotten(key));
        }
    }

    pub fn receive(&mut self, batch: WireBatch) -> Vec<(u64, TileKey, u64, bool)> {
        let mut rejected = Vec::new();
        for tile in batch.tiles {
            if batch.epoch != self.epoch
                || !self.wanted.contains(&tile.key)
                || self.pending.len() >= 8
            {
                rejected.push((batch.epoch, tile.key, tile.revision, false));
            } else {
                self.transported
                    .insert((batch.epoch, tile.key, tile.revision));
                self.pending.push_back((batch.epoch, tile));
            }
        }
        rejected
    }

    pub fn invalidate(&mut self, epoch: u64, tiles: &[(u8, i32, i32, i32, u64)]) {
        if epoch != self.epoch {
            return;
        }
        for &(size, x, y, z, _) in tiles {
            if let Ok(key) = TileKey::new(size, [x, y, z]) {
                self.client.invalidate(key);
                self.sources.remove(&key);
                self.geometry_current.remove(&key);
                let dependents: Vec<_> = self
                    .contexts
                    .iter()
                    .filter(|(_, (_, deps))| deps.iter().any(|(dep, _)| *dep == key))
                    .map(|(other, _)| *other)
                    .collect();
                for dependent in dependents {
                    self.queue_remesh(dependent);
                }
            }
        }
    }

    pub fn near_ready(&mut self, key: [i32; 3]) {
        self.changes.push(CoverageChange::NearReady(key));
    }
    pub fn forget_near(&mut self, key: [i32; 3]) {
        self.changes.push(CoverageChange::NearForgotten(key));
    }

    pub fn update(
        &mut self,
        world: &VoxelWorld,
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        mask: &wgpu::Buffer,
        near_busy: bool,
    ) -> Vec<(u64, TileKey, u64, bool)> {
        let mut acks = std::mem::take(&mut self.stale_acks);
        let upload_start = Instant::now();
        let mut bytes = 0;
        for _ in 0..8 {
            if upload_start.elapsed() >= Duration::from_millis(1) {
                break;
            }
            let Some(part) = self.client.poll_parts(1, 1024 * 1024 - bytes).pop() else {
                break;
            };
            let part_bytes = part.part.vertices.len() * size_of::<LodVertex>();
            if self
                .client
                .gpu_bytes()
                .saturating_add(self.client.reserved_gpu_bytes())
                .saturating_add(part_bytes)
                > GPU_VERTEX_BYTES
                || self.client.reserve_upload(part.ticket).is_err()
            {
                // Outer retained data can be discarded under pressure; detail never changes.
                let victim = self
                    .client
                    .residents()
                    .filter(|r| {
                        r.key != part.key
                            && !r.parts.is_empty()
                            && (!self.wanted.contains(&r.key)
                                || tile_distance(r.key, self.center)
                                    > tile_distance(part.key, self.center))
                    })
                    .max_by_key(|r| tile_distance(r.key, self.center))
                    .map(|r| r.key);
                if let Some(key) = victim {
                    self.client.evict(key);
                    self.changes.push(CoverageChange::TileForgotten(key));
                }
                if victim.is_some() {
                    self.client.defer_part(part.ticket).ok();
                } else {
                    self.client
                        .reject_part(part.ticket, crate::lod_client::LodError::GpuBudgetExceeded)
                        .ok();
                }
                break;
            }
            bytes += part.part.vertices.len() * size_of::<LodVertex>();
            let handle = GpuPart::upload(device, &part.part.vertices);
            self.client.ack_part(part.ticket, handle).ok();
        }
        for event in self.client.drain_events(16) {
            match event {
                LodEvent::Ready {
                    epoch,
                    key,
                    revision,
                } => {
                    self.finish_mesh(key);
                    if epoch != self.epoch {
                        acks.push((epoch, key, revision, false));
                        continue;
                    }
                    let current = self
                        .contexts
                        .get(&key)
                        .is_some_and(|(center, dependencies)| {
                            geometry_context_current(
                                *center,
                                self.center,
                                dependencies,
                                &self.sources,
                            )
                        });
                    if current {
                        self.geometry_current.insert(key);
                    } else {
                        self.geometry_current.remove(&key);
                    }
                    self.held_coverage.insert(key);
                    acks.push((epoch, key, revision, true));
                }
                LodEvent::Rejected {
                    epoch,
                    key,
                    revision,
                    reason,
                } => {
                    self.finish_mesh(key);
                    if epoch == self.epoch
                        && self.wanted.contains(&key)
                        && reason == crate::lod_client::LodError::GpuBudgetExceeded
                        && !self.transported.contains(&(epoch, key, revision))
                    {
                        self.queue_remesh(key);
                        self.pressure_retry = Instant::now() + Duration::from_millis(100);
                    }
                    acks.push((epoch, key, revision, false));
                }
                LodEvent::Completed { .. } => {}
                LodEvent::Dropped { key, .. } => {
                    self.coverage_dropped(key);
                }
            }
        }
        let revealed: Vec<_> = self
            .held_coverage
            .iter()
            .copied()
            .filter(|key| {
                self.contexts.get(key).is_some_and(|(_, dependencies)| {
                    coverage_dependencies_ready(
                        key.cell_size,
                        dependencies,
                        &self.geometry_current,
                        &self.sources,
                    )
                })
            })
            .collect();
        for key in revealed {
            self.held_coverage.remove(&key);
            self.changes.push(CoverageChange::TileReady(key));
        }
        if !near_busy && self.client.running_jobs() < 8 && Instant::now() >= self.pressure_retry {
            let work = self.pending.pop_front().or_else(|| {
                while let Some(key) = self.remesh.pop_front() {
                    self.remesh_set.remove(&key);
                    if !self.wanted.contains(&key) {
                        continue;
                    }
                    if self.meshing.get(&key).copied().unwrap_or(0) > 0 {
                        self.queue_remesh(key);
                        break;
                    }
                    if let Some((revision, payload)) = self.client.cached_tile(key) {
                        return Some((
                            self.epoch,
                            WireTile {
                                key,
                                revision,
                                payload: payload.as_ref().clone(),
                            },
                        ));
                    }
                    self.needs.insert(key);
                }
                None
            });
            if let Some((epoch, tile)) = work {
                let key = tile.key;
                let revision = tile.revision;
                let bounds = key.origin().expect("validated tile");
                let halo = i32::from(key.cell_size);
                let low = bounds.map(|v| v - halo);
                let high = bounds.map(|v| v + key.span() + halo - 1);
                let snapshot = world.lod_near_snapshot(low, high);
                let near: Arc<BoundarySampler> = Arc::new(move |p| snapshot.lod_boundary_cell(p));
                let neighbor_keys = required_neighbors(key, self.center, &self.config);
                if neighbor_keys.len() > 64 {
                    eprintln!("LOD seam neighborhood exceeds the fixed 64-tile bound");
                    acks.push((epoch, key, revision, false));
                    return self.filter_transport_acks(acks);
                }
                let neighbors = self
                    .client
                    .encoded_snapshot(&neighbor_keys)
                    .expect("bounded neighbor list");
                let center = self.center;
                let config = self.config.clone();
                let factory: Arc<SamplerFactory> = Arc::new(move |tile, neighbors, near| {
                    let own = Arc::new(tile.clone());
                    let neighbors = neighbors.clone();
                    let config = config.clone();
                    Arc::new(move |p| {
                        let size = requested_size(
                            [p[0].div_euclid(16), p[2].div_euclid(16)],
                            center,
                            &config,
                        );
                        if size == 1 {
                            return near(p);
                        }
                        if size == 0 {
                            return Some(BoundaryCell {
                                origin: p,
                                size: 1,
                                cell: Default::default(),
                            });
                        }
                        let span = i32::from(size) * 32;
                        let neighbor_key =
                            TileKey::new(size, p.map(|v| v.div_euclid(span))).ok()?;
                        let tile = if size == own.key.cell_size {
                            &own
                        } else {
                            neighbors.get(&neighbor_key)?
                        };
                        let cell = tile.sample(p)?;
                        Some(BoundaryCell {
                            origin: p.map(|v| v.div_euclid(i32::from(size)) * i32::from(size)),
                            size,
                            cell,
                        })
                    })
                });
                let (colors, descriptors) = world.lod_materials();
                let newly_cached = self.sources.get(&key) != Some(&revision);
                for dep in &neighbor_keys {
                    if !neighbors.contains_key(dep) && self.sources.contains_key(dep) {
                        self.needs.insert(*dep);
                    }
                }
                let dependencies = neighbor_keys
                    .into_iter()
                    .map(|dep| {
                        let revision = if neighbors.contains_key(&dep) {
                            self.sources.get(&dep).copied()
                        } else {
                            None
                        };
                        (dep, revision)
                    })
                    .collect();
                if let Err(error) = self.client.submit(
                    WireBatch {
                        epoch,
                        tiles: vec![tile],
                    },
                    colors,
                    descriptors,
                    neighbors,
                    near,
                    factory,
                ) {
                    eprintln!("LOD tile admission rejected: {error:?}");
                    acks.push((epoch, key, revision, false));
                } else {
                    *self.meshing.entry(key).or_default() += 1;
                    self.contexts.insert(key, (self.center, dependencies));
                    if newly_cached {
                        self.sources.insert(key, revision);
                        let dependents: Vec<_> = self
                            .contexts
                            .iter()
                            .filter(|(other, (_, deps))| {
                                self.wanted.contains(other)
                                    && deps.iter().any(|(dep, _)| *dep == key)
                            })
                            .map(|(other, _)| *other)
                            .collect();
                        for dependent in dependents {
                            self.queue_remesh(dependent);
                        }
                    }
                }
            }
        }
        if let Some(frame) = self.coverage.frame()
            && frame.epoch == self.epoch
            && frame.center_chunk == [self.center[0], self.center[2]]
        {
            queue.write_buffer(mask, 0, bytemuck::cast_slice(&frame.columns));
            self.coverage_frame = Some(frame);
        }
        let changes = std::mem::take(&mut self.changes);
        if let Err(changes) = self.coverage.send(changes) {
            self.changes = changes;
        }
        self.filter_transport_acks(acks)
    }

    pub fn pending_tiles(&self) -> usize {
        self.pending.len() + self.remesh.len()
    }

    fn coverage_dropped(&mut self, key: TileKey) {
        self.geometry_current.remove(&key);
        self.held_coverage.remove(&key);
        self.changes.push(CoverageChange::TileForgotten(key));
        if self.wanted.contains(&key) {
            self.queue_remesh(key);
        }
    }

    fn queue_remesh(&mut self, key: TileKey) {
        self.geometry_current.remove(&key);
        if self.remesh_set.insert(key) {
            self.remesh.push_back(key);
        }
    }

    fn finish_mesh(&mut self, key: TileKey) {
        if let Some(count) = self.meshing.get_mut(&key) {
            *count = count.saturating_sub(1);
        }
    }

    pub fn drain_needs(&mut self) -> Vec<TileKey> {
        let keys: Vec<_> = self.needs.iter().copied().take(16).collect();
        for key in &keys {
            self.needs.remove(key);
        }
        keys
    }

    pub fn restore_needs(&mut self, epoch: u64, keys: impl IntoIterator<Item = TileKey>) {
        if epoch != self.epoch {
            return;
        }
        for key in keys {
            if self.wanted.contains(&key) {
                self.needs.insert(key);
            }
        }
    }

    fn filter_transport_acks(
        &mut self,
        acks: Vec<(u64, TileKey, u64, bool)>,
    ) -> Vec<(u64, TileKey, u64, bool)> {
        acks.into_iter()
            .filter(|(epoch, key, revision, _)| self.transported.remove(&(*epoch, *key, *revision)))
            .collect()
    }
}

fn coverage_dependencies_ready(
    size: u8,
    dependencies: &[(TileKey, Option<u64>)],
    geometry_current: &HashSet<TileKey>,
    sources: &HashMap<TileKey, u64>,
) -> bool {
    dependencies.iter().all(|(dep, revision)| {
        dep.cell_size >= size
            || (revision.is_some()
                && sources.get(dep).copied() == *revision
                && geometry_current.contains(dep))
    })
}

fn geometry_context_current(
    old_center: [i32; 3],
    center: [i32; 3],
    dependencies: &[(TileKey, Option<u64>)],
    sources: &HashMap<TileKey, u64>,
) -> bool {
    [old_center[0], old_center[2]] == [center[0], center[2]]
        && dependencies
            .iter()
            .all(|(dep, revision)| revision.is_some() && sources.get(dep).copied() == *revision)
}

fn required_neighbors(key: TileKey, center: [i32; 3], config: &LodConfig) -> Vec<TileKey> {
    let span = i32::from(key.cell_size) * 2;
    let low = [key.position[0] * span, key.position[2] * span];
    let high = low.map(|v| v + span - 1);
    let origin = key.origin().expect("validated tile");
    let halo = i32::from(key.cell_size);
    let mut keys = HashSet::new();
    for x in low[0] - 1..=high[0] + 1 {
        for z in low[1] - 1..=high[1] + 1 {
            let size = requested_size([x, z], center, config);
            if size < 2 || size == key.cell_size {
                continue;
            }
            let touches = [[-1, 0], [1, 0], [0, -1], [0, 1]].into_iter().any(|d| {
                let p = [x + d[0], z + d[1]];
                (low[0]..=high[0]).contains(&p[0])
                    && (low[1]..=high[1]).contains(&p[1])
                    && requested_size(p, center, config) == key.cell_size
            });
            if !touches {
                continue;
            }
            let blocks = i32::from(size) * 32;
            for y in (origin[1] - halo).max(config.min_y).div_euclid(blocks)
                ..=(origin[1] + key.span() + halo - 1)
                    .min(config.max_y)
                    .div_euclid(blocks)
            {
                if let Ok(dep) = TileKey::new(
                    size,
                    [
                        x.div_euclid(i32::from(size) * 2),
                        y,
                        z.div_euclid(i32::from(size) * 2),
                    ],
                ) {
                    keys.insert(dep);
                }
            }
        }
    }
    let mut keys: Vec<_> = keys.into_iter().collect();
    keys.sort_by_key(|k| (k.cell_size, k.position));
    keys
}

fn requested_size(column: [i32; 2], center: [i32; 3], config: &LodConfig) -> u8 {
    let dx = i64::from(column[0]) - i64::from(center[0]);
    let dz = i64::from(column[1]) - i64::from(center[2]);
    let distance = dx * dx + dz * dz;
    for size in [1, 2, 4, 8, 16] {
        if size > config.max_cell_size {
            break;
        }
        let radius = i64::from(config.near_radius) * i64::from(size);
        if distance <= radius * radius {
            return size;
        }
    }
    0
}

fn tile_distance(key: TileKey, center: [i32; 3]) -> i64 {
    let span = i64::from(key.cell_size) * 2;
    let dx = i64::from(key.position[0]) * span + span / 2 - i64::from(center[0]);
    let dz = i64::from(key.position[2]) * span + span / 2 - i64::from(center[2]);
    dx * dx + dz * dz
}

fn retained_tile(key: TileKey, center: [i32; 3], config: &LodConfig) -> bool {
    let radius = i64::from(config.near_radius) * i64::from(config.max_cell_size)
        + 2
        + i64::from(key.cell_size) * 2;
    tile_distance(key, center) <= radius * radius
}

fn boundary_tile(key: TileKey, center: [i32; 3], config: &LodConfig) -> bool {
    let span = i32::from(key.cell_size) * 2;
    let low = [
        key.position[0] * span - center[0],
        key.position[2] * span - center[2],
    ];
    let high = low.map(|v| v + span - 1);
    let min: i64 = (0..2)
        .map(|i| {
            if low[i] > 0 {
                i64::from(low[i])
            } else if high[i] < 0 {
                i64::from(high[i])
            } else {
                0
            }
        })
        .map(|v| v * v)
        .sum();
    let max: i64 = (0..2)
        .map(|i| i64::from(low[i].abs().max(high[i].abs())))
        .map(|v| v * v)
        .sum();
    [1, 2, 4, 8]
        .into_iter()
        .filter(|size| *size < config.max_cell_size)
        .any(|size| {
            let radius = i64::from(config.near_radius) * i64::from(size);
            min <= (radius + 2) * (radius + 2) && max >= (radius - 2).max(0).pow(2)
        })
}

#[cfg(test)]
#[path = "lod_runtime_tests.rs"]
mod integration_tests;

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn config_and_camera_match_the_negotiated_fixed_bounds() {
        assert_eq!(size_of::<CameraUniform>(), 128);
        let mut config = LodConfig {
            protocol: 1,
            enabled: true,
            generation_workers: 4,
            meshing_workers: 4,
            parallelism: 22,
            worker_budget: 8,
            near_radius: 11,
            max_cell_size: 2,
            min_y: -192,
            max_y: 319,
        };
        assert!(config.validate());
        config.max_cell_size = 32;
        assert!(!config.validate());
        config.max_cell_size = 0;
        assert!(!config.validate());
        config.enabled = false;
        assert!(config.validate());
        config.meshing_workers = 9;
        assert!(!config.validate());
    }
}
