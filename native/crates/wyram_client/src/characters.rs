use crate::{
    animation::Animator,
    replica::{Replica, Snapshot},
    rig::{MAX_VERTICES, Rig, Source},
    world::{Vertex, VoxelWorld},
};
use glam::Vec3;
use std::collections::{HashMap, HashSet};

#[derive(Default)]
pub struct Scene {
    models: HashMap<String, Rig>,
    peers: HashMap<String, Replica>,
    animators: HashMap<String, Animator>,
}
impl Scene {
    pub fn models(&mut self, sources: Vec<Source>) {
        self.models.clear();
        self.animators.clear();
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
        self.animators.retain(|id, _| present.contains(id));
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
    pub fn vertices(
        &mut self,
        player: &Replica,
        world: &VoxelWorld,
        show_player: bool,
        dt: f32,
    ) -> Vec<Vertex> {
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
            let poses = self.animators.entry(state.id.clone()).or_default().sample(
                model,
                state,
                dt,
                replica.age(),
            );
            vertices.extend(model.vertices(
                feet,
                state.yaw,
                state.standing_height.unwrap_or(model.source.base_height),
                &poses,
            ));
        }
        vertices.truncate(MAX_VERTICES);
        vertices
    }
}
