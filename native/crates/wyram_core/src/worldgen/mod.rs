//! Version 1 data-driven generation. Elixir resolves policy and refs; native loops own packed operations.
mod features;
mod lod_generation;
mod noise;
mod settings;
mod terrain;
use crate::{BYTE_COUNT, CHUNK_SIDE};
pub use settings::{Biome, Carver, Feature, Field, Islands, Settings, Terrain};
#[derive(Debug)]
pub struct Column {
    pub height: i32,
    pub climate: [f64; 6],
    pub weights: Vec<f64>,
    pub biome: usize,
    pub island: Option<(i32, i32)>,
}
pub struct Generator {
    seed: u64,
    settings: Settings,
}
impl Generator {
    pub fn new(seed: u64, settings: Settings) -> Result<Self, &'static str> {
        if !settings.valid() {
            return Err("invalid world generation settings");
        }
        Ok(Self { seed, settings })
    }
    pub fn bounds(&self) -> (i32, i32) {
        (
            self.settings.min_y,
            self.settings.min_y + self.settings.height - 1,
        )
    }
    pub fn column(&self, x: i32, z: i32) -> Column {
        let p = [f64::from(x), 0.0, f64::from(z)];
        let f = self
            .settings
            .fields
            .map(|field| noise::sample(self.seed, field, p));
        let continent = ((f[0] - 0.48) * 2.8).clamp(-1.0, 1.0);
        let inland = (continent * 3.0).clamp(0.0, 1.0);
        let ridge = (1.0 - (f[2] * 2.0 - 1.0).abs()).powi(3);
        let relief = f64::from(self.settings.relief);
        let geology = relief * (continent * 0.72 + inland * ridge * (1.0 - f[1]) * 0.95)
            + (f[5] - 0.5) * (12.0 + inland * 20.0);
        let h =
            f64::from(self.settings.sea_level) + terrain::height(self, p, geology, inland, f[1]);
        let climate = [
            (f[3] - geology.max(0.0) * 0.0015).clamp(0.0, 1.0),
            (f[4] + (1.0 - inland) * 0.08).clamp(0.0, 1.0),
            f[0],
            f[1],
            ((h - f64::from(self.settings.min_y)) / f64::from(self.settings.height))
                .clamp(0.0, 1.0),
            f[2],
        ];
        let weights = self.weights(climate);
        let offset = self
            .settings
            .biomes
            .iter()
            .zip(&weights)
            .map(|(b, w)| f64::from(b.elevation_offset) * w)
            .sum::<f64>();
        let height = (h + offset).floor().clamp(
            f64::from(self.settings.min_y + 4),
            f64::from(self.bounds().1 - 2),
        ) as i32;
        let pick = noise::unit(noise::hash(self.seed ^ 0x42494f4d45, x, 0, z));
        let mut sum = 0.0;
        let mut biome = weights.len() - 1;
        for (i, w) in weights.iter().enumerate() {
            sum += w;
            if pick < sum {
                biome = i;
                break;
            }
        }
        let island = self.settings.islands.as_ref().and_then(|i| {
            let n = noise::sample(self.seed, i.field, p);
            if n < i.threshold {
                return None;
            }
            let strength = (n - i.threshold) / (1.0 - i.threshold);
            let top = i.base_y + (strength * f64::from(i.relief)).floor() as i32;
            let depth = (strength.sqrt() * f64::from(i.thickness)).floor() as i32 + 1;
            Some((top - depth, top))
        });
        Column {
            height,
            climate,
            weights,
            biome,
            island,
        }
    }
    fn weights(&self, climate: [f64; 6]) -> Vec<f64> {
        let distances: Vec<_> = self
            .settings
            .biomes
            .iter()
            .map(|b| {
                b.climate
                    .iter()
                    .zip(climate)
                    .map(|(a, b)| (a - b).powi(2))
                    .sum::<f64>()
            })
            .collect();
        let nearest = distances.iter().copied().fold(f64::INFINITY, f64::min);
        // Subtract the nearest distance so even narrow blends cannot underflow every weight.
        let mut weights: Vec<_> = distances
            .iter()
            .map(|d| (-(d - nearest) / (2.0 * self.settings.blend.powi(2))).exp())
            .collect();
        let total = weights.iter().sum::<f64>();
        weights.iter_mut().for_each(|w| *w /= total);
        weights
    }
    fn carved(&self, p: [i32; 3], surface: i32) -> bool {
        if p[1] == self.settings.min_y {
            return false;
        }
        self.settings.carvers.iter().any(|c| {
            if p[1] < c.min_y || p[1] > c.max_y || p[1] > surface - c.surface_buffer {
                return false;
            }
            let point = p.map(f64::from);
            if c.kind == 0 {
                noise::sample(self.seed, c.field, point) > c.threshold
            } else {
                (noise::sample(self.seed, c.field, [point[0], 0.0, point[2]]) - 0.5).abs()
                    < (1.0 - c.threshold) * 0.08
            }
        })
    }
    fn base(&self, p: [i32; 3], column: &Column) -> u16 {
        let (low, high) = self.bounds();
        if p[1] < low || p[1] > high {
            return 0;
        }
        let b = &self.settings.biomes[column.biome];
        let surface = if p[1] <= column.height {
            Some(column.height)
        } else {
            column
                .island
                .filter(|(bottom, top)| p[1] >= *bottom && p[1] <= *top)
                .map(|(_, top)| top)
        };
        if let Some(top) = surface {
            if self.carved(p, top) {
                return 0;
            }
            if p[1] == top && top >= self.settings.sea_level {
                b.surface
            } else if p[1] > top - 4 {
                b.soil
            } else {
                b.rock
            }
        } else if p[1] <= self.settings.sea_level {
            b.water
        } else {
            0
        }
    }
    pub fn voxel(&self, p: [i32; 3]) -> u16 {
        if !valid_position(p) {
            return 0;
        }
        let column = self.column(p[0], p[2]);
        let id = self.base(p, &column);
        if id > 0 || p[1] < self.bounds().0 || p[1] > self.bounds().1 {
            return id;
        }
        features::instances(self, p, p)
            .iter()
            .map(|i| i.block(p, &column))
            .find(|id| *id > 0)
            .unwrap_or(0)
    }
    pub fn chunk(&self, key: [i32; 3]) -> Result<Vec<u8>, &'static str> {
        if key.iter().any(|c| c.unsigned_abs() > 62_500) {
            return Err("world coordinate out of bounds");
        }
        let origin = key.map(|v| v * 16);
        let max = origin.map(|v| v + 15);
        let mut bytes = vec![0; BYTE_COUNT];
        if max[1] < self.bounds().0 || origin[1] > self.bounds().1 {
            return Ok(bytes);
        }
        let instances = features::instances(self, origin, max);
        for z in 0..CHUNK_SIDE {
            for x in 0..CHUNK_SIDE {
                let column = self.column(origin[0] + x as i32, origin[2] + z as i32);
                for y in 0..CHUNK_SIDE {
                    let p = [
                        origin[0] + x as i32,
                        origin[1] + y as i32,
                        origin[2] + z as i32,
                    ];
                    let mut id = self.base(p, &column);
                    if id == 0 && p[1] >= self.bounds().0 && p[1] <= self.bounds().1 {
                        id = instances
                            .iter()
                            .map(|i| i.block(p, &column))
                            .find(|id| *id > 0)
                            .unwrap_or(0);
                    }
                    let at = ((y * 16 + z) * 16 + x) * 2;
                    bytes[at..at + 2].copy_from_slice(&id.to_le_bytes());
                }
            }
        }
        Ok(bytes)
    }

    /// Reuse horizontal fields and feature anchors within one native batch.
    /// Cache lifetime is the call: no shared locks, mutable generator state or
    /// persistent memory growth across region requests.
    pub fn chunks(&self, keys: &[[i32; 3]]) -> Result<Vec<Vec<u8>>, &'static str> {
        use std::collections::HashMap;
        if keys.iter().flatten().any(|c| c.unsigned_abs() > 62_500) {
            return Err("world coordinate out of bounds");
        }
        let mut counts = HashMap::new();
        for [x, _, z] in keys {
            *counts.entry([*x, *z]).or_insert(0usize) += 1;
        }
        let mut prepared = HashMap::new();
        for (&[x, z], &count) in &counts {
            if count < 2 {
                continue;
            }
            let columns: Vec<_> = (0..16)
                .flat_map(|dz| (0..16).map(move |dx| (dx, dz)))
                .map(|(dx, dz)| self.column(x * 16 + dx, z * 16 + dz))
                .collect();
            let instances = features::instances(
                self,
                [x * 16, self.bounds().0, z * 16],
                [x * 16 + 15, self.bounds().1, z * 16 + 15],
            );
            prepared.insert([x, z], (columns, instances));
        }
        keys.iter()
            .map(|&key| match prepared.get(&[key[0], key[2]]) {
                Some((columns, instances)) => Ok(self.prepared_chunk(key, columns, instances)),
                None => self.chunk(key),
            })
            .collect()
    }

    fn prepared_chunk(
        &self,
        key: [i32; 3],
        columns: &[Column],
        instances: &[features::Instance<'_>],
    ) -> Vec<u8> {
        let origin = key.map(|v| v * 16);
        let max = origin.map(|v| v + 15);
        let mut bytes = vec![0; BYTE_COUNT];
        if max[1] < self.bounds().0 || origin[1] > self.bounds().1 {
            return bytes;
        }
        let instances: Vec<_> = instances
            .iter()
            .filter(|i| {
                i.anchor[1] - i.feature.support_depth <= max[1]
                    && i.anchor[1] + i.feature.height > origin[1]
            })
            .collect();
        // Conservative absence proof. Carvers only remove material; islands,
        // water and every intersecting feature remain accounted for.
        if instances.is_empty()
            && columns.iter().all(|c| {
                c.height < origin[1]
                    && self.settings.sea_level < origin[1]
                    && c.island.is_none_or(|(_, top)| top < origin[1])
            })
        {
            return bytes;
        }
        for z in 0..CHUNK_SIDE {
            for x in 0..CHUNK_SIDE {
                let column = &columns[z * CHUNK_SIDE + x];
                for y in 0..CHUNK_SIDE {
                    let p = [
                        origin[0] + x as i32,
                        origin[1] + y as i32,
                        origin[2] + z as i32,
                    ];
                    let mut id = self.base(p, column);
                    if id == 0 && p[1] >= self.bounds().0 && p[1] <= self.bounds().1 {
                        id = instances
                            .iter()
                            .map(|i| i.block(p, column))
                            .find(|id| *id > 0)
                            .unwrap_or(0);
                    }
                    let at = ((y * 16 + z) * 16 + x) * 2;
                    bytes[at..at + 2].copy_from_slice(&id.to_le_bytes());
                }
            }
        }
        bytes
    }
    pub fn spawn(&self) -> [i32; 3] {
        for radius in 0i32..=64 {
            for z in -radius..=radius {
                for x in -radius..=radius {
                    if x.abs() != radius && z.abs() != radius {
                        continue;
                    }
                    let x = x * 32;
                    let z = z * 32;
                    let c = self.column(x, z);
                    if c.height > self.settings.sea_level + 4 && c.height + 66 < self.bounds().1 {
                        return [x, self.surface_spawn_height(x, z), z];
                    }
                }
            }
        }
        [0, self.surface_spawn_height(0, 0), 0]
    }
    pub fn surface_spawn_height(&self, x: i32, z: i32) -> i32 {
        let c = self.column(x, z);
        let mut top = c.height.max(self.settings.sea_level);
        for instance in features::instances(self, [x, top + 1, z], [x, top + 64, z]) {
            for y in (top + 1..=top + 64).rev() {
                if instance.block([x, y, z], &c) > 0 {
                    top = top.max(y);
                    break;
                }
            }
        }
        (top + 1).min(self.bounds().1 - 2)
    }
}
fn valid_position(p: [i32; 3]) -> bool {
    p.iter().all(|v| v.unsigned_abs() <= 1_000_000)
}
