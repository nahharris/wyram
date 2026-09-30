//! Presentation cameras. Character look and edit rays are independent of camera placement.
use crate::world::VoxelWorld;
use glam::Vec3;
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Mode {
    #[default]
    First,
    Third,
    Front,
}
pub struct View {
    pub position: Vec3,
    pub direction: Vec3,
    pub show_player: bool,
}
pub struct Camera {
    pub mode: Mode,
    distance: f32,
}
impl Default for Camera {
    fn default() -> Self {
        Self {
            mode: Mode::First,
            distance: 3.,
        }
    }
}
impl Camera {
    pub fn cycle(&mut self) {
        self.mode = match self.mode {
            Mode::First => Mode::Third,
            Mode::Third => Mode::Front,
            Mode::Front => Mode::First,
        };
    }
    pub fn zoom(&mut self, amount: f32) {
        if amount.is_finite() {
            self.distance = (self.distance - amount * 0.25).clamp(1., 6.);
        }
    }
    pub fn view(&self, eye: Vec3, aim: Vec3, world: &VoxelWorld, radius: f32) -> View {
        let first = View {
            position: eye,
            direction: aim,
            show_player: false,
        };
        let sign = match self.mode {
            Mode::First => return first,
            Mode::Third => -1.,
            Mode::Front => 1.,
        };
        let Some(position) = world.camera_eye(eye, aim * sign * self.distance) else {
            return first;
        };
        if position.distance(eye) < (radius + 0.5).max(0.8) {
            return first;
        }
        View {
            position,
            direction: (eye - position).normalize_or_zero(),
            show_player: true,
        }
    }
}
#[cfg(test)]
#[path = "camera_tests.rs"]
mod tests;
