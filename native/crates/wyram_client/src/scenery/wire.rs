use wyram_core::scenery::{LodTile, MAX_ENCODED_TILE_BYTES, TileKey};

#[derive(Debug)]
pub struct Node {
    pub key: TileKey,
    pub children: Vec<usize>,
}
#[derive(Debug)]
pub struct Plan {
    pub epoch: u64,
    pub content: u64,
    pub stamp: u64,
    pub distance: u16,
    pub cache_bytes: usize,
    pub mesh_bytes: usize,
    pub roots: Vec<usize>,
    pub nodes: Vec<Node>,
    pub revisions: Option<std::collections::HashMap<TileKey, u64>>,
}
#[derive(Debug)]
pub struct Batch {
    pub epoch: u64,
    pub delivery: u64,
    pub tiles: Vec<LodTile>,
}

fn take<const N: usize>(bytes: &mut &[u8]) -> Result<[u8; N], &'static str> {
    let value = bytes
        .get(..N)
        .ok_or("truncated scenery packet")?
        .try_into()
        .unwrap();
    *bytes = &bytes[N..];
    Ok(value)
}

fn supported(key: TileKey) -> bool {
    let width = i64::from(key.scale()) * 16;
    (1..=6).contains(&key.level())
        && key
            .origin()
            .iter()
            .all(|&v| v >= -1_000_000 && v + width - 1 <= 1_000_000)
}

pub fn plan(mut bytes: &[u8]) -> Result<Plan, &'static str> {
    let revisioned = match take::<4>(&mut bytes)? {
        value if value == *b"WSP1" => false,
        value if value == *b"WSP2" => true,
        _ => return Err("unknown scenery plan protocol"),
    };
    let epoch = u64::from_be_bytes(take(&mut bytes)?);
    let content = u64::from_be_bytes(take(&mut bytes)?);
    let stamp = u64::from_be_bytes(take(&mut bytes)?);
    let distance = u16::from_be_bytes(take(&mut bytes)?);
    let cache_bytes = u32::from_be_bytes(take(&mut bytes)?) as usize;
    let mesh_bytes = u32::from_be_bytes(take(&mut bytes)?) as usize;
    let count = u16::from_be_bytes(take(&mut bytes)?) as usize;
    let root_count = u16::from_be_bytes(take(&mut bytes)?) as usize;
    if count > 4096 || root_count > count {
        return Err("invalid scenery plan bounds");
    }
    let roots = (0..root_count)
        .map(|_| take(&mut bytes).map(|v| u16::from_be_bytes(v) as usize))
        .collect::<Result<Vec<_>, _>>()?;
    let mut nodes = Vec::with_capacity(count);
    let mut seen = std::collections::HashSet::with_capacity(count);
    let mut revisions = revisioned.then(|| std::collections::HashMap::with_capacity(count));
    for _ in 0..count {
        let position = [
            i32::from_be_bytes(take(&mut bytes)?),
            i32::from_be_bytes(take(&mut bytes)?),
            i32::from_be_bytes(take(&mut bytes)?),
        ];
        let level = take::<1>(&mut bytes)?[0];
        let key = TileKey::new(position, level).map_err(|_| "invalid scenery key")?;
        let child_count = take::<1>(&mut bytes)?[0] as usize;
        if !supported(key) || !seen.insert(key) || ![0, 8].contains(&child_count) {
            return Err("invalid scenery node");
        }
        let children = (0..child_count)
            .map(|_| take(&mut bytes).map(|v| u16::from_be_bytes(v) as usize))
            .collect::<Result<Vec<_>, _>>()?;
        if let Some(revisions) = &mut revisions {
            let revision = u64::from_be_bytes(take(&mut bytes)?);
            if revision > stamp {
                return Err("scenery revision exceeds snapshot");
            }
            revisions.insert(key, revision);
        }
        nodes.push(Node { key, children });
    }
    if !bytes.is_empty() {
        return Err("trailing scenery plan data");
    }
    let plan = Plan {
        epoch,
        content,
        stamp,
        distance,
        cache_bytes,
        mesh_bytes,
        roots,
        nodes,
        revisions,
    };
    forest(&plan)?;
    Ok(plan)
}

fn forest(plan: &Plan) -> Result<(), &'static str> {
    if plan.epoch == 0
        || plan.content == 0
        || !(128..=4096).contains(&plan.distance)
        || !plan.distance.is_multiple_of(16)
        || !(1_048_576..=268_435_456).contains(&plan.cache_bytes)
        || !(4_194_304..=268_435_456).contains(&plan.mesh_bytes)
        || plan.nodes.len() * MAX_ENCODED_TILE_BYTES > plan.cache_bytes
    {
        return Err("invalid scenery plan bounds");
    }
    let mut parents = vec![0u8; plan.nodes.len()];
    for (index, node) in plan.nodes.iter().enumerate() {
        for &child in &node.children {
            let key = plan
                .nodes
                .get(child)
                .ok_or("invalid scenery child index")?
                .key;
            if child <= index || key.parent() != Ok(node.key) || parents[child] != 0 {
                return Err("invalid scenery hierarchy");
            }
            parents[child] = 1;
        }
    }
    let mut root_flags = vec![false; parents.len()];
    let mut root_level = None;
    for &root in &plan.roots {
        let level = plan
            .nodes
            .get(root)
            .ok_or("invalid scenery root index")?
            .key
            .level();
        if root_flags[root] || parents[root] != 0 || root_level.is_some_and(|v| v != level) {
            return Err("invalid scenery root");
        }
        root_flags[root] = true;
        root_level = Some(level);
    }
    if parents.iter().zip(root_flags).any(|(&p, r)| (p == 0) != r) {
        return Err("unreachable scenery node");
    }
    Ok(())
}

pub fn batch(mut bytes: &[u8]) -> Result<Batch, &'static str> {
    if take::<4>(&mut bytes)? != *b"WST1" {
        return Err("unknown scenery tile protocol");
    }
    let epoch = u64::from_be_bytes(take(&mut bytes)?);
    let delivery = u64::from_be_bytes(take(&mut bytes)?);
    let count = u16::from_be_bytes(take(&mut bytes)?) as usize;
    if epoch == 0 || delivery == 0 || !(1..=2).contains(&count) {
        return Err("invalid scenery credit");
    }
    let mut tiles = Vec::with_capacity(count);
    for _ in 0..count {
        let size = u32::from_be_bytes(take(&mut bytes)?) as usize;
        if ![20, 28, 30, 32788, MAX_ENCODED_TILE_BYTES].contains(&size) {
            return Err("invalid scenery tile size");
        }
        let payload = bytes.get(..size).ok_or("truncated scenery tile")?;
        bytes = &bytes[size..];
        let tile = LodTile::decode(payload).map_err(|_| "invalid scenery tile data")?;
        if !supported(tile.key()) || tiles.iter().any(|v: &LodTile| v.key() == tile.key()) {
            return Err("invalid scenery tile key");
        }
        tiles.push(tile);
    }
    if !bytes.is_empty() {
        return Err("trailing scenery tile data");
    }
    Ok(Batch {
        epoch,
        delivery,
        tiles,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn header(count: u16, roots: &[u16]) -> Vec<u8> {
        let mut b = b"WSP1".to_vec();
        for n in [3u64, 7, 5] {
            b.extend(n.to_be_bytes());
        }
        b.extend(1024u16.to_be_bytes());
        for n in [67_108_864u32; 2] {
            b.extend(n.to_be_bytes());
        }
        b.extend(count.to_be_bytes());
        b.extend((roots.len() as u16).to_be_bytes());
        for n in roots {
            b.extend(n.to_be_bytes());
        }
        b
    }
    fn node(b: &mut Vec<u8>, position: [i32; 3], level: u8, children: &[u16]) {
        for n in position {
            b.extend(n.to_be_bytes());
        }
        b.extend([level, children.len() as u8]);
        for n in children {
            b.extend(n.to_be_bytes());
        }
    }
    fn refined() -> Vec<u8> {
        let mut b = header(9, &[0]);
        node(&mut b, [-1, 0, -1], 2, &[1, 2, 3, 4, 5, 6, 7, 8]);
        for octant in 0..8 {
            node(
                &mut b,
                [-2 + (octant & 1), (octant >> 1) & 1, -2 + (octant >> 2)],
                1,
                &[],
            );
        }
        b
    }
    fn delivery(tiles: &[Vec<u8>]) -> Vec<u8> {
        let mut b = b"WST1".to_vec();
        b.extend(3u64.to_be_bytes());
        b.extend(11u64.to_be_bytes());
        b.extend((tiles.len() as u16).to_be_bytes());
        for tile in tiles {
            b.extend((tile.len() as u32).to_be_bytes());
            b.extend(tile);
        }
        b
    }

    #[test]
    fn portable_header_matches_the_server_layout_and_complete_negative_siblings() {
        let mut b = header(1, &[0]);
        node(&mut b, [-1, 0, 2], 1, &[]);
        assert_eq!(b.len(), 58);
        let p = plan(&b).expect("portable plan");
        assert_eq!((p.epoch, p.content, p.stamp, p.distance), (3, 7, 5, 1024));
        assert_eq!((p.cache_bytes, p.mesh_bytes), (67_108_864, 67_108_864));
        assert_eq!(p.nodes[0].key.position(), [-1, 0, 2]);
        let p = plan(&refined()).expect("complete refinement");
        assert_eq!(p.roots, [0]);
        assert_eq!(p.nodes[0].children, (1..9).collect::<Vec<_>>());
        assert_eq!(
            plan(&header(0, &[])).expect("empty edge view").nodes.len(),
            0
        );
    }

    #[test]
    fn invalid_counts_budgets_identity_keys_and_truncated_records_are_rejected() {
        let good = refined();
        for end in 0..good.len() {
            assert!(plan(&good[..end]).is_err(), "prefix{end}");
        }
        let mut trailing = good.clone();
        trailing.push(0);
        assert!(plan(&trailing).is_err());
        assert!(plan(&header(4097, &[])).is_err());
        for range in [4..12, 12..20, 30..34, 34..38] {
            let mut bad = good.clone();
            bad[range].fill(0);
            assert!(plan(&bad).is_err());
        }
        for (position, level) in [([0; 3], 0), ([0; 3], 7), ([i32::MAX; 3], 1)] {
            let mut bad = header(1, &[0]);
            node(&mut bad, position, level, &[]);
            assert!(plan(&bad).is_err());
        }
    }

    #[test]
    fn malformed_forests_cannot_create_holes_cycles_duplicate_parents_or_keys() {
        let mut missing = header(1, &[]);
        node(&mut missing, [0; 3], 1, &[]);
        assert!(plan(&missing).is_err());
        let mut roots = header(1, &[0, 0]);
        node(&mut roots, [0; 3], 1, &[]);
        assert!(plan(&roots).is_err());
        let mut duplicate = header(2, &[0, 1]);
        node(&mut duplicate, [0; 3], 1, &[]);
        node(&mut duplicate, [0; 3], 1, &[]);
        assert!(plan(&duplicate).is_err());
        let mut bad = refined();
        bad[58..60].copy_from_slice(&0u16.to_be_bytes());
        assert!(plan(&bad).is_err());
        let mut bad = refined();
        bad[44 + 13] = 7;
        assert!(plan(&bad).is_err());
        let mut bad = refined();
        bad[74..78].copy_from_slice(&99i32.to_be_bytes());
        assert!(plan(&bad).is_err());
        let mut mixed_roots = header(2, &[0, 1]);
        node(&mut mixed_roots, [0; 3], 2, &[]);
        node(&mut mixed_roots, [4, 0, 0], 1, &[]);
        assert!(plan(&mixed_roots).is_err());
    }

    #[test]
    fn revisioned_plans_keep_bounded_node_revisions_and_reject_future_values() {
        let mut bytes = header(2, &[0, 1]);
        bytes[..4].copy_from_slice(b"WSP2");
        node(&mut bytes, [-1, 0, 0], 1, &[]);
        bytes.extend(0u64.to_be_bytes());
        node(&mut bytes, [0, 0, 0], 1, &[]);
        bytes.extend(4u64.to_be_bytes());
        assert!(plan(&bytes).is_ok(), "valid per-node revisions must decode");
        for end in 0..bytes.len() {
            assert!(plan(&bytes[..end]).is_err());
        }
        let end = bytes.len();
        bytes[end - 8..].copy_from_slice(&6u64.to_be_bytes());
        assert!(plan(&bytes).is_err(), "revision exceeds snapshot stamp");
    }

    #[test]
    fn tile_batches_validate_cells_lengths_keys_and_credit_bounds() {
        let key = TileKey::new([-1, 0, 2], 1).unwrap();
        let tile = LodTile::uniform(key, 0).encode();
        let b = delivery(std::slice::from_ref(&tile));
        let decoded = batch(&b).expect("tile batch");
        assert_eq!((decoded.epoch, decoded.delivery), (3, 11));
        assert_eq!(decoded.tiles[0].key(), key);
        let mut surface = tile.clone();
        surface[3] = b'2';
        surface[5] = 1;
        surface.extend_from_slice(&[3, 0, 8, 0, 0, 0, 255, 1, 9, 0]);
        let decoded = batch(&delivery(&[surface])).unwrap();
        assert_eq!(decoded.tiles[0].top_material([0; 3]).unwrap(), 9);
        for end in 0..b.len() {
            assert!(batch(&b[..end]).is_err());
        }
        assert!(batch(&delivery(&[])).is_err());
        assert!(batch(&delivery(&[tile.clone(), tile.clone()])).is_err());
        assert!(batch(&delivery(&[tile.clone(), tile.clone(), tile])).is_err());
        assert!(batch(&delivery(&[vec![0; 32789]])).is_err());
        let mut bad = b.clone();
        bad[4..12].fill(0);
        assert!(batch(&bad).is_err());
        let mut bad = b.clone();
        bad[12..20].fill(0);
        assert!(batch(&bad).is_err());
        let mut bad = b.clone();
        bad.push(0);
        assert!(batch(&bad).is_err());
        let invalid = LodTile::uniform(TileKey::new([0; 3], 7).unwrap(), 1).encode();
        assert!(batch(&delivery(&[invalid])).is_err());
    }
}
