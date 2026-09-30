use crate::{
    replica::{Replica, Snapshot},
    rig::{BonePose, MAX_VERTICES, Rig, Source},
    world::{Vertex, VoxelWorld},
};
use glam::{Quat, Vec3};
use std::collections::{HashMap, HashSet};

#[derive(Default)]
pub struct Scene {
    models: HashMap<String, Rig>,
    peers: HashMap<String, Replica>,
}
impl Scene {
    pub fn models(&mut self, sources: Vec<Source>) {
        self.models.clear();
        for source in sources.into_iter().take(16) {
            match Rig::import(source) {
                Ok(rig) => {
                    self.models.insert(rig.source.id.clone(), rig);
                }
                Err(reason) => eprintln!("character model rejected: {reason}"),
            }
        }
    }
    pub fn receive(&mut self, snapshots: Vec<Snapshot>) -> Option<Snapshot> {
        let present: HashSet<_> = snapshots.iter().take(16).map(|s| s.id.clone()).collect();
        self.peers.retain(|id, _| present.contains(id));
        let mut player = None;
        for snapshot in snapshots.into_iter().take(16) {
            if snapshot.id == "player" {
                player = Some(snapshot);
            } else {
                self.peers
                    .entry(snapshot.id.clone())
                    .or_default()
                    .accept(snapshot);
            }
        }
        player
    }
    pub fn vertices(&self, player: &Replica, world: &VoxelWorld, show_player: bool) -> Vec<Vertex> {
        let mut vertices = Vec::new();
        let characters = self.peers.values().chain(show_player.then_some(player));
        for replica in characters {
            let Some(state) = &replica.state else {
                continue;
            };
            let Some(model) = self.models.get(&state.model) else {
                continue;
            };
            let feet = replica.sample(world) - Vec3::Y * state.eye_height;
            let mut poses = vec![BonePose::default(); model.source.bones.len()];
            if let Some(head) = model.role("head") {
                poses[head].rotation = Quat::from_rotation_x(state.pitch);
            }
            vertices.extend(model.vertices(feet, state.yaw, state.height, &poses));
        }
        vertices.truncate(MAX_VERTICES);
        vertices
    }
}
