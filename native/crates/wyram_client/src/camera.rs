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
    visual_eye: Option<(u64, f32)>,
}
impl Default for Camera {
    fn default() -> Self {
        Self {
            mode: Mode::First,
            distance: 3.,
            visual_eye: None,
        }
    }
}
impl Camera {
    pub fn cycle(&mut self) {
        self.visual_eye = None;
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
    /// Blend only the eye's local height. Translation, jumps and teleports never acquire camera lag.
    pub fn eye(
        &mut self,
        approved: Vec3,
        state: Option<&crate::replica::Snapshot>,
        dt: f32,
        world: &VoxelWorld,
    ) -> Vec3 {
        let Some(s) = state else {
            self.visual_eye = None;
            return approved;
        };
        let height = s.eye_height;
        let target = height
            + match s.transition.as_str() {
                "jump_start" => -0.025,
                "landing" => -0.035,
                _ => 0.,
            };
        let old = self
            .visual_eye
            .filter(|(epoch, _)| *epoch == s.epoch)
            .map_or(height, |(_, h)| h);
        let next = old + (target - old) * (1. - (-24. * dt.clamp(0., 0.05)).exp());
        let desired = Vec3::Y * (next - height);
        let safe = if desired.length_squared() < 1e-10 {
            approved
        } else {
            world.camera_eye(approved, desired).unwrap_or(approved)
        };
        // Collision can shorten a blend immediately under a low ceiling.
        self.visual_eye = Some((s.epoch, height + safe.y - approved.y));
        safe
    }
    fn offset(&self, aim: Vec3, sign: f32) -> Vec3 {
        if self.mode != Mode::Third {
            return aim * sign * self.distance;
        }
        let shoulder = aim.cross(Vec3::Y).normalize_or_zero() * 0.5 + Vec3::Y * 0.12;
        // Keep the whole offset within the bounded collision-query reach, even at steep pitch.
        (aim * sign * self.distance + shoulder).normalize_or_zero() * self.distance
    }
    #[cfg(test)]
    pub fn view(&self, eye: Vec3, aim: Vec3, world: &VoxelWorld, radius: f32) -> View {
        self.view_at(eye, aim, world.aim_point(eye, aim), world, radius)
    }
    pub fn view_at(
        &self,
        eye: Vec3,
        aim: Vec3,
        target: Vec3,
        world: &VoxelWorld,
        radius: f32,
    ) -> View {
        let first = View {
            position: eye,
            direction: (target - eye).normalize_or_zero(),
            show_player: false,
        };
        let sign = match self.mode {
            Mode::First => return first,
            Mode::Third => -1.,
            Mode::Front => 1.,
        };
        let Some(position) = world.camera_eye(eye, self.offset(aim, sign)) else {
            return first;
        };
        if position.distance(eye) < (radius + 0.5).max(0.8) {
            return first;
        }
        View {
            position,
            direction: (if self.mode == Mode::Third {
                target
            } else {
                eye
            } - position)
                .normalize_or_zero(),
            show_player: true,
        }
    }
}
#[cfg(test)]
#[path = "camera_tests.rs"]
mod tests;
