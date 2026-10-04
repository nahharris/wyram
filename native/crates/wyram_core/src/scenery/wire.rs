use super::{Cells, LodCell, LodError, LodTile, TileKey, TopMaterials};
use crate::BLOCK_COUNT;

const HEADER: usize = 20;
const CELL: usize = 8;

impl LodTile {
    /// Stable little-endian visual data, independent of Rust struct layout.
    pub fn encode(&self) -> Vec<u8> {
        let extended = self.top.is_some();
        let cell_size = CELL + if extended { 2 } else { 0 };
        let mode = if self.occupied == 0 {
            0
        } else if matches!(self.cells, Cells::Uniform(_))
            && !matches!(self.top, Some(TopMaterials::Dense(_)))
        {
            1
        } else {
            2
        };
        let count = match mode {
            0 => 0,
            1 => 1,
            _ => BLOCK_COUNT,
        };
        let payload = count * cell_size;
        let mut bytes = Vec::with_capacity(HEADER + payload);
        bytes.extend_from_slice(if extended { b"WSL2" } else { b"WSL1" });
        bytes.extend_from_slice(&[self.key.level, mode, 0, 0]);
        for coordinate in self.key.position {
            bytes.extend_from_slice(&coordinate.to_le_bytes());
        }
        for at in 0..count {
            encode_cell(&mut bytes, self.cell_at(at));
            if extended {
                bytes.extend_from_slice(&self.top_at(at).to_le_bytes());
            }
        }
        bytes
    }

    /// Reject malformed counts, masks, flags and lengths before allocating a grid.
    pub fn decode(bytes: &[u8]) -> Result<Self, LodError> {
        if bytes.len() < HEADER
            || !matches!(&bytes[..4], b"WSL1" | b"WSL2")
            || bytes[6..8] != [0, 0]
        {
            return Err(LodError::BadEncoding);
        }
        let extended = &bytes[..4] == b"WSL2";
        let cell_size = CELL + if extended { 2 } else { 0 };
        let expected = match bytes[5] {
            0 => HEADER,
            1 => HEADER + cell_size,
            2 => HEADER + cell_size * BLOCK_COUNT,
            _ => return Err(LodError::BadEncoding),
        };
        if bytes.len() != expected {
            return Err(LodError::BadEncoding);
        }
        let position = std::array::from_fn(|axis| {
            let at = 8 + axis * 4;
            i32::from_le_bytes(
                bytes[at..at + 4]
                    .try_into()
                    .expect("validated header length"),
            )
        });
        let key = TileKey::new(position, bytes[4])?;
        match bytes[5] {
            0 => Ok(Self::uniform(key, 0)),
            1 => {
                let cell = decode_cell(&bytes[HEADER..HEADER + CELL], key)?;
                if extended {
                    let top = decode_top(&bytes[HEADER + CELL..], cell, key)?;
                    Ok(Self::from_cells_with_top(
                        key,
                        vec![cell; BLOCK_COUNT],
                        vec![top; BLOCK_COUNT],
                    ))
                } else {
                    Ok(Self {
                        key,
                        cells: Cells::Uniform(cell),
                        occupied: u64::from(cell.occupied) * BLOCK_COUNT as u64,
                        top: None,
                    })
                }
            }
            2 => {
                let mut cells = Vec::with_capacity(BLOCK_COUNT);
                let mut top = if extended {
                    Vec::with_capacity(BLOCK_COUNT)
                } else {
                    Vec::new()
                };
                for bytes in bytes[HEADER..].chunks_exact(cell_size) {
                    let cell = decode_cell(&bytes[..CELL], key)?;
                    if extended {
                        top.push(decode_top(&bytes[CELL..], cell, key)?);
                    }
                    cells.push(cell);
                }
                Ok(if extended {
                    Self::from_cells_with_top(key, cells, top)
                } else {
                    Self::from_cells(key, cells)
                })
            }
            _ => Err(LodError::BadEncoding),
        }
    }
}

fn decode_top(bytes: &[u8], cell: LodCell, key: TileKey) -> Result<u16, LodError> {
    let top = u16::from_le_bytes(bytes.try_into().expect("validated surface length"));
    if (top == 0) != (cell.occupied == 0) || (key.level == 0 && top != cell.material) {
        return Err(LodError::BadEncoding);
    }
    Ok(top)
}

fn encode_cell(bytes: &mut Vec<u8>, cell: LodCell) {
    bytes.extend_from_slice(&cell.material.to_le_bytes());
    bytes.extend_from_slice(&cell.occupied.to_le_bytes());
    bytes.extend_from_slice(&[cell.child_mask, u8::from(cell.mixed_materials)]);
}

fn decode_cell(bytes: &[u8], key: TileKey) -> Result<LodCell, LodError> {
    let material = u16::from_le_bytes(bytes[..2].try_into().expect("validated cell length"));
    let occupied = u32::from_le_bytes(bytes[2..6].try_into().expect("validated cell length"));
    let child_mask = bytes[6];
    let mixed_materials = bytes[7] == 1;
    let capacity = u32::from(key.scale()).pow(3);
    if bytes[7] > 1
        || occupied > capacity
        || (material == 0) != (occupied == 0)
        || (mixed_materials && occupied < 2)
    {
        return Err(LodError::BadEncoding);
    }
    if key.level == 0 {
        if child_mask != 0 || mixed_materials {
            return Err(LodError::BadEncoding);
        }
    } else {
        let children = child_mask.count_ones();
        let child_capacity = capacity / 8;
        if children > occupied || occupied > children * child_capacity {
            return Err(LodError::BadEncoding);
        }
    }
    Ok(LodCell {
        material,
        occupied,
        child_mask,
        mixed_materials,
    })
}
