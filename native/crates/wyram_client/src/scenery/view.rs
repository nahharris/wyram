use super::wire::{Batch, Plan};
use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use wyram_core::scenery::{LodTile, TileKey};

#[derive(Default)]
pub struct Reception {
    epoch: u64,
    wanted: HashSet<TileKey>,
    delivery: u64,
    revision_context: Option<(u64, u64)>,
    revisions: std::collections::HashMap<TileKey, u64>,
}

impl Reception {
    pub fn replace(&mut self, plan: &Plan) -> bool {
        if self.epoch >= plan.epoch {
            return false;
        }
        if let Some(revisions) = &plan.revisions {
            if revisions.len() != plan.nodes.len()
                || plan
                    .nodes
                    .iter()
                    .any(|node| revisions.get(&node.key).is_none_or(|&r| r > plan.stamp))
            {
                return false;
            }
            if self.revision_context.is_some_and(|(lineage, stamp)| {
                lineage == plan.content
                    && (plan.stamp < stamp
                        || revisions.iter().any(|(key, revision)| {
                            self.revisions
                                .get(key)
                                .is_some_and(|previous| revision < previous)
                        }))
            }) {
                return false;
            }
        }
        self.epoch = plan.epoch;
        self.revision_context = plan.revisions.as_ref().map(|_| (plan.content, plan.stamp));
        self.revisions = plan.revisions.clone().unwrap_or_default();
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
        let same_content = self.plan.as_ref().is_some_and(|current| {
            current.content == plan.content
                && match (&current.revisions, &plan.revisions) {
                    (Some(_), Some(_)) => true,
                    (None, None) => current.stamp == plan.stamp,
                    _ => false,
                }
        });
        if same_content {
            let previous = self.plan.as_ref().unwrap();
            self.tiles.retain(|key, _| {
                self.reception.wanted.contains(key)
                    && match (&previous.revisions, &plan.revisions) {
                        (Some(before), Some(after)) => before.get(key) == after.get(key),
                        _ => true,
                    }
            });
        } else {
            self.tiles.clear();
        }
        self.plan = Some(plan);
        true
    }

    pub fn accept(&mut self, batch: Batch) -> bool {
        let revisioned = self
            .plan
            .as_ref()
            .is_some_and(|plan| plan.revisions.is_some());
        if revisioned
            && batch.tiles.iter().any(|tile| {
                self.tiles
                    .get(&tile.key())
                    .is_some_and(|current| current.as_ref() != tile)
            })
        {
            return false;
        }
        if !self.reception.accept(&batch) {
            return false;
        }
        for tile in batch.tiles {
            if revisioned {
                self.tiles
                    .entry(tile.key())
                    .or_insert_with(|| Arc::new(tile));
            } else {
                self.tiles.insert(tile.key(), Arc::new(tile));
            }
        }
        true
    }

    pub fn revision(&self, key: TileKey) -> Option<(u64, u64)> {
        let plan = self.plan.as_ref()?;
        self.tiles.get(&key)?;
        let revision = match &plan.revisions {
            Some(revisions) => *revisions.get(&key)?,
            None => plan.stamp,
        };
        Some((plan.content, revision))
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
            revisions: None,
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

    fn revisioned(epoch: u64, stamp: u64, revisions: &[(TileKey, u64)]) -> Plan {
        let mut plan = plan(
            epoch,
            7,
            &revisions.iter().map(|&(key, _)| key).collect::<Vec<_>>(),
        );
        plan.stamp = stamp;
        plan.revisions = Some(revisions.iter().copied().collect());
        plan
    }

    #[test]
    fn coalesced_plans_preserve_only_unchanged_revisions_and_reject_regressions() {
        let mut view = View::default();
        assert!(view.replace(revisioned(1, 0, &[(key(0), 0), (key(1), 0)])));
        assert!(view.accept(batch(1, 1, &[key(0), key(1)])));
        let saved = view.tiles[&key(1)].clone();
        assert!(view.replace(revisioned(2, 1, &[(key(0), 1), (key(1), 0)])));
        assert_eq!(view.tiles.len(), 1);
        assert!(Arc::ptr_eq(&saved, &view.tiles[&key(1)]));
        assert!(view.accept(batch(2, 2, &[key(1)])));
        assert!(
            Arc::ptr_eq(&saved, &view.tiles[&key(1)]),
            "duplicate delivery preserves identity"
        );
        assert!(view.replace(revisioned(3, 2, &[(key(0), 1), (key(1), 2)])));
        assert!(
            view.tiles.is_empty(),
            "second plan also invalidates its changed data"
        );
        assert!(!view.accept(batch(2, 3, &[key(0)])));
        assert!(!view.replace(revisioned(4, 1, &[(key(0), 1), (key(1), 1)])));
        assert!(!view.replace(revisioned(4, 3, &[(key(0), 0), (key(1), 2)])));
        assert!(view.accept(batch(3, 3, &[key(0), key(1)])));
        let mut restarted = revisioned(4, 0, &[(key(0), 0), (key(1), 0)]);
        restarted.content = 8;
        assert!(view.replace(restarted));
        assert!(view.tiles.is_empty());
    }

    #[test]
    fn conflicting_same_revision_bytes_cannot_partially_replace_an_immutable_view() {
        let mut view = View::default();
        assert!(view.replace(revisioned(1, 0, &[(key(0), 0), (key(1), 0)])));
        assert!(view.accept(batch(1, 1, &[key(0)])));
        let mut conflict = batch(1, 2, &[key(0), key(1)]);
        conflict.tiles[0] = LodTile::uniform(key(0), 43);
        assert!(!view.accept(conflict));
        assert_eq!(view.tiles.len(), 1);
        assert!(view.accept(batch(1, 2, &[key(0), key(1)])));
        let mut missing = revisioned(2, 1, &[(key(0), 0), (key(1), 0)]);
        missing.revisions.as_mut().unwrap().remove(&key(1));
        assert!(!view.replace(missing));
        assert_eq!(view.plan.as_ref().unwrap().epoch, 1);
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
            if packet.starts_with(b"WSP1") || packet.starts_with(b"WSP2") {
                let p = super::super::wire::plan(packet).expect("server plan");
                if plans == 1 {
                    assert_eq!(v.tiles.len(), 9);
                    let key = TileKey::new([-2, -6, -2], 1).unwrap();
                    assert_eq!(v.tiles[&key].cell([0; 3]).unwrap().occupied(), 0);
                    assert_eq!(v.tiles[&key].cell([8, 0, 0]).unwrap().material(), 42);
                }
                if plans == 4 {
                    assert_eq!(v.tiles.len(), 9);
                    let key = TileKey::new([-2, -6, -2], 1).unwrap();
                    assert!(v.tiles[&key].cell([0; 3]).unwrap().occupied() > 0);
                }
                assert!(v.replace(p));
                assert_eq!(
                    v.tiles.len(),
                    match plans {
                        1 => 1,
                        4 => 7,
                        _ => 0,
                    }
                );
                plans += 1;
            } else {
                let b = super::super::wire::batch(packet).expect("server tiles");
                assert_eq!(b.delivery, deliveries + 1);
                assert!(v.accept(b));
                deliveries += 1;
            }
        }
        assert_eq!((plans, deliveries), (5, 11));
        assert_eq!(v.plan.as_ref().unwrap().content, 20);
        assert_eq!(v.plan.as_ref().unwrap().stamp, 2);
        assert_eq!(v.tiles.len(), 9);
        let key = TileKey::new([-2, -6, -2], 1).unwrap();
        assert_eq!(v.tiles[&key].cell([0; 3]).unwrap().occupied(), 0);
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
