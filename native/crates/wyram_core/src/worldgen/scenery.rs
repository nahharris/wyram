use super::{Generator, features, scenic_edits::sample_y};
use crate::scenery::{LodCell, LodTile, TileKey, reduce_top};
use crate::{BLOCK_COUNT, CHUNK_SIDE};

impl Generator {
    /// Eight stratified world-rule samples per cell. Level one is exact;
    /// higher levels estimate occupancy and can omit unsampled small details.
    /// The sea-level stratum samples its surface if the midpoint would miss it.
    /// At most 32³ volume samples and 32² terrain columns are evaluated per tile,
    /// plus at most two geological surface evaluations per column.
    pub fn scenic_tile(&self, key: TileKey) -> Result<LodTile, &'static str> {
        self.scenic_tile_with_samples(key, &[])
    }

    pub(super) fn build_scenic_tile(
        &self,
        key: TileKey,
        overrides: &[(usize, u16)],
    ) -> Result<LodTile, &'static str> {
        if key.level() == 0 {
            let mut bytes = self.chunk(key.position())?;
            for &(index, material) in overrides {
                bytes[index * 2..index * 2 + 2].copy_from_slice(&material.to_le_bytes());
            }
            return LodTile::from_chunk(key, &bytes).map_err(|_| "invalid scenic chunk");
        }
        if key.level() > 6 {
            return Err("unsupported scenic generation level");
        }
        let wide_origin = key.origin();
        let width = i64::from(key.scale()) * CHUNK_SIDE as i64;
        if wide_origin
            .iter()
            .any(|&v| v < -1_000_000 || v + width - 1 > 1_000_000)
        {
            return Err("world coordinate out of bounds");
        }
        let origin = wide_origin.map(|v| v as i32);
        let (low, high) = self.bounds();
        let end_y = origin[1] + width as i32 - 1;
        if end_y < low || origin[1] > high {
            return Ok(LodTile::uniform(key, 0));
        }
        let half = key.scale() / 2;
        let step = i32::from(half);
        let sample_origin = origin.map(|v| v + step / 2);
        let side = CHUNK_SIDE * 2;
        let mut samples = vec![0u16; side.pow(3)];
        let mut top_samples = vec![0u16; side.pow(3)];
        for z in 0..side {
            for x in 0..side {
                let px = sample_origin[0] + x as i32 * step;
                let pz = sample_origin[2] + z as i32 * step;
                let column = self.column(px, pz);
                let mut decorations = None;
                for y in 0..side {
                    let py = sample_y(
                        sample_origin[1] + y as i32 * step,
                        step,
                        self.settings.sea_level,
                    );
                    if py < low || py > high {
                        continue;
                    }
                    let p = [px, py, pz];
                    let mut material = self.base(p, &column);
                    if material == 0 {
                        // Enumerate only anchors touching this column, never a
                        // potentially huge coarse tile's entire horizontal area.
                        let instances = decorations.get_or_insert_with(|| {
                            features::instances(
                                self,
                                [px, origin[1].max(low), pz],
                                [px, end_y.min(high), pz],
                            )
                        });
                        material = instances
                            .iter()
                            .map(|i| i.block(p, &column))
                            .find(|&id| id != 0)
                            .unwrap_or(0);
                    }
                    let at = (y * side + z) * side + x;
                    samples[at] = material;
                    let biome = &self.settings.biomes[column.biome];
                    let surface = [Some(column.height), column.island.map(|(_, top)| top)]
                        .into_iter()
                        .flatten()
                        // The last occupied sample can lie below the cell
                        // containing the thin surface; its next sample is air.
                        .filter(|&top| top >= py && top < py + step)
                        .max();
                    top_samples[at] = if material != 0
                        && [biome.rock, biome.soil, biome.surface].contains(&material)
                    {
                        surface.map_or(material, |top| {
                            let id = self.base([px, top, pz], &column);
                            if id == 0 { material } else { id }
                        })
                    } else {
                        material
                    };
                }
            }
        }
        for &(index, material) in overrides {
            samples[index] = material;
            top_samples[index] = material;
        }
        let (cells, top): (Vec<_>, Vec<_>) = (0..BLOCK_COUNT)
            .map(|at| {
                let p = [at % 16 * 2, at / 256 * 2, at / 16 % 16 * 2];
                let children = std::array::from_fn(|octant| {
                    let x = p[0] + (octant & 1);
                    let y = p[1] + ((octant >> 1) & 1);
                    let z = p[2] + ((octant >> 2) & 1);
                    LodCell::uniform(samples[(y * side + z) * side + x], half)
                });
                let top = reduce_top(std::array::from_fn(|octant| {
                    let x = p[0] + (octant & 1);
                    let y = p[1] + ((octant >> 1) & 1);
                    let z = p[2] + ((octant >> 2) & 1);
                    (
                        children[octant].occupied(),
                        top_samples[(y * side + z) * side + x],
                    )
                }));
                (LodCell::reduce(children), top)
            })
            .unzip();
        Ok(LodTile::from_cells_with_top(key, cells, top))
    }
}
