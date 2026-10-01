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
        // Snapshot time and at most 40 ms extrapolation prevent drifting during stalls.
        if age <= 0.25 || reset {
            self.phase = (state.sequence % 100_000) as f32 * 0.02 + age.min(0.04);
        }
        let target = pose(rig, state, clip, self.phase);
        if reset || self.poses.len() != target.len() {
            self.poses = target;
        } else {
            let alpha = 1. - (-18. * dt).exp();
            for (old, new) in self.poses.iter_mut().zip(target) {
                old.rotation = old.rotation.slerp(new.rotation, alpha).normalize();
                old.offset = old.offset.lerp(new.offset, alpha);
            }
        }
        self.epoch = Some(state.epoch);
        self.model = rig.source.id.clone();
        self.clip = clip;
        self.poses.clone()
    }
}
fn pose(rig: &Rig, s: &Snapshot, clip: Clip, seconds: f32) -> Vec<BonePose> {
    let mut p = vec![BonePose::default(); rig.source.bones.len()];
    if !rig.source.capabilities.iter().any(|c| c == "humanoid") {
        return p;
    }
    let speed = Vec3::new(s.velocity[0], 0., s.velocity[2]).length();
    let swing = if speed < 0.1 {
        0.
    } else {
        (seconds * (speed * 1.6).clamp(1., 15.)).sin()
    };
    let mut angles = [0.; 6]; // torso, head, left/right arms, left/right legs
    angles[1] = s.pitch;
    let mut root = Quat::IDENTITY;
    match clip {
        Clip::Idle => {}
        Clip::Walk | Clip::Run => {
            let a = if clip == Clip::Run { 0.85 } else { 0.45 };
            angles[2] = swing * a;
            angles[3] = -swing * a;
            angles[4] = -swing * a;
            angles[5] = swing * a;
            angles[0] = if clip == Clip::Run { -0.12 } else { 0. };
        }
        Clip::Sneak | Clip::Land => {
            angles[0] = -0.3;
            angles[4] = 0.6 + swing * 0.15;
            angles[5] = 0.6 - swing * 0.15;
            angles[2] = -0.3;
            angles[3] = -0.3;
        }
        Clip::Crawl => {
            root = Quat::from_rotation_x(-FRAC_PI_2);
            angles[1] = FRAC_PI_2 + s.pitch * 0.3;
            angles[2] = 2.5 + swing * 0.15;
            angles[3] = 2.5 - swing * 0.15;
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
            angles[2] = -PI * 0.85 + swing * 0.25;
            angles[3] = -PI * 0.85 - swing * 0.25;
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
            angles[2] = -FRAC_PI_2;
            angles[3] = -FRAC_PI_2;
            angles[4] = 0.3;
            angles[5] = 0.3;
        }
        Clip::Roll => {
            if let Some(action) = &s.action {
                let t = (action.elapsed / action.duration.max(0.1)).clamp(0., 1.) * TAU;
                root = match action.local_direction.as_str() {
                    "back" | "backward" => Quat::from_rotation_x(-t),
                    "left" => Quat::from_rotation_z(-t),
                    "right" => Quat::from_rotation_z(t),
                    _ => Quat::from_rotation_x(t),
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
    }
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
            p[at].rotation = Quat::from_rotation_x(angle);
        }
    }
    p
}
#[cfg(test)]
#[path = "animation_tests.rs"]
mod tests;
