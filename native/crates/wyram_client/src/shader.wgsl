struct Camera {
  view_projection: mat4x4<f32>,
  eye: vec4<f32>,
  // x = contiguous ready radius in blocks; y = enabled; z = protected near radius;
  // w = elapsed time in seconds.
  fog: vec4<f32>,
  // x/z = chunk origin, z = side length, w = center chunk x.
  grid: vec4<i32>,
  // x = center chunk z, y = protected near radius, z = first vertical chunk;
  // w = fog bypass.
  anchor: vec4<i32>,
};

@group(0) @binding(0) var<uniform> camera: Camera;
// xyz carry float bits for current/previous detail and fade time; w is a
// 32-bit near-chunk residency mask. Integer storage preserves every mask bit.
@group(0) @binding(1) var<storage, read> lod_columns: array<vec4<u32>>;

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

fn column_at(world_position: vec3<f32>) -> vec4<u32> {
  let chunk = vec2<i32>(floor(world_position.xz / 16.0));
  let relative = chunk - camera.grid.xy;
  if (relative.x < 0 || relative.y < 0 || relative.x >= camera.grid.z || relative.y >= camera.grid.z) {
    return vec4<u32>(0u);
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

fn layer_accepts(column: vec4<u32>, lod_size: u32, world_position: vec3<f32>, threshold: f32) -> bool {
  let y = i32(floor(world_position.y / 16.0)) - camera.anchor.z;
  let near_ready = y >= 0 && y < 32 && (column.w & (1u << u32(clamp(y, 0, 31)))) != 0u;
  let current_size = u32(round(bitcast<f32>(column.x)));
  let previous_size = u32(round(bitcast<f32>(column.y)));
  if (protected_column(world_position)) {
    // Resident near meshes draw immediately, including before the first mask.
    if (near_ready || camera.grid.z == 0) { return lod_size == 1u; }
    // Keep the prior published representation until this vertical chunk arrives.
    if (lod_size == 1u) { return false; }
  }
  if (current_size == 0u) {
    return false;
  }
  if (lod_size == current_size) {
    if (current_size == previous_size) {
      return true;
    }
    return threshold < clamp((camera.fog.w - bitcast<f32>(column.z)) / 0.2, 0.0, 1.0);
  }
  if (previous_size != 0u && lod_size == previous_size && previous_size != current_size) {
    return threshold >= clamp((camera.fog.w - bitcast<f32>(column.z)) / 0.2, 0.0, 1.0);
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

fn surface_owner(position: vec3<f32>, dx: vec3<f32>, dy: vec3<f32>, front_facing: bool) -> vec3<f32> {
  // Orient the derivative normal using the rasterizer's winding convention.
  // Sample just inside the cell owning the face, including vertical boundaries.
  let normal = normalize(cross(dx, dy));
  let outward = select(normal, -normal, front_facing);
  return position - outward * 0.001;
}

@fragment fn fs_main(input: Output, @builtin(front_facing) front_facing: bool) -> @location(0) vec4<f32> {
  let dx = dpdx(input.world_position);
  let dy = dpdy(input.world_position);
  if (input.source != 2u && camera.fog.y > 0.5) {
    // Screen-anchored threshold is identical for coincident old/new transparent faces.
    let threshold = hash_threshold(vec3<f32>(input.position.xy, 0.0));
    let owner = surface_owner(input.world_position, dx, dy, front_facing);
    if (!layer_accepts(column_at(owner), input.lod_size, owner, threshold)) {
      discard;
    }
  }
  var color = input.color;
  if (input.source != 2u && camera.fog.y > 0.5 && camera.anchor.w == 0 && !protected_column(input.world_position)) {
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
