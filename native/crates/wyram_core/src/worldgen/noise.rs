use super::Field;
pub fn hash(seed: u64, x: i32, y: i32, z: i32) -> u64 {
    let mut v = seed
        ^ (x as u32 as u64).wrapping_mul(0x9e3779b97f4a7c15)
        ^ (y as u32 as u64).wrapping_mul(0xd6e8feb86659fd93)
        ^ (z as u32 as u64).wrapping_mul(0xbf58476d1ce4e5b9);
    v ^= v >> 30;
    v = v.wrapping_mul(0xbf58476d1ce4e5b9);
    v ^= v >> 27;
    v = v.wrapping_mul(0x94d049bb133111eb);
    v ^ (v >> 31)
}
pub fn unit(v: u64) -> f64 {
    (v >> 11) as f64 / ((1u64 << 53) as f64)
}
fn fade(v: f64) -> f64 {
    v * v * v * (v * (v * 6.0 - 15.0) + 10.0)
}
fn mix(a: f64, b: f64, t: f64) -> f64 {
    a + (b - a) * t
}
fn value(seed: u64, p: [f64; 3]) -> f64 {
    let q = p.map(|v| v.floor() as i32);
    let t = std::array::from_fn::<_, 3, _>(|i| fade(p[i] - f64::from(q[i])));
    let corner = |x, y, z| unit(hash(seed, q[0] + x, q[1] + y, q[2] + z));
    mix(
        mix(
            mix(corner(0, 0, 0), corner(1, 0, 0), t[0]),
            mix(corner(0, 0, 1), corner(1, 0, 1), t[0]),
            t[2],
        ),
        mix(
            mix(corner(0, 1, 0), corner(1, 1, 0), t[0]),
            mix(corner(0, 1, 1), corner(1, 1, 1), t[0]),
            t[2],
        ),
        t[1],
    )
}
pub fn sample(seed: u64, field: Field, p: [f64; 3]) -> f64 {
    let mut scale = field.scale;
    let mut amplitude = 1.0;
    let mut sum = 0.0;
    let mut total = 0.0;
    for octave in 0..field.octaves {
        sum += value(
            seed ^ field.salt ^ u64::from(octave).wrapping_mul(0x517cc1b727220a95),
            p.map(|v| v / scale),
        ) * amplitude;
        total += amplitude;
        scale *= 0.5;
        amplitude *= 0.5;
    }
    sum / total
}
