use super::{Feature, Generator, noise};
pub struct Instance<'a> {
    pub anchor: [i32; 3],
    pub feature: &'a Feature,
}
impl Instance<'_> {
    pub fn block(&self, p: [i32; 3]) -> u16 {
        let [x, y, z] = std::array::from_fn(|i| p[i] - self.anchor[i]);
        let f = self.feature;
        if y < 0 || y >= f.height || x.abs() > f.radius || z.abs() > f.radius {
            return 0;
        }
        let r = f64::from(f.radius);
        let h = f64::from(f.height);
        let d = f64::from(x * x + z * z);
        match f.kind {
            0 if x.abs() <= 1 && z.abs() <= 1 && y < f.height - f.height / 4 => f.block,
            0 if y >= f.height / 2
                && d / r.powi(2) + (f64::from(y) - h * 0.72).powi(2) / (h * 0.3).powi(2) <= 1.0 =>
            {
                f.accent
            }
            1 if d / r.powi(2) + (f64::from(y) / h).powi(2) <= 1.0 => f.block,
            2 if f64::from(x.abs() + z.abs()) <= r * (1.0 - f64::from(y) / h) => {
                if (x + z).rem_euclid(3) == 0 {
                    f.accent
                } else {
                    f.block
                }
            }
            _ => 0,
        }
    }
}
pub fn instances(g: &Generator, min: [i32; 3], max: [i32; 3]) -> Vec<Instance<'_>> {
    let mut out = vec![];
    for (biome, b) in g.settings.biomes.iter().enumerate() {
        for f in &b.features {
            if f.density == 0.0 {
                continue;
            }
            let s = f.spacing;
            for gz in (min[2] - f.radius).div_euclid(s)..=(max[2] + f.radius).div_euclid(s) {
                for gx in (min[0] - f.radius).div_euclid(s)..=(max[0] + f.radius).div_euclid(s) {
                    let hash = noise::hash(g.seed ^ f.salt, gx, 0, gz);
                    if noise::unit(hash) >= f.density {
                        continue;
                    }
                    let x = gx * s + (noise::hash(hash, 1, 0, 0) % s as u64) as i32;
                    let z = gz * s + (noise::hash(hash, 2, 0, 0) % s as u64) as i32;
                    let column = g.column(x, z);
                    if column.biome != biome {
                        continue;
                    }
                    let y = if f.domain == 0 {
                        if column.height <= g.settings.sea_level + 1 {
                            continue;
                        }
                        column.height + 1
                    } else {
                        let Some((_, top)) = column.island else {
                            continue;
                        };
                        top + 1
                    };
                    if y > max[1] || y + f.height <= min[1] {
                        continue;
                    }
                    out.push(Instance {
                        anchor: [x, y, z],
                        feature: f,
                    });
                }
            }
        }
    }
    out
}
