use std::collections::{BTreeMap, HashMap};

use super::{Column, Generator, features};
use crate::lod::{Cell, TILE_SIDE_WITH_HALO, Tile, TileKey, cell_index};

struct SurfaceSample {
    terrain: Option<(i32, u16)>,
    island: Option<(i32, i32, u16)>,
    feature: Option<(i32, u16)>,
}

impl Generator {
    /// Builds one deterministic coarse summary. It is view-independent and does
    /// not create or read gameplay region state.
    pub fn lod_tile(&self, key: TileKey, liquid_ids: &[u16]) -> Result<Tile, &'static str> {
        let origin = key.origin()?;
        if liquid_ids.len() > 256 || liquid_ids.contains(&0) {
            return Err("invalid LOD liquid IDs");
        }
        let mut tile = Tile::empty(key)?;
        let size = i32::from(key.cell_size);
        let end = origin.map(|v| v + key.span());
        let (low, high) = self.bounds();
        if end[1] <= low || origin[1] > high {
            return Ok(tile);
        }

        let xs = sample_axis(origin[0], size);
        let zs = sample_axis(origin[2], size);
        let feature_min = [
            origin[0] - size,
            low.max(origin[1] - size),
            origin[2] - size,
        ];
        let feature_max = [
            end[0] + size - 1,
            high.min(end[1] + size - 1),
            end[2] + size - 1,
        ];
        let instances = features::instances(self, feature_min, feature_max);
        let feature_index = index_features(&instances, &xs, &zs);

        let mut columns = Vec::with_capacity(xs.len() * zs.len());
        let mut surfaces = Vec::with_capacity(xs.len() * zs.len());
        for &z in &zs {
            for &x in &xs {
                let column = self.column(x, z);
                let feature_candidates = feature_index.get(&(x, z)).map_or(&[][..], Vec::as_slice);
                let surface = surface_sample(
                    self,
                    [x, z],
                    &column,
                    feature_candidates,
                    &instances,
                    low,
                    high,
                );
                columns.push(column);
                surfaces.push(surface);
            }
        }

        let sample_offsets = vertical_sample_offsets(key.cell_size);
        for y in 0..TILE_SIDE_WITH_HALO {
            let cell_low = origin[1] + (y as i32 - 1) * size;
            if cell_low + size <= low || cell_low > high {
                continue;
            }
            for z in 0..TILE_SIDE_WITH_HALO {
                for x in 0..TILE_SIDE_WITH_HALO {
                    let mut solids = BTreeMap::<u16, usize>::new();
                    let mut top_liquids = BTreeMap::<u16, usize>::new();
                    let mut solid_hits = 0usize;
                    let mut liquid_top = None;
                    let mut heights = [0i32; 4];
                    let mut feature_height = 0;
                    let mut top_materials = BTreeMap::<u16, usize>::new();
                    let mut supported_columns = 0usize;
                    for hz in 0..2 {
                        for hx in 0..2 {
                            let sample_x_index = x * 2 + hx;
                            let sample_z_index = z * 2 + hz;
                            let column_index = sample_z_index * xs.len() + sample_x_index;
                            let column = &columns[column_index];
                            let surface = &surfaces[column_index];
                            let local_column = hz * 2 + hx;
                            let mut exposed = Vec::new();
                            if let Some((surface_y, material)) = surface.terrain {
                                heights[local_column] = heights[local_column]
                                    .max((surface_y - cell_low + 1).clamp(0, size));
                                if (cell_low..cell_low + size).contains(&surface_y) {
                                    exposed.push((surface_y, material));
                                }
                            }
                            if let Some((bottom, surface_y, material)) = surface.island {
                                if surface_y >= cell_low && bottom < cell_low + size {
                                    heights[local_column] = heights[local_column]
                                        .max((surface_y - cell_low + 1).clamp(0, size));
                                }
                                if (cell_low..cell_low + size).contains(&surface_y) {
                                    exposed.push((surface_y, material));
                                }
                            }
                            if let Some((surface_y, material)) = surface.feature
                                && surface_y >= cell_low
                                && surface_y < cell_low + size
                            {
                                heights[local_column] =
                                    heights[local_column].max(surface_y - cell_low + 1);
                                exposed.push((surface_y, material));
                            }
                            if let Some((_, material)) = exposed.into_iter().max_by_key(|s| s.0) {
                                *top_materials.entry(material).or_default() += 1;
                            }
                            let mut column_solid = false;
                            let world_x = xs[sample_x_index];
                            let world_z = zs[sample_z_index];
                            let feature_candidates = feature_index
                                .get(&(world_x, world_z))
                                .map_or(&[][..], Vec::as_slice);
                            for &sample_y in &sample_offsets {
                                let world_y = cell_low + sample_y;
                                if !(low..=high).contains(&world_y) {
                                    continue;
                                }
                                let p = [world_x, world_y, world_z];
                                let mut material = self.base(p, column);
                                if material == 0 {
                                    material = feature_candidates
                                        .iter()
                                        .map(|&i| instances[i].block(p, column))
                                        .find(|&id| id != 0)
                                        .unwrap_or(0);
                                    if material != 0
                                        && let Some((top, _)) = surface.feature
                                    {
                                        heights[local_column] = heights[local_column]
                                            .max((top - cell_low + 1).clamp(0, size));
                                        feature_height =
                                            feature_height.max((top - cell_low + 1).clamp(0, size));
                                    }
                                }
                                if material == 0 {
                                    continue;
                                }
                                if liquid_ids.contains(&material) {
                                    match liquid_top {
                                        None => {
                                            liquid_top = Some(sample_y);
                                            *top_liquids.entry(material).or_default() += 1;
                                        }
                                        Some(previous) if sample_y > previous => {
                                            liquid_top = Some(sample_y);
                                            top_liquids.clear();
                                            *top_liquids.entry(material).or_default() += 1;
                                        }
                                        Some(previous) if sample_y == previous => {
                                            *top_liquids.entry(material).or_default() += 1;
                                        }
                                        _ => {}
                                    }
                                } else {
                                    solid_hits += 1;
                                    column_solid = true;
                                    *solids.entry(material).or_default() += 1;
                                }
                            }
                            supported_columns += usize::from(column_solid);
                        }
                    }

                    let top_supported = top_materials.values().sum::<usize>() >= 2;
                    let solid_supported = supported_columns >= 2;
                    let volume_material = weighted_id(&solids);
                    let material = if solid_supported || top_supported {
                        if volume_material != 0 {
                            volume_material
                        } else {
                            weighted_id(&top_materials)
                        }
                    } else {
                        0
                    };
                    let mut solid_height = if solid_supported || top_supported {
                        // Unsupported footprint columns must not shorten every
                        // vertical tree cell into disconnected horizontal slabs.
                        ((heights.iter().sum::<i32>() + 2) / 4)
                            .max(feature_height)
                            .clamp(0, size) as u8
                    } else {
                        0
                    };
                    if material != 0 && solid_height == 0 {
                        solid_height = 1;
                    }
                    let liquid = weighted_id(&top_liquids);
                    let liquid_height = if liquid == 0 {
                        0
                    } else {
                        let liquid_top = if liquid_ids.contains(&liquid)
                            && top_liquids.keys().any(|id| id == &liquid)
                            && self
                                .settings
                                .biomes
                                .iter()
                                .any(|biome| biome.water == liquid)
                            && cell_low <= self.settings.sea_level
                        {
                            self.settings.sea_level - cell_low + 1
                        } else {
                            liquid_top.unwrap_or(0) + 1
                        };
                        liquid_top.clamp(0, size) as u8
                    };
                    let liquid_height = if liquid_height <= solid_height {
                        0
                    } else {
                        liquid_height
                    };
                    let cell = Cell {
                        material,
                        top_material: if top_supported {
                            weighted_id(&top_materials)
                        } else {
                            0
                        },
                        liquid: if liquid_height == 0 { 0 } else { liquid },
                        coverage: ((solid_hits * 255 + 4) / 8) as u8,
                        solid_height,
                        liquid_height,
                        reserved: 0,
                    };
                    tile.cells[cell_index(x, y, z)] = cell;
                }
            }
        }
        Ok(tile)
    }
}

fn sample_axis(origin: i32, size: i32) -> Vec<i32> {
    let offsets = horizontal_sample_offsets(size);
    (0..TILE_SIDE_WITH_HALO)
        .flat_map(|cell| {
            let low = origin + (cell as i32 - 1) * size;
            offsets.iter().map(move |&offset| low + offset)
        })
        .collect()
}

fn horizontal_sample_offsets(size: i32) -> [i32; 2] {
    if size == 2 {
        [0, 1]
    } else {
        [size / 4, (size * 3) / 4]
    }
}

fn vertical_sample_offsets(size: u8) -> [i32; 2] {
    horizontal_sample_offsets(i32::from(size))
}

fn index_features(
    instances: &[features::Instance<'_>],
    xs: &[i32],
    zs: &[i32],
) -> HashMap<(i32, i32), Vec<usize>> {
    let mut index = HashMap::<(i32, i32), Vec<usize>>::new();
    for (instance_index, instance) in instances.iter().enumerate() {
        let radius = instance.feature.radius;
        for &z in zs
            .iter()
            .filter(|&&z| (z - instance.anchor[2]).abs() <= radius)
        {
            for &x in xs
                .iter()
                .filter(|&&x| (x - instance.anchor[0]).abs() <= radius)
            {
                index.entry((x, z)).or_default().push(instance_index);
            }
        }
    }
    index
}

fn surface_sample(
    generator: &Generator,
    horizontal: [i32; 2],
    column: &Column,
    feature_candidates: &[usize],
    instances: &[features::Instance<'_>],
    low: i32,
    high: i32,
) -> SurfaceSample {
    let terrain = find_surface(generator, horizontal, column, column.height, low, high);
    let island = column.island.and_then(|(bottom, top)| {
        if top <= column.height {
            return None;
        }
        find_surface(generator, horizontal, column, top, bottom.max(low), high)
            .map(|(y, material)| (bottom, y, material))
    });
    let mut feature = None;
    for &index in feature_candidates {
        let instance = &instances[index];
        let start = (instance.anchor[1] - instance.feature.support_depth).max(low);
        let end = (instance.anchor[1] + instance.feature.height - 1).min(high);
        for y in (start..=end).rev() {
            let id = instance.block([horizontal[0], y, horizontal[1]], column);
            // A floating island above a tree does not bury the tree's cap.
            // Check occupancy at the cap rather than the highest geology surface.
            if id != 0
                && generator.base([horizontal[0], y, horizontal[1]], column) == 0
                && feature.is_none_or(|(previous, _)| y > previous)
            {
                feature = Some((y, id));
                break;
            }
        }
    }
    SurfaceSample {
        terrain,
        island,
        feature,
    }
}

fn find_surface(
    generator: &Generator,
    horizontal: [i32; 2],
    column: &Column,
    top: i32,
    bottom: i32,
    high: i32,
) -> Option<(i32, u16)> {
    (bottom.max(top - 64)..=top.min(high)).rev().find_map(|y| {
        let material = generator.base([horizontal[0], y, horizontal[1]], column);
        (material != 0).then_some((y, material))
    })
}

fn weighted_id(counts: &BTreeMap<u16, usize>) -> u16 {
    counts
        .iter()
        .max_by(|(left_id, left_count), (right_id, right_count)| {
            left_count
                .cmp(right_count)
                .then_with(|| right_id.cmp(left_id))
        })
        .map_or(0, |(&id, _)| id)
}
