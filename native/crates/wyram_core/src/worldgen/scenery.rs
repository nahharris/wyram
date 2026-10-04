use super::{Generator, features};
use crate::scenery::{LodCell, LodTile, TileKey};
use crate::{BLOCK_COUNT, CHUNK_SIDE};

impl Generator {
    /// Eight stratified world-rule samples per cell. Level one is exact;
    /// higher levels estimate occupancy and can omit unsampled small details.
    /// At most 32³ samples and 32² terrain columns are evaluated per tile.
    pub fn scenic_tile(&self, key: TileKey) -> Result<LodTile, &'static str> {
        if key.level() == 0 {
            let bytes = self.chunk(key.position())?;
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
        for z in 0..side {
            for x in 0..side {
                let px = sample_origin[0] + x as i32 * step;
                let pz = sample_origin[2] + z as i32 * step;
                let column = self.column(px, pz);
                let mut decorations = None;
                for y in 0..side {
                    let py = sample_origin[1] + y as i32 * step;
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
                    samples[(y * side + z) * side + x] = material;
                }
            }
        }
        let cells = (0..BLOCK_COUNT)
            .map(|at| {
                let p = [at % 16 * 2, at / 256 * 2, at / 16 % 16 * 2];
                let children = std::array::from_fn(|octant| {
                    let x = p[0] + (octant & 1);
                    let y = p[1] + ((octant >> 1) & 1);
                    let z = p[2] + ((octant >> 2) & 1);
                    LodCell::uniform(samples[(y * side + z) * side + x], half)
                });
                LodCell::reduce(children)
            })
            .collect();
        Ok(LodTile::from_cells(key, cells))
    }
}
