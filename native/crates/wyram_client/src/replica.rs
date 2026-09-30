use crate::world::VoxelWorld;
use glam::Vec3;
use serde::Deserialize;
use std::time::Instant;

#[derive(Debug, Deserialize)]
pub struct Snapshot {
    pub id: String,
    #[serde(default = "default_model")]
    pub model: String,
    #[serde(default)]
    pub mode: String,
    #[serde(default)]
    pub posture: String,
    #[serde(default)]
    pub grounded: bool,
    pub x: f32,
    pub y: f32,
    pub z: f32,
    pub feet: [f32; 3],
    pub velocity: [f32; 3],
    pub radius: f32,
    pub height: f32,
    pub eye_height: f32,
    pub yaw: f32,
    pub pitch: f32,
    pub sequence: u64,
    pub epoch: u64,
    pub unavailable: bool,
    pub action: Option<Action>,
}

#[derive(Debug, Deserialize)]
pub struct Action {
    pub kind: String,
    pub phase: String,
    pub target: Option<[f32; 3]>,
    #[serde(default)]
    pub elapsed: f32,
    #[serde(default)]
    pub duration: f32,
    #[serde(default)]
    pub local_direction: String,
}

impl Snapshot {
    fn approved_delta(&self, seconds: f32) -> Vec3 {
        let delta = Vec3::from_array(self.velocity) * seconds;
        let Some(action) = &self.action else {
            return delta;
        };
        if !matches!(action.kind.as_str(), "climb" | "roll")
            || !matches!(action.phase.as_str(), "rise" | "cross" | "active")
        {
            return delta;
        }
        let Some(target) = action.target else {
            return delta;
        };
        let remaining = Vec3::from_array(target) - Vec3::from_array(self.feet);
        delta.clamp(remaining.min(Vec3::ZERO), remaining.max(Vec3::ZERO))
    }
}
fn default_model() -> String {
    "default".into()
}

pub struct Replica {
    pub state: Option<Snapshot>,
    received_at: Instant,
}
impl Default for Replica {
    fn default() -> Self {
        Self {
            state: None,
            received_at: Instant::now(),
        }
    }
}
impl Replica {
    pub fn accept(&mut self, snapshot: Snapshot) -> bool {
        if self.state.as_ref().is_some_and(|old| {
            snapshot.epoch < old.epoch
                || (snapshot.epoch == old.epoch && snapshot.sequence <= old.sequence)
        }) {
            return false;
        }
        self.state = Some(snapshot);
        self.received_at = Instant::now();
        true
    }
    pub fn age(&self) -> f32 {
        self.received_at.elapsed().as_secs_f32()
    }
    pub fn epoch(&self) -> u64 {
        self.state.as_ref().map_or(0, |state| state.epoch)
    }
    pub fn sample(&self, world: &VoxelWorld) -> Vec3 {
        let Some(state) = &self.state else {
            return Vec3::new(0.5, 73.0, 0.5);
        };
        let eye = Vec3::new(state.x, state.y, state.z);
        if state.unavailable {
            return eye;
        }
        // Predict only a short interval of approved velocity; actions stay in Elixir.
        let seconds = self.received_at.elapsed().as_secs_f32().min(0.04);
        world
            .predict_body(
                state.feet,
                state.approved_delta(seconds),
                state.radius,
                state.height,
                state.eye_height,
            )
            .unwrap_or(eye)
    }
}

#[cfg(test)]
#[path = "replica_tests.rs"]
mod tests;
