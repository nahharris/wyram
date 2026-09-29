struct Camera { view_projection: mat4x4<f32> }
@group(0) @binding(0) var<uniform> camera: Camera;

struct Input {
  @location(0) position: vec3<f32>,
  @location(1) color: vec3<f32>,
}

struct Output {
  @builtin(position) position: vec4<f32>,
  @location(0) color: vec3<f32>,
}

@vertex fn vs_main(input: Input) -> Output {
  var output: Output;
  output.position = camera.view_projection * vec4<f32>(input.position, 1.0);
  output.color = input.color;
  return output;
}

@fragment fn fs_main(input: Output) -> @location(0) vec4<f32> {
  return vec4<f32>(input.color, 1.0);
}
