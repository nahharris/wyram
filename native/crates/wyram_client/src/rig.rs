use crate::world::Vertex;
use glam::{Mat4, Quat, Vec3};
use serde::Deserialize;
use std::collections::HashMap;

pub const MAX_VERTICES: usize = 16 * 64 * 36;
#[derive(Debug, Deserialize)]
pub struct Source {
    pub id: String,
    pub base_height: f32,
    pub bones: Vec<Bone>,
    pub attachments: HashMap<String, String>,
    pub capabilities: Vec<String>,
}
#[derive(Debug, Deserialize)]
pub struct Bone {
    pub name: String,
    pub parent: Option<String>,
    pub role: String,
    pub pivot: [f32; 3],
    pub boxes: Vec<Cuboid>,
}
#[derive(Debug, Deserialize)]
pub struct Cuboid {
    pub center: [f32; 3],
    pub size: [f32; 3],
    pub color: [u8; 3],
}
#[derive(Clone, Copy)]
pub struct BonePose {
    pub rotation: Quat,
    pub offset: Vec3,
}
impl Default for BonePose {
    fn default() -> Self {
        Self {
            rotation: Quat::IDENTITY,
            offset: Vec3::ZERO,
        }
    }
}
pub struct Rig {
    pub source: Source,
    parents: Vec<Option<usize>>,
    roles: HashMap<String, usize>,
}
impl Rig {
    pub fn import(source: Source) -> Result<Self, &'static str> {
        if !label(&source.id)
            || !source.base_height.is_finite()
            || !(0.1..=8.0).contains(&source.base_height)
            || source.bones.is_empty()
            || source.bones.len() > 32
            || source.capabilities.len() > 16
            || !source.capabilities.iter().all(|name| label(name))
        {
            return Err("invalid rig header");
        }
        let mut names = HashMap::new();
        let mut origins: Vec<Vec3> = Vec::new();
        let mut parents = Vec::new();
        let mut roles = HashMap::new();
        let mut parts = 0;
        for (index, bone) in source.bones.iter().enumerate() {
            if !label(&bone.name)
                || names.contains_key(&bone.name)
                || !vector(bone.pivot)
                || bone.boxes.len() > 8
            {
                return Err("invalid rig bone");
            }
            let parent = match &bone.parent {
                None if index == 0 => None,
                Some(name) => Some(*names.get(name).ok_or("parent must precede child")?),
                _ => return Err("rig requires exactly one root"),
            };
            if !bone.role.is_empty()
                && (!label(&bone.role) || roles.insert(bone.role.clone(), index).is_some())
            {
                return Err("duplicate or invalid role");
            }
            let origin = parent.map_or(Vec3::ZERO, |at| origins[at]) + Vec3::from_array(bone.pivot);
            for part in &bone.boxes {
                if !vector(part.center)
                    || !part
                        .size
                        .iter()
                        .all(|v| v.is_finite() && *v > 0.0 && *v <= 8.0)
                {
                    return Err("invalid cuboid");
                }
                let center = origin + Vec3::from_array(part.center);
                let half = Vec3::from_array(part.size) * 0.5;
                let low = center - half;
                let high = center + half;
                if low.y < -0.0001
                    || high.y > source.base_height + 0.0001
                    || low.x < -8.0
                    || high.x > 8.0
                    || low.z < -8.0
                    || high.z > 8.0
                {
                    return Err("rig is outside feet-space bounds");
                }
            }
            parts += bone.boxes.len();
            names.insert(bone.name.clone(), index);
            origins.push(origin);
            parents.push(parent);
        }
        if parts == 0
            || parts > 64
            || source.attachments.len() > 16
            || !source
                .attachments
                .iter()
                .all(|(name, bone)| label(name) && names.contains_key(bone))
        {
            return Err("invalid rig parts or attachments");
        }
        Ok(Self {
            source,
            parents,
            roles,
        })
    }
    pub fn role(&self, name: &str) -> Option<usize> {
        self.roles.get(name).copied()
    }
    pub fn leg_length(&self) -> f32 {
        let length = ["left_leg", "right_leg"]
            .iter()
            .filter_map(|role| self.role(role))
            .flat_map(|at| &self.source.bones[at].boxes)
            .map(|part| part.size[1] * 0.5 - part.center[1])
            .fold(0.0_f32, f32::max);
        if length > 0. {
            length
        } else {
            self.source.base_height * 0.2
        }
    }
    pub fn vertices(
        &self,
        feet: Vec3,
        yaw: f32,
        standing_height: f32,
        poses: &[BonePose],
    ) -> Vec<Vertex> {
        let mut transforms: Vec<Mat4> = Vec::with_capacity(self.source.bones.len());
        let mut local = Vec::new();
        for (index, bone) in self.source.bones.iter().enumerate() {
            let pose = poses.get(index).copied().unwrap_or_default();
            let transform = self.parents[index].map_or(Mat4::IDENTITY, |at| transforms[at])
                * Mat4::from_translation(Vec3::from_array(bone.pivot) + pose.offset)
                * Mat4::from_quat(pose.rotation);
            transforms.push(transform);
            for part in &bone.boxes {
                cuboid(&mut local, part, transform);
            }
        }
        let low = local
            .iter()
            .map(|v| v.position[1])
            .fold(f32::INFINITY, f32::min);
        // Immutable uniform size, independent of posture and posed bounds.
        let scale = standing_height.max(0.1) / self.source.base_height;
        let world = Mat4::from_translation(feet) * Mat4::from_rotation_y(-yaw);
        for vertex in &mut local {
            let mut point = Vec3::from_array(vertex.position);
            point.y -= low;
            point *= scale;
            vertex.position = world.transform_point3(point).to_array();
        }
        local
    }
}
fn label(value: &str) -> bool {
    !value.is_empty() && value.len() <= 64
}
fn vector(value: [f32; 3]) -> bool {
    value.iter().all(|v| v.is_finite() && v.abs() <= 8.0)
}
fn cuboid(vertices: &mut Vec<Vertex>, part: &Cuboid, transform: Mat4) {
    let center = Vec3::from_array(part.center);
    let half = Vec3::from_array(part.size) * 0.5;
    let faces = [
        (
            [
                [-1., -1., -1.],
                [-1., 1., -1.],
                [1., 1., -1.],
                [1., -1., -1.],
            ],
            0.8,
        ),
        (
            [[-1., -1., 1.], [1., -1., 1.], [1., 1., 1.], [-1., 1., 1.]],
            0.8,
        ),
        (
            [
                [-1., -1., -1.],
                [-1., -1., 1.],
                [-1., 1., 1.],
                [-1., 1., -1.],
            ],
            0.7,
        ),
        (
            [[1., -1., -1.], [1., 1., -1.], [1., 1., 1.], [1., -1., 1.]],
            0.9,
        ),
        (
            [
                [-1., -1., -1.],
                [1., -1., -1.],
                [1., -1., 1.],
                [-1., -1., 1.],
            ],
            0.6,
        ),
        (
            [[-1., 1., -1.], [-1., 1., 1.], [1., 1., 1.], [1., 1., -1.]],
            1.0,
        ),
    ];
    for (corners, shade) in faces {
        let color = part.color.map(|channel| f32::from(channel) / 255.0 * shade);
        for index in [0, 1, 2, 0, 2, 3] {
            let point = center + Vec3::from_array(corners[index]) * half;
            vertices.push(Vertex {
                position: transform.transform_point3(point).to_array(),
                color,
                opacity: 1.0,
            });
        }
    }
}
#[cfg(test)]
#[path = "rig_tests.rs"]
mod tests;

pub fn validate_file(path: &str) -> Result<usize, String> {
    let bytes = std::fs::read(path).map_err(|error| error.to_string())?;
    let sources: Vec<Source> = serde_json::from_slice(&bytes).map_err(|error| error.to_string())?;
    if sources.is_empty() || sources.len() > 16 {
        return Err("invalid model catalog size".into());
    }
    let count = sources.len();
    let mut names = std::collections::HashSet::new();
    for source in sources {
        if !names.insert(source.id.clone()) {
            return Err("duplicate model id".into());
        }
        Rig::import(source).map_err(str::to_string)?;
    }
    Ok(count)
}
