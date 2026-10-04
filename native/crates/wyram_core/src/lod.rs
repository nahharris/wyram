//! Immutable, world-aligned summaries for distant voxel presentation.
use std::collections::{BTreeMap, HashSet};

use crate::{BYTE_COUNT, CHUNK_SIDE, read_block};

pub const TILE_CELLS: usize = 32;
pub const TILE_SIDE_WITH_HALO: usize = TILE_CELLS + 2;
pub const TILE_CELL_COUNT: usize = TILE_SIDE_WITH_HALO * TILE_SIDE_WITH_HALO * TILE_SIDE_WITH_HALO;
pub const MAX_TILE_ENCODED_BYTES: usize = 1024 * 1024;
const TILE_MAGIC: &[u8; 4] = b"LT01";
const CELL_WIRE_BYTES: usize = 10;
const WORLD_LIMIT: i64 = 1_000_000;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct TileKey {
    pub cell_size: u8,
    pub position: [i32; 3],
}

impl TileKey {
    pub fn new(cell_size: u8, position: [i32; 3]) -> Result<Self, &'static str> {
        if !matches!(cell_size, 2 | 4 | 8 | 16) {
            return Err("invalid LOD cell size");
        }
        let key = Self {
            cell_size,
            position,
        };
        key.origin()?;
        Ok(key)
    }

    pub fn origin(self) -> Result<[i32; 3], &'static str> {
        if !matches!(self.cell_size, 2 | 4 | 8 | 16) {
            return Err("invalid LOD cell size");
        }
        let size = i64::from(self.cell_size);
        let span = size * TILE_CELLS as i64;
        let mut origin = [0; 3];
        for (axis, coordinate) in self.position.into_iter().enumerate() {
            let start = i64::from(coordinate)
                .checked_mul(span)
                .ok_or("LOD tile coordinate overflow")?;
            let end = start
                .checked_add(span)
                .ok_or("LOD tile coordinate overflow")?;
            if start - size < -WORLD_LIMIT || end + size > WORLD_LIMIT {
                return Err("LOD tile outside world bounds");
            }
            origin[axis] = i32::try_from(start).map_err(|_| "LOD tile coordinate overflow")?;
        }
        Ok(origin)
    }

    pub fn span(self) -> i32 {
        i32::from(self.cell_size) * TILE_CELLS as i32
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Cell {
    pub material: u16,
    pub top_material: u16,
    pub liquid: u16,
    pub coverage: u8,
    pub solid_height: u8,
    pub liquid_height: u8,
    pub reserved: u8,
}

impl Cell {
    fn validate(self, cell_size: u8) -> Result<(), &'static str> {
        if self.reserved != 0
            || self.solid_height > cell_size
            || self.liquid_height > cell_size
            || (self.material == 0) != (self.solid_height == 0)
            || (self.liquid == 0) != (self.liquid_height == 0)
        {
            return Err("invalid LOD cell");
        }
        Ok(())
    }

    fn encode_into(self, out: &mut Vec<u8>) {
        out.extend_from_slice(&self.material.to_le_bytes());
        out.extend_from_slice(&self.top_material.to_le_bytes());
        out.extend_from_slice(&self.liquid.to_le_bytes());
        out.extend_from_slice(&[
            self.coverage,
            self.solid_height,
            self.liquid_height,
            self.reserved,
        ]);
    }

    fn decode(bytes: &[u8]) -> Self {
        Self {
            material: u16::from_le_bytes([bytes[0], bytes[1]]),
            top_material: u16::from_le_bytes([bytes[2], bytes[3]]),
            liquid: u16::from_le_bytes([bytes[4], bytes[5]]),
            coverage: bytes[6],
            solid_height: bytes[7],
            liquid_height: bytes[8],
            reserved: bytes[9],
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Tile {
    pub key: TileKey,
    /// Z-major inside Y, then X: `(y * 34 + z) * 34 + x`.
    /// Rendered cells use indices 1 through 32; the outer cells are a one-cell halo.
    pub cells: Vec<Cell>,
}

#[derive(Clone, Copy, Debug)]
pub struct ChunkOverride<'a> {
    pub key: [i32; 3],
    pub data: &'a [u8],
}

impl Tile {
    pub fn empty(key: TileKey) -> Result<Self, &'static str> {
        key.origin()?;
        Ok(Self {
            key,
            cells: vec![Cell::default(); TILE_CELL_COUNT],
        })
    }

    pub fn sample(&self, world: [i32; 3]) -> Option<Cell> {
        let origin = self.key.origin().ok()?;
        let size = i32::from(self.key.cell_size);
        let mut cell = [0usize; 3];
        for axis in 0..3 {
            let relative = world[axis].checked_sub(origin[axis])?;
            let index = relative.div_euclid(size).checked_add(1)?;
            if !(0..TILE_SIDE_WITH_HALO as i32).contains(&index) {
                return None;
            }
            cell[axis] = index as usize;
        }
        self.cells
            .get(cell_index(cell[0], cell[1], cell[2]))
            .copied()
    }

    pub fn encode(&self) -> Result<Vec<u8>, &'static str> {
        self.validate()?;
        let mut out = Vec::with_capacity(4 + TILE_CELL_COUNT * 3);
        out.extend_from_slice(TILE_MAGIC);
        let mut start = 0;
        while start < self.cells.len() {
            let cell = self.cells[start];
            let mut end = start + 1;
            while end < self.cells.len()
                && self.cells[end] == cell
                && end - start < u16::MAX as usize
            {
                end += 1;
            }
            out.extend_from_slice(&((end - start) as u16).to_le_bytes());
            cell.encode_into(&mut out);
            start = end;
        }
        if out.len() > MAX_TILE_ENCODED_BYTES {
            return Err("encoded LOD tile exceeds size limit");
        }
        Ok(out)
    }

    pub fn decode(key: TileKey, bytes: &[u8]) -> Result<Self, &'static str> {
        key.origin()?;
        if bytes.len() > MAX_TILE_ENCODED_BYTES || bytes.len() < 4 || &bytes[..4] != TILE_MAGIC {
            return Err("invalid LOD tile encoding");
        }
        let mut cells = Vec::with_capacity(TILE_CELL_COUNT);
        let mut cursor = 4;
        while cursor < bytes.len() {
            if bytes.len() - cursor < 2 + CELL_WIRE_BYTES {
                return Err("truncated LOD tile run");
            }
            let run = u16::from_le_bytes([bytes[cursor], bytes[cursor + 1]]) as usize;
            cursor += 2;
            if run == 0 || run > TILE_CELL_COUNT - cells.len() {
                return Err("invalid LOD tile run length");
            }
            let cell = Cell::decode(&bytes[cursor..cursor + CELL_WIRE_BYTES]);
            cell.validate(key.cell_size)?;
            cells.resize(cells.len() + run, cell);
            cursor += CELL_WIRE_BYTES;
        }
        if cursor != bytes.len() || cells.len() != TILE_CELL_COUNT {
            return Err("incomplete LOD tile");
        }
        Ok(Self { key, cells })
    }

    pub fn apply_overrides(
        &mut self,
        edits: &[ChunkOverride<'_>],
        liquid_ids: &[u16],
    ) -> Result<(), &'static str> {
        if edits.len() > 128 || liquid_ids.len() > 256 || liquid_ids.contains(&0) {
            return Err("invalid LOD edit batch");
        }
        let origin = self.key.origin()?;
        if self.cells.len() != TILE_CELL_COUNT {
            return Err("invalid LOD tile storage");
        }
        let liquids: HashSet<_> = liquid_ids.iter().copied().collect();
        let mut unique = HashSet::with_capacity(edits.len());
        let mut changes = Vec::new();
        for edit in edits {
            if edit.data.len() != BYTE_COUNT {
                return Err("invalid LOD override chunk");
            }
            if !unique.insert(edit.key) {
                return Err("duplicate LOD override chunk");
            }
            let chunk_origin_wide = edit.key.map(|c| i64::from(c) * CHUNK_SIDE as i64);
            if chunk_origin_wide
                .iter()
                .any(|&p| p < -WORLD_LIMIT || p + CHUNK_SIDE as i64 > WORLD_LIMIT)
            {
                return Err("LOD override outside world bounds");
            }
            let chunk_origin = chunk_origin_wide.map(|p| p as i32);
            let size = i32::from(self.key.cell_size);
            let first: [i32; 3] = std::array::from_fn(|axis| {
                (chunk_origin[axis] - origin[axis]).div_euclid(size) + 1
            });
            let last: [i32; 3] = std::array::from_fn(|axis| {
                (chunk_origin[axis] + 16 - size - origin[axis]).div_euclid(size) + 1
            });
            if (0..3).any(|axis| {
                last[axis] < 0
                    || first[axis] >= TILE_SIDE_WITH_HALO as i32
                    || first[axis] > last[axis]
            }) {
                continue;
            }
            let ranges: [std::ops::RangeInclusive<usize>; 3] = std::array::from_fn(|axis| {
                (first[axis].max(0) as usize)
                    ..=(last[axis].min(TILE_SIDE_WITH_HALO as i32 - 1) as usize)
            });
            for y in ranges[1].clone() {
                for z in ranges[2].clone() {
                    for x in ranges[0].clone() {
                        let coordinates = [x, y, z];
                        let cell_origin = std::array::from_fn(|axis| {
                            origin[axis] + (coordinates[axis] as i32 - 1) * size
                        });
                        let cell = summarize_chunk_cell(
                            edit.data,
                            cell_origin,
                            chunk_origin,
                            size,
                            &liquids,
                        )?;
                        changes.push((cell_index(x, y, z), cell));
                    }
                }
            }
        }
        for (index, cell) in changes {
            self.cells[index] = cell;
        }
        Ok(())
    }

    fn validate(&self) -> Result<(), &'static str> {
        self.key.origin()?;
        if self.cells.len() != TILE_CELL_COUNT {
            return Err("invalid LOD tile storage");
        }
        self.cells
            .iter()
            .try_for_each(|cell| cell.validate(self.key.cell_size))
    }
}

fn summarize_chunk_cell(
    data: &[u8],
    cell_origin: [i32; 3],
    chunk_origin: [i32; 3],
    size: i32,
    liquids: &HashSet<u16>,
) -> Result<Cell, &'static str> {
    let mut solids = BTreeMap::<u16, usize>::new();
    let mut solid_voxels = 0usize;
    let mut column_tops = vec![None; (size * size) as usize];
    let mut top_y = None;
    let mut fluid_top = None;
    let mut top_fluids = BTreeMap::<u16, usize>::new();
    for z in 0..size {
        for x in 0..size {
            let column_index = (z * size + x) as usize;
            let mut column_top = None;
            for y in 0..size {
                let local_x = (cell_origin[0] + x - chunk_origin[0]) as usize;
                let local_y = (cell_origin[1] + y - chunk_origin[1]) as usize;
                let local_z = (cell_origin[2] + z - chunk_origin[2]) as usize;
                let material = read_block(data, local_x, local_y, local_z)
                    .map_err(|_| "invalid LOD override chunk")?;
                if material == 0 {
                    continue;
                }
                if liquids.contains(&material) {
                    match fluid_top {
                        None => {
                            fluid_top = Some(y);
                            *top_fluids.entry(material).or_default() += 1;
                        }
                        Some(previous) if y > previous => {
                            fluid_top = Some(y);
                            top_fluids.clear();
                            *top_fluids.entry(material).or_default() += 1;
                        }
                        Some(previous) if y == previous => {
                            *top_fluids.entry(material).or_default() += 1;
                        }
                        _ => {}
                    }
                } else {
                    solid_voxels += 1;
                    *solids.entry(material).or_default() += 1;
                    column_top = Some((y as usize + 1, material));
                    top_y = Some(top_y.map_or(y, |previous: i32| previous.max(y)));
                }
            }
            if let Some(top) = column_top {
                column_tops[column_index] = Some(top);
            }
        }
    }
    let material = weighted_id(&solids);
    let liquid = weighted_id(&top_fluids);
    let mut top_materials = BTreeMap::<u16, usize>::new();
    for (height, id) in column_tops.iter().flatten() {
        if Some(*height as i32 - 1) == top_y {
            *top_materials.entry(*id).or_default() += 1;
        }
    }
    let horizontal_count = column_tops.len();
    let occupied_columns = column_tops.iter().filter(|top| top.is_some()).count();
    let top_supported = top_materials.values().sum::<usize>() * 2 >= horizontal_count;
    let solid_supported = occupied_columns * 2 >= horizontal_count;
    let solid_height = if !solid_supported {
        0
    } else {
        let total: usize = column_tops
            .iter()
            .flatten()
            .map(|(height, _)| *height)
            .sum();
        ((total + horizontal_count / 2) / horizontal_count).max(1) as u8
    };
    let mut liquid_height = fluid_top.map_or(0, |height| height as u8 + 1);
    let mut liquid = liquid;
    if liquid_height <= solid_height {
        liquid = 0;
        liquid_height = 0;
    }
    let volume = size.pow(3) as usize;
    let cell = Cell {
        material: if solid_supported || top_supported {
            if material != 0 {
                material
            } else {
                weighted_id(&top_materials)
            }
        } else {
            0
        },
        top_material: if top_supported {
            weighted_id(&top_materials)
        } else {
            0
        },
        liquid,
        coverage: ((solid_voxels * 255 + volume / 2) / volume) as u8,
        solid_height: if top_supported && solid_height == 0 {
            1
        } else {
            solid_height
        },
        liquid_height,
        reserved: 0,
    };
    cell.validate(size as u8)?;
    Ok(cell)
}

fn weighted_id(counts: &BTreeMap<u16, usize>) -> u16 {
    counts
        .iter()
        .max_by(|(left_id, left_count), (right_id, right_count)| {
            left_count
                .cmp(right_count)
                .then_with(|| right_id.cmp(left_id))
        })
        .map_or(0, |(&id, _)| id)
}

#[inline]
pub(crate) fn cell_index(x: usize, y: usize, z: usize) -> usize {
    (y * TILE_SIDE_WITH_HALO + z) * TILE_SIDE_WITH_HALO + x
}
