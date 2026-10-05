use std::collections::HashSet;

use wyram_core::lod::{MAX_TILE_ENCODED_BYTES, TileKey};

pub const MAX_LOD_BATCH_BYTES: usize = 1024 * 1024;
const HEADER_BYTES: usize = 14;
const RECORD_HEADER_BYTES: usize = 25;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WireTile {
    pub key: TileKey,
    pub revision: u64,
    pub payload: Vec<u8>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WireBatch {
    pub epoch: u64,
    pub tiles: Vec<WireTile>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WireError {
    TooLarge,
    Truncated,
    BadMagic,
    InvalidTileCount,
    InvalidTileKey,
    InvalidPayload,
    DuplicateTile,
    TrailingBytes,
}

pub fn decode(bytes: &[u8]) -> Result<WireBatch, WireError> {
    if bytes.len() > MAX_LOD_BATCH_BYTES {
        return Err(WireError::TooLarge);
    }
    if bytes.len() < HEADER_BYTES {
        return Err(WireError::Truncated);
    }
    if &bytes[..4] != b"WL01" {
        return Err(WireError::BadMagic);
    }
    let epoch = u64::from_le_bytes(bytes[4..12].try_into().expect("fixed slice"));
    let count = u16::from_le_bytes(bytes[12..14].try_into().expect("fixed slice")) as usize;
    if !(1..=2).contains(&count) {
        return Err(WireError::InvalidTileCount);
    }

    let mut cursor = HEADER_BYTES;
    let mut keys = HashSet::with_capacity(count);
    let mut tiles = Vec::with_capacity(count);
    for _ in 0..count {
        if bytes.len() - cursor < RECORD_HEADER_BYTES {
            return Err(WireError::Truncated);
        }
        let cell_size = bytes[cursor];
        let position = [
            i32::from_le_bytes(
                bytes[cursor + 1..cursor + 5]
                    .try_into()
                    .expect("fixed slice"),
            ),
            i32::from_le_bytes(
                bytes[cursor + 5..cursor + 9]
                    .try_into()
                    .expect("fixed slice"),
            ),
            i32::from_le_bytes(
                bytes[cursor + 9..cursor + 13]
                    .try_into()
                    .expect("fixed slice"),
            ),
        ];
        let revision = u64::from_le_bytes(
            bytes[cursor + 13..cursor + 21]
                .try_into()
                .expect("fixed slice"),
        );
        let payload_len = u32::from_le_bytes(
            bytes[cursor + 21..cursor + 25]
                .try_into()
                .expect("fixed slice"),
        ) as usize;
        cursor += RECORD_HEADER_BYTES;

        let key = TileKey::new(cell_size, position).map_err(|_| WireError::InvalidTileKey)?;
        if !keys.insert(key) {
            return Err(WireError::DuplicateTile);
        }
        if !(16..=MAX_TILE_ENCODED_BYTES).contains(&payload_len) {
            return Err(WireError::InvalidPayload);
        }
        let payload_end = cursor
            .checked_add(payload_len)
            .filter(|&end| end <= bytes.len())
            .ok_or(WireError::Truncated)?;
        let payload = &bytes[cursor..payload_end];
        if &payload[..4] != b"LT01" {
            return Err(WireError::InvalidPayload);
        }
        tiles.push(WireTile {
            key,
            revision,
            payload: payload.to_vec(),
        });
        cursor = payload_end;
    }
    if cursor != bytes.len() {
        return Err(WireError::TrailingBytes);
    }
    Ok(WireBatch { epoch, tiles })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn record(size: u8, position: [i32; 3], revision: u64, payload: &[u8]) -> Vec<u8> {
        let mut out = vec![size];
        for coordinate in position {
            out.extend_from_slice(&coordinate.to_le_bytes());
        }
        out.extend_from_slice(&revision.to_le_bytes());
        out.extend_from_slice(&(payload.len() as u32).to_le_bytes());
        out.extend_from_slice(payload);
        out
    }

    fn batch(records: &[Vec<u8>]) -> Vec<u8> {
        let mut out = b"WL01".to_vec();
        out.extend_from_slice(&42u64.to_le_bytes());
        out.extend_from_slice(&(records.len() as u16).to_le_bytes());
        for item in records {
            out.extend_from_slice(item);
        }
        out
    }

    #[test]
    fn decodes_exact_batch_and_rejects_trailing_or_duplicate_records() {
        let payload = b"LT01payload12345";
        let one = record(2, [-1, 0, 3], u64::MAX, payload);
        let two = record(4, [0, -2, 3], 9, payload);
        let decoded = decode(&batch(&[one.clone(), two])).unwrap();
        assert_eq!(decoded.epoch, 42);
        assert_eq!(decoded.tiles.len(), 2);
        assert_eq!(decoded.tiles[0].key, TileKey::new(2, [-1, 0, 3]).unwrap());
        assert_eq!(decoded.tiles[0].revision, u64::MAX);
        assert_eq!(
            decode(&[batch(std::slice::from_ref(&one)), vec![0]].concat()),
            Err(WireError::TrailingBytes)
        );
        assert_eq!(
            decode(&batch(&[one.clone(), one])),
            Err(WireError::DuplicateTile)
        );
    }

    #[test]
    fn rejects_bad_headers_keys_payloads_lengths_and_limits() {
        let payload = b"LT01payload12345";
        assert_eq!(decode(b"WL0"), Err(WireError::Truncated));
        assert_eq!(
            decode(b"NOPE\0\0\0\0\0\0\0\0\x01\0"),
            Err(WireError::BadMagic)
        );
        assert_eq!(decode(&batch(&[])), Err(WireError::InvalidTileCount));
        assert_eq!(
            decode(&batch(&[record(3, [0; 3], 1, payload)])),
            Err(WireError::InvalidTileKey)
        );
        assert_eq!(
            decode(&batch(&[record(2, [1_000_000, 0, 0], 1, payload)])),
            Err(WireError::InvalidTileKey)
        );
        assert_eq!(
            decode(&batch(&[record(2, [0; 3], 1, b"NOPEpayload1234")])),
            Err(WireError::InvalidPayload)
        );
        assert_eq!(
            decode(&batch(&[record(2, [0; 3], 1, b"LT01")])),
            Err(WireError::InvalidPayload)
        );
        let mut truncated = batch(&[record(2, [0; 3], 1, payload)]);
        truncated.pop();
        assert_eq!(decode(&truncated), Err(WireError::Truncated));
        assert_eq!(
            decode(&vec![0; MAX_LOD_BATCH_BYTES + 1]),
            Err(WireError::TooLarge)
        );
        let oversized = vec![b'x'; MAX_LOD_BATCH_BYTES];
        let data = batch(&[record(
            2,
            [0; 3],
            1,
            &oversized[..MAX_LOD_BATCH_BYTES - HEADER_BYTES - RECORD_HEADER_BYTES + 1],
        )]);
        assert_eq!(decode(&data), Err(WireError::TooLarge));
    }
}
