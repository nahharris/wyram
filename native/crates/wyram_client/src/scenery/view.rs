use super::wire::{Batch, Plan};
use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use wyram_core::scenery::{LodTile, TileKey};

#[derive(Default)]
pub struct Reception {
    epoch: u64,
    wanted: HashSet<TileKey>,
    delivery: u64,
}

impl Reception {
    pub fn replace(&mut self, plan: &Plan) -> bool {
        if self.epoch >= plan.epoch {
            return false;
        }
        self.epoch = plan.epoch;
        self.wanted = plan.nodes.iter().map(|node| node.key).collect();
        self.delivery = 0;
        true
    }

    pub fn accept(&mut self, batch: &Batch) -> bool {
        if self.epoch == 0
            || batch.epoch != self.epoch
            || batch.delivery <= self.delivery
            || batch
                .tiles
                .iter()
                .any(|tile| !self.wanted.contains(&tile.key()))
        {
            return false;
        }
        self.delivery = batch.delivery;
        true
    }
}

#[derive(Default)]
pub struct View {
    pub plan: Option<Plan>,
    pub tiles: HashMap<TileKey, Arc<LodTile>>,
    reception: Reception,
}

impl View {
    pub fn replace(&mut self, plan: Plan) -> bool {
        if !self.reception.replace(&plan) {
            return false;
        }
        let same_content = self
            .plan
            .as_ref()
            .is_some_and(|current| current.content == plan.content && current.stamp == plan.stamp);
        if same_content {
            self.tiles
                .retain(|key, _| self.reception.wanted.contains(key));
        } else {
            self.tiles.clear();
        }
        self.plan = Some(plan);
        true
    }

    pub fn accept(&mut self, batch: Batch) -> bool {
        if !self.reception.accept(&batch) {
            return false;
        }
        for tile in batch.tiles {
            self.tiles.insert(tile.key(), Arc::new(tile));
        }
        true
    }
}

#[cfg(test)]
mod tests {
    use super::super::wire::Node;
    use super::*;

    fn key(x: i32) -> TileKey {
        TileKey::new([x, 0, 0], 1).unwrap()
    }
    fn plan(epoch: u64, content: u64, keys: &[TileKey]) -> Plan {
        Plan {
            epoch,
            content,
            stamp: 0,
            distance: 1024,
            cache_bytes: 67_108_864,
            mesh_bytes: 67_108_864,
            roots: (0..keys.len()).collect(),
            nodes: keys
                .iter()
                .map(|&key| Node {
                    key,
                    children: vec![],
                })
                .collect(),
        }
    }
    fn batch(epoch: u64, delivery: u64, keys: &[TileKey]) -> Batch {
        Batch {
            epoch,
            delivery,
            tiles: keys.iter().map(|&key| LodTile::uniform(key, 42)).collect(),
        }
    }

    #[test]
    #[ignore = "cross-runtime scenery fixture; run by repository test script"]
    fn matched_server_wire_fixture() {
        let path = std::env::var("WYRAM_SCENERY_FIXTURE").expect("fixture path");
        let bytes = std::fs::read(path).expect("server fixture");
        assert!(bytes.len() < 2 * 1024 * 1024);
        let mut remaining = bytes.as_slice();
        let mut v = View::default();
        let mut plans = 0;
        let mut deliveries = 0;
        while !remaining.is_empty() {
            let size = u32::from_be_bytes(remaining[..4].try_into().unwrap()) as usize;
            let packet = &remaining[4..4 + size];
            remaining = &remaining[4 + size..];
            if packet.starts_with(b"WSP1") {
                let p = super::super::wire::plan(packet).expect("server plan");
                if plans == 1 {
                    assert_eq!(v.tiles.len(), 9);
                    let key = TileKey::new([-2, -6, -2], 1).unwrap();
                    assert_eq!(v.tiles[&key].cell([0; 3]).unwrap().occupied(), 0);
                    assert_eq!(v.tiles[&key].cell([8, 0, 0]).unwrap().material(), 42);
                }
                assert!(v.replace(p));
                assert_eq!(v.tiles.len(), if plans == 1 { 1 } else { 0 });
                plans += 1;
            } else {
                let b = super::super::wire::batch(packet).expect("server tiles");
                assert_eq!(b.delivery, deliveries + 1);
                assert!(v.accept(b));
                deliveries += 1;
            }
        }
        assert_eq!((plans, deliveries), (3, 5));
        assert_eq!(v.plan.as_ref().unwrap().content, 8);
    }

    #[test]
    fn camera_changes_reuse_only_wanted_tiles_but_content_changes_clear_them() {
        let mut v = View::default();
        assert!(v.replace(plan(1, 7, &[key(0), key(1)])));
        assert!(v.accept(batch(1, 1, &[key(0), key(1)])));
        let saved = v.tiles[&key(0)].clone();
        assert!(v.replace(plan(2, 7, &[key(0), key(2)])));
        assert_eq!(v.tiles.len(), 1);
        assert!(Arc::ptr_eq(&saved, &v.tiles[&key(0)]));
        assert!(!v.accept(batch(1, 2, &[key(2)])));
        assert!(v.accept(batch(2, 2, &[key(2)])));
        assert!(v.replace(plan(3, 8, &[key(0), key(2)])));
        assert!(v.tiles.is_empty());
    }

    #[test]
    fn old_epochs_deliveries_and_unknown_keys_cannot_partially_replace_the_view() {
        let mut v = View::default();
        assert!(!v.accept(batch(1, 1, &[key(0)])));
        assert!(v.replace(plan(3, 7, &[key(0), key(1)])));
        assert!(!v.replace(plan(2, 8, &[])));
        assert!(!v.accept(batch(2, 1, &[key(0)])));
        assert!(!v.accept(batch(3, 1, &[key(0), key(99)])));
        assert!(v.tiles.is_empty());
        assert!(v.accept(batch(3, 2, &[key(0)])));
        assert!(!v.accept(batch(3, 2, &[key(1)])));
        assert!(!v.accept(batch(3, 1, &[key(1)])));
        assert_eq!(v.tiles.len(), 1);
        assert!(v.replace(plan(4, 7, &[])));
        assert!(v.tiles.is_empty());
    }
}
