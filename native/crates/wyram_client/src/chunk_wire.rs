use wyram_core::BYTE_COUNT;

#[derive(Debug)]
pub struct PackedChunk {
    pub key: [i32; 3],
    pub revision: u64,
    pub data: Vec<u8>,
}

fn take<const N: usize>(bytes: &mut &[u8]) -> Result<[u8; N], &'static str> {
    let value = bytes
        .get(..N)
        .ok_or("truncated chunk packet")?
        .try_into()
        .unwrap();
    *bytes = &bytes[N..];
    Ok(value)
}

pub fn decode(mut bytes: &[u8]) -> Result<Vec<PackedChunk>, &'static str> {
    if take::<4>(&mut bytes)? != *b"WYC1" {
        return Err("unknown chunk protocol");
    }
    let count = u16::from_be_bytes(take(&mut bytes)?) as usize;
    if count > 16 {
        return Err("oversized chunk batch");
    }
    let mut chunks = Vec::with_capacity(count);
    for _ in 0..count {
        let key = [
            i32::from_be_bytes(take(&mut bytes)?),
            i32::from_be_bytes(take(&mut bytes)?),
            i32::from_be_bytes(take(&mut bytes)?),
        ];
        let revision = u64::from_be_bytes(take(&mut bytes)?);
        let size = u16::from_be_bytes(take(&mut bytes)?) as usize;
        let data = match size {
            0 => vec![0; BYTE_COUNT],
            BYTE_COUNT => {
                let data = bytes.get(..size).ok_or("truncated chunk data")?.to_vec();
                bytes = &bytes[size..];
                data
            }
            _ => return Err("invalid chunk size"),
        };
        chunks.push(PackedChunk {
            key,
            revision,
            data,
        });
    }
    if !bytes.is_empty() {
        return Err("trailing chunk data");
    }
    Ok(chunks)
}

#[cfg(test)]
mod tests {
    use super::*;
    use wyram_core::BYTE_COUNT;

    fn packet(entries: &[([i32; 3], u64, Vec<u8>)]) -> Vec<u8> {
        let mut bytes = b"WYC1".to_vec();
        bytes.extend_from_slice(&(entries.len() as u16).to_be_bytes());
        for (key, revision, data) in entries {
            for coordinate in key {
                bytes.extend_from_slice(&coordinate.to_be_bytes());
            }
            bytes.extend_from_slice(&revision.to_be_bytes());
            bytes.extend_from_slice(&(data.len() as u16).to_be_bytes());
            bytes.extend_from_slice(data);
        }
        bytes
    }

    #[test]
    fn decodes_packed_and_empty_chunks_at_negative_coordinates_and_high_revisions() {
        let bytes = vec![7; BYTE_COUNT];
        let wire = packet(&[
            ([-1, -12, 0], u64::MAX, bytes.clone()),
            ([0, 19, 0], 1, vec![]),
        ]);
        let decoded = decode(&wire).unwrap();
        assert_eq!(decoded[0].key, [-1, -12, 0]);
        assert_eq!(decoded[0].revision, u64::MAX);
        assert_eq!(decoded[0].data, bytes);
        assert_eq!(decoded[1].data, vec![0; BYTE_COUNT]);
    }

    #[test]
    fn malformed_truncated_oversized_and_trailing_payloads_are_rejected() {
        let valid = packet(&[([0, 0, 0], 0, vec![1; BYTE_COUNT])]);
        for length in [0, 3, 5, 6, 20, valid.len() - 1] {
            assert!(decode(&valid[..length]).is_err());
        }
        assert!(decode(&packet(&[([0, 0, 0], 0, vec![1; 2])])).is_err());
        assert!(decode(&packet(&vec![([0, 0, 0], 0, vec![]); 17])).is_err());
        let mut trailing = valid;
        trailing.push(0);
        assert!(decode(&trailing).is_err());
        assert!(decode(b"WYC2\0\0").is_err());
    }
}
