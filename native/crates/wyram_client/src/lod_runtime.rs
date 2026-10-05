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
                let had_deferred_updates = coverage.has_deferred_updates();
                let frame = coverage.frame(start.elapsed().as_secs_f32());
                if changed
                    || had_deferred_updates
                    || (frame.frontier_radius_blocks - last_frontier).abs() > 0.05
                {
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
    pub coverage_frame: Option<Arc<CoverageFrame>>,
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
    near_ready: HashSet<[i32; 3]>,
    geometry_current: HashSet<TileKey>,
    held_coverage: HashSet<TileKey>,
    meshing: HashMap<TileKey, usize>,
    needs: HashSet<TileKey>,
    stale_acks: Vec<(u64, TileKey, u64, bool)>,
    pressure_retry: Instant,
    transported: HashSet<(u64, TileKey, u64)>,
}

struct MeshContext {
    center: [i32; 3],
    dependencies: Vec<(TileKey, Option<u64>)>,
    near_dependencies: Arc<std::sync::Mutex<HashMap<[i32; 3], bool>>>,
}

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
            near_ready: HashSet::new(),
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
            self.near_ready.clear();
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
        world.set_render_circle(
            [center[0], center[2]],
            near_prefetch_radius(self.config.near_radius),
        );
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
            .filter(|key| {
                !self.wanted.contains(key)
                    && !retained_tile(*key, center, &self.config)
                    && !self.tile_pinned(*key)
            })
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
                    .filter(|(_, context)| {
                        context
                            .dependencies
                            .iter()
                            .any(|(dep, revision)| *dep == key && revision.is_some())
                    })
                    .map(|(other, _)| *other)
                    .collect();
                for dependent in dependents {
                    self.queue_remesh(dependent);
                }
            }
        }
    }

    pub fn near_ready(&mut self, key: [i32; 3]) {
        if self.near_ready.insert(key) {
            self.changes.push(CoverageChange::NearReady(key));
            self.queue_near_dependents(key);
        }
    }
    pub fn forget_near(&mut self, key: [i32; 3]) {
        if self.near_ready.remove(&key) {
            self.changes.push(CoverageChange::NearForgotten(key));
            self.queue_near_dependents(key);
        }
    }

    pub fn near_replacement_ready(&self, chunk: [i32; 3]) -> bool {
        let dx = i64::from(chunk[0]) - i64::from(self.center[0]);
        let dz = i64::from(chunk[2]) - i64::from(self.center[2]);
        if dx * dx + dz * dz <= i64::from(self.config.near_radius).pow(2) {
            return false;
        }
        let size = requested_size([chunk[0], chunk[2]], self.center, &self.config);
        if size == 0 {
            return true;
        }
        if size < 2 {
            return false;
        }
        let span_chunks = i32::from(size) * 2;
        let tile_x = chunk[0].div_euclid(span_chunks);
        let tile_z = chunk[2].div_euclid(span_chunks);
        (self.config.min_y.div_euclid(size as i32 * 32)
            ..=self.config.max_y.div_euclid(size as i32 * 32))
            .all(|tile_y| {
                let Ok(key) = TileKey::new(size, [tile_x, tile_y, tile_z]) else {
                    return false;
                };
                self.client
                    .resident(key)
                    .is_some_and(|resident| self.sources.get(&key) == Some(&resident.revision))
            })
    }

    pub fn near_geometry_pinned(&self, chunk: [i32; 3]) -> bool {
        let Some(frame) = self.coverage_frame.as_deref() else {
            return self.near_ready.contains(&chunk)
                && near_chunk_protected(chunk, self.center, self.config.near_radius);
        };
        let protected = near_chunk_protected(chunk, self.center, self.config.near_radius);
        let column = coverage_column(frame, [chunk[0], chunk[2]]);
        let near_bit = chunk[1] - self.config.min_y.div_euclid(16);
        let mask_ready = column.is_some_and(|column| {
            (0..32).contains(&near_bit) && column[3].to_bits() & (1u32 << near_bit) != 0
        });
        let Some(column) = column else {
            return false;
        };
        let current = column[0].round() as u8;
        let previous = column[1].round() as u8;
        let old_near_active = previous == 1
            && previous != current
            && self.start.elapsed().as_secs_f32() >= column[2]
            && self.start.elapsed().as_secs_f32() - column[2] < 0.2;
        (protected && mask_ready) || current == 1 || old_near_active
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
                let now = self.start.elapsed().as_secs_f32();
                let victim = self
                    .client
                    .residents()
                    .filter(|r| {
                        r.key != part.key
                            && !r.parts.is_empty()
                            && !self.wanted.contains(&r.key)
                            && !self
                                .coverage_frame
                                .as_ref()
                                .is_some_and(|frame| coverage_pins_tile(r.key, frame, now))
                    })
                    .max_by_key(|r| tile_distance(r.key, self.center))
                    .map(|r| r.key);
                if let Some(key) = victim {
                    self.client.evict(key);
                    self.changes.push(CoverageChange::TileForgotten(key));
                }
                self.client.defer_part(part.ticket).ok();
                self.pressure_retry = Instant::now() + Duration::from_millis(100);
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
                    self.queue_stale_dependents(key, revision);
                    if epoch != self.epoch {
                        acks.push((epoch, key, revision, false));
                        continue;
                    }
                    let current = self.contexts.get(&key).is_some_and(|context| {
                        geometry_context_current(
                            context.center,
                            self.center,
                            &context.dependencies,
                            &self.sources,
                        ) && !self.context_near_stale(context)
                    });
                    if current {
                        self.geometry_current.insert(key);
                    } else {
                        self.geometry_current.remove(&key);
                        if self.wanted.contains(&key) {
                            self.queue_remesh(key);
                        }
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
                    self.queue_unresident_dependents(key);
                    self.coverage_dropped(key);
                }
            }
        }
        let revealed: Vec<_> = self
            .held_coverage
            .iter()
            .copied()
            .filter(|key| {
                self.contexts.get(key).is_some_and(|context| {
                    open_seam_dependencies_publishable(&context.dependencies)
                })
            })
            .collect();
        for key in revealed {
            self.held_coverage.remove(&key);
            self.changes.push(CoverageChange::TileReady(key));
        }
        if self.client.running_jobs() < mesh_admission_limit(near_busy)
            && Instant::now() >= self.pressure_retry
        {
            let work = self.pending.pop_front().or_else(|| {
                while let Some(&key) = self.remesh.front() {
                    if !self.wanted.contains(&key) {
                        self.remesh.pop_front();
                        self.remesh_set.remove(&key);
                        continue;
                    }
                    if self.meshing.get(&key).copied().unwrap_or(0) > 0 {
                        break;
                    }
                    self.remesh.pop_front();
                    self.remesh_set.remove(&key);
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
                let coverage = self.coverage_frame.clone();
                let neighbor_keys =
                    mesh_neighbor_keys(key, self.center, &self.config, coverage.as_deref());
                if neighbor_keys.len() > 64 {
                    eprintln!("LOD mesh neighborhood exceeds the fixed 64-tile bound");
                    acks.push((epoch, key, revision, false));
                    return self.filter_transport_acks(acks);
                }
                let neighbors = self
                    .client
                    .encoded_snapshot(&neighbor_keys)
                    .expect("bounded neighbor list");
                let center = self.center;
                let config = self.config.clone();
                let mut gpu_ready_revisions = HashMap::new();
                for dep in &neighbor_keys {
                    let source_revision = self.sources.get(dep).copied();
                    let resident_revision = self.client.resident(*dep).map(|r| r.revision);
                    if let Some(revision) = matching_resident_revision(
                        source_revision,
                        resident_revision,
                        neighbors.iter().any(|(neighbor, _)| neighbor == dep),
                    ) {
                        gpu_ready_revisions.insert(*dep, revision);
                    }
                }
                if let Some(resident_revision) = self.client.resident(key).map(|r| r.revision)
                    && matching_resident_revision(
                        self.sources.get(&key).copied(),
                        Some(resident_revision),
                        true,
                    ) == Some(revision)
                {
                    gpu_ready_revisions.insert(key, revision);
                }
                let near_ready = Arc::new(self.near_ready.clone());
                let coverage_for_sampler = coverage.clone();
                let dependencies: Vec<_> = neighbor_keys
                    .iter()
                    .copied()
                    .map(|dep| {
                        let revision = gpu_ready_revisions
                            .get(&dep)
                            .copied()
                            .filter(|_| neighbors.iter().any(|(neighbor, _)| *neighbor == dep));
                        (dep, revision)
                    })
                    .collect();
                let near_dependencies = Arc::new(std::sync::Mutex::new(HashMap::new()));
                let recorded_near_dependencies = Arc::clone(&near_dependencies);
                let factory: Arc<SamplerFactory> = Arc::new(move |tile, neighbors, near| {
                    let own = Arc::new(tile.clone());
                    let neighbors = neighbors.clone();
                    let config = config.clone();
                    let gpu_ready_revisions = gpu_ready_revisions.clone();
                    let near_ready = Arc::clone(&near_ready);
                    let coverage = coverage_for_sampler.clone();
                    let near_dependencies = Arc::clone(&recorded_near_dependencies);
                    Arc::new(move |p| {
                        let column = [p[0].div_euclid(16), p[2].div_euclid(16)];
                        let requested = requested_size(column, center, &config);
                        let own_origin = own.key.origin().ok()?;
                        let inside_own_core = (0..3).all(|axis| {
                            p[axis] >= own_origin[axis]
                                && p[axis] < own_origin[axis] + own.key.span()
                        });
                        let own_key = TileKey::new(
                            own.key.cell_size,
                            p.map(|v| v.div_euclid(i32::from(own.key.cell_size) * 32)),
                        )
                        .ok()?;
                        if requested == own.key.cell_size && own_key == own.key && inside_own_core {
                            let cell = own.sample(p)?;
                            return Some(BoundaryCell {
                                origin: p.map(|v| {
                                    v.div_euclid(i32::from(own.key.cell_size))
                                        * i32::from(own.key.cell_size)
                                }),
                                size: own.key.cell_size,
                                cell,
                                geometry_ready: true,
                            });
                        }
                        let size = coverage_selected_size(
                            coverage.as_deref(),
                            p,
                            center,
                            &config,
                            &near_ready,
                        );
                        let chunk = p.map(|v| v.div_euclid(16));
                        let wants_near = requested == 1 || size == 1;
                        let near_sample = if wants_near && size == 1 && near_ready.contains(&chunk)
                        {
                            near(p)
                        } else {
                            None
                        };
                        if wants_near {
                            near_dependencies
                                .lock()
                                .expect("near dependency set poisoned")
                                .insert(chunk, near_sample.is_some());
                        }
                        if size == 1 {
                            return near_sample
                                .map(|mut cell| {
                                    cell.geometry_ready = true;
                                    cell
                                })
                                .or_else(|| Some(unready_boundary_cell(p, 1)));
                        }
                        if size == 0 {
                            return Some(unready_boundary_cell(p, 1));
                        }
                        let span = i32::from(size) * 32;
                        let neighbor_key =
                            TileKey::new(size, p.map(|v| v.div_euclid(span))).ok()?;
                        let resident_matches = gpu_ready_revisions.get(&neighbor_key).is_some_and(
                            |resident_revision| {
                                neighbor_key != own.key || *resident_revision == revision
                            },
                        );
                        if !resident_matches
                            || (neighbor_key != own.key && !neighbors.contains_key(&neighbor_key))
                        {
                            return Some(unready_boundary_cell(p, size));
                        }
                        let tile = if neighbor_key == own.key {
                            &own
                        } else {
                            neighbors.get(&neighbor_key)?
                        };
                        let cell = tile.sample(p)?;
                        Some(BoundaryCell {
                            geometry_ready: true,
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
                    self.contexts.insert(
                        key,
                        MeshContext {
                            center: self.center,
                            dependencies,
                            near_dependencies,
                        },
                    );
                    if newly_cached {
                        self.sources.insert(key, revision);
                    }
                }
            }
        }
        if let Some(frame) = self.coverage.frame()
            && frame.epoch == self.epoch
            && frame.center_chunk == [self.center[0], self.center[2]]
        {
            queue.write_buffer(mask, 0, bytemuck::cast_slice(&frame.columns));
            self.coverage_frame = Some(Arc::new(frame));
            self.reconcile_near_dependents();
            self.evict_obsolete_unpinned();
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

    fn tile_pinned(&self, key: TileKey) -> bool {
        self.coverage_frame
            .as_deref()
            .is_some_and(|frame| coverage_pins_tile(key, frame, self.start.elapsed().as_secs_f32()))
    }

    fn evict_obsolete_unpinned(&mut self) {
        let now = self.start.elapsed().as_secs_f32();
        let evicted: Vec<_> = self
            .client
            .residents()
            .map(|resident| resident.key)
            .filter(|key| {
                !self.wanted.contains(key)
                    && !retained_tile(*key, self.center, &self.config)
                    && !self
                        .coverage_frame
                        .as_deref()
                        .is_some_and(|frame| coverage_pins_tile(*key, frame, now))
            })
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

    fn queue_stale_dependents(&mut self, key: TileKey, revision: u64) {
        let dependents: Vec<_> = self
            .contexts
            .iter()
            .filter(|(_, context)| {
                context
                    .dependencies
                    .iter()
                    .any(|(dependency, seen)| *dependency == key && *seen != Some(revision))
            })
            .map(|(dependent, _)| *dependent)
            .filter(|dependent| self.wanted.contains(dependent))
            .collect();
        for dependent in dependents {
            self.queue_remesh(dependent);
        }
    }

    fn queue_unresident_dependents(&mut self, key: TileKey) {
        let dependents: Vec<_> = self
            .contexts
            .iter()
            .filter(|(_, context)| {
                context
                    .dependencies
                    .iter()
                    .any(|(dependency, revision)| *dependency == key && revision.is_some())
            })
            .map(|(dependent, _)| *dependent)
            .filter(|dependent| self.wanted.contains(dependent))
            .collect();
        for dependent in dependents {
            self.queue_remesh(dependent);
        }
    }

    fn queue_near_dependents(&mut self, chunk: [i32; 3]) {
        let current = self.near_chunk_sample_ready(chunk);
        let dependents: Vec<_> = self
            .contexts
            .iter()
            .filter_map(|(&key, context)| {
                let dependencies = context.near_dependencies.lock().ok()?;
                (dependencies
                    .get(&chunk)
                    .is_some_and(|seen| *seen != current))
                .then_some(key)
            })
            .filter(|key| self.wanted.contains(key))
            .collect();
        for dependent in dependents {
            self.queue_remesh(dependent);
        }
    }

    fn near_chunk_sample_ready(&self, chunk: [i32; 3]) -> bool {
        if !self.near_ready.contains(&chunk) {
            return false;
        }
        let position = chunk.map(|v| v.saturating_mul(16));
        coverage_selected_size(
            self.coverage_frame.as_deref(),
            position,
            self.center,
            &self.config,
            &self.near_ready,
        ) == 1
    }

    fn context_near_stale(&self, context: &MeshContext) -> bool {
        context.near_dependencies.lock().is_ok_and(|dependencies| {
            dependencies
                .iter()
                .any(|(&chunk, &seen)| seen != self.near_chunk_sample_ready(chunk))
        })
    }

    fn reconcile_near_dependents(&mut self) {
        let mut stale = Vec::new();
        for (&key, context) in &self.contexts {
            if self.context_near_stale(context) && self.wanted.contains(&key) {
                stale.push(key);
            }
        }
        for key in stale {
            self.queue_remesh(key);
        }
    }
}

fn open_seam_dependencies_publishable(_dependencies: &[(TileKey, Option<u64>)]) -> bool {
    // Unready samples produce open faces, so a missing neighbor must not create a
    // circular wait for the coverage that would make that neighbor visible.
    true
}

fn geometry_context_current(
    old_center: [i32; 3],
    center: [i32; 3],
    dependencies: &[(TileKey, Option<u64>)],
    sources: &HashMap<TileKey, u64>,
) -> bool {
    [old_center[0], old_center[2]] == [center[0], center[2]]
        && dependencies.iter().all(|(dep, revision)| {
            revision.is_none_or(|revision| sources.get(dep) == Some(&revision))
        })
}

fn unready_boundary_cell(origin: [i32; 3], size: u8) -> BoundaryCell {
    BoundaryCell {
        origin,
        size,
        cell: Default::default(),
        geometry_ready: false,
    }
}

fn near_prefetch_radius(near_radius: u32) -> i32 {
    near_radius.saturating_add(2).min(i32::MAX as u32) as i32
}

fn near_chunk_protected(chunk: [i32; 3], center: [i32; 3], radius: u32) -> bool {
    let dx = i64::from(chunk[0]) - i64::from(center[0]);
    let dz = i64::from(chunk[2]) - i64::from(center[2]);
    dx * dx + dz * dz <= i64::from(radius).pow(2)
}

fn matching_resident_revision(
    source_revision: Option<u64>,
    resident_revision: Option<u64>,
    encoded_available: bool,
) -> Option<u64> {
    source_revision.filter(|revision| encoded_available && resident_revision == Some(*revision))
}

fn mesh_admission_limit(near_busy: bool) -> usize {
    if near_busy { 1 } else { 8 }
}

fn coverage_column(frame: &CoverageFrame, column: [i32; 2]) -> Option<&[f32; 4]> {
    let x = column[0].checked_sub(frame.origin_chunk[0])?;
    let z = column[1].checked_sub(frame.origin_chunk[1])?;
    if x < 0 || z < 0 || x >= frame.side as i32 || z >= frame.side as i32 {
        return None;
    }
    frame.columns.get(z as usize * frame.side + x as usize)
}

fn coverage_current_size(frame: Option<&CoverageFrame>, column: [i32; 2]) -> u8 {
    frame
        .and_then(|frame| coverage_column(frame, column))
        .map_or(0, |entry| entry[0].round().clamp(0.0, 16.0) as u8)
}

fn coverage_selected_size(
    frame: Option<&CoverageFrame>,
    position: [i32; 3],
    center: [i32; 3],
    config: &LodConfig,
    near_ready: &HashSet<[i32; 3]>,
) -> u8 {
    let chunk = position.map(|v| v.div_euclid(16));
    let protected = near_chunk_protected(chunk, center, config.near_radius);
    if protected && near_ready.contains(&chunk) {
        let Some(frame) = frame else {
            return 1;
        };
        let min_y_chunk = config.min_y.div_euclid(16);
        let y = chunk[1] - min_y_chunk;
        if let Some(column) = coverage_column(frame, [chunk[0], chunk[2]])
            && (0..32).contains(&y)
            && (column[3].to_bits() & (1u32 << y)) != 0
        {
            return 1;
        }
    }
    coverage_current_size(frame, [chunk[0], chunk[2]])
}

fn coverage_pins_tile(key: TileKey, frame: &CoverageFrame, now: f32) -> bool {
    let span_chunks = i32::from(key.cell_size) * 2;
    let low = [key.position[0] * span_chunks, key.position[2] * span_chunks];
    let high = [low[0] + span_chunks, low[1] + span_chunks];
    let frame_high = [
        frame.origin_chunk[0] + frame.side as i32,
        frame.origin_chunk[1] + frame.side as i32,
    ];
    let start = [
        low[0].max(frame.origin_chunk[0]),
        low[1].max(frame.origin_chunk[1]),
    ];
    let end = [high[0].min(frame_high[0]), high[1].min(frame_high[1])];
    for z in start[1]..end[1] {
        for x in start[0]..end[0] {
            let Some(column) = coverage_column(frame, [x, z]) else {
                continue;
            };
            let current = column[0].round() as u8;
            let previous = column[1].round() as u8;
            let previous_active = previous == key.cell_size
                && previous != current
                && now >= column[2]
                && now - column[2] < 0.2;
            if (current != 0 && current == key.cell_size) || previous_active {
                return true;
            }
        }
    }
    false
}

fn mesh_neighbor_keys(
    key: TileKey,
    center: [i32; 3],
    config: &LodConfig,
    frame: Option<&CoverageFrame>,
) -> Vec<TileKey> {
    let span = i32::from(key.cell_size) * 2;
    let low = [key.position[0] * span, key.position[2] * span];
    let high = [low[0] + span - 1, low[1] + span - 1];
    let origin = key.origin().expect("validated tile");
    let halo = i32::from(key.cell_size);
    let mut keys: HashSet<_> = required_neighbors(key, center, config)
        .into_iter()
        .collect();
    for x in low[0] - 1..=high[0] + 1 {
        for z in low[1] - 1..=high[1] + 1 {
            let touches = [[-1, 0], [1, 0], [0, -1], [0, 1]].into_iter().any(|d| {
                let p = [x + d[0], z + d[1]];
                (low[0]..=high[0]).contains(&p[0]) && (low[1]..=high[1]).contains(&p[1])
            });
            if !touches {
                continue;
            }
            let published = coverage_current_size(frame, [x, z]);
            let requested = requested_size([x, z], center, config);
            for size in [requested, published] {
                if size < 2 || size > config.max_cell_size {
                    continue;
                }
                let blocks = i32::from(size) * 32;
                for y in (origin[1] - halo).max(config.min_y).div_euclid(blocks)
                    ..=(origin[1] + key.span() + halo - 1)
                        .min(config.max_y)
                        .div_euclid(blocks)
                {
                    if let Ok(neighbor) = TileKey::new(
                        size,
                        [
                            x.div_euclid(i32::from(size) * 2),
                            y,
                            z.div_euclid(i32::from(size) * 2),
                        ],
                    ) && neighbor != key
                    {
                        keys.insert(neighbor);
                    }
                }
            }
        }
    }
    // Same-size vertical neighbors are sampled at the tile's top and bottom halos.
    for dy in [-1, 1] {
        if let Ok(neighbor) = TileKey::new(
            key.cell_size,
            [key.position[0], key.position[1] + dy, key.position[2]],
        ) {
            keys.insert(neighbor);
        }
    }
    let mut keys: Vec<_> = keys.into_iter().collect();
    keys.sort_by_key(|k| (k.cell_size, k.position));
    keys
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
