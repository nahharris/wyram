use std::collections::HashMap;

use crate::world::Vertex;
use wyram_core::CHUNK_SIDE;

pub(crate) const FACES: [([i32; 3], [[f32; 3]; 4], f32); 6] = [
    (
        [1, 0, 0],
        [[1., 0., 0.], [1., 1., 0.], [1., 1., 1.], [1., 0., 1.]],
        0.78,
    ),
    (
        [-1, 0, 0],
        [[0., 0., 1.], [0., 1., 1.], [0., 1., 0.], [0., 0., 0.]],
        0.66,
    ),
    (
        [0, 1, 0],
        [[0., 1., 0.], [0., 1., 1.], [1., 1., 1.], [1., 1., 0.]],
        1.0,
    ),
    (
        [0, -1, 0],
        [[0., 0., 1.], [0., 0., 0.], [1., 0., 0.], [1., 0., 1.]],
        0.45,
    ),
    (
        [0, 0, 1],
        [[1., 0., 1.], [1., 1., 1.], [0., 1., 1.], [0., 0., 1.]],
        0.82,
    ),
    (
        [0, 0, -1],
        [[0., 0., 0.], [0., 1., 0.], [1., 1., 0.], [1., 0., 0.]],
        0.72,
    ),
];

fn read(data: &[u8], p: [usize; 3]) -> u16 {
    let at = ((p[1] * CHUNK_SIDE + p[2]) * CHUNK_SIDE + p[0]) * 2;
    u16::from_le_bytes([data[at], data[at + 1]])
}

pub fn build(
    data: &[u8],
    key: [i32; 3],
    colors: &HashMap<u16, [u8; 3]>,
    neighbor: impl Fn([i32; 3]) -> u16,
) -> Vec<Vertex> {
    if data.iter().all(|byte| *byte == 0) {
        return Vec::new();
    }
    let origin = key.map(|v| v * CHUNK_SIDE as i32);
    let mut vertices = Vec::new();
    for (offset, corners, shade) in FACES {
        let axis = offset
            .iter()
            .position(|v| *v != 0)
            .expect("face has a normal");
        let u = (axis + 1) % 3;
        let v = (axis + 2) % 3;
        for layer in 0..CHUNK_SIDE {
            let mut mask = [0u16; CHUNK_SIDE * CHUNK_SIDE];
            for j in 0..CHUNK_SIDE {
                for i in 0..CHUNK_SIDE {
                    let mut p = [0; 3];
                    p[axis] = layer;
                    p[u] = i;
                    p[v] = j;
                    let material = read(data, p);
                    if material == 0 {
                        continue;
                    }
                    let next = layer as i32 + offset[axis];
                    let adjacent = if (0..CHUNK_SIDE as i32).contains(&next) {
                        let mut p = p;
                        p[axis] = next as usize;
                        read(data, p)
                    } else {
                        neighbor(std::array::from_fn(|d| origin[d] + p[d] as i32 + offset[d]))
                    };
                    if adjacent == 0 {
                        mask[j * CHUNK_SIDE + i] = material;
                    }
                }
            }
            for j in 0..CHUNK_SIDE {
                let mut i = 0;
                while i < CHUNK_SIDE {
                    let material = mask[j * CHUNK_SIDE + i];
                    if material == 0 {
                        i += 1;
                        continue;
                    }
                    let mut width = 1;
                    while i + width < CHUNK_SIDE && mask[j * CHUNK_SIDE + i + width] == material {
                        width += 1;
                    }
                    let mut height = 1;
                    while j + height < CHUNK_SIDE
                        && (0..width).all(|x| mask[(j + height) * CHUNK_SIDE + i + x] == material)
                    {
                        height += 1;
                    }
                    let mut base = origin.map(|p| p as f32);
                    base[axis] += layer as f32;
                    base[u] += i as f32;
                    base[v] += j as f32;
                    let mut extent = [1.0; 3];
                    extent[u] = width as f32;
                    extent[v] = height as f32;
                    let color = colors
                        .get(&material)
                        .copied()
                        .unwrap_or([255, 0, 255])
                        .map(|value| value as f32 / 255.0 * shade);
                    for corner in [0, 1, 2, 0, 2, 3] {
                        vertices.push(Vertex {
                            position: [
                                base[0] + corners[corner][0] * extent[0],
                                base[1] + corners[corner][1] * extent[1],
                                base[2] + corners[corner][2] * extent[2],
                            ],
                            color,
                        });
                    }
                    for y in j..j + height {
                        mask[y * CHUNK_SIDE + i..y * CHUNK_SIDE + i + width].fill(0);
                    }
                    i += width;
                }
            }
        }
    }
    vertices
}
