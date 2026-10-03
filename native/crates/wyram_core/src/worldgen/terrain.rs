use super::{Field, Generator, noise};
fn smooth(value: f64) -> f64 {
    let t = value.clamp(0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}
pub fn height(g: &Generator, p: [f64; 3], broad: f64, inland: f64, erosion: f64) -> f64 {
    let t = g.settings.terrain;
    let plains = smooth((erosion - 0.35) / 0.2) * t.plains_strength;
    let rugged = inland * (1.0 - plains).powi(3);
    let detail = g.settings.fields[5];
    let fine = noise::sample(
        g.seed,
        Field {
            scale: (detail.scale * 0.25).max(16.0),
            salt: detail.salt ^ 0x524f5547,
            ..detail
        },
        p,
    ) * 2.0
        - 1.0;
    let valley = noise::sample(
        g.seed,
        Field {
            scale: (g.settings.fields[1].scale * 0.25).max(16.0),
            salt: g.settings.fields[1].salt ^ 0x56414c4c,
            ..g.settings.fields[1]
        },
        p,
    );
    let channel = (1.0 - (valley * 2.0 - 1.0).abs()).powi(8);
    let eroded = broad - channel * t.valley_depth * rugged;
    let step = f64::from(t.shelf_height);
    let level = (eroded / step).floor() * step;
    let phase = (eroded - level) / step;
    let shelf = level + step * smooth((phase - 0.25) / 0.5);
    let shaped = eroded + (shelf - eroded) * t.shelf_strength * inland;
    shaped + fine * t.roughness * inland * (0.08 + (1.0 - plains).powi(3) * 2.5)
}
