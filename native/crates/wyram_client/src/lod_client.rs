use std::collections::{HashMap, HashSet, VecDeque};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::mpsc::{self, Receiver, SyncSender, TrySendError};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};

use wyram_core::lod::{MAX_TILE_ENCODED_BYTES, Tile, TileKey};

use crate::lod_mesh::{BoundaryCell, MeshCompletion, MeshPart, build_parts};
use crate::lod_wire::WireBatch;
use crate::world::RenderDescriptor;

pub const MAX_LOD_JOBS: usize = 8;
pub const MAX_QUEUED_PARTS: usize = 16;
pub const MAX_PART_BYTES: usize = 1024 * 1024;
pub const MAX_GPU_BYTES: usize = 256 * 1024 * 1024;
pub const MAX_ENCODED_CACHE_BYTES: usize = 256 * 1024 * 1024;
pub const MAX_ENCODED_CACHE_ENTRIES: usize = 65_536;

pub type LodColors = HashMap<u16, [u8; 3]>;
pub type LodDescriptors = HashMap<u16, RenderDescriptor>;
pub type BoundarySampler = dyn Fn([i32; 3]) -> Option<BoundaryCell> + Send + Sync + 'static;
pub type EncodedNeighbors = HashMap<TileKey, Arc<Vec<u8>>>;
pub type DecodedNeighbors = HashMap<TileKey, Arc<Tile>>;
pub type SamplerFactory = dyn Fn(&Tile, &DecodedNeighbors, Arc<BoundarySampler>) -> Arc<BoundarySampler>
    + Send
    + Sync
    + 'static;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum LodError {
    InvalidWorkerCount,
    TooManyJobs,
    StaleBatch,
    DuplicateTile,
    QueueFull,
    InvalidTile(String),
    WorkerFailed(String),
    UnknownPart,
    UploadNotReserved,
    GpuBudgetExceeded,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum LodEvent {
    Completed {
        epoch: u64,
        key: TileKey,
        revision: u64,
        parts: u16,
    },
    Ready {
        epoch: u64,
        key: TileKey,
        revision: u64,
    },
    Dropped {
        epoch: u64,
        key: TileKey,
        revision: u64,
    },
    Rejected {
        epoch: u64,
        key: TileKey,
        revision: u64,
        reason: LodError,
    },
}

#[derive(Clone, Debug)]
pub struct PendingPart {
    pub ticket: u64,
    pub epoch: u64,
    pub key: TileKey,
    pub revision: u64,
    pub part: MeshPart,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PartTicket(pub u64);

impl From<u64> for PartTicket {
    fn from(value: u64) -> Self {
        Self(value)
    }
}

impl From<PendingPart> for PartTicket {
    fn from(value: PendingPart) -> Self {
        Self(value.ticket)
    }
}

#[allow(dead_code)]
pub struct Resident<'a, G> {
    pub epoch: u64,
    pub key: TileKey,
    pub revision: u64,
    pub parts: &'a [G],
}

struct JobInput {
    id: u64,
    key: TileKey,
    payload: Arc<Vec<u8>>,
    colors: Arc<LodColors>,
    descriptors: Arc<LodDescriptors>,
    neighbors: Arc<EncodedNeighbors>,
    near_sampler: Arc<BoundarySampler>,
    sampler_factory: Arc<SamplerFactory>,
}

enum WorkerMessage {
    Part {
        id: u64,
        index: u16,
        part: MeshPart,
    },
    Finished {
        id: u64,
        result: Result<MeshCompletion, WorkerFailure>,
    },
}

struct WorkerFailure {
    message: String,
    invalid_source: bool,
}

struct JobState<G> {
    epoch: u64,
    key: TileKey,
    revision: u64,
    token: u64,
    source_payload: Arc<Vec<u8>>,
    expected_parts: Option<u16>,
    uploaded: Vec<Option<G>>,
    uploaded_bytes: usize,
    finished: bool,
}

struct InFlight {
    id: u64,
    part_index: u16,
    bytes: usize,
    reserved: bool,
    epoch: u64,
    key: TileKey,
    revision: u64,
    part: MeshPart,
}

struct ResidentData<G> {
    epoch: u64,
    revision: u64,
    bytes: usize,
    parts: Vec<G>,
}

struct CacheEntry {
    revision: u64,
    payload: Arc<Vec<u8>>,
    last_used: u64,
}

/// Bounded native-side LOD meshing and GPU admission state. GPU allocation stays with the caller.
pub struct LodClient<G: Send + 'static> {
    job_tx: SyncSender<JobInput>,
    message_rx: Receiver<WorkerMessage>,
    workers: Vec<JoinHandle<()>>,
    epoch: u64,
    plan: HashSet<TileKey>,
    latest: HashMap<TileKey, (u64, u64)>,
    running: HashSet<u64>,
    slots: HashSet<u64>,
    jobs: HashMap<u64, JobState<G>>,
    queued_parts: VecDeque<PendingPart>,
    in_flight: HashMap<u64, InFlight>,
    events: VecDeque<LodEvent>,
    residents: HashMap<TileKey, ResidentData<G>>,
    next_id: u64,
    next_ticket: u64,
    gpu_bytes: usize,
    reserved_bytes: usize,
    encoded_cache: HashMap<TileKey, CacheEntry>,
    encoded_cache_bytes: usize,
    cache_clock: u64,
    next_token: u64,
}

impl<G: Send + 'static> LodClient<G> {
    pub fn new(mesh_workers: usize) -> Result<Self, LodError> {
        if !(1..=8).contains(&mesh_workers) {
            return Err(LodError::InvalidWorkerCount);
        }
        let (job_tx, job_rx) = mpsc::sync_channel::<JobInput>(MAX_LOD_JOBS);
        let (message_tx, message_rx) = mpsc::sync_channel::<WorkerMessage>(0);
        let shared_rx = Arc::new(Mutex::new(job_rx));
        let mut workers = Vec::with_capacity(mesh_workers);
        for _ in 0..mesh_workers {
            let rx = Arc::clone(&shared_rx);
            let tx = message_tx.clone();
            workers.push(thread::spawn(move || {
                loop {
                    let job = match rx.lock().expect("LOD job queue poisoned").recv() {
                        Ok(job) => job,
                        Err(_) => break,
                    };
                    let id = job.id;
                    let result = catch_unwind(AssertUnwindSafe(|| {
                        let tile =
                            Tile::decode(job.key, &job.payload).map_err(|error| WorkerFailure {
                                message: error.to_string(),
                                invalid_source: true,
                            })?;
                        let mut decoded_neighbors = HashMap::with_capacity(job.neighbors.len());
                        for (key, payload) in job.neighbors.iter() {
                            let neighbor =
                                Tile::decode(*key, payload).map_err(|error| WorkerFailure {
                                    message: format!("invalid neighbor tile: {error}"),
                                    invalid_source: false,
                                })?;
                            decoded_neighbors.insert(*key, Arc::new(neighbor));
                        }
                        let sampler = (job.sampler_factory)(
                            &tile,
                            &decoded_neighbors,
                            Arc::clone(&job.near_sampler),
                        );
                        let mut next_index = 0u16;
                        let completion = build_parts(
                            &tile,
                            &job.colors,
                            &job.descriptors,
                            |position| sampler(position),
                            |part| {
                                let index = next_index;
                                next_index = match next_index.checked_add(1) {
                                    Some(value) => value,
                                    None => return false,
                                };
                                let bytes = part
                                    .vertices
                                    .len()
                                    .saturating_mul(size_of::<crate::lod_mesh::LodVertex>());
                                if bytes > MAX_PART_BYTES {
                                    return false;
                                }
                                tx.send(WorkerMessage::Part { id, index, part }).is_ok()
                            },
                        );
                        if completion.cancelled {
                            Err(WorkerFailure {
                                message: "LOD mesher cancelled or part output failed".to_owned(),
                                invalid_source: false,
                            })
                        } else if next_index != completion.parts {
                            Err(WorkerFailure {
                                message: "LOD part index overflow".to_owned(),
                                invalid_source: false,
                            })
                        } else {
                            Ok(completion)
                        }
                    }));
                    let result = match result {
                        Ok(result) => result,
                        Err(_) => Err(WorkerFailure {
                            message: "LOD worker panicked".to_owned(),
                            invalid_source: false,
                        }),
                    };
                    if tx.send(WorkerMessage::Finished { id, result }).is_err() {
                        break;
                    }
                }
            }));
        }
        drop(message_tx);
        Ok(Self {
            job_tx,
            message_rx,
            workers,
            epoch: 0,
            plan: HashSet::new(),
            latest: HashMap::new(),
            running: HashSet::new(),
            slots: HashSet::new(),
            jobs: HashMap::new(),
            queued_parts: VecDeque::new(),
            in_flight: HashMap::new(),
            events: VecDeque::new(),
            residents: HashMap::new(),
            next_id: 1,
            next_ticket: 1,
            gpu_bytes: 0,
            reserved_bytes: 0,
            encoded_cache: HashMap::new(),
            encoded_cache_bytes: 0,
            cache_clock: 1,
            next_token: 1,
        })
    }

    pub fn set_plan(&mut self, epoch: u64, ordered_wanted: &[TileKey]) {
        let changed_epoch = self.epoch != epoch;
        self.epoch = epoch;
        self.plan.clear();
        self.plan.extend(ordered_wanted.iter().copied());
        self.latest.retain(|key, _| self.plan.contains(key));
        if changed_epoch {
            self.latest.clear();
            self.events.extend(
                self.residents
                    .iter()
                    .map(|(&key, resident)| LodEvent::Dropped {
                        epoch: resident.epoch,
                        key,
                        revision: resident.revision,
                    }),
            );
            self.residents.clear();
            self.gpu_bytes = 0;
        }
        let obsolete: Vec<_> = self
            .jobs
            .keys()
            .copied()
            .filter(|&id| {
                self.jobs.get(&id).is_some_and(|job| {
                    !self.is_current(job.epoch, job.key, job.revision, job.token)
                })
            })
            .collect();
        for id in obsolete {
            self.reject_job(id, LodError::StaleBatch);
        }
    }

    pub fn submit(
        &mut self,
        batch: WireBatch,
        colors: Arc<LodColors>,
        descriptors: Arc<LodDescriptors>,
        neighbors: Arc<EncodedNeighbors>,
        near_sampler: Arc<BoundarySampler>,
        sampler_factory: Arc<SamplerFactory>,
    ) -> Result<Vec<(TileKey, u64)>, LodError> {
        if batch.epoch != self.epoch || batch.tiles.is_empty() || batch.tiles.len() > 2 {
            return Err(LodError::StaleBatch);
        }
        if neighbors.len() > 64 {
            return Err(LodError::InvalidTile(
                "neighbor snapshot exceeds 64 tiles".into(),
            ));
        }
        if neighbors.iter().any(|(key, bytes)| {
            key.origin().is_err() || bytes.len() < 16 || bytes.len() > MAX_TILE_ENCODED_BYTES
        }) {
            return Err(LodError::InvalidTile("invalid neighbor snapshot".into()));
        }
        let mut keys = HashSet::new();
        for tile in &batch.tiles {
            if !keys.insert(tile.key) {
                return Err(LodError::DuplicateTile);
            }
            if !self.plan.contains(&tile.key) {
                return Err(LodError::StaleBatch);
            }
            if tile.payload.len() < 16
                || tile.payload.len() > MAX_TILE_ENCODED_BYTES
                || &tile.payload[..4] != b"LT01"
            {
                return Err(LodError::InvalidTile("encoded tile exceeds limit".into()));
            }
        }
        self.cache_received(&batch)?;
        if self.slots.len() + batch.tiles.len() > MAX_LOD_JOBS {
            return Err(LodError::TooManyJobs);
        }

        let mut accepted = Vec::with_capacity(batch.tiles.len());
        for tile in batch.tiles {
            let id = self.next_id;
            self.next_id = self.next_id.checked_add(1).ok_or(LodError::TooManyJobs)?;
            let key = tile.key;
            let revision = tile.revision;
            let token = self.next_token;
            self.next_token = self.next_token.wrapping_add(1).max(1);
            let (cached_revision, payload) = self.cached_tile(key).ok_or_else(|| {
                LodError::InvalidTile("received tile missing from encoded cache".into())
            })?;
            if cached_revision != revision {
                return Err(LodError::StaleBatch);
            }
            let job = JobInput {
                id,
                key,
                payload: Arc::clone(&payload),
                colors: Arc::clone(&colors),
                descriptors: Arc::clone(&descriptors),
                neighbors: Arc::clone(&neighbors),
                near_sampler: Arc::clone(&near_sampler),
                sampler_factory: Arc::clone(&sampler_factory),
            };
            match self.job_tx.try_send(job) {
                Ok(()) => {
                    self.latest.insert(key, (revision, token));
                    self.running.insert(id);
                    self.slots.insert(id);
                    self.jobs.insert(
                        id,
                        JobState {
                            epoch: batch.epoch,
                            key,
                            revision,
                            token,
                            source_payload: payload,
                            expected_parts: None,
                            uploaded: Vec::new(),
                            uploaded_bytes: 0,
                            finished: false,
                        },
                    );
                    accepted.push((key, revision));
                }
                Err(TrySendError::Full(_)) => return Err(LodError::QueueFull),
                Err(TrySendError::Disconnected(_)) => return Err(LodError::QueueFull),
            }
        }
        Ok(accepted)
    }

    pub fn invalidate(&mut self, key: TileKey) {
        self.latest.remove(&key);
        if let Some(entry) = self.encoded_cache.remove(&key) {
            self.encoded_cache_bytes = self.encoded_cache_bytes.saturating_sub(entry.payload.len());
        }
        let obsolete: Vec<_> = self
            .jobs
            .iter()
            .filter_map(|(&id, job)| (job.key == key).then_some(id))
            .collect();
        for id in obsolete {
            self.reject_job(id, LodError::StaleBatch);
        }
    }

    /// Explicit retention-manager eviction; plan updates alone never free resident GPU data.
    pub fn evict(&mut self, key: TileKey) -> usize {
        self.invalidate(key);
        self.plan.remove(&key);
        if let Some(resident) = self.residents.remove(&key) {
            self.gpu_bytes = self.gpu_bytes.saturating_sub(resident.bytes);
            self.events.push_back(LodEvent::Dropped {
                epoch: resident.epoch,
                key,
                revision: resident.revision,
            });
            resident.bytes
        } else {
            0
        }
    }

    pub fn cache_tile(
        &mut self,
        key: TileKey,
        revision: u64,
        payload: Arc<Vec<u8>>,
    ) -> Result<(), LodError> {
        key.origin()
            .map_err(|error| LodError::InvalidTile(error.into()))?;
        if payload.len() < 16 || payload.len() > MAX_TILE_ENCODED_BYTES || &payload[..4] != b"LT01"
        {
            return Err(LodError::InvalidTile(
                "invalid encoded tile cache entry".into(),
            ));
        }
        if let Some(previous) = self.encoded_cache.get(&key) {
            if previous.revision > revision {
                return Ok(());
            }
            if previous.revision == revision {
                if previous.payload.as_ref() != payload.as_ref() {
                    return Err(LodError::InvalidTile(
                        "encoded tile changed without a revision change".into(),
                    ));
                }
                self.cache_clock = self.cache_clock.wrapping_add(1).max(1);
                self.encoded_cache.get_mut(&key).unwrap().last_used = self.cache_clock;
                return Ok(());
            }
        }
        if let Some(previous) = self.encoded_cache.remove(&key) {
            self.encoded_cache_bytes = self
                .encoded_cache_bytes
                .saturating_sub(previous.payload.len());
        }
        while self.encoded_cache_bytes.saturating_add(payload.len()) > MAX_ENCODED_CACHE_BYTES
            || self.encoded_cache.len() >= MAX_ENCODED_CACHE_ENTRIES
        {
            let Some(oldest) = self
                .encoded_cache
                .iter()
                .min_by_key(|(_, entry)| entry.last_used)
                .map(|(&key, _)| key)
            else {
                break;
            };
            if let Some(evicted) = self.encoded_cache.remove(&oldest) {
                self.encoded_cache_bytes = self
                    .encoded_cache_bytes
                    .saturating_sub(evicted.payload.len());
            }
        }
        self.cache_clock = self.cache_clock.wrapping_add(1).max(1);
        self.encoded_cache_bytes = self.encoded_cache_bytes.saturating_add(payload.len());
        self.encoded_cache.insert(
            key,
            CacheEntry {
                revision,
                payload,
                last_used: self.cache_clock,
            },
        );
        Ok(())
    }

    pub fn cached_tile(&mut self, key: TileKey) -> Option<(u64, Arc<Vec<u8>>)> {
        self.cache_clock = self.cache_clock.wrapping_add(1).max(1);
        let entry = self.encoded_cache.get_mut(&key)?;
        entry.last_used = self.cache_clock;
        Some((entry.revision, Arc::clone(&entry.payload)))
    }

    pub fn encoded_neighbors(
        &mut self,
        keys: &[TileKey],
    ) -> Result<Arc<EncodedNeighbors>, LodError> {
        if keys.len() > 64 {
            return Err(LodError::InvalidTile(
                "neighbor snapshot exceeds 64 tiles".into(),
            ));
        }
        let mut result = HashMap::with_capacity(keys.len());
        for &key in keys {
            if let Some((_, bytes)) = self.cached_tile(key) {
                result.insert(key, bytes);
            }
        }
        Ok(Arc::new(result))
    }

    pub fn encoded_snapshot(
        &mut self,
        keys: &[TileKey],
    ) -> Result<Arc<EncodedNeighbors>, LodError> {
        self.encoded_neighbors(keys)
    }

    #[allow(dead_code)]
    pub fn cache_bytes(&self) -> usize {
        self.encoded_cache_bytes
    }

    pub fn cache_received(&mut self, batch: &WireBatch) -> Result<(), LodError> {
        for tile in &batch.tiles {
            tile.key
                .origin()
                .map_err(|error| LodError::InvalidTile(error.into()))?;
            if tile.payload.len() < 16
                || tile.payload.len() > MAX_TILE_ENCODED_BYTES
                || &tile.payload[..4] != b"LT01"
            {
                return Err(LodError::InvalidTile("invalid encoded tile".into()));
            }
            if self.encoded_cache.get(&tile.key).is_some_and(|previous| {
                previous.revision == tile.revision && previous.payload.as_ref() != &tile.payload
            }) {
                return Err(LodError::InvalidTile(
                    "encoded tile changed without a revision change".into(),
                ));
            }
        }
        for tile in &batch.tiles {
            self.cache_tile(tile.key, tile.revision, Arc::new(tile.payload.clone()))?;
        }
        Ok(())
    }

    pub fn poll_parts(&mut self, max_parts: usize, max_bytes: usize) -> Vec<PendingPart> {
        self.pump_messages(MAX_QUEUED_PARTS);
        let mut parts = Vec::new();
        let mut bytes = 0usize;
        while parts.len() < max_parts {
            let Some(next) = self.queued_parts.front() else {
                break;
            };
            if self.queued_parts.len() + self.in_flight.len() > MAX_QUEUED_PARTS {
                break;
            }
            let size = vertex_bytes(&next.part);
            if size > MAX_PART_BYTES || bytes.saturating_add(size) > max_bytes {
                break;
            }
            let mut part = self.queued_parts.pop_front().expect("front exists");
            let current = self
                .jobs
                .get(&part.ticket)
                .is_some_and(|job| self.is_current(job.epoch, job.key, job.revision, job.token));
            if !current {
                self.reject_job(part.ticket, LodError::StaleBatch);
                continue;
            }
            let ticket = self.next_ticket;
            self.next_ticket = self.next_ticket.wrapping_add(1).max(1);
            let id = part.ticket;
            let part_index = part.part.index;
            part.ticket = ticket;
            self.in_flight.insert(
                ticket,
                InFlight {
                    id,
                    part_index,
                    bytes: size,
                    reserved: false,
                    epoch: part.epoch,
                    key: part.key,
                    revision: part.revision,
                    part: part.part.clone(),
                },
            );
            bytes += size;
            parts.push(part);
        }
        parts
    }

    pub fn reserve_upload(&mut self, ticket: u64) -> Result<(), LodError> {
        let Some((id, epoch, key, revision, reserved, bytes)) =
            self.in_flight.get(&ticket).map(|flight| {
                (
                    flight.id,
                    flight.epoch,
                    flight.key,
                    flight.revision,
                    flight.reserved,
                    flight.bytes,
                )
            })
        else {
            return Err(LodError::UnknownPart);
        };
        let current = self.jobs.get(&id).is_some_and(|job| {
            job.epoch == epoch
                && job.key == key
                && job.revision == revision
                && self.is_current(job.epoch, job.key, job.revision, job.token)
        });
        if !current {
            if let Some(flight) = self.in_flight.remove(&ticket)
                && flight.reserved
            {
                self.reserved_bytes = self.reserved_bytes.saturating_sub(flight.bytes);
            }
            self.reject_job(id, LodError::StaleBatch);
            return Err(LodError::StaleBatch);
        }
        if reserved {
            return Ok(());
        }
        if self
            .gpu_bytes
            .saturating_add(self.reserved_bytes)
            .saturating_add(bytes)
            > MAX_GPU_BYTES
        {
            return Err(LodError::GpuBudgetExceeded);
        }
        self.in_flight
            .get_mut(&ticket)
            .expect("flight exists")
            .reserved = true;
        self.reserved_bytes += bytes;
        Ok(())
    }

    pub fn defer_part(&mut self, ticket: impl Into<PartTicket>) -> Result<(), LodError> {
        let ticket = ticket.into().0;
        let Some(flight) = self.in_flight.remove(&ticket) else {
            return Err(LodError::UnknownPart);
        };
        if flight.reserved {
            self.reserved_bytes = self.reserved_bytes.saturating_sub(flight.bytes);
        }
        self.queued_parts.push_front(PendingPart {
            ticket: flight.id,
            epoch: flight.epoch,
            key: flight.key,
            revision: flight.revision,
            part: flight.part,
        });
        Ok(())
    }

    pub fn ack_part(
        &mut self,
        ticket: impl Into<PartTicket>,
        handle: G,
    ) -> Result<(), (G, LodError)> {
        let ticket = ticket.into().0;
        let Some(flight) = self.in_flight.remove(&ticket) else {
            return Err((handle, LodError::UnknownPart));
        };
        let Some((epoch, key, revision, token, expected_parts)) =
            self.jobs.get(&flight.id).map(|state| {
                (
                    state.epoch,
                    state.key,
                    state.revision,
                    state.token,
                    state.expected_parts,
                )
            })
        else {
            if flight.reserved {
                self.reserved_bytes = self.reserved_bytes.saturating_sub(flight.bytes);
            }
            return Err((handle, LodError::UnknownPart));
        };
        if !flight.reserved {
            self.queued_parts.push_front(PendingPart {
                ticket: flight.id,
                epoch: flight.epoch,
                key: flight.key,
                revision: flight.revision,
                part: flight.part,
            });
            return Err((handle, LodError::UploadNotReserved));
        }
        if !self.is_current(epoch, key, revision, token) {
            self.reserved_bytes = self.reserved_bytes.saturating_sub(flight.bytes);
            self.reject_job(flight.id, LodError::StaleBatch);
            return Err((handle, LodError::StaleBatch));
        }
        if expected_parts.is_some_and(|expected| {
            flight.part_index >= expected
                || self.jobs[&flight.id]
                    .uploaded
                    .get(flight.part_index as usize)
                    .is_some_and(Option::is_some)
        }) || expected_parts.is_none()
            && self.jobs[&flight.id]
                .uploaded
                .get(flight.part_index as usize)
                .is_some_and(Option::is_some)
        {
            self.reserved_bytes = self.reserved_bytes.saturating_sub(flight.bytes);
            self.reject_job(flight.id, LodError::UnknownPart);
            return Err((handle, LodError::UnknownPart));
        }
        let state = self.jobs.get_mut(&flight.id).expect("job still exists");
        if let Some(expected) = expected_parts
            && state.uploaded.len() != expected as usize
        {
            state.uploaded.resize_with(expected as usize, || None);
        } else {
            state
                .uploaded
                .resize_with(flight.part_index as usize + 1, || None);
        }
        state.uploaded_bytes += flight.bytes;
        state.uploaded[flight.part_index as usize] = Some(handle);
        // Reservations remain charged while handles are staged for atomic replacement.
        self.maybe_commit(flight.id);
        Ok(())
    }

    #[allow(dead_code)]
    pub fn reject_part(
        &mut self,
        ticket: impl Into<PartTicket>,
        reason: LodError,
    ) -> Result<(), LodError> {
        let ticket = ticket.into().0;
        let Some(flight) = self.in_flight.remove(&ticket) else {
            return Err(LodError::UnknownPart);
        };
        if flight.reserved {
            self.reserved_bytes = self.reserved_bytes.saturating_sub(flight.bytes);
        }
        self.reject_job(flight.id, reason);
        Ok(())
    }

    pub fn drain_events(&mut self, max_events: usize) -> Vec<LodEvent> {
        self.pump_messages(MAX_QUEUED_PARTS);
        (0..max_events)
            .filter_map(|_| self.events.pop_front())
            .collect()
    }

    #[allow(dead_code)]
    pub fn resident(&self, key: TileKey) -> Option<Resident<'_, G>> {
        let item = self.residents.get(&key)?;
        Some(Resident {
            epoch: item.epoch,
            key,
            revision: item.revision,
            parts: &item.parts,
        })
    }

    pub fn residents(&self) -> impl Iterator<Item = Resident<'_, G>> {
        self.residents.iter().map(|(&key, item)| Resident {
            epoch: item.epoch,
            key,
            revision: item.revision,
            parts: &item.parts,
        })
    }

    #[cfg(test)]
    pub fn is_ready(&self, epoch: u64, key: TileKey, revision: u64) -> bool {
        self.residents
            .get(&key)
            .is_some_and(|resident| resident.epoch == epoch && resident.revision == revision)
    }

    #[allow(dead_code)]
    pub fn gpu_bytes(&self) -> usize {
        self.gpu_bytes
    }

    #[allow(dead_code)]
    pub fn reserved_gpu_bytes(&self) -> usize {
        self.reserved_bytes
    }

    pub fn running_jobs(&self) -> usize {
        self.slots.len()
    }

    fn pump_messages(&mut self, limit: usize) {
        for _ in 0..limit {
            if self.queued_parts.len() + self.in_flight.len() >= MAX_QUEUED_PARTS {
                break;
            }
            let Ok(message) = self.message_rx.try_recv() else {
                break;
            };
            match message {
                WorkerMessage::Part { id, index, part } => {
                    let Some(state) = self.jobs.get(&id) else {
                        continue;
                    };
                    if !self.is_current(state.epoch, state.key, state.revision, state.token) {
                        continue;
                    }
                    let ticket = id;
                    self.queued_parts.push_back(PendingPart {
                        ticket,
                        epoch: state.epoch,
                        key: state.key,
                        revision: state.revision,
                        part: MeshPart { index, ..part },
                    });
                }
                WorkerMessage::Finished { id, result } => {
                    self.running.remove(&id);
                    if !self.jobs.contains_key(&id) {
                        self.slots.remove(&id);
                        continue;
                    }
                    match result {
                        Ok(completion) => {
                            let (epoch, key, revision, token) = {
                                let state = self.jobs.get_mut(&id).expect("checked above");
                                state.finished = true;
                                state.expected_parts = Some(completion.parts);
                                state
                                    .uploaded
                                    .resize_with(completion.parts as usize, || None);
                                (state.epoch, state.key, state.revision, state.token)
                            };
                            self.events.push_back(LodEvent::Completed {
                                epoch,
                                key,
                                revision,
                                parts: completion.parts,
                            });
                            if !self.is_current(epoch, key, revision, token) {
                                self.reject_job(id, LodError::StaleBatch);
                            } else {
                                self.maybe_commit(id);
                            }
                        }
                        Err(error) => {
                            let bad_source = self.jobs.get(&id).and_then(|state| {
                                error.invalid_source.then(|| {
                                    (state.key, state.revision, Arc::clone(&state.source_payload))
                                })
                            });
                            if let Some((key, revision, payload)) = bad_source {
                                self.remove_cached_payload(key, revision, &payload);
                            }
                            self.reject_job(id, LodError::WorkerFailed(error.message));
                        }
                    }
                }
            }
        }
    }

    fn is_current(&self, epoch: u64, key: TileKey, revision: u64, token: u64) -> bool {
        epoch == self.epoch
            && self.plan.contains(&key)
            && self.latest.get(&key) == Some(&(revision, token))
    }

    fn remove_cached_payload(&mut self, key: TileKey, revision: u64, payload: &Arc<Vec<u8>>) {
        let same_payload = self.encoded_cache.get(&key).is_some_and(|entry| {
            entry.revision == revision && Arc::ptr_eq(&entry.payload, payload)
        });
        if same_payload && let Some(entry) = self.encoded_cache.remove(&key) {
            self.encoded_cache_bytes = self.encoded_cache_bytes.saturating_sub(entry.payload.len());
        }
    }

    fn maybe_commit(&mut self, id: u64) {
        let Some((epoch, key, revision, token, expected, finished, uploaded_count, all_uploaded)) =
            self.jobs.get(&id).map(|state| {
                (
                    state.epoch,
                    state.key,
                    state.revision,
                    state.token,
                    state.expected_parts,
                    state.finished,
                    state.uploaded.len(),
                    state.uploaded.iter().all(Option::is_some),
                )
            })
        else {
            return;
        };
        let Some(expected) = expected else {
            return;
        };
        if !finished || uploaded_count != expected as usize || !all_uploaded {
            return;
        }
        if !self.is_current(epoch, key, revision, token) {
            self.reject_job(id, LodError::StaleBatch);
            return;
        }
        let state = self.jobs.remove(&id).expect("job exists");
        self.slots.remove(&id);
        let parts = state.uploaded.into_iter().map(Option::unwrap).collect();
        let old = self.residents.remove(&key);
        if let Some(old) = &old {
            self.gpu_bytes = self.gpu_bytes.saturating_sub(old.bytes);
        }
        self.reserved_bytes = self.reserved_bytes.saturating_sub(state.uploaded_bytes);
        self.gpu_bytes = self.gpu_bytes.saturating_add(state.uploaded_bytes);
        self.residents.insert(
            key,
            ResidentData {
                epoch: state.epoch,
                revision: state.revision,
                bytes: state.uploaded_bytes,
                parts,
            },
        );
        self.events.push_back(LodEvent::Ready {
            epoch,
            key,
            revision,
        });
    }

    fn reject_job(&mut self, id: u64, reason: LodError) {
        let Some(state) = self.jobs.remove(&id) else {
            return;
        };
        if !self.running.contains(&id) {
            self.slots.remove(&id);
        }
        self.reserved_bytes = self.reserved_bytes.saturating_sub(state.uploaded_bytes);
        let stale_tickets: Vec<_> = self
            .in_flight
            .iter()
            .filter_map(|(&ticket, flight)| (flight.id == id).then_some(ticket))
            .collect();
        for ticket in stale_tickets {
            if let Some(flight) = self.in_flight.remove(&ticket)
                && flight.reserved
            {
                self.reserved_bytes = self.reserved_bytes.saturating_sub(flight.bytes);
            }
        }
        self.queued_parts.retain(|part| {
            !(part.epoch == state.epoch && part.key == state.key && part.revision == state.revision)
        });
        self.events.push_back(LodEvent::Rejected {
            epoch: state.epoch,
            key: state.key,
            revision: state.revision,
            reason,
        });
    }
}

impl<G: Send + 'static> Drop for LodClient<G> {
    fn drop(&mut self) {
        // Dropping the sender and receiver below disconnects workers and releases blocked sends.
        let (replacement, _receiver) = mpsc::sync_channel(1);
        self.job_tx = replacement;
        self.workers.clear();
    }
}

fn vertex_bytes(part: &MeshPart) -> usize {
    part.vertices
        .len()
        .saturating_mul(size_of::<crate::lod_mesh::LodVertex>())
}

#[cfg(test)]
#[path = "lod_client_tests.rs"]
mod tests;
