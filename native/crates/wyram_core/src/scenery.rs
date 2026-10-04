//! Visual-only voxel summaries. They do not supply collision or simulation data.
//!
//! Each tile contains a 16³ grid. Cell widths double at every level; exact leaf
//! chunks become progressively coarser representations without losing the count
//! of non-air samples. Representative materials are approximate at higher levels.

use crate::{BLOCK_COUNT, BYTE_COUNT, CHUNK_SIDE};
mod wire;

/// Keeps each cell's exact sample count within `u32` (1024³ at the last level).
pub const MAX_LEVEL: u8 = 10;
pub const MAX_ENCODED_TILE_BYTES: usize = 20 + BLOCK_COUNT * 10;
// Bump when visual generation, sample positions, reduction, or encoding changes.
pub const CACHE_VERSION: u32 = 3;

/// One vote per horizontal column, taking its highest occupied child.
pub(crate) fn reduce_top(children: [(u32, u16); 8]) -> u16 {
    let mut weights = [(0u16, 0u8); 4];
    let mut used = 0;
    for lower in [0, 1, 4, 5] {
        let upper = lower | 2;
        let (occupied, material) = if children[upper].0 > 0 {
            children[upper]
        } else {
            children[lower]
        };
        if occupied == 0 {
            continue;
        }
        let slot = weights[..used]
            .iter()
            .position(|&(id, _)| id == material)
            .unwrap_or_else(|| {
                let slot = used;
                used += 1;
                slot
            });
        weights[slot].0 = material;
        weights[slot].1 += 1;
    }
    weights[..used]
        .iter()
        .max_by_key(|&&(id, weight)| (weight, std::cmp::Reverse(id)))
        .map_or(0, |&(id, _)| id)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LodError {
    OutOfBounds,
    BadLength,
    NotLeaf,
    MaxLevel,
    DuplicateChild,
    IncompatibleChildren,
    BadEncoding,
}

/// A material proxy and occupancy information for a visual cell.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct LodCell {
    occupied: u32,
    material: u16,
    child_mask: u8,
    mixed_materials: bool,
}

impl LodCell {
    pub fn material(self) -> u16 {
        self.material
    }
    pub fn occupied(self) -> u32 {
        self.occupied
    }
    /// Bits use x, y and z as the first, second and third octant bits.
    /// Leaf cells have no children and use zero.
    pub fn child_mask(self) -> u8 {
        self.child_mask
    }
    pub fn mixed_materials(self) -> bool {
        self.mixed_materials
    }

    pub(crate) fn uniform(material: u16, scale: u16) -> Self {
        let occupied = if material == 0 {
            0
        } else {
            u32::from(scale).pow(3)
        };
        Self {
            material,
            occupied,
            child_mask: if occupied > 0 && scale > 1 { 255 } else { 0 },
            mixed_materials: false,
        }
    }

    pub(crate) fn reduce(children: [Self; 8]) -> Self {
        let mut result = Self::default();
        let mut weights = [(0u16, 0u32); 8];
        let mut used = 0;
        for (octant, child) in children.into_iter().enumerate() {
            result.occupied += child.occupied;
            result.mixed_materials |= child.mixed_materials;
            if child.occupied == 0 {
                continue;
            }
            result.child_mask |= 1 << octant;
            let slot = weights[..used]
                .iter()
                .position(|&(id, _)| id == child.material)
                .unwrap_or_else(|| {
                    let slot = used;
                    used += 1;
                    slot
                });
            weights[slot].0 = child.material;
            weights[slot].1 += child.occupied;
        }
        result.mixed_materials |= used > 1;
        let mut best = 0;
        for &(material, weight) in &weights[..used] {
            if weight > best || (weight == best && material < result.material) {
                best = weight;
                result.material = material;
            }
        }
        result
    }
}

/// Coordinates index tiles at this level, rather than exact chunks.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct TileKey {
    position: [i32; 3],
    level: u8,
}

impl TileKey {
    pub fn new(position: [i32; 3], level: u8) -> Result<Self, LodError> {
        if level > MAX_LEVEL {
            return Err(LodError::MaxLevel);
        }
        Ok(Self { position, level })
    }
    pub fn position(self) -> [i32; 3] {
        self.position
    }
    pub fn level(self) -> u8 {
        self.level
    }
    pub fn scale(self) -> u16 {
        1 << self.level
    }
    pub fn origin(self) -> [i64; 3] {
        let width = CHUNK_SIDE as i64 * i64::from(self.scale());
        self.position
            .map(|coordinate| i64::from(coordinate) * width)
    }
    pub fn parent(self) -> Result<Self, LodError> {
        Self::new(
            self.position.map(|coordinate| coordinate.div_euclid(2)),
            self.level + 1,
        )
    }
    fn octant(self) -> usize {
        self.position
            .iter()
            .enumerate()
            .map(|(axis, coordinate)| (coordinate.rem_euclid(2) as usize) << axis)
            .sum()
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum Cells {
    Uniform(LodCell),
    Dense(Box<[LodCell]>),
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum TopMaterials {
    Uniform(u16),
    Dense(Box<[u16]>),
}

/// Immutable scenery data. Authoritative edits and revision ownership stay outside it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LodTile {
    key: TileKey,
    cells: Cells,
    occupied: u64,
    top: Option<TopMaterials>,
}

impl LodTile {
    pub fn uniform(key: TileKey, material: u16) -> Self {
        let cell = LodCell::uniform(material, key.scale());
        Self {
            key,
            cells: Cells::Uniform(cell),
            occupied: u64::from(cell.occupied) * BLOCK_COUNT as u64,
            top: None,
        }
    }

    pub fn from_chunk(key: TileKey, data: &[u8]) -> Result<Self, LodError> {
        if key.level != 0 {
            return Err(LodError::NotLeaf);
        }
        if data.len() != BYTE_COUNT {
            return Err(LodError::BadLength);
        }
        let cells = data
            .as_chunks::<2>()
            .0
            .iter()
            .map(|bytes| {
                let material = u16::from_le_bytes(*bytes);
                LodCell {
                    material,
                    occupied: u32::from(material != 0),
                    ..LodCell::default()
                }
            })
            .collect();
        Ok(Self::from_cells(key, cells))
    }

    /// Reduce eight complete siblings. Arrival order is irrelevant; duplicate or
    /// incompatible keys are rejected before even empty data can be accepted.
    pub fn reduce(children: [&Self; 8]) -> Result<Self, LodError> {
        let parent = children[0].key.parent()?;
        let mut ordered = [None; 8];
        for child in children {
            if child.key.level != parent.level - 1 || child.key.parent()? != parent {
                return Err(LodError::IncompatibleChildren);
            }
            let slot = &mut ordered[child.key.octant()];
            if slot.replace(child).is_some() {
                return Err(LodError::DuplicateChild);
            }
        }
        // Eight unique keys with one parent cover all eight octants.
        let ordered = ordered.map(|child| child.expect("complete validated sibling set"));
        if ordered.iter().all(|child| child.occupied == 0) {
            return Ok(Self::uniform(parent, 0));
        }
        let (cells, top): (Vec<_>, Vec<_>) = (0..BLOCK_COUNT)
            .map(|at| {
                let position = [
                    at % CHUNK_SIDE,
                    at / (CHUNK_SIDE * CHUNK_SIDE),
                    (at / CHUNK_SIDE) % CHUNK_SIDE,
                ];
                let octant =
                    (position[0] / 8) | ((position[1] / 8) << 1) | ((position[2] / 8) << 2);
                let local = position.map(|coordinate| coordinate % 8 * 2);
                let first = (local[1] * CHUNK_SIDE + local[2]) * CHUNK_SIDE + local[0];
                // Aligned pairs never straddle a child tile; offsets stay inside its
                // 16³ storage. Packed cells follow the same y/z/x order as chunks.
                let samples = std::array::from_fn(|sample| {
                    let offset = (sample & 1)
                        + ((sample >> 1) & 1) * CHUNK_SIDE * CHUNK_SIDE
                        + ((sample >> 2) & 1) * CHUNK_SIDE;
                    ordered[octant].cell_at(first + offset)
                });
                let top = reduce_top(std::array::from_fn(|sample| {
                    let offset = (sample & 1)
                        + ((sample >> 1) & 1) * CHUNK_SIDE * CHUNK_SIDE
                        + ((sample >> 2) & 1) * CHUNK_SIDE;
                    (
                        samples[sample].occupied,
                        ordered[octant].top_at(first + offset),
                    )
                }));
                (LodCell::reduce(samples), top)
            })
            .unzip();
        Ok(Self::from_cells_with_top(parent, cells, top))
    }

    pub(crate) fn from_cells_with_top(key: TileKey, cells: Vec<LodCell>, top: Vec<u16>) -> Self {
        let mut tile = Self::from_cells(key, cells);
        if top
            .iter()
            .enumerate()
            .any(|(i, &material)| material != tile.cell_at(i).material)
        {
            tile.top = Some(if top.iter().all(|&id| id == top[0]) {
                TopMaterials::Uniform(top[0])
            } else {
                TopMaterials::Dense(top.into_boxed_slice())
            });
        }
        tile
    }

    pub(crate) fn from_cells(key: TileKey, cells: Vec<LodCell>) -> Self {
        let occupied = cells.iter().map(|cell| u64::from(cell.occupied)).sum();
        let first = cells[0];
        let cells = if cells.iter().all(|&cell| cell == first) {
            Cells::Uniform(first)
        } else {
            Cells::Dense(cells.into_boxed_slice())
        };
        Self {
            key,
            cells,
            occupied,
            top: None,
        }
    }

    pub fn key(&self) -> TileKey {
        self.key
    }
    pub fn occupied(&self) -> u64 {
        self.occupied
    }
    /// Cell payload bytes, excluding the tile object's fixed metadata and allocator overhead.
    pub fn resident_cell_bytes(&self) -> usize {
        let cells = match &self.cells {
            Cells::Uniform(cell) if cell.occupied == 0 => 0,
            Cells::Uniform(_) => size_of::<LodCell>(),
            Cells::Dense(cells) => size_of_val(&**cells),
        };
        cells
            + match &self.top {
                None => 0,
                Some(TopMaterials::Uniform(_)) => size_of::<u16>(),
                Some(TopMaterials::Dense(top)) => size_of_val(&**top),
            }
    }
    /// Approximate exposed top-face color, independent of volume material.
    pub fn top_material(&self, position: [usize; 3]) -> Result<u16, LodError> {
        let at = crate::index(position[0], position[1], position[2])
            .map_err(|_| LodError::OutOfBounds)?;
        Ok(self.top_at(at))
    }
    fn top_at(&self, at: usize) -> u16 {
        match &self.top {
            None => self.cell_at(at).material,
            Some(TopMaterials::Uniform(id)) => *id,
            Some(TopMaterials::Dense(top)) => top[at],
        }
    }
    pub fn cell(&self, position: [usize; 3]) -> Result<LodCell, LodError> {
        let at = crate::index(position[0], position[1], position[2])
            .map_err(|_| LodError::OutOfBounds)?;
        Ok(self.cell_at(at))
    }
    fn cell_at(&self, at: usize) -> LodCell {
        match &self.cells {
            Cells::Uniform(cell) => *cell,
            Cells::Dense(cells) => cells[at],
        }
    }
}
