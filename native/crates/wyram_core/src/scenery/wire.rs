use super::{Cells, LodCell, LodError, LodTile, TileKey};
use crate::BLOCK_COUNT;

const HEADER: usize = 20;
const CELL: usize = 8;

impl LodTile {
    /// Stable little-endian visual data, independent of Rust struct layout.
    pub fn encode(&self) -> Vec<u8> {
        let (mode, payload) = match &self.cells {
            Cells::Uniform(cell) if cell.occupied == 0 => (0, 0),
            Cells::Uniform(_) => (1, CELL),
            Cells::Dense(_) => (2, CELL * BLOCK_COUNT),
        };
        let mut bytes = Vec::with_capacity(HEADER + payload);
        bytes.extend_from_slice(b"WSL1");
        bytes.extend_from_slice(&[self.key.level, mode, 0, 0]);
        for coordinate in self.key.position {
            bytes.extend_from_slice(&coordinate.to_le_bytes());
        }
        match &self.cells {
            Cells::Uniform(cell) if mode == 1 => encode_cell(&mut bytes, *cell),
            Cells::Dense(cells) => cells.iter().for_each(|&cell| encode_cell(&mut bytes, cell)),
            Cells::Uniform(_) => {}
        }
        bytes
    }

    /// Reject malformed counts, masks, flags and lengths before allocating a grid.
    pub fn decode(bytes: &[u8]) -> Result<Self, LodError> {
        if bytes.len() < HEADER || &bytes[..4] != b"WSL1" || bytes[6..8] != [0, 0] {
            return Err(LodError::BadEncoding);
        }
        let expected = match bytes[5] {
            0 => HEADER,
            1 => HEADER + CELL,
            2 => HEADER + CELL * BLOCK_COUNT,
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
                let cell = decode_cell(&bytes[HEADER..], key)?;
                Ok(Self {
                    key,
                    cells: Cells::Uniform(cell),
                    occupied: u64::from(cell.occupied) * BLOCK_COUNT as u64,
                })
            }
            2 => {
                let cells = bytes[HEADER..]
                    .as_chunks::<CELL>()
                    .0
                    .iter()
                    .map(|bytes| decode_cell(bytes, key))
                    .collect::<Result<Vec<_>, _>>()?;
                Ok(Self::from_cells(key, cells))
            }
            _ => Err(LodError::BadEncoding),
        }
    }
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
