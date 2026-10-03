#[derive(Clone, Copy, Debug)]
pub struct Field {
    pub scale: f64,
    pub octaves: u32,
    pub salt: u64,
}
impl Field {
    pub fn new(scale: f64, salt: u64) -> Self {
        Self {
            scale,
            octaves: 3,
            salt,
        }
    }
    pub fn valid(self) -> bool {
        (16.0..=8192.0).contains(&self.scale)
            && (1..=5).contains(&self.octaves)
            && self.salt <= u32::MAX as u64
    }
}
#[derive(Clone, Debug)]
pub struct Feature {
    pub kind: u8,
    pub block: u16,
    pub accent: u16,
    pub spacing: i32,
    pub density: f64,
    pub radius: i32,
    pub height: i32,
    pub salt: u64,
    pub domain: u8,
    pub support_depth: i32,
}
#[derive(Clone, Debug)]
pub struct Biome {
    pub climate: [f64; 6],
    pub surface: u16,
    pub soil: u16,
    pub rock: u16,
    pub water: u16,
    pub elevation_offset: i32,
    pub features: Vec<Feature>,
}
#[derive(Clone, Debug)]
pub struct Carver {
    pub kind: u8,
    pub field: Field,
    pub threshold: f64,
    pub min_y: i32,
    pub max_y: i32,
    pub surface_buffer: i32,
}
#[derive(Clone, Debug)]
pub struct Islands {
    pub field: Field,
    pub base_y: i32,
    pub thickness: i32,
    pub relief: i32,
    pub threshold: f64,
}
#[derive(Clone, Copy, Debug)]
pub struct Terrain {
    pub roughness: f64,
    pub valley_depth: f64,
    pub plains_strength: f64,
    pub shelf_height: i32,
    pub shelf_strength: f64,
}
impl Default for Terrain {
    fn default() -> Self {
        Self {
            roughness: 12.0,
            valley_depth: 20.0,
            plains_strength: 0.8,
            shelf_height: 8,
            shelf_strength: 0.65,
        }
    }
}
impl Terrain {
    fn valid(self) -> bool {
        (0.0..=32.0).contains(&self.roughness)
            && (0.0..=64.0).contains(&self.valley_depth)
            && (0.0..=1.0).contains(&self.plains_strength)
            && (2..=16).contains(&self.shelf_height)
            && (0.0..=1.0).contains(&self.shelf_strength)
    }
}
#[derive(Clone, Debug)]
pub struct Settings {
    pub min_y: i32,
    pub height: i32,
    pub sea_level: i32,
    pub relief: i32,
    pub blend: f64,
    pub terrain: Terrain,
    pub fields: [Field; 6],
    pub carvers: Vec<Carver>,
    pub islands: Option<Islands>,
    pub biomes: Vec<Biome>,
}
impl Default for Settings {
    fn default() -> Self {
        Self {
            min_y: -192,
            height: 512,
            sea_level: 0,
            relief: 140,
            blend: 0.2,
            terrain: Terrain::default(),
            fields: [
                Field::new(1536.0, 11),
                Field::new(256.0, 23),
                Field::new(640.0, 31),
                Field::new(1024.0, 43),
                Field::new(768.0, 53),
                Field::new(64.0, 61),
            ],
            carvers: vec![Carver {
                kind: 0,
                field: Field {
                    scale: 48.0,
                    octaves: 2,
                    salt: 71,
                },
                threshold: 0.68,
                min_y: -184,
                max_y: 176,
                surface_buffer: 8,
            }],
            islands: Some(Islands {
                field: Field::new(384.0, 97),
                base_y: 224,
                thickness: 40,
                relief: 32,
                threshold: 0.62,
            }),
            biomes: vec![Biome {
                climate: [0.5; 6],
                surface: 1,
                soil: 2,
                rock: 3,
                water: 4,
                elevation_offset: 0,
                features: vec![],
            }],
        }
    }
}
impl Settings {
    pub fn valid(&self) -> bool {
        (-4096..=3584).contains(&self.min_y)
            && self.min_y % 16 == 0
            && (64..=512).contains(&self.height)
            && self.height % 16 == 0
            && (self.min_y + 8..=self.min_y + self.height - 8).contains(&self.sea_level)
            && (0..=192).contains(&self.relief)
            && (0.01..=1.0).contains(&self.blend)
            && self.terrain.valid()
            && self.fields.iter().all(|f| f.valid())
            && self.valid_carvers()
            && self.valid_islands()
            && self.valid_biomes()
    }
    fn valid_carvers(&self) -> bool {
        self.carvers.len() <= 4
            && self.carvers.iter().all(|c| {
                c.kind <= 1
                    && c.field.valid()
                    && (0.5..=0.95).contains(&c.threshold)
                    && c.min_y > self.min_y
                    && c.max_y >= c.min_y
                    && c.max_y < self.min_y + self.height
                    && (0..=32).contains(&c.surface_buffer)
            })
    }
    fn valid_islands(&self) -> bool {
        self.islands.as_ref().is_none_or(|i| {
            i.field.valid()
                && (-4096..=4095).contains(&i.base_y)
                && (4..=96).contains(&i.thickness)
                && (0..=64).contains(&i.relief)
                && (0.5..=0.9).contains(&i.threshold)
                && i.base_y - i.thickness >= self.min_y
                && i.base_y + i.relief < self.min_y + self.height
        })
    }
    fn valid_biomes(&self) -> bool {
        (1..=32).contains(&self.biomes.len())
            && self.biomes.iter().map(|b| b.features.len()).sum::<usize>() <= 64
            && self.biomes.iter().all(|b| {
                b.climate.iter().all(|v| (0.0..=1.0).contains(v))
                    && b.surface > 0
                    && b.soil > 0
                    && b.rock > 0
                    && (-64..=64).contains(&b.elevation_offset)
                    && b.features.len() <= 8
                    && valid_features(&b.features)
            })
    }
}
fn valid_features(features: &[Feature]) -> bool {
    let mut salts = std::collections::HashSet::new();
    features.iter().all(|f| {
        f.kind <= 2
            && (0..=64).contains(&f.support_depth)
            && f.domain <= 1
            && f.block > 0
            && f.accent > 0
            && (16..=128).contains(&f.spacing)
            && (0.0..=1.0).contains(&f.density)
            && (1..=16).contains(&f.radius)
            && (1..=64).contains(&f.height)
            && f.salt <= u32::MAX as u64
            && salts.insert(f.salt)
    })
}
