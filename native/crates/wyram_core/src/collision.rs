use std::collections::HashMap;

const EPSILON: f64 = 1e-9;

pub struct PackedWorld<'a> {
    chunks: HashMap<[i32; 3], &'a [u8]>,
}

#[derive(Debug)]
pub struct Sweep {
    pub position: [f64; 3],
    pub blocked: [bool; 3],
    pub unavailable: bool,
}

impl<'a> PackedWorld<'a> {
    pub fn new(chunks: impl Iterator<Item = ([i32; 3], &'a [u8])>) -> Result<Self, &'static str> {
        let mut world = Self {
            chunks: HashMap::new(),
        };
        for (key, bytes) in chunks {
            if bytes.len() != crate::BYTE_COUNT || world.chunks.len() >= 4096 {
                return Err("invalid collision chunk batch");
            }
            if world.chunks.insert(key, bytes).is_some() {
                return Err("duplicate collision chunk");
            }
        }
        Ok(world)
    }

    fn solid(&self, cell: [i32; 3]) -> Option<bool> {
        let key = cell.map(|v| v.div_euclid(16));
        let bytes = self.chunks.get(&key)?;
        let [x, y, z] = cell.map(|v| v.rem_euclid(16) as usize);
        let index = ((y * 16 + z) * 16 + x) * 2;
        Some(bytes[index] != 0 || bytes[index + 1] != 0)
    }

    /// Query packed voxels only: this does not select gameplay actions or advance time.
    pub fn sweep(
        &self,
        position: [f64; 3],
        delta: [f64; 3],
        radius: f64,
        height: f64,
    ) -> Result<Sweep, &'static str> {
        if !position
            .iter()
            .all(|v| v.is_finite() && v.abs() <= 1_000_000.0)
            || !delta.iter().all(|v| v.is_finite() && v.abs() <= 8.0)
            || !radius.is_finite()
            || !(0.1..=2.0).contains(&radius)
            || !height.is_finite()
            || !(0.1..=8.0).contains(&height)
        {
            return Err("invalid collision query");
        }
        let lower = [-radius, 0.0, -radius];
        let upper = [radius, height, radius];
        let mut result = Sweep {
            position,
            blocked: [false; 3],
            unavailable: false,
        };
        let mut cells = Vec::new();
        let start: [i32; 3] = std::array::from_fn(|i| {
            (position[i].min(position[i] + delta[i]) + lower[i] + EPSILON).floor() as i32
        });
        let end: [i32; 3] = std::array::from_fn(|i| {
            (position[i].max(position[i] + delta[i]) + upper[i] - EPSILON).floor() as i32
        });
        let count: i64 = (0..3).map(|i| i64::from(end[i] - start[i] + 1)).product();
        if count > 4096 {
            return Err("oversized collision query");
        }
        for x in start[0]..=end[0] {
            for y in start[1]..=end[1] {
                for z in start[2]..=end[2] {
                    let cell = [x, y, z];
                    match self.solid(cell) {
                        None => {
                            result.unavailable = true;
                            return Ok(result);
                        }
                        Some(true) => cells.push(cell),
                        Some(false) => {}
                    }
                }
            }
        }
        let overlap = |p: [f64; 3], cell: [i32; 3], axis: usize| {
            p[axis] + upper[axis] > f64::from(cell[axis]) + EPSILON
                && p[axis] + lower[axis] < f64::from(cell[axis]) + 1.0 - EPSILON
        };
        if cells
            .iter()
            .any(|cell| (0..3).all(|i| overlap(position, *cell, i)))
        {
            result.blocked = [true; 3];
            return Ok(result);
        }
        for axis in [0, 2, 1] {
            let mut allowed = delta[axis];
            for cell in &cells {
                if !(0..3)
                    .filter(|i| *i != axis)
                    .all(|i| overlap(result.position, *cell, i))
                {
                    continue;
                }
                let min = f64::from(cell[axis]);
                let max = min + 1.0;
                let body_max = result.position[axis] + upper[axis];
                let body_min = result.position[axis] + lower[axis];
                if allowed > 0.0 && min >= body_max - EPSILON && min < body_max + allowed {
                    allowed = (min - body_max).max(0.0);
                } else if allowed < 0.0 && max <= body_min + EPSILON && max > body_min + allowed {
                    allowed = (max - body_min).min(0.0);
                }
            }
            result.blocked[axis] = (allowed - delta[axis]).abs() > EPSILON;
            result.position[axis] += allowed;
        }
        Ok(result)
    }
}
