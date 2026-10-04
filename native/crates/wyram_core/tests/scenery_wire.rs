use wyram_core::scenery::{LodTile, TileKey};
use wyram_core::{BLOCK_COUNT, BYTE_COUNT};

fn key(position: [i32; 3], level: u8) -> TileKey {
    TileKey::new(position, level).expect("fixture key")
}

#[test]
fn empty_tile_has_a_versioned_little_endian_header_and_no_cell_grid() {
    let tile = LodTile::uniform(key([-1, -2, 3], 0), 0);
    assert_eq!(
        tile.encode(),
        [
            87, 83, 76, 49, 0, 0, 0, 0, 255, 255, 255, 255, 254, 255, 255, 255, 3, 0, 0, 0
        ]
    );
    assert_eq!(
        LodTile::decode(&tile.encode()).expect("empty roundtrip"),
        tile
    );
}

#[test]
fn solid_and_mixed_tiles_roundtrip_without_exposing_native_memory_layout() {
    let solid = LodTile::uniform(key([3, 0, -2], 2), 65535);
    let bytes = solid.encode();
    assert_eq!(bytes.len(), 28);
    assert_eq!(&bytes[20..], &[255, 255, 64, 0, 0, 0, 255, 0]);
    assert_eq!(LodTile::decode(&bytes).expect("solid roundtrip"), solid);
    let packed: Vec<_> = (0..BLOCK_COUNT)
        .flat_map(|i| ((i % 11) as u16).to_le_bytes())
        .collect();
    let mixed = LodTile::from_chunk(key([-3, -1, 5], 0), &packed).expect("leaf");
    let bytes = mixed.encode();
    assert_eq!(bytes.len(), 20 + BLOCK_COUNT * 8);
    assert_eq!(LodTile::decode(&bytes).expect("mixed roundtrip"), mixed);
}

#[test]
fn decoder_rejects_truncated_oversized_and_unknown_header_data() {
    let bytes = LodTile::uniform(key([0; 3], 1), 7).encode();
    assert_eq!(bytes.len(), 28, "fixture requires an encoded uniform tile");
    for length in 0..bytes.len() {
        assert!(LodTile::decode(&bytes[..length]).is_err());
    }
    let mut trailing = bytes.clone();
    trailing.push(0);
    assert!(LodTile::decode(&trailing).is_err());
    for (offset, bad) in [(0, 0), (3, b'2'), (4, 11), (5, 3), (6, 1), (7, 1)] {
        let mut invalid = bytes.clone();
        invalid[offset] = bad;
        assert!(
            LodTile::decode(&invalid).is_err(),
            "invalid header at {offset}"
        );
    }
}

#[test]
fn decoder_rejects_impossible_cell_counts_masks_materials_and_flags() {
    let bytes = LodTile::uniform(key([0; 3], 1), 7).encode();
    assert_eq!(bytes.len(), 28, "fixture requires an encoded uniform tile");
    for (offset, bad) in [(20, 0), (22, 0), (22, 9), (26, 0), (26, 1), (27, 2)] {
        let mut invalid = bytes.clone();
        invalid[offset] = bad;
        assert!(
            LodTile::decode(&invalid).is_err(),
            "invalid cell at {offset}"
        );
    }
    let leaf = LodTile::uniform(key([0; 3], 0), 7).encode();
    for (offset, bad) in [(22, 2), (26, 1), (27, 1)] {
        let mut invalid = leaf.clone();
        invalid[offset] = bad;
        assert!(LodTile::decode(&invalid).is_err());
    }
}

#[test]
fn sparse_reduced_cells_roundtrip_with_occupancy_and_refinement_hints() {
    let mut packed = vec![0; BYTE_COUNT];
    packed[..2].copy_from_slice(&41u16.to_le_bytes());
    let inputs: [LodTile; 8] = std::array::from_fn(|i| {
        let key = key(std::array::from_fn(|axis| ((i >> axis) & 1) as i32), 0);
        if i == 0 {
            LodTile::from_chunk(key, &packed).expect("thin feature")
        } else {
            LodTile::uniform(key, 0)
        }
    });
    let parent = LodTile::reduce(std::array::from_fn(|i| &inputs[i])).expect("parent");
    assert_eq!(
        LodTile::decode(&parent.encode()).expect("sparse roundtrip"),
        parent
    );
}

#[test]
fn surface_metadata_roundtrips_with_strict_lengths_and_legacy_fallback() {
    let inputs: [LodTile; 8] = std::array::from_fn(|i| {
        LodTile::uniform(
            key([(i & 1) as i32, ((i >> 1) & 1) as i32, (i >> 2) as i32], 0),
            if i & 2 == 0 { 9 } else { 4 },
        )
    });
    let tile = LodTile::reduce(std::array::from_fn(|i| &inputs[i])).unwrap();
    let bytes = tile.encode();
    // Pure children still retain the legacy encoding until a reduction mixes
    // volume and surface materials in the same cell.
    let mut extended = b"WSL2".to_vec();
    extended.extend_from_slice(&[1, 1, 0, 0]);
    extended.extend_from_slice(&[0; 12]);
    extended.extend_from_slice(&[9, 0, 8, 0, 0, 0, 255, 1, 4, 0]);
    let decoded = LodTile::decode(&extended).unwrap();
    assert_eq!(decoded.cell([0; 3]).unwrap().material(), 9);
    assert_eq!(decoded.top_material([0; 3]).unwrap(), 4);
    assert_eq!(decoded.resident_cell_bytes(), 10);
    assert_eq!(decoded.encode(), extended);
    for length in 0..extended.len() {
        assert!(LodTile::decode(&extended[..length]).is_err());
    }
    let mut bad = extended.clone();
    bad[28] = 0;
    assert!(LodTile::decode(&bad).is_err());
    let mut leaf = extended.clone();
    leaf[4] = 0;
    leaf[22] = 1;
    leaf[26] = 0;
    leaf[27] = 0;
    assert!(LodTile::decode(&leaf).is_err());
    let mut legacy = extended[..28].to_vec();
    legacy[3] = b'1';
    let legacy = LodTile::decode(&legacy).unwrap();
    assert_eq!(legacy.top_material([0; 3]).unwrap(), 9);
    assert_eq!(LodTile::decode(&bytes).unwrap(), tile);
    let packed: Vec<_> = (0..BLOCK_COUNT)
        .flat_map(|i| (if i / 256 % 2 == 0 { 3u16 } else { 9u16 }).to_le_bytes())
        .collect();
    let dense: [LodTile; 8] = std::array::from_fn(|i| {
        if i == 0 {
            LodTile::from_chunk(key([0; 3], 0), &packed).unwrap()
        } else {
            LodTile::uniform(
                key([(i & 1) as i32, ((i >> 1) & 1) as i32, (i >> 2) as i32], 0),
                0,
            )
        }
    });
    let dense = LodTile::reduce(std::array::from_fn(|i| &dense[i])).unwrap();
    let bytes = dense.encode();
    assert_eq!(&bytes[..4], b"WSL2");
    assert_eq!(bytes.len(), wyram_core::scenery::MAX_ENCODED_TILE_BYTES);
    assert_eq!(dense.top_material([0; 3]).unwrap(), 9);
    assert_eq!(LodTile::decode(&bytes).unwrap(), dense);
    for change in [true, false] {
        let mut bad = bytes.clone();
        if change {
            bad.push(0);
        } else {
            bad.pop();
        }
        assert!(LodTile::decode(&bad).is_err());
    }
}
