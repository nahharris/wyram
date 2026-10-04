use super::Generator;
use crate::BYTE_COUNT;
use crate::scenery::{LodTile, TileKey};
use std::collections::{BTreeSet, HashSet};

// Keep the sea surface in its stratum when a midpoint above it would be air.
// Unit samples stay exact, and midpoints already below the surface stay put.
pub(super) fn sample_y(center: i32, step: i32, sea_level: i32) -> i32 {
    if (center - step / 2..center).contains(&sea_level) {
        sea_level
    } else {
        center
    }
}

struct Grid {
    origin: [i32; 3],
    side: usize,
    step: i32,
    sea_level: i32,
}

impl Grid {
    fn new(key: TileKey, sea_level: i32) -> Result<Self, &'static str> {
        if key.level() > 6 {
            return Err("unsupported scenic generation level");
        }
        let origin = key.origin();
        let width = i64::from(key.scale()) * 16;
        let valid = if key.level() == 0 {
            key.position().iter().all(|v| v.unsigned_abs() <= 62_500)
        } else {
            origin
                .iter()
                .all(|&v| v >= -1_000_000 && v + width - 1 <= 1_000_000)
        };
        if !valid {
            return Err("world coordinate out of bounds");
        }
        let step = if key.level() == 0 {
            1
        } else {
            i32::from(key.scale() / 2)
        };
        let offset = if key.level() == 0 { 0 } else { step / 2 };
        Ok(Self {
            origin: origin.map(|v| v as i32 + offset),
            side: if key.level() == 0 { 16 } else { 32 },
            step,
            sea_level,
        })
    }
    fn count(&self) -> usize {
        self.side.pow(3)
    }
    fn position(&self, index: usize) -> [i32; 3] {
        let local = [
            index % self.side,
            index / self.side.pow(2),
            index / self.side % self.side,
        ];
        let mut position =
            std::array::from_fn(|axis| self.origin[axis] + local[axis] as i32 * self.step);
        position[1] = sample_y(position[1], self.step, self.sea_level);
        position
    }
    fn range(&self, axis: usize, low: i32, high: i32) -> Option<std::ops::RangeInclusive<usize>> {
        if axis == 1 {
            // The shifted sea sample can cross a chunk boundary. Its positions
            // remain ordered, so a bounded scan still yields a contiguous range.
            let mut matching = (0..self.side).filter(|&index| {
                let y = sample_y(
                    self.origin[1] + index as i32 * self.step,
                    self.step,
                    self.sea_level,
                );
                (low..=high).contains(&y)
            });
            let first = matching.next()?;
            return Some(first..=matching.next_back().unwrap_or(first));
        }
        let first = -(-(low - self.origin[axis])).div_euclid(self.step);
        let last = (high - self.origin[axis]).div_euclid(self.step);
        let first = first.max(0);
        let last = last.min(self.side as i32 - 1);
        (first <= last).then_some(first as usize..=last as usize)
    }
}

impl Generator {
    /// Distinct chunks containing actual samples, ordered for deterministic bounded reads.
    pub fn scenic_sample_chunks(&self, key: TileKey) -> Result<Vec<[i32; 3]>, &'static str> {
        let grid = Grid::new(key, self.settings.sea_level)?;
        let (low, high) = self.bounds();
        let keys: BTreeSet<_> = (0..grid.count())
            .filter_map(|index| {
                let p = grid.position(index);
                (p[1] >= low && p[1] <= high).then(|| p.map(|v| v.div_euclid(16)))
            })
            .collect();
        Ok(keys.into_iter().collect())
    }
    pub fn extract_scenic_samples(
        &self,
        key: TileKey,
        chunks: &[([i32; 3], &[u8])],
    ) -> Result<Vec<u8>, &'static str> {
        if chunks.len() > 256 {
            return Err("oversized scenic edit batch");
        }
        let grid = Grid::new(key, self.settings.sea_level)?;
        let (low, high) = self.bounds();
        let mut seen = HashSet::with_capacity(chunks.len());
        let mut output = Vec::new();
        for &(position, bytes) in chunks {
            if bytes.len() != BYTE_COUNT
                || position.iter().any(|v| v.unsigned_abs() > 62_500)
                || !seen.insert(position)
            {
                return Err("invalid scenic edited chunk");
            }
            let origin = position.map(|v| v * 16);
            let ranges: [Option<_>; 3] = std::array::from_fn(|axis| {
                let min = if axis == 1 {
                    origin[axis].max(low)
                } else {
                    origin[axis]
                };
                let max = if axis == 1 {
                    (origin[axis] + 15).min(high)
                } else {
                    origin[axis] + 15
                };
                grid.range(axis, min, max)
            });
            let [Some(xs), Some(ys), Some(zs)] = ranges else {
                return Err("unrelated scenic edited chunk");
            };
            for y in ys {
                for z in zs.clone() {
                    for x in xs.clone() {
                        let index = (y * grid.side + z) * grid.side + x;
                        let p = grid.position(index).map(|v| v.rem_euclid(16) as usize);
                        let at = ((p[1] * 16 + p[2]) * 16 + p[0]) * 2;
                        output.extend_from_slice(&(index as u16).to_le_bytes());
                        output.extend_from_slice(&bytes[at..at + 2]);
                    }
                }
            }
        }
        Ok(output)
    }
    pub fn scenic_tile_with_samples(
        &self,
        key: TileKey,
        overrides: &[u8],
    ) -> Result<LodTile, &'static str> {
        let grid = Grid::new(key, self.settings.sea_level)?;
        if overrides.len() > grid.count() * 4 || !overrides.len().is_multiple_of(4) {
            return Err("invalid scenic sample overrides");
        }
        let mut seen = vec![false; grid.count()];
        let mut decoded = Vec::with_capacity(overrides.len() / 4);
        let (low, high) = self.bounds();
        for bytes in overrides.as_chunks::<4>().0 {
            let index = usize::from(u16::from_le_bytes([bytes[0], bytes[1]]));
            if index >= grid.count() || seen[index] {
                return Err("invalid scenic sample overrides");
            }
            let y = grid.position(index)[1];
            if y < low || y > high {
                return Err("invalid scenic sample overrides");
            }
            seen[index] = true;
            decoded.push((index, u16::from_le_bytes([bytes[2], bytes[3]])));
        }
        self.build_scenic_tile(key, &decoded)
    }
}
