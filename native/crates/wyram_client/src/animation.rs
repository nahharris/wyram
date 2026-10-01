//! Original procedural poses. Approved snapshots choose clips; poses never move authority.
use crate::{
    replica::Snapshot,
    rig::{BonePose, Rig},
};
use glam::{Quat, Vec3};
use std::f32::consts::{FRAC_PI_2, PI, TAU};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
enum Clip {
    #[default]
    Idle,
    Walk,
    Run,
    Sneak,
    Crawl,
    Jump,
    Fall,
    Land,
    Climb,
    Slide,
    WallSlide,
    Roll,
}
impl Clip {
    fn select(s: &Snapshot) -> Self {
        if s.unavailable {
            return Self::Idle;
        }
        if let Some(action) = &s.action {
            match action.kind.as_str() {
                "climb" => return Self::Climb,
                "slide" => return Self::Slide,
                "wall_slide" => return Self::WallSlide,
                "roll" => return Self::Roll,
                _ => {}
            }
        }
        if matches!(s.transition.as_str(), "jump_start" | "landing")
            && s.grounded
            && s.posture != "prone"
        {
            return Self::Land;
        }
        if !s.grounded {
            return if s.velocity[1] > 0. {
                Self::Jump
            } else {
                Self::Fall
            };
        }
        if s.posture == "prone" {
            return Self::Crawl;
        }
        if s.posture == "crouch" {
            return Self::Sneak;
        }
        if Vec3::from_array(s.velocity).length_squared() < 0.01 {
            return Self::Idle;
        }
        match s.mode.as_str() {
            "walk" => Self::Walk,
            "run" => Self::Run,
            "sneak" => Self::Sneak,
            "crawl" => Self::Crawl,
            _ => Self::Idle,
        }
    }
}
#[derive(Default)]
pub struct Animator {
    epoch: Option<u64>,
    model: String,
    poses: Vec<BonePose>,
    clip: Clip,
    phase: f32,
    landing: f32,
    clock: f64,
    blend_from: Vec<BonePose>,
    blend_elapsed: f32,
}
impl Animator {
    pub fn sample(&mut self, rig: &Rig, state: &Snapshot, dt: f32, age: f32) -> Vec<BonePose> {
        let reset = self.epoch != Some(state.epoch) || self.model != rig.source.id;
        let dt = dt.clamp(0., 0.05);
        if reset {
            self.landing = 0.;
        }
        let mut clip = Clip::select(state);
        if !reset && matches!(self.clip, Clip::Jump | Clip::Fall) && state.grounded {
            self.landing = 0.12;
        }
        if self.landing > 0. && clip == Clip::Idle {
            clip = Clip::Land;
        }
        self.landing = (self.landing - dt).max(0.);
        // Advance a continuous distance phase; speed changes never rephase the feet.
        let clock = state.sequence as f64 * 0.02 + f64::from(age.clamp(0., 0.04));
        if reset {
            self.phase = 0.;
            self.clock = clock;
        } else if age <= 0.25 && !state.unavailable {
            let elapsed = (clock - self.clock).clamp(0., 0.05) as f32;
            let speed = Vec3::new(state.velocity[0], 0., state.velocity[2]).length();
            let scale =
                state.standing_height.unwrap_or(rig.source.base_height) / rig.source.base_height;
            let stride =
                4. * rig.leg_length() * scale * gait_amplitude(clip).sin() * gait_base(clip).cos();
            self.phase = (self.phase + speed * elapsed / stride.max(0.01) * TAU).rem_euclid(TAU);
            self.clock = self.clock.max(clock);
        } else {
            self.clock = self.clock.max(clock);
        }
        let target = pose(rig, state, clip, self.phase);
        if reset || self.poses.len() != target.len() {
            self.poses = target;
            self.blend_from.clear();
        } else {
            if self.clip != clip {
                self.blend_from = self.poses.clone();
                self.blend_elapsed = 0.;
            }
            self.blend_elapsed += dt;
            let alpha = (self.blend_elapsed / 0.12).clamp(0., 1.);
            self.poses = target;
            if alpha < 1. {
                for (new, old) in self.poses.iter_mut().zip(&self.blend_from) {
                    new.rotation = old.rotation.slerp(new.rotation, alpha).normalize();
                    new.offset = old.offset.lerp(new.offset, alpha);
                }
            } else {
                self.blend_from.clear();
            }
        }
        self.epoch = Some(state.epoch);
        self.model = rig.source.id.clone();
        self.clip = clip;
        self.poses.clone()
    }
}
fn gait_amplitude(clip: Clip) -> f32 {
    match clip {
        Clip::Run => 0.95,
        Clip::Sneak => 0.3,
        Clip::Land => 0.35,
        Clip::Crawl => 0.2,
        _ => 0.65,
    }
}
fn gait_base(clip: Clip) -> f32 {
    if clip == Clip::Sneak { 0.9 } else { 0. }
}
// The stance foot travels linearly backwards; the return stroke eases forwards.
fn leg_angle(phase: f32, amplitude: f32, base: f32) -> f32 {
    let cycle = phase.rem_euclid(TAU) / TAU;
    let travel = if cycle < 0.5 {
        1. - 4. * cycle
    } else {
        let t = (cycle - 0.5) * 2.;
        -1. + 2. * t * t * (3. - 2. * t)
    };
    (base.sin() + base.cos() * amplitude.sin() * travel)
        .clamp(-1., 1.)
        .asin()
}
fn pose(rig: &Rig, s: &Snapshot, clip: Clip, phase: f32) -> Vec<BonePose> {
    let mut p = vec![BonePose::default(); rig.source.bones.len()];
    if !rig.source.capabilities.iter().any(|c| c == "humanoid") {
        return p;
    }
    let speed = Vec3::new(s.velocity[0], 0., s.velocity[2]).length();
    let swing = if speed < 0.1 { 0. } else { phase.sin() };
    let mut angles = [0.; 6]; // torso, head, left/right arms, left/right legs
    angles[1] = s.pitch;
    let mut root = Quat::IDENTITY;
    match clip {
        Clip::Idle => {}
        Clip::Walk | Clip::Run => {
            let a = gait_amplitude(clip);
            if speed >= 0.1 {
                angles[4] = leg_angle(phase, a, 0.);
                angles[5] = leg_angle(phase + PI, a, 0.);
                angles[2] = -angles[4] * 0.7;
                angles[3] = -angles[5] * 0.7;
            }
            angles[0] = if clip == Clip::Run { -0.12 } else { 0. };
        }
        Clip::Sneak => {
            angles[0] = -1.05;
            angles[1] = 1.05 + s.pitch.clamp(-0.1, 0.1);
            angles[4] = if speed >= 0.1 {
                leg_angle(phase, 0.3, 0.9)
            } else {
                0.9
            };
            angles[5] = if speed >= 0.1 {
                leg_angle(phase + PI, 0.3, 0.9)
            } else {
                0.9
            };
            angles[2] = 1.05 + swing * 0.1;
            angles[3] = 1.05 - swing * 0.1;
        }
        Clip::Land => {
            angles[0] = -0.3;
            angles[1] += 0.3;
            angles[4] = 0.6;
            angles[5] = 0.6;
            angles[2] = -0.3;
            angles[3] = -0.3;
        }
        Clip::Crawl => {
            root = Quat::from_rotation_x(-FRAC_PI_2);
            angles[1] = FRAC_PI_2 + s.pitch.clamp(-0.1, 0.1);
            angles[2] = PI + swing * 0.15;
            angles[3] = PI - swing * 0.15;
            angles[4] = swing * 0.2;
            angles[5] = -swing * 0.2;
        }
        Clip::Jump | Clip::Fall => {
            let a = if clip == Clip::Jump { -0.7 } else { -0.3 };
            angles[2] = a;
            angles[3] = a;
            angles[4] = 0.35;
            angles[5] = -0.2;
        }
        Clip::Climb => {
            angles[2] = PI * 0.65 + swing * 0.25;
            angles[3] = PI * 0.65 - swing * 0.25;
            angles[4] = 0.8;
            angles[5] = -0.3;
        }
        Clip::Slide => {
            root = Quat::from_rotation_x(0.65);
            angles[4] = -1.1;
            angles[5] = -1.1;
            angles[2] = -0.3;
            angles[3] = -0.3;
        }
        Clip::WallSlide => {
            angles[2] = FRAC_PI_2;
            angles[3] = FRAC_PI_2;
            angles[4] = 0.3;
            angles[5] = 0.3;
        }
        Clip::Roll => {
            if let Some(action) = &s.action {
                let t = (action.elapsed / action.duration.max(0.1)).clamp(0., 1.) * TAU;
                root = match action.local_direction.as_str() {
                    "back" | "backward" => Quat::from_rotation_x(t),
                    "left" => Quat::from_rotation_z(t),
                    "right" => Quat::from_rotation_z(-t),
                    _ => Quat::from_rotation_x(-t),
                };
                angles[4] = 1.;
                angles[5] = 1.;
                angles[2] = -1.;
                angles[3] = -1.;
            }
        }
    }
    if let Some(at) = rig.role("root") {
        p[at].rotation = root;
        // Tumble around the body, rather than orbiting the feet.
        let pivot = Vec3::Y * rig.source.base_height * 0.5;
        p[at].offset = pivot - root * pivot;
    }
    let local_velocity = Quat::from_rotation_y(s.yaw) * Vec3::new(s.velocity[0], 0., s.velocity[2]);
    let gait_axis = Vec3::new(-local_velocity.z, 0., local_velocity.x).normalize_or_zero();
    for (role, angle) in [
        "torso",
        "head",
        "left_arm",
        "right_arm",
        "left_leg",
        "right_leg",
    ]
    .into_iter()
    .zip(angles)
    {
        if let Some(at) = rig.role(role) {
            p[at].rotation = if matches!(clip, Clip::Walk | Clip::Run)
                && role.ends_with("leg")
                && speed >= 0.1
            {
                Quat::from_axis_angle(gait_axis, angle)
            } else {
                Quat::from_rotation_x(angle)
            };
        }
    }
    if clip == Clip::Crawl
        && let Some(head) = rig.role("head")
    {
        // Join the back of the upright skull to the horizontal chest.
        let depth = rig.source.bones[head]
            .boxes
            .first()
            .map_or(rig.source.base_height * 0.25, |part| part.size[2]);
        p[head].offset = Vec3::new(0., depth * 0.5, -rig.leg_length() * 0.7);
    }
    p
}
#[cfg(test)]
#[path = "animation_tests.rs"]
mod tests;
