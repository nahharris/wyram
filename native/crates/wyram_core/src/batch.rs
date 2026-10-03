use crate::{BYTE_COUNT, ChunkError, index, read_block};

/// Check the whole batch before copying, so stale or duplicate edits are atomic failures.
pub fn compare_write(
    data: &[u8],
    edits: &[(usize, usize, usize, u16, u16)],
) -> Result<Vec<u8>, ChunkError> {
    if data.len() != BYTE_COUNT || edits.len() > 4096 {
        return Err(ChunkError::BadLength);
    }
    let mut visited = std::collections::HashSet::new();
    for &(x, y, z, expected, _) in edits {
        if !visited.insert(index(x, y, z)?) || read_block(data, x, y, z)? != expected {
            return Err(ChunkError::Precondition);
        }
    }
    let mut changed = data.to_vec();
    for &(x, y, z, _, id) in edits {
        let at = index(x, y, z)? * 2;
        changed[at..at + 2].copy_from_slice(&id.to_le_bytes());
    }
    Ok(changed)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn stale_or_duplicate_edits_cannot_partially_change_a_chunk() {
        let data = vec![0; BYTE_COUNT];
        let edits = [(0, 0, 0, 0, 10), (15, 15, 15, 0, 11)];
        let changed = compare_write(&data, &edits).unwrap();
        assert_eq!(read_block(&changed, 0, 0, 0), Ok(10));
        assert_eq!(read_block(&changed, 15, 15, 15), Ok(11));
        assert_eq!(
            compare_write(&changed, &edits),
            Err(ChunkError::Precondition)
        );
        assert_eq!(
            compare_write(&data, &[edits[0], edits[0]]),
            Err(ChunkError::Precondition)
        );
        assert_eq!(read_block(&data, 0, 0, 0), Ok(0));
    }
}
