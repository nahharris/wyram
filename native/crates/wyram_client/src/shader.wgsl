struct Camera {
  view_projection: mat4x4<f32>,
  eye: vec4<f32>,
  // x = contiguous ready radius in blocks; y = enabled; z = protected near radius;
  // w = elapsed time in seconds.
  fog: vec4<f32>,
  // x/z = chunk origin, z = side length, w = center chunk x.
  grid: vec4<i32>,
  // x = center chunk z, y = protected near radius, z = max LOD cell size.
  anchor: vec4<i32>,
};

@group(0) @binding(0) var<uniform> camera: Camera;
@group(0) @binding(1) var<storage, read> lod_columns: array<vec4<f32>>;

struct NearInput {
  @location(0) position: vec3<f32>,
  @location(1) color: vec3<f32>,
  @location(2) opacity: f32,
}

struct LodInput {
  @location(0) position: vec3<f32>,
  @location(1) color: vec3<f32>,
  @location(2) opacity: f32,
  @location(3) lod_size: f32,
}

struct Output {
  @builtin(position) position: vec4<f32>,
  @location(0) color: vec4<f32>,
  @location(1) world_position: vec3<f32>,
  @location(2) @interpolate(flat) lod_size: u32,
  @location(3) @interpolate(flat) source: u32,
}

fn make_output(position: vec3<f32>, color: vec3<f32>, opacity: f32, lod_size: u32, source: u32) -> Output {
  var output: Output;
  output.position = camera.view_projection * vec4<f32>(position, 1.0);
  output.color = vec4<f32>(color, opacity);
  output.world_position = position;
  output.lod_size = lod_size;
  output.source = source;
  return output;
}

@vertex fn vs_main(input: NearInput) -> Output {
  return make_output(input.position, input.color, input.opacity, 1u, 0u);
}

@vertex fn vs_lod(input: LodInput) -> Output {
  return make_output(input.position, input.color, input.opacity, u32(round(input.lod_size)), 1u);
}

@vertex fn vs_character(input: NearInput) -> Output {
  return make_output(input.position, input.color, input.opacity, 0u, 2u);
}

fn column_at(world_position: vec3<f32>) -> vec4<f32> {
  let chunk = vec2<i32>(floor(world_position.xz / 16.0));
  let relative = chunk - camera.grid.xy;
  if (relative.x < 0 || relative.y < 0 || relative.x >= camera.grid.z || relative.y >= camera.grid.z) {
    return vec4<f32>(0.0);
  }
  let index = u32(relative.y * camera.grid.z + relative.x);
  return lod_columns[index];
}

fn protected_column(world_position: vec3<f32>) -> bool {
  let chunk_center = floor(world_position.xz / 16.0) + vec2<f32>(0.5);
  let center = vec2<f32>(f32(camera.grid.w), f32(camera.anchor.x)) + vec2<f32>(0.5);
  let delta = chunk_center - center;
  let radius = f32(camera.anchor.y);
  return dot(delta, delta) <= radius * radius;
}

fn layer_accepts(column: vec4<f32>, lod_size: u32, world_position: vec3<f32>, threshold: f32) -> bool {
  let readiness = u32(round(column.w));
  // The camera can cross a chunk boundary before the background coverage window
  // catches up. Full-detail prefetch is already GPU-resident and safe to reveal.
  if (protected_column(world_position)) {
    return lod_size == 1u && (readiness & 2u) != 0u;
  }
  if ((readiness & 1u) == 0u) {
    return false;
  }
  let current_size = u32(round(column.x));
  let previous_size = u32(round(column.y));
  if (lod_size == current_size) {
    if (current_size == previous_size) {
      return true;
    }
    return threshold < clamp((camera.fog.w - column.z) / 0.2, 0.0, 1.0);
  }
  if (previous_size != 0u && lod_size == previous_size && previous_size != current_size) {
    return threshold >= clamp((camera.fog.w - column.z) / 0.2, 0.0, 1.0);
  }
  return false;
}

fn hash_threshold(position: vec3<f32>) -> f32 {
  let q = vec3<i32>(floor(position * 8.0));
  var hash = bitcast<u32>(q.x) * 0x8da6b343u;
  hash = hash ^ (bitcast<u32>(q.y) * 0xd8163841u);
  hash = hash ^ (bitcast<u32>(q.z) * 0xcb1ab31fu);
  hash = hash ^ (hash >> 13u);
  hash = hash * 0x85ebca6bu;
  hash = hash ^ (hash >> 16u);
  return f32(hash & 0x00ffffffu) / 16777216.0;
}

fn is_integer_boundary(value: f32) -> bool {
  return abs(value / 16.0 - round(value / 16.0)) < 0.0001;
}

fn boundary_accepts(world_position: vec3<f32>, lod_size: u32, threshold: f32, derivatives_x: vec3<f32>, derivatives_y: vec3<f32>) -> bool {
  let direct = layer_accepts(column_at(world_position), lod_size, world_position, threshold);
  // A vertical wall exactly on a chunk edge belongs to the union of its two columns.
  // Evaluate both sides so closing near walls and their far counterpart remain covered.
  let vertical = abs(derivatives_x.y) + abs(derivatives_y.y) > 0.0001;
  if (!vertical) {
    return direct;
  }
  let x_face = abs(derivatives_x.x) + abs(derivatives_y.x) < 0.0001 && is_integer_boundary(world_position.x);
  let z_face = abs(derivatives_x.z) + abs(derivatives_y.z) < 0.0001 && is_integer_boundary(world_position.z);
  if (x_face) {
    let low = world_position - vec3<f32>(0.001, 0.0, 0.0);
    let high = world_position + vec3<f32>(0.001, 0.0, 0.0);
    return direct || layer_accepts(column_at(low), lod_size, low, threshold) || layer_accepts(column_at(high), lod_size, high, threshold);
  }
  if (z_face) {
    let low = world_position - vec3<f32>(0.0, 0.0, 0.001);
    let high = world_position + vec3<f32>(0.0, 0.0, 0.001);
    return direct || layer_accepts(column_at(low), lod_size, low, threshold) || layer_accepts(column_at(high), lod_size, high, threshold);
  }
  return direct;
}

@fragment fn fs_main(input: Output) -> @location(0) vec4<f32> {
  let dx = dpdx(input.world_position);
  let dy = dpdy(input.world_position);
  if (input.source != 2u && camera.fog.y > 0.5) {
    // Screen-anchored threshold is identical for coincident old/new transparent faces.
    let threshold = hash_threshold(vec3<f32>(input.position.xy, 0.0));
    if (!boundary_accepts(input.world_position, input.lod_size, threshold, dx, dy)) {
      discard;
    }
  }
  var color = input.color;
  if (input.source != 2u && camera.fog.y > 0.5 && camera.anchor.w == 0) {
    let center = vec2<f32>(f32(camera.grid.w), f32(camera.anchor.x)) * 16.0 + vec2<f32>(8.0);
    let distance = length(input.world_position.xz - center);
    let radius = max(camera.fog.x, 1.0);
    let fade_start = radius * 0.8;
    let fog_amount = smoothstep(fade_start, radius, distance);
    let sky = vec3<f32>(0.43, 0.65, 0.86);
    color = vec4<f32>(mix(color.rgb, sky, fog_amount), mix(color.a, 1.0, fog_amount));
  }
  return color;
}
