//! CPU-side residency and per-column LOD coverage for the far terrain renderer.
use std::collections::{BTreeMap, HashMap, HashSet};

use wyram_core::lod::TileKey;

#[derive(Clone, Copy, Debug)]
pub struct CoverageConfig {
    pub near_radius_chunks: u32,
    pub max_cell_size: u8,
    pub min_y_chunk: i32,
    pub max_y_chunk: i32,
    pub columns_per_side: usize,
    pub frontier_fade_fraction: f32,
    pub transition_seconds: f32,
    pub promotion_buffer_chunks: u32,
    pub demotion_buffer_chunks: u32,
}

#[derive(Clone, Debug)]
pub struct CoverageFrame {
    pub epoch: u64,
    pub origin_chunk: [i32; 2],
    pub center_chunk: [i32; 2],
    pub side: usize,
    /// `[current_size, previous_size, transition_start_seconds, near_chunk_mask_bits]`.
    /// The final float preserves a `u32` bit mask: bit N marks near chunk
    /// `min_y_chunk + N` as resident for this horizontal column.
    pub columns: Vec<[f32; 4]>,
    pub frontier_radius_blocks: f32,
}

#[derive(Clone, Copy, Debug, Default)]
struct ColumnState {
    current: u8,
    previous: u8,
    transition_start: f32,
    near_mask: u32,
}

impl ColumnState {
    fn gpu(self) -> [f32; 4] {
        [
            f32::from(self.current),
            f32::from(self.previous),
            self.transition_start,
            f32::from_bits(self.near_mask),
        ]
    }
}

/// A `CoverageFrame` owns its fixed-size GPU mask; setters rebuild it only on a view or
/// residency change, so the renderer can upload one coherent snapshot.
pub struct LodCoverage {
    config: CoverageConfig,
    center: [i32; 2],
    epoch: Option<u64>,
    view_set: bool,
    near_chunks: HashSet<[i32; 3]>,
    near_ready_columns: HashSet<[i32; 2]>,
    ready_tiles: HashSet<TileKey>,
    ready_tile_columns: HashSet<(u8, i32, i32)>,
    desired: HashMap<[i32; 2], u8>,
    states: HashMap<[i32; 2], ColumnState>,
    deferred: HashSet<[i32; 2]>,
    frame: CoverageFrame,
    missing_by_distance2: BTreeMap<i64, usize>,
    frontier_target: f32,
    frontier_initialized: bool,
    last_frame_time: f32,
}

impl LodCoverage {
    pub fn new(config: CoverageConfig) -> Result<Self, &'static str> {
        if config.near_radius_chunks == 0
            || !matches!(config.max_cell_size, 2 | 4 | 8 | 16)
            || config.min_y_chunk > config.max_y_chunk
            || config.columns_per_side == 0
            || config.columns_per_side > 1024
            || i64::from(config.max_y_chunk) - i64::from(config.min_y_chunk) + 1 > 32
            || !config.frontier_fade_fraction.is_finite()
            || (config.frontier_fade_fraction - 0.2).abs() > f32::EPSILON
            || !config.transition_seconds.is_finite()
            || (config.transition_seconds - 0.2).abs() > f32::EPSILON
        {
            return Err("invalid LOD coverage configuration");
        }
        let side = config.columns_per_side;
        Ok(Self {
            config,
            center: [0, 0],
            epoch: None,
            view_set: false,
            near_chunks: HashSet::new(),
            near_ready_columns: HashSet::new(),
            ready_tiles: HashSet::new(),
            ready_tile_columns: HashSet::new(),
            desired: HashMap::new(),
            states: HashMap::new(),
            deferred: HashSet::new(),
            frame: CoverageFrame {
                epoch: 0,
                origin_chunk: [0, 0],
                center_chunk: [0, 0],
                side,
                columns: vec![[0.0; 4]; side * side],
                frontier_radius_blocks: 0.0,
            },
            missing_by_distance2: BTreeMap::new(),
            frontier_target: 0.0,
            frontier_initialized: false,
            last_frame_time: 0.0,
        })
    }

    /// Moves the fixed-size coverage window. An epoch change is a teleport and resets
    /// transition state; ordinary movement preserves band hysteresis and resident data.
    pub fn set_view(&mut self, center_chunk: [i32; 2], now: f32, epoch: u64) {
        let teleported = self.epoch.is_some_and(|old| old != epoch);
        let moved = !self.view_set || self.center != center_chunk;
        let reset_frontier = !self.view_set || teleported;
        self.epoch = Some(epoch);
        self.last_frame_time = now;
        if !moved && !teleported {
            return;
        }
        let previous_desired = std::mem::take(&mut self.desired);
        self.center = center_chunk;
        self.view_set = true;
        if teleported {
            self.near_chunks.clear();
            self.near_ready_columns.clear();
            self.ready_tiles.clear();
            self.ready_tile_columns.clear();
            self.states.clear();
            self.deferred.clear();
        }
        let side = self.frame.side as i32;
        let half = side / 2;
        let origin = [center_chunk[0] - half, center_chunk[1] - half];
        self.frame.center_chunk = center_chunk;
        self.frame.epoch = epoch;
        self.frame.origin_chunk = origin;
        let [origin_x, origin_z] = origin;
        let side = self.frame.side as i32;
        self.deferred.retain(|[x, z]| {
            *x >= origin_x && *z >= origin_z && *x < origin_x + side && *z < origin_z + side
        });
        self.frame.columns.fill([0.0; 4]);
        self.missing_by_distance2.clear();
        for z in origin[1]..origin[1] + side {
            for x in origin[0]..origin[0] + side {
                let key = [x, z];
                let prior = if teleported {
                    None
                } else {
                    previous_desired.get(&key).copied()
                };
                let size = self.choose_size(key, prior);
                self.desired.insert(key, size);
                let should_refresh = teleported
                    || !previous_desired.contains_key(&key)
                    || self
                        .states
                        .get(&key)
                        .is_none_or(|state| state.current != size);
                if should_refresh {
                    self.refresh_column_inner(key, now, false, false);
                }
                let index = self.index(key).unwrap();
                let (gpu, ready) = {
                    let state = self.states.entry(key).or_default();
                    if teleported {
                        state.previous = state.current;
                        state.transition_start = now;
                    }
                    (state.gpu(), state.current != 0)
                };
                if !ready {
                    self.add_missing(key);
                }
                self.frame.columns[index] = gpu;
            }
        }
        self.update_frontier(reset_frontier);
    }

    /// Marks one immutable near chunk resident. Empty chunks count as ready. A near
    /// column remains unavailable until every configured vertical chunk is resident.
    pub fn mark_near_ready(&mut self, chunk: [i32; 3], now: f32) {
        if !self.valid_y_chunk(chunk[1]) || !self.near_chunks.insert(chunk) {
            return;
        }
        self.refresh_near_column([chunk[0], chunk[2]], now);
    }

    pub fn forget_near(&mut self, chunk: [i32; 3], now: f32) {
        if self.near_chunks.remove(&chunk) {
            self.refresh_near_column([chunk[0], chunk[2]], now);
        }
    }

    /// Marks an entire tile resident only after every mesh part has reached the GPU.
    /// Valid empty tiles are represented by the same ready key.
    pub fn mark_tile_ready(&mut self, key: TileKey, now: f32) {
        if !self.valid_tile(key) || !self.ready_tiles.insert(key) {
            return;
        }
        self.refresh_ready_tile_column(key, now);
    }

    pub fn forget_tile(&mut self, key: TileKey, now: f32) {
        if self.ready_tiles.remove(&key) {
            self.refresh_ready_tile_column(key, now);
        }
    }

    pub fn desired_size(&self, column: [i32; 2]) -> u8 {
        self.desired
            .get(&column)
            .copied()
            .unwrap_or_else(|| self.base_size(column))
    }

    /// Returns zero if the exact detail assigned to the column is not fully resident.
    /// A finer resident representation is allowed; a coarser fallback is never returned.
    #[cfg(test)]
    pub fn represented_size(&self, column: [i32; 2]) -> u8 {
        self.states.get(&column).map_or(0, |state| state.current)
    }

    /// Returns each requested far tile once, including every vertical tile needed to
    /// cover the configured world bounds. The caller may queue these incrementally.
    #[cfg(test)]
    pub fn requested_tiles(&self) -> Vec<TileKey> {
        let mut keys = HashSet::new();
        for (&[x, z], &size) in &self.desired {
            if size <= 1 {
                continue;
            }
            let span_chunks = i32::from(size) * 2;
            let tx = x.div_euclid(span_chunks);
            let tz = z.div_euclid(span_chunks);
            for ty in self.tile_y_range(size) {
                if let Ok(key) = TileKey::new(size, [tx, ty, tz]) {
                    keys.insert(key);
                }
            }
        }
        let mut keys: Vec<_> = keys.into_iter().collect();
        keys.sort_by_key(|key| (key.cell_size, key.position));
        keys
    }

    /// Returns the current mask and advances only the smooth frontier scalar. Column
    /// transitions are shader-timed, so this path does not rescan the fixed grid.
    pub fn frame(&mut self, now: f32) -> &CoverageFrame {
        let finished: Vec<_> = self
            .deferred
            .iter()
            .copied()
            .filter(|column| {
                self.states.get(column).is_none_or(|state| {
                    state.current == state.previous
                        || now - state.transition_start >= self.config.transition_seconds
                })
            })
            .collect();
        for column in finished {
            self.deferred.remove(&column);
            self.refresh_column(column, now);
        }
        if self.frontier_initialized {
            let dt = (now - self.last_frame_time).clamp(0.0, 0.1);
            let current = self.frame.frontier_radius_blocks;
            let target = self.frontier_target;
            if target <= current {
                self.frame.frontier_radius_blocks = target;
            } else {
                let alpha = 1.0 - (-8.0 * dt).exp();
                self.frame.frontier_radius_blocks =
                    (current + (target - current) * alpha).min(target);
            }
        }
        self.last_frame_time = now;
        &self.frame
    }

    /// Whether a representation swap is waiting for its active transition to finish.
    /// The runtime uses this to publish a new frame when time alone makes the swap due.
    pub fn has_deferred_updates(&self) -> bool {
        !self.deferred.is_empty()
    }

    fn valid_y_chunk(&self, y: i32) -> bool {
        (self.config.min_y_chunk..=self.config.max_y_chunk).contains(&y)
    }

    fn valid_tile(&self, key: TileKey) -> bool {
        if !matches!(key.cell_size, 2 | 4 | 8 | 16) || key.cell_size > self.config.max_cell_size {
            return false;
        }
        let Ok(origin) = key.origin() else {
            return false;
        };
        let span = i32::from(key.cell_size) * 32;
        let min_y = self.config.min_y_chunk.saturating_mul(16);
        let max_y = self
            .config
            .max_y_chunk
            .saturating_add(1)
            .saturating_mul(16)
            .saturating_sub(1);
        origin[1] <= max_y && origin[1].saturating_add(span) > min_y
    }

    fn tile_y_range(&self, size: u8) -> std::ops::RangeInclusive<i32> {
        let span = i32::from(size) * 32;
        let min_y = self.config.min_y_chunk.saturating_mul(16);
        let max_y = self
            .config
            .max_y_chunk
            .saturating_add(1)
            .saturating_mul(16)
            .saturating_sub(1);
        min_y.div_euclid(span)..=max_y.div_euclid(span)
    }

    fn base_size(&self, [x, z]: [i32; 2]) -> u8 {
        let dx = i64::from(x) * 2 + 1 - (i64::from(self.center[0]) * 2 + 1);
        let dz = i64::from(z) * 2 + 1 - (i64::from(self.center[1]) * 2 + 1);
        let distance2 = dx * dx + dz * dz;
        let near = i64::from(self.config.near_radius_chunks) * 2;
        if distance2 <= near * near {
            return 1;
        }
        let mut size = 2u8;
        let mut boundary = near * 2;
        while size < self.config.max_cell_size && distance2 > boundary * boundary {
            size *= 2;
            boundary *= 2;
        }
        if distance2 > boundary * boundary {
            0
        } else {
            size.min(self.config.max_cell_size)
        }
    }

    fn choose_size(&self, column: [i32; 2], prior: Option<u8>) -> u8 {
        let mut target = self.base_size(column);
        if target == 0 || target == 1 {
            return target;
        }
        let Some(mut current) = prior.filter(|size| *size == 1 || matches!(*size, 2 | 4 | 8 | 16))
        else {
            return target;
        };
        let [x, z] = column;
        let dx = i64::from(x) * 2 + 1 - (i64::from(self.center[0]) * 2 + 1);
        let dz = i64::from(z) * 2 + 1 - (i64::from(self.center[1]) * 2 + 1);
        let distance = ((dx * dx + dz * dz) as f64).sqrt() * 0.5;
        let demote = f64::from(self.config.demotion_buffer_chunks);
        let promote = f64::from(self.config.promotion_buffer_chunks);
        if current > target {
            return target;
        }
        while current == target && current > 2 {
            let finer_boundary = f64::from(self.config.near_radius_chunks) * f64::from(current / 2);
            if distance < finer_boundary + promote {
                current /= 2;
                target = current;
            } else {
                break;
            }
        }
        while current < target {
            let boundary = f64::from(self.config.near_radius_chunks) * f64::from(current);
            if distance <= boundary + demote {
                target = current;
                break;
            }
            current = if current == 1 { 2 } else { current * 2 };
        }
        target.min(current).min(self.config.max_cell_size)
    }

    fn near_column_ready(&self, [x, z]: [i32; 2]) -> bool {
        self.near_ready_columns.contains(&[x, z])
    }

    fn near_chunk_mask(&self, [x, z]: [i32; 2]) -> u32 {
        (self.config.min_y_chunk..=self.config.max_y_chunk)
            .enumerate()
            .fold(0, |mask, (bit, y)| {
                if self.near_chunks.contains(&[x, y, z]) {
                    mask | (1u32 << bit)
                } else {
                    mask
                }
            })
    }

    fn tile_stack_ready(&self, size: u8, [x, z]: [i32; 2]) -> bool {
        let span_chunks = i32::from(size) * 2;
        let tile_x = x.div_euclid(span_chunks);
        let tile_z = z.div_euclid(span_chunks);
        self.ready_tile_columns.contains(&(size, tile_x, tile_z))
    }

    fn available_size(&self, column: [i32; 2], desired: u8) -> u8 {
        if desired == 0 {
            return 0;
        }
        // Ready full-detail prefetch can cover a band while its distant replacement loads.
        if self.near_column_ready(column) {
            return 1;
        }
        if desired == 1 {
            return 0;
        }
        for size in [2, 4, 8, 16] {
            if size > desired || size > self.config.max_cell_size {
                break;
            }
            if self.tile_stack_ready(size, column) {
                return size;
            }
        }
        0
    }

    fn representation_ready(&self, column: [i32; 2], size: u8) -> bool {
        match size {
            1 => self.near_column_ready(column),
            2 | 4 | 8 | 16 => self.tile_stack_ready(size, column),
            _ => false,
        }
    }

    fn refresh_column(&mut self, column: [i32; 2], now: f32) {
        self.refresh_column_inner(column, now, true, true);
    }

    fn refresh_column_inner(
        &mut self,
        column: [i32; 2],
        now: f32,
        update_frontier: bool,
        update_histogram: bool,
    ) {
        if !self.view_set || !self.in_grid(column) {
            return;
        }
        let desired = self.desired_size(column);
        let mut current = self.available_size(column, desired);
        let published = self.states.get(&column).map_or(0, |state| state.current);
        if current == 0
            && desired != 0
            && published != 0
            && self.representation_ready(column, published)
        {
            current = published;
        }
        let defer_swap = self.states.get(&column).is_some_and(|state| {
            current != state.current
                && state.current != state.previous
                && now - state.transition_start < self.config.transition_seconds
                && self.representation_ready(column, state.current)
        });
        if defer_swap {
            current = published;
            self.deferred.insert(column);
        } else {
            self.deferred.remove(&column);
        }
        let near_mask = self.near_chunk_mask(column);
        let index = self.index(column).unwrap();
        let (changed, representation_changed, was_ready, is_ready, gpu) = {
            let state = self.states.entry(column).or_default();
            if state.current == current && state.near_mask == near_mask {
                let ready = state.current != 0;
                (false, false, ready, ready, state.gpu())
            } else {
                let old = state.current;
                let representation_changed = old != current;
                if representation_changed {
                    state.previous = if old != 0 && current != 0 {
                        old
                    } else {
                        current
                    };
                    state.current = current;
                    state.transition_start = now;
                }
                state.near_mask = near_mask;
                (
                    true,
                    representation_changed,
                    old != 0,
                    current != 0,
                    state.gpu(),
                )
            }
        };
        if changed {
            if update_histogram && representation_changed && was_ready != is_ready {
                if is_ready {
                    self.remove_missing(column);
                } else {
                    self.add_missing(column);
                }
            }
            self.frame.columns[index] = gpu;
            if update_frontier {
                self.update_frontier(false);
            }
        }
    }

    fn refresh_tile_columns(&mut self, key: TileKey, now: f32) {
        if !self.view_set {
            return;
        }
        let span = i32::from(key.cell_size) * 2;
        let first_x = key.position[0].saturating_mul(span);
        let first_z = key.position[2].saturating_mul(span);
        for z in first_z..first_z.saturating_add(span) {
            for x in first_x..first_x.saturating_add(span) {
                self.refresh_column_inner([x, z], now, false, true);
            }
        }
        self.update_frontier(false);
    }

    fn refresh_near_column(&mut self, column: [i32; 2], now: f32) {
        let ready = (self.config.min_y_chunk..=self.config.max_y_chunk)
            .all(|y| self.near_chunks.contains(&[column[0], y, column[1]]));
        if ready {
            self.near_ready_columns.insert(column)
        } else {
            self.near_ready_columns.remove(&column)
        };
        self.refresh_column(column, now);
    }

    fn refresh_ready_tile_column(&mut self, key: TileKey, now: f32) {
        let horizontal = (key.cell_size, key.position[0], key.position[2]);
        let ready = self.tile_y_range(key.cell_size).all(|tile_y| {
            self.ready_tiles.contains(&TileKey {
                cell_size: key.cell_size,
                position: [key.position[0], tile_y, key.position[2]],
            })
        });
        let changed = if ready {
            self.ready_tile_columns.insert(horizontal)
        } else {
            self.ready_tile_columns.remove(&horizontal)
        };
        if changed {
            self.refresh_tile_columns(key, now);
        }
    }

    fn update_frontier(&mut self, immediate: bool) {
        if !self.view_set {
            return;
        }
        self.frontier_target = self.missing_by_distance2.first_key_value().map_or(
            self.frame.side as f32 * 8.0,
            |(distance2, _)| {
                ((*distance2 as f32).sqrt() - std::f32::consts::FRAC_1_SQRT_2).max(0.0) * 16.0
            },
        );
        self.frontier_initialized = true;
        if immediate {
            self.frame.frontier_radius_blocks = self.frontier_target;
        }
    }

    fn distance2(&self, [x, z]: [i32; 2]) -> i64 {
        let dx = i64::from(x) - i64::from(self.center[0]);
        let dz = i64::from(z) - i64::from(self.center[1]);
        dx * dx + dz * dz
    }

    fn add_missing(&mut self, column: [i32; 2]) {
        *self
            .missing_by_distance2
            .entry(self.distance2(column))
            .or_default() += 1;
    }

    fn remove_missing(&mut self, column: [i32; 2]) {
        let distance2 = self.distance2(column);
        if let Some(count) = self.missing_by_distance2.get_mut(&distance2) {
            *count -= 1;
            if *count == 0 {
                self.missing_by_distance2.remove(&distance2);
            }
        }
    }

    fn in_grid(&self, [x, z]: [i32; 2]) -> bool {
        self.index([x, z]).is_some()
    }

    fn index(&self, [x, z]: [i32; 2]) -> Option<usize> {
        let rx = x.checked_sub(self.frame.origin_chunk[0])?;
        let rz = z.checked_sub(self.frame.origin_chunk[1])?;
        if rx < 0 || rz < 0 || rx >= self.frame.side as i32 || rz >= self.frame.side as i32 {
            return None;
        }
        Some(rz as usize * self.frame.side + rx as usize)
    }

    #[cfg(test)]
    fn column_index(&self, column: [i32; 2]) -> Option<usize> {
        self.index(column)
    }
}

#[cfg(test)]
pub fn transition_weight(now: f32, start: f32) -> f32 {
    ((now - start) / 0.2).clamp(0.0, 1.0)
}

/// Old and new layers sum to one at every point in the transition.
#[cfg(test)]
pub fn complementary_weights(old_size: u8, new_size: u8, now: f32, start: f32) -> (f32, f32) {
    if old_size == new_size {
        return (0.0, 1.0);
    }
    let new_weight = transition_weight(now, start);
    (1.0 - new_weight, new_weight)
}

#[cfg(test)]
#[path = "lod_coverage_tests.rs"]
mod tests;
