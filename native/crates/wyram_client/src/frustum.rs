use glam::{Mat4, Vec4};

pub struct Frustum([Vec4; 6]);

impl Frustum {
    pub fn new(matrix: Mat4) -> Self {
        let rows = matrix.transpose();
        Self([
            rows.w_axis + rows.x_axis,
            rows.w_axis - rows.x_axis,
            rows.w_axis + rows.y_axis,
            rows.w_axis - rows.y_axis,
            rows.z_axis,
            rows.w_axis - rows.z_axis,
        ])
    }

    pub fn intersects_chunk(&self, key: [i32; 3]) -> bool {
        let low = key.map(|c| c as f32 * 16.0);
        self.intersects_box(low, low.map(|v| v + 16.0))
    }

    pub fn intersects_box(&self, low: [f32; 3], high: [f32; 3]) -> bool {
        self.0.iter().all(|plane| {
            let normal = plane.truncate();
            let corner = glam::Vec3::from_array(std::array::from_fn(|i| {
                if normal[i] >= 0.0 { high[i] } else { low[i] }
            }));
            // Keep uncertain boundary boxes, including at large coordinates.
            let error = (normal.abs().dot(corner.abs()) + plane.w.abs()) * f32::EPSILON * 8.0;
            (normal.dot(corner) + plane.w).partial_cmp(&-error) != Some(std::cmp::Ordering::Less)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use glam::{Mat4, Vec3};

    fn view(eye: Vec3) -> Mat4 {
        Mat4::perspective_rh(70f32.to_radians(), 16.0 / 9.0, 0.05, 512.0)
            * Mat4::look_to_rh(eye, Vec3::NEG_Z, Vec3::Y)
    }

    #[test]
    fn rejects_behind_and_far_chunks_but_keeps_intersections_and_negative_edges() {
        let frustum = Frustum::new(view(Vec3::new(0.0, 8.0, 0.0)));
        assert!(frustum.intersects_chunk([0, 0, -1]));
        assert!(frustum.intersects_chunk([-1, 0, -1]));
        assert!(frustum.intersects_chunk([0, 0, -32]));
        assert!(!frustum.intersects_chunk([0, 0, 1]));
        assert!(!frustum.intersects_chunk([0, 0, -34]));
        assert!(!frustum.intersects_chunk([100, 0, -1]));
        assert!(Frustum::new(view(Vec3::new(-16.0, 8.0, -16.0))).intersects_chunk([-1, 0, -2]));
    }

    #[test]
    fn every_projected_inside_sample_has_a_visible_chunk_at_large_coordinates() {
        for eye in [
            Vec3::new(0.0, 8.0, 0.0),
            Vec3::new(-999_000.0, 104.0, 998_000.0),
        ] {
            let matrix = view(eye);
            let frustum = Frustum::new(matrix);
            for z in [-0.1, -16.0, -100.0, -511.0] {
                for x in [-0.01, 0.0, 0.01] {
                    let point = eye + Vec3::new(x, 0.0, z);
                    let clip = matrix * point.extend(1.0);
                    if clip.z >= 0.0
                        && clip.z <= clip.w
                        && clip.x.abs() <= clip.w
                        && clip.y.abs() <= clip.w
                    {
                        let key = point.to_array().map(|v| (v.floor() as i32).div_euclid(16));
                        assert!(frustum.intersects_chunk(key), "visible point {point:?}");
                    }
                }
            }
        }
    }
}
