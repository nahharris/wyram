struct Camera { view_projection: mat4x4<f32> }
@group(0) @binding(0) var<uniform> camera: Camera;
struct Frame { origin: vec4<i32>, size: vec4<u32>, eye: vec4<f32>, fog: vec4<f32>, near_bounds: vec4<i32> }
@group(1) @binding(0) var<uniform> frame: Frame;
@group(1) @binding(1) var<storage, read> coverage: array<u32>;
struct Input {
  @location(0) position: vec3<f32>, @location(1) color: vec3<f32>,
  @location(2) opacity: f32, @location(3) normal: vec4<f32>,
}
struct Output {
  @builtin(position) position: vec4<f32>, @location(0) color: vec4<f32>,
  @location(1) world: vec3<f32>, @location(2) @interpolate(flat) normal: vec4<f32>,
}
@vertex fn vs_main(input: Input) -> Output {
  var output: Output;
  output.position = camera.view_projection * vec4<f32>(input.position, 1.0);
  output.color = vec4<f32>(input.color, input.opacity);
  output.world = input.position; output.normal = input.normal;
  return output;
}
@fragment fn fs_main(input: Output) -> @location(0) vec4<f32> {
  var color = input.color;
  if input.normal.w > 0.5 {
    // Full-detail residency owns these columns even before its meshes arrive.
    // Missing near geometry must not be replaced by a coarse solid proxy.
    let near_point = input.world.xz - input.normal.xz * 0.125;
    if all(near_point >= vec2<f32>(frame.near_bounds.xy)) &&
       all(near_point < vec2<f32>(frame.near_bounds.zw)) { discard; }
    let chunk = vec3<i32>(floor((input.world - input.normal.xyz * 0.125) / 16.0));
    let local = chunk - frame.origin.xyz;
    if all(local >= vec3<i32>(0)) && all(vec3<u32>(local) < frame.size.xyz) {
      let p = vec3<u32>(local);
      let bit = (p.y * frame.size.z + p.z) * frame.size.x + p.x;
      if (coverage[bit / 32u] & (1u << (bit % 32u))) != 0u { discard; }
    }
    let distance = length(input.world.xz - frame.eye.xz);
    if distance >= frame.eye.w { discard; }
    let fog = smoothstep(frame.fog.w, frame.eye.w, distance);
    color = vec4<f32>(mix(color.rgb, frame.fog.rgb, fog), color.a);
  }
  return color;
}
